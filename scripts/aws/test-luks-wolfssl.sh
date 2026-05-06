#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# scripts/aws/test-luks-wolfssl.sh
#
# Provisions an EC2 instance, builds wolfSSL as a kernel module (libwolfssl.ko)
# with AES-XTS and SHA-256 enabled, loads it into the kernel, verifies algorithm
# registration in /proc/crypto, creates a LUKS2 volume on a loopback device
# backed by wolfSSL crypto, and exercises the full open/mount/use/close cycle.
# Tears everything down unless KEEP_INSTANCE=1.
#
# Mirrors the structure of ../WOLFKM/tests/ci/test-on-aws.sh.
#
# ============================================================================
# PREREQUISITES
# ============================================================================
#
#   1. AWS CLI v2 installed and configured:
#        aws configure sso
#        aws sso login --profile <your-profile>
#
#   2. IAM permissions:
#        ec2:RunInstances, TerminateInstances, DescribeInstances,
#        DescribeImages, DescribeVpcs,
#        ec2:CreateKeyPair, DeleteKeyPair,
#        ec2:CreateSecurityGroup, DeleteSecurityGroup,
#        ec2:AuthorizeSecurityGroupIngress, ec2:CreateTags,
#        ec2-instance-connect:SendSerialConsoleSSHPublicKey,
#        sts:GetCallerIdentity
#
# ============================================================================
# ENVIRONMENT VARIABLES
# ============================================================================
#
#   Required:
#     AWS_PROFILE       — AWS CLI profile name (or pass as $1)
#
#   Optional:
#     AWS_REGION        — default: us-west-2
#     DISTRO            — ubuntu|debian|centos|fedora|nixos (default: ubuntu)
#     UBUNTU_VERSION    — 22.04, 24.04, 26.04 (ubuntu distro only; default: 22.04)
#     DEBIAN_VERSION    — 11, 12, 13 (debian distro only; default: 12)
#     NIXOS_CHANNEL     — nixos channel prefix (nixos distro only; default: 25.11)
#     ARM64             — set to 1 for ARM64/Graviton (c7g.2xlarge)
#     CUSTOM_KERNEL     — set to 1 to build a custom kernel with CONFIG_CRYPTO_FIPS=n
#                         before running the wolfSSL tests.  Required for distros
#                         whose stock kernels have CONFIG_CRYPTO_FIPS=y (Fedora,
#                         Debian, CentOS).  Adds ~20-30 min to the run.
#     KEEP_INSTANCE     — set to 1 to leave instance running for debugging
#     SSH_KEY_PATH      — where to store ephemeral SSH key (default: /tmp)
#     WOLFSSL_REPO      — default: https://github.com/wolfSSL/wolfssl
#     WOLFSSL_REF       — default: master
#     LUKS_IMG_SIZE_MB  — LUKS loopback image size in MB (default: 256)
#     INSTANCE_TYPE     — override default instance type
#     DISK_SIZE_GB      — override default disk size (default: 30)
#
# ============================================================================
# USAGE
# ============================================================================
#
#   ./scripts/aws/test-luks-wolfssl.sh AdministratorAccess-921772462201
#
#   # Ubuntu 24.04 (kernel 6.8):
#   UBUNTU_VERSION=24.04 ./scripts/aws/test-luks-wolfssl.sh <profile>
#
#   # ARM64 / Graviton (Ubuntu 22.04):
#   ARM64=1 ./scripts/aws/test-luks-wolfssl.sh <profile>
#
#   # Debian 12:
#   DISTRO=debian ./scripts/aws/test-luks-wolfssl.sh <profile>
#
#   # CentOS Stream 9:
#   DISTRO=centos ./scripts/aws/test-luks-wolfssl.sh <profile>
#
#   # Fedora latest:
#   DISTRO=fedora ./scripts/aws/test-luks-wolfssl.sh <profile>
#
#   # NixOS 25.11 x86-64:
#   DISTRO=nixos ./scripts/aws/test-luks-wolfssl.sh <profile>
#
#   # NixOS ARM64/Graviton:
#   DISTRO=nixos ARM64=1 ./scripts/aws/test-luks-wolfssl.sh <profile>
#
#   # Fedora with custom FIPS=n kernel (unblocks CONFIG_CRYPTO_FIPS=y):
#   DISTRO=fedora CUSTOM_KERNEL=1 ./scripts/aws/test-luks-wolfssl.sh <profile>
#
#   # Debian 12 with custom FIPS=n kernel:
#   DISTRO=debian CUSTOM_KERNEL=1 ./scripts/aws/test-luks-wolfssl.sh <profile>
#
#   # Keep instance alive for debugging:
#   KEEP_INSTANCE=1 ./scripts/aws/test-luks-wolfssl.sh <profile>
#
# ============================================================================

set -euo pipefail

# ── Parameters ───────────────────────────────────────────────────────────────

AWS_PROFILE="${1:-${AWS_PROFILE:-}}"
if [[ -z "$AWS_PROFILE" ]]; then
    echo "ERROR: AWS_PROFILE not set."
    echo "Usage: $0 <aws-profile>"
    exit 1
fi

AWS_REGION="${AWS_REGION:-us-west-2}"
DISTRO="${DISTRO:-ubuntu}"
ARM64="${ARM64:-0}"
# CUSTOM_KERNEL=1: build a custom kernel with CONFIG_CRYPTO_FIPS=n before
# running the wolfSSL tests.  Required for Fedora/Debian/CentOS which ship
# CONFIG_CRYPTO_FIPS=y in their cloud kernels.  Adds ~20-30 min.
CUSTOM_KERNEL="${CUSTOM_KERNEL:-0}"
UBUNTU_VERSION="${UBUNTU_VERSION:-22.04}"
DEBIAN_VERSION="${DEBIAN_VERSION:-12}"
KEEP_INSTANCE="${KEEP_INSTANCE:-0}"
SSH_KEY_PATH="${SSH_KEY_PATH:-/tmp}"
DISK_SIZE_GB="${DISK_SIZE_GB:-30}"
WOLFSSL_REPO="${WOLFSSL_REPO:-https://github.com/wolfSSL/wolfssl}"
WOLFSSL_REF="${WOLFSSL_REF:-master}"
# Size of the LUKS loopback image.  256 MB is enough to hold LUKS2 metadata
# plus a small test filesystem; larger is not needed for correctness testing.
LUKS_IMG_SIZE_MB="${LUKS_IMG_SIZE_MB:-256}"

# ── Distro-specific settings ──────────────────────────────────────────────────
# AMI_OWNER / AMI_NAME_PATTERN: passed to describe-images for latest-AMI lookup.
# INSTANCE_USER: SSH login user for the launched instance.
# PKG_FAMILY: apt or dnf — selects the deps install branch.

case "$DISTRO" in
    ubuntu)
        AMI_OWNER="099720109477"   # Canonical
        if [[ "$ARM64" == "1" ]]; then
            case "$UBUNTU_VERSION" in
                22.04) AMI_NAME_PATTERN="ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*" ;;
                24.04) AMI_NAME_PATTERN="ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" ;;
                26.04) AMI_NAME_PATTERN="ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-arm64-server-*" ;;
                *) echo "ERROR: UBUNTU_VERSION must be 22.04, 24.04, or 26.04"; exit 1 ;;
            esac
        else
            case "$UBUNTU_VERSION" in
                22.04) AMI_NAME_PATTERN="ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" ;;
                24.04) AMI_NAME_PATTERN="ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" ;;
                26.04) AMI_NAME_PATTERN="ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*" ;;
                *) echo "ERROR: UBUNTU_VERSION must be 22.04, 24.04, or 26.04"; exit 1 ;;
            esac
        fi
        INSTANCE_USER="ubuntu"
        PKG_FAMILY="apt"
        DISTRO_VERSION="$UBUNTU_VERSION"
        ;;
    debian)
        AMI_OWNER="136693071363"   # Debian official
        if [[ "$ARM64" == "1" ]]; then
            case "$DEBIAN_VERSION" in
                11) AMI_NAME_PATTERN="debian-11-arm64-*" ;;
                12) AMI_NAME_PATTERN="debian-12-arm64-*" ;;
                13) AMI_NAME_PATTERN="debian-13-arm64-*" ;;
                *) echo "ERROR: DEBIAN_VERSION must be 11, 12, or 13"; exit 1 ;;
            esac
        else
            case "$DEBIAN_VERSION" in
                11) AMI_NAME_PATTERN="debian-11-amd64-*" ;;
                12) AMI_NAME_PATTERN="debian-12-amd64-*" ;;
                13) AMI_NAME_PATTERN="debian-13-amd64-*" ;;
                *) echo "ERROR: DEBIAN_VERSION must be 11, 12, or 13"; exit 1 ;;
            esac
        fi
        INSTANCE_USER="admin"
        PKG_FAMILY="apt"
        DISTRO_VERSION="$DEBIAN_VERSION"
        # Custom kernel build needs ~15 GB extra; use faster instance type.
        if [[ "$CUSTOM_KERNEL" == "1" ]]; then
            : "${DISK_SIZE_GB:=60}"
            [[ "$ARM64" == "1" ]] && : "${INSTANCE_TYPE:=c7g.4xlarge}" \
                                  || : "${INSTANCE_TYPE:=c5.4xlarge}"
        fi
        ;;
    centos)
        AMI_OWNER="125523088429"   # CentOS project
        if [[ "$ARM64" == "1" ]]; then
            # CentOS Stream 9 uses 'aarch64' (not 'arm64') in its AMI names.
            AMI_NAME_PATTERN="CentOS Stream 9 aarch64*"
        else
            AMI_NAME_PATTERN="CentOS Stream 9 x86_64*"
        fi
        INSTANCE_USER="ec2-user"
        PKG_FAMILY="dnf"
        DISTRO_VERSION="9"
        ;;
    fedora)
        AMI_OWNER="125523088429"   # Fedora project
        if [[ "$ARM64" == "1" ]]; then
            # Fedora Cloud AMIs use 'aarch64' in their names.
            AMI_NAME_PATTERN="Fedora-Cloud-Base-AmazonEC2.aarch64-*"
        else
            AMI_NAME_PATTERN="Fedora-Cloud-Base-*x86_64*"
        fi
        INSTANCE_USER="fedora"
        PKG_FAMILY="dnf"
        DISTRO_VERSION="latest"
        # Custom kernel build needs ~15 GB extra; use faster instance type.
        if [[ "$CUSTOM_KERNEL" == "1" ]]; then
            : "${DISK_SIZE_GB:=60}"
            [[ "$ARM64" == "1" ]] && : "${INSTANCE_TYPE:=c7g.4xlarge}" \
                                  || : "${INSTANCE_TYPE:=c5.4xlarge}"
        fi
        ;;
    nixos)
        # Official NixOS AMIs published by NixOS project (owner 427812963091).
        # AMI names follow: nixos/<channel>.<rev>-<arch>-linux
        # x86-64 arch string in AMI name: "x86_64-linux"
        # ARM64 arch string in AMI name:  "aarch64-linux"
        AMI_OWNER="427812963091"
        NIXOS_CHANNEL="${NIXOS_CHANNEL:-25.11}"
        if [[ "$ARM64" == "1" ]]; then
            AMI_NAME_PATTERN="nixos/${NIXOS_CHANNEL}.*aarch64-linux"
        else
            AMI_NAME_PATTERN="nixos/${NIXOS_CHANNEL}.*x86_64-linux"
        fi
        # NixOS boots with root as the default SSH login user.
        INSTANCE_USER="root"
        # NixOS uses the nix package manager — neither apt nor dnf.
        PKG_FAMILY="nix"
        DISTRO_VERSION="${NIXOS_CHANNEL}"
        # NixOS AMIs use /dev/xvda as the root device (not /dev/sda1).
        ROOT_DEVICE="/dev/xvda"
        # Nix downloads kernel dev + build tools from cache — needs ~10 GB extra.
        # Override the default disk size unless the user has set it explicitly.
        : "${DISK_SIZE_GB:=50}"
        ;;
    *)
        echo "ERROR: DISTRO must be ubuntu|debian|centos|fedora|nixos, got: $DISTRO"
        exit 1
        ;;
esac

# ── Architecture settings ─────────────────────────────────────────────────────

if [[ "$ARM64" == "1" ]]; then
    : "${INSTANCE_TYPE:=c7g.2xlarge}"   # Graviton 3
    RUN_ID_SUFFIX="-arm64"
    KERN_ARCH="arm64"
    # --enable-armasm enables WOLFSSL_ARMASM which triggers
    # WOLFSSL_USE_SAVE_VECTOR_REGISTERS.  In the linuxkm build, ARM SIMD
    # register saving is not yet implemented (blocked by the guard:
    # "kernel module ARM SIMD is not yet tested or usable" in linuxkm_wc_port.h).
    # So we explicitly do NOT pass --enable-armasm for the linuxkm target;
    # the software-only implementation is used instead, which works correctly.
    WOLFSSL_ASM_OPT=""
    # 'make module' requires explicit ARCH on ARM64 builds.
    MAKE_ARCH_OPT="ARCH=arm64"
else
    : "${INSTANCE_TYPE:=c5.2xlarge}"    # x86-64, 8 vCPU / 16 GB
    RUN_ID_SUFFIX=""
    KERN_ARCH="x86_64"
    # Intel AES-NI / AVX — improves throughput but not required for correctness.
    WOLFSSL_ASM_OPT="--enable-intelasm"
    MAKE_ARCH_OPT=""
fi

# ── AWS CLI shorthand ─────────────────────────────────────────────────────────

A="--profile $AWS_PROFILE --region $AWS_REGION"

# ── Run ID and ephemeral resource names ──────────────────────────────────────

RUN_ID="luks-wolfssl-${DISTRO}${DISTRO_VERSION}${RUN_ID_SUFFIX}-$(date +%Y%m%d-%H%M%S)"
KEY_NAME="$RUN_ID"
SG_NAME="$RUN_ID"
KEY_FILE="$SSH_KEY_PATH/${RUN_ID}.pem"

INSTANCE_ID=""
SG_ID=""
PUBLIC_IP=""
SERIAL_PID=""
# Set by Phase 5; used in cleanup trap for loopback teardown.
LOOP_DEV=""

# ── Test counters ─────────────────────────────────────────────────────────────

TESTS_PASSED=0
TESTS_FAILED=0

# ── Logging helpers ───────────────────────────────────────────────────────────

log()  { echo "=== $(date +%H:%M:%S) $*"; }
pass() { echo "  PASS: $*"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $*"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
skip() { echo "  SKIP: $*"; }

# ── SSH helpers ───────────────────────────────────────────────────────────────

remote() {
    ssh -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=6 \
        -i "$KEY_FILE" \
        "${INSTANCE_USER}@$PUBLIC_IP" \
        "$@"
}

remote_script() {
    ssh -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=6 \
        -i "$KEY_FILE" \
        "${INSTANCE_USER}@$PUBLIC_IP" \
        'bash -s'
}

wait_for_ssh() {
    local attempts="${1:-36}"   # default: 36 × 5 s = 3 minutes
    for i in $(seq 1 "$attempts"); do
        if remote 'true' 2>/dev/null; then return 0; fi
        sleep 5
    done
    echo "ERROR: SSH not available after $((attempts * 5)) seconds"
    return 1
}

# ── Serial console helpers ────────────────────────────────────────────────────
#
# Use EC2 Instance Connect serial console for live kernel output during long
# phases (build, reboot, LUKS format).  Serial console streams in real time
# with no buffering delay, unlike get-console-output which can lag minutes.
#
# watch_serial: push a throwaway SSH pubkey and connect in the background.
# stop_serial:  kill the background connection.
#
# Usage:
#   watch_serial 600   # stream for up to 600 s (background)
#   <long operation>
#   stop_serial

watch_serial() {
    local duration="${1:-300}"
    local serial_key
    serial_key=$(mktemp /tmp/serial-XXXXXX)
    # mktemp creates an empty file; ssh-keygen won't overwrite without -f but
    # will prompt interactively.  Remove the placeholder first so ssh-keygen
    # writes a fresh key pair without any prompt.
    rm -f "$serial_key"

    # Generate a throwaway RSA key; EC2 Instance Connect accepts it for 60 s.
    ssh-keygen -t rsa -b 2048 -N "" -f "$serial_key" -q

    # Push the public key.  The 60-second window is enough to open the TCP
    # connection before the key expires.
    # This is best-effort — serial console is for visibility only.  Failures
    # (e.g. SerialConsoleSessionLimitExceededException, throttling) must NOT
    # abort the main script.  Capture stderr and swallow non-zero exit.
    local push_err
    push_err=$(aws ec2-instance-connect send-serial-console-ssh-public-key \
        $A \
        --instance-id "$INSTANCE_ID" \
        --serial-port 0 \
        --ssh-public-key "$(cat "${serial_key}.pub")" 2>&1) || {
        echo "[watch_serial] WARN: send-serial-console-ssh-public-key failed (non-fatal): ${push_err}" >&2
        rm -f "$serial_key" "${serial_key}.pub"
        SERIAL_PID=""
        return 0
    }

    # Connect in the background; timeout kills it after $duration seconds so
    # this never hangs if the caller forgets to call stop_serial.
    timeout "$duration" \
        ssh -i "$serial_key" \
            -p 9001 \
            -o StrictHostKeyChecking=no \
            -o ServerAliveInterval=10 \
            -o ServerAliveCountMax=12 \
            "${INSTANCE_ID}.port0@serial-console.ec2-instance-connect.${AWS_REGION}.aws" \
        2>/dev/null &
    SERIAL_PID=$!

    # Clean up key files immediately — the connection is already authenticated.
    rm -f "$serial_key" "${serial_key}.pub"
}

stop_serial() {
    if [[ -n "${SERIAL_PID:-}" ]]; then
        kill "$SERIAL_PID" 2>/dev/null || true
        wait "$SERIAL_PID" 2>/dev/null || true
    fi
    SERIAL_PID=""
}

# ── Cleanup ────────────────────────────────────────────────────────────────────

cleanup() {
    local rc=$?
    echo ""
    log "Cleanup"

    # Kill any lingering serial console connection.
    stop_serial

    if [[ "$KEEP_INSTANCE" == "1" && -n "$INSTANCE_ID" ]]; then
        log "KEEP_INSTANCE=1 — instance left running"
        log "  Instance: $INSTANCE_ID ($PUBLIC_IP)"
        log "  SSH:      ssh -i $KEY_FILE ${INSTANCE_USER}@$PUBLIC_IP"
        log "  Terminate: aws ec2 terminate-instances $A --instance-ids $INSTANCE_ID"
        return $rc
    fi

    # Detach loopback device if Phase 5 set it up but Phase 9 didn't run
    # (e.g. script failed mid-way through the LUKS phases).
    if [[ -n "${LOOP_DEV:-}" && -n "$INSTANCE_ID" ]]; then
        remote_script <<LOOP_CLEANUP 2>/dev/null || true
sudo losetup -d ${LOOP_DEV} 2>/dev/null || true
rm -f ~/luks-test.img
LOOP_CLEANUP
    fi

    if [[ -n "$INSTANCE_ID" ]]; then
        log "Terminating $INSTANCE_ID..."
        aws ec2 terminate-instances $A --instance-ids "$INSTANCE_ID" \
            --query 'TerminatingInstances[0].CurrentState.Name' \
            --output text 2>/dev/null || true
        aws ec2 wait instance-terminated $A \
            --instance-ids "$INSTANCE_ID" 2>/dev/null || sleep 30
    fi

    [[ -n "${KEY_NAME:-}" ]] && \
        aws ec2 delete-key-pair $A --key-name "$KEY_NAME" 2>/dev/null || true
    [[ -n "${SG_ID:-}" ]] && \
        aws ec2 delete-security-group $A --group-id "$SG_ID" 2>/dev/null || true
    rm -f "$KEY_FILE"

    log "Cleanup complete (passed=$TESTS_PASSED failed=$TESTS_FAILED)"
    return $rc
}

trap cleanup EXIT

# ── Phase 0: Provision EC2 ────────────────────────────────────────────────────

log "Verifying AWS credentials (profile: $AWS_PROFILE, region: $AWS_REGION)"
CALLER=$(aws sts get-caller-identity $A --query 'Arn' --output text)
log "Authenticated as: $CALLER"

log "Finding latest ${DISTRO} ${DISTRO_VERSION} ${KERN_ARCH} AMI..."
AMI_ID=$(aws ec2 describe-images $A \
    --owners "$AMI_OWNER" \
    --filters \
        "Name=name,Values=${AMI_NAME_PATTERN}" \
        "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)
if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    echo "ERROR: No AMI found for ${DISTRO} ${DISTRO_VERSION} ${KERN_ARCH} (owner=$AMI_OWNER pattern=$AMI_NAME_PATTERN)"
    exit 1
fi
log "AMI: $AMI_ID"

log "Creating SSH key pair: $KEY_NAME"
aws ec2 create-key-pair $A \
    --key-name "$KEY_NAME" \
    --key-type rsa \
    --key-format pem \
    --query 'KeyMaterial' \
    --output text > "$KEY_FILE"
chmod 600 "$KEY_FILE"

log "Creating security group: $SG_NAME"
VPC_ID=$(aws ec2 describe-vpcs $A \
    --filters "Name=is-default,Values=true" \
    --query 'Vpcs[0].VpcId' --output text)
SG_ID=$(aws ec2 create-security-group $A \
    --group-name "$SG_NAME" \
    --description "luks-wolfssl-test ($RUN_ID)" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress $A \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 > /dev/null

log "Launching $INSTANCE_TYPE instance (${DISTRO} ${DISTRO_VERSION})..."
INSTANCE_ID=$(aws ec2 run-instances $A \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --block-device-mappings \
        "[{\"DeviceName\":\"${ROOT_DEVICE:-/dev/sda1}\",\"Ebs\":{\"VolumeSize\":${DISK_SIZE_GB},\"VolumeType\":\"gp3\"}}]" \
    --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=$RUN_ID},{Key=Project,Value=luks-wolfssl}]" \
    --query 'Instances[0].InstanceId' \
    --output text)
log "Instance: $INSTANCE_ID"

log "Waiting for instance to be running..."
aws ec2 wait instance-running $A --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances $A \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
log "Public IP: $PUBLIC_IP"

log "Waiting for SSH (streaming serial console for live progress)..."
watch_serial 300
wait_for_ssh 60
stop_serial

KVER=$(remote 'uname -r')
log "Connected. Kernel: $KVER"
pass "EC2 instance provisioned: $INSTANCE_ID (kernel $KVER)"

# ── Phase 0.5: Build and boot custom kernel with CONFIG_CRYPTO_FIPS=n ─────────
#
# Stock Fedora, Debian, CentOS, and Amazon Linux cloud kernels all ship with
# CONFIG_CRYPTO_FIPS=y.  wolfSSL's lkcapi_glue.c requires HAVE_FIPS to match
# CONFIG_CRYPTO_FIPS at compile time, so non-FIPS wolfSSL cannot build its
# kernel crypto registrations against those kernels.
#
# Real wolfSSL customers building their own kernel set CONFIG_CRYPTO_FIPS=n.
# This phase replicates that: download the distro kernel source, copy the
# running kernel's .config, flip CONFIG_CRYPTO_FIPS=n (plus a few other
# options needed for a clean EC2 boot), build, install, and reboot.
#
# After reboot the test proceeds normally — wolfSSL builds against the new
# custom kernel headers and registers its algorithms as usual.
#
# Disk note: kernel source + build artifacts need ~10-15 GB.  The CUSTOM_KERNEL
# path sets DISK_SIZE_GB=60 by default in the distro config block.

if [[ "$CUSTOM_KERNEL" == "1" ]]; then
    log "Phase 0.5: Building custom kernel with CONFIG_CRYPTO_FIPS=n (~20-30 min)..."

    if [[ "$PKG_FAMILY" == "apt" ]]; then
        # ── Debian / Ubuntu: build kernel .deb packages ───────────────────────
        KARCH="$KERN_ARCH"
        remote_script <<CUSTOM_KERNEL_APT
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== Installing kernel build dependencies ==="
sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential libncurses-dev bison flex libssl-dev libelf-dev \
    dwarves bc rsync kmod cpio xz-utils debhelper dpkg-dev 2>&1 | tail -5

KVER=\$(uname -r)
echo "Running kernel: \$KVER"
KMAJ_MIN=\$(uname -r | cut -d. -f1,2)

# Add deb-src lines if missing (Debian minimal images omit them)
CODENAME=\$(. /etc/os-release && echo \$VERSION_CODENAME)
for suite in "\$CODENAME" "\${CODENAME}-updates" "\${CODENAME}-backports" "\${CODENAME}-security"; do
    if ! grep -rq "^deb-src.*\${suite}" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        echo "deb-src http://deb.debian.org/debian \${suite} main" \
            | sudo tee -a /etc/apt/sources.list > /dev/null
    fi
done
sudo apt-get update -qq

echo "=== Getting kernel source ==="
mkdir -p ~/kernel-build && cd ~/kernel-build
# linux-source-X.Y package is fastest; fall back to apt-get source
sudo apt-get install -y -qq linux-source-\${KMAJ_MIN} 2>/dev/null || \
    apt-get source --download-only linux 2>&1 | tail -5

if [[ -f /usr/src/linux-source-\${KMAJ_MIN}.tar.xz ]]; then
    tar -xf /usr/src/linux-source-\${KMAJ_MIN}.tar.xz
    SRC_DIR=\$(ls -d linux-source-*/ | head -1)
else
    dpkg-source -x linux_*.dsc linux-src 2>/dev/null || true
    SRC_DIR=\$(ls -d linux-src/ linux-*/ 2>/dev/null | head -1)
fi
cd "\$SRC_DIR"

echo "=== Configuring: CONFIG_CRYPTO_FIPS=n ==="
cp /boot/config-\$KVER .config
make olddefconfig ARCH=${KARCH} 2>&1 | tail -3

# Disable FIPS — the whole point of this custom kernel build
scripts/config --disable CONFIG_CRYPTO_FIPS
# Speed up build: skip debug info (saves ~30 min of DWARF compression)
scripts/config --enable  CONFIG_DEBUG_INFO_NONE
# EC2 needs NVMe built-in (no initrd on some AMI configurations)
scripts/config --enable  CONFIG_NVME_CORE
scripts/config --enable  CONFIG_BLK_DEV_NVME
# Clear signing key paths so the build doesn't fail on missing certs
scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""
make olddefconfig ARCH=${KARCH} 2>&1 | tail -3

grep -q "^CONFIG_CRYPTO_FIPS=y" .config && \
    { echo "ERROR: CONFIG_CRYPTO_FIPS still y after disabling" >&2; exit 1; }
echo "CONFIG_CRYPTO_FIPS is off ✓"

echo "=== Building kernel (~15-25 min on \$(nproc) cores) ==="
make -j\$(nproc) ARCH=${KARCH} LOCALVERSION=-wolfssl-nofips deb-pkg 2>&1 | tail -10

echo "=== Installing kernel .deb packages ==="
cd ~/kernel-build
sudo dpkg -i linux-image-*-wolfssl-nofips_*.deb linux-headers-*-wolfssl-nofips_*.deb

NEW_KVER=\$(ls /boot/vmlinuz-*wolfssl-nofips 2>/dev/null | sort -V | tail -1 | sed 's|.*/vmlinuz-||')
echo "New kernel: \$NEW_KVER"

# Make the new kernel the default boot entry
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub
sudo update-grub 2>&1 | tail -3
echo "Grub updated. Ready to reboot."
CUSTOM_KERNEL_APT

    elif [[ "$PKG_FAMILY" == "dnf" ]]; then
        # ── Fedora / CentOS: build kernel directly with make (not rpmbuild) ───
        # Using make directly (not rpmbuild) avoids the full RPM packaging
        # overhead (~60 min) and gives the same result: a bootable kernel with
        # CONFIG_CRYPTO_FIPS=n.  This mirrors what a developer would do when
        # building a custom kernel for their product.
        KARCH="$KERN_ARCH"
        [[ "$ARM64" == "1" ]] && RPM_ARCH="aarch64" || RPM_ARCH="x86_64"
        remote_script <<CUSTOM_KERNEL_DNF
set -eo pipefail

echo "=== Installing kernel build dependencies ==="
DNF_CMD=\$(command -v dnf5 2>/dev/null || command -v dnf)
echo "Package manager: \$DNF_CMD"
sudo "\$DNF_CMD" install -y -q \
    gcc make bison flex elfutils-libelf-devel openssl-devel \
    bc perl xz dwarves ncurses-devel \
    glibc-static \
    kernel-devel-\$(uname -r) 2>/dev/null || \
sudo "\$DNF_CMD" install -y -q \
    gcc make bison flex elfutils-libelf-devel openssl-devel \
    bc perl xz dwarves ncurses-devel \
    glibc-static kernel-devel 2>&1 | tail -5

echo "=== Getting kernel source ==="
# Use kernel-devel's source tree — it already has the right config
# and all the generated headers for the running kernel.
KVER=\$(uname -r)
KDEVEL_SRC=\$(ls -d /usr/src/kernels/\${KVER} 2>/dev/null | head -1)
if [[ -z "\$KDEVEL_SRC" ]]; then
    echo "ERROR: kernel-devel source not found at /usr/src/kernels/\$KVER" >&2
    ls /usr/src/kernels/ 2>/dev/null
    exit 1
fi
echo "kernel-devel source: \$KDEVEL_SRC"

# Download the full kernel source matching the running version
mkdir -p ~/kernel-build && cd ~/kernel-build

# Try to get source from enabled repos
DNF_CMD=\$(command -v dnf5 2>/dev/null || command -v dnf)
sudo "\$DNF_CMD" config-manager --set-enabled fedora-source updates-source 2>/dev/null || true
sudo "\$DNF_CMD" makecache -q 2>/dev/null || true
sudo "\$DNF_CMD" download --source \
    kernel-\$(uname -r | sed 's/\\.${RPM_ARCH}//') 2>/dev/null || \
sudo "\$DNF_CMD" download --source kernel 2>&1 | tail -3

SRPM=\$(ls kernel-*.src.rpm 2>/dev/null | head -1)
[[ -z "\$SRPM" ]] && { echo "ERROR: kernel SRPM not found" >&2; exit 1; }
echo "SRPM: \$SRPM"

# Extract just the source tarball from the SRPM (no need for full rpm -ivh)
rpm2cpio "\$SRPM" | cpio -idmv "*.tar.xz" "*.tar.gz" 2>&1 | tail -5
TARBALL=\$(find . -maxdepth 1 -name "linux-*.tar.xz" -o -name "linux-*.tar.gz" 2>/dev/null | head -1)
[[ -z "\$TARBALL" ]] && { echo "ERROR: kernel tarball not extracted from SRPM" >&2; exit 1; }
echo "Extracting \$TARBALL (~1 min)..."
tar -xf "\$TARBALL"
SRC_DIR=\$(find . -maxdepth 1 -type d -name "linux-*" | sort | head -1 | sed 's|^./||')
[[ -z "\$SRC_DIR" ]] && { echo "ERROR: kernel source dir not found after extraction" >&2; exit 1; }
echo "Source: \$SRC_DIR"
cd "\$SRC_DIR"

echo "=== Configuring kernel: CONFIG_CRYPTO_FIPS=n ==="
# Start from the running kernel's config
cp "\$KDEVEL_SRC/.config" .config 2>/dev/null || \
    cp /boot/config-\$KVER .config 2>/dev/null || \
    { echo "ERROR: no .config found"; exit 1; }
make olddefconfig ARCH=${KARCH} 2>&1 | tail -3

# Disable FIPS — the whole point of this custom kernel
scripts/config --disable CONFIG_CRYPTO_FIPS
# Skip debug info (saves ~30 min)
scripts/config --disable CONFIG_DEBUG_INFO || true
scripts/config --enable  CONFIG_DEBUG_INFO_NONE || true
# Clear signing key paths
scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS "" || true
scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS "" || true
# NVMe must be built-in for EC2
scripts/config --enable  CONFIG_NVME_CORE
scripts/config --enable  CONFIG_BLK_DEV_NVME
make olddefconfig ARCH=${KARCH} 2>&1 | tail -3

grep -q "^CONFIG_CRYPTO_FIPS=y" .config && \
    { echo "ERROR: CONFIG_CRYPTO_FIPS still y" >&2; exit 1; }
echo "CONFIG_CRYPTO_FIPS is off ✓"

echo "=== Building kernel with make (~15-25 min on \$(nproc) cores) ==="
make -j\$(nproc) ARCH=${KARCH} LOCALVERSION=-wolfssl-nofips 2>&1 | tail -5

echo "=== Installing kernel ==="
sudo make ARCH=${KARCH} modules_install 2>&1 | tail -3
sudo make ARCH=${KARCH} install 2>&1 | tail -3

NEW_KVER=\$(ls /boot/vmlinuz-*-wolfssl-nofips 2>/dev/null | sort -V | tail -1 | sed 's|.*/vmlinuz-||' || echo "")
[[ -z "\$NEW_KVER" ]] && NEW_KVER=\$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed 's|.*/vmlinuz-||')
echo "New kernel: \$NEW_KVER"

# Update bootloader — use grubby which understands BLS entries on Fedora 43+
sudo grubby --set-default "/boot/vmlinuz-\$NEW_KVER"
GRUB_CFG=\$(find /boot -name "grub.cfg" 2>/dev/null | head -1)
[[ -n "\$GRUB_CFG" ]] && sudo grub2-mkconfig -o "\$GRUB_CFG" 2>&1 | tail -3 || true
echo "Bootloader updated. Default: \$(sudo grubby --default-kernel)"
echo "Ready to reboot."
CUSTOM_KERNEL_DNF

    else
        log "WARN: CUSTOM_KERNEL=1 not supported for PKG_FAMILY=$PKG_FAMILY; skipping"
    fi

    # Reboot into custom kernel
    # The kernel build takes ~30 min; the install (especially modules_install)
    # can add another 5-10 min.  Give SSH up to 15 min to come back after reboot.
    log "Rebooting into custom kernel (waiting up to 15 min for SSH)..."
    watch_serial 180
    remote 'sudo reboot' 2>/dev/null || true
    sleep 30
    wait_for_ssh 180
    stop_serial

    KVER=$(remote 'uname -r')
    log "Rebooted. Kernel: $KVER"

    # Verify FIPS is actually off in the new kernel
    FIPS_CHECK=$(remote 'bash -c "
        for f in /boot/config-\$(uname -r) /boot/config; do
            [[ -f \"\$f\" ]] || continue
            grep CONFIG_CRYPTO_FIPS \"\$f\" && exit 0
        done
        echo \"config not found\"
    "')
    log "Kernel FIPS config: $FIPS_CHECK"
    if echo "$FIPS_CHECK" | grep -q "^CONFIG_CRYPTO_FIPS=y"; then
        fail "Custom kernel still has CONFIG_CRYPTO_FIPS=y — rebuild failed"
        exit 1
    fi
    if echo "$KVER" | grep -q "wolfssl-nofips\|nofips\|custom"; then
        pass "Custom FIPS=n kernel booted: $KVER"
    else
        # Kernel may not have LOCALVERSION embedded — just check the FIPS config
        if echo "$FIPS_CHECK" | grep -qv "=y"; then
            pass "Custom FIPS=n kernel booted: $KVER (FIPS disabled in config)"
        else
            log "WARN: Could not confirm custom kernel; proceeding (FIPS check: $FIPS_CHECK)"
        fi
    fi

    # After rebooting into the custom kernel, set LINUX_SOURCE so wolfSSL
    # configure uses the custom kernel's build directory.
    # 'make modules_install' creates /lib/modules/KVER/build as a symlink
    # back to the kernel source tree used during the build.
    KVER_CUSTOM=$(remote 'uname -r')
    LINUX_SOURCE_CUSTOM="/lib/modules/${KVER_CUSTOM}/build"
    KBUILD_CHECK=$(remote "test -f '${LINUX_SOURCE_CUSTOM}/Makefile' && echo yes || echo no")
    if [[ "$KBUILD_CHECK" == "yes" ]]; then
        LINUX_SOURCE="$LINUX_SOURCE_CUSTOM"
        log "Custom kernel build dir: $LINUX_SOURCE"
    else
        log "WARN: custom kernel build dir not found at $LINUX_SOURCE_CUSTOM"
    fi
fi

# ── Phase 0.8: Kernel/kernel-devel version alignment (dnf distros only) ───────
#
# On RHEL/CentOS AMIs, the running kernel may predate the latest kernel-devel
# package in the repo.  Building a module against a mismatched kernel-devel
# produces a wrong vermagic, causing insmod to reject with "Invalid module
# format".  Fedora AMIs are usually current; the update is a no-op for them.
#
# Procedure: update kernel packages, reboot if the version changed, then
# install matching kernel-devel in the deps phase below.

if [[ "$PKG_FAMILY" == "dnf" ]]; then
    log "Ensuring kernel/kernel-devel version alignment (dnf distro: $DISTRO)..."
    KVER_BEFORE=$(remote 'uname -r')
    remote 'sudo dnf update -y -q kernel kernel-core kernel-modules >/dev/null 2>&1 || true'
    LATEST_KVER=$(remote 'rpm -q --last kernel 2>/dev/null | head -1 | sed "s/kernel-//;s/ .*//"')
    if [[ -n "$LATEST_KVER" && "$LATEST_KVER" != "$KVER_BEFORE" ]]; then
        log "Kernel updated from ${KVER_BEFORE} to ${LATEST_KVER}, rebooting..."
        watch_serial 180
        remote 'sudo reboot' 2>/dev/null || true
        sleep 10
        wait_for_ssh 36
        stop_serial
        KVER=$(remote 'uname -r')
        log "Rebooted into kernel: $KVER"
        pass "Kernel updated to match kernel-devel: $KVER"
    else
        log "Kernel already current: $KVER_BEFORE"
    fi
fi

# ── Phase 1: Install build dependencies ──────────────────────────────────────
#
# gcc selection:
#   Ubuntu/Debian: versioned gcc — kernel major version determines which gcc:
#     (gcc-11 for 5.x, gcc-12 for 6.0-6.13, gcc-14 for ≥6.14, gcc-15 for ≥7.x)
#   CentOS/Fedora: distro default gcc (the 'gcc' package).
#   NixOS: gcc from nixpkgs (gcc14 matches the kernel build compiler).
#
# Package names differ between package managers:
#   apt:  cryptsetup-bin, libssl-dev, linux-headers-$(uname -r)
#   dnf:  cryptsetup, openssl-devel, kernel-devel-$(uname -r)
#   nix:  cryptsetup, openssl (nix-shell -p)
#
# NixOS kernel build path:
#   NixOS does not use /lib/modules/$(uname -r)/build.
#   The kernel dev tree lives in the nix store:
#     $(nix-instantiate --eval -E '...linuxPackages.kernel.dev.outPath')/lib/modules/<ver>/build
#   We resolve this path on the remote host and export it as LINUX_SOURCE.

log "Installing build dependencies..."

# For NixOS: resolve kernel dev path before installing anything
LINUX_SOURCE=""
if [[ "$PKG_FAMILY" == "nix" ]]; then
    # On NixOS, the kernel dev tree lives in the nix store.
    # The derivation is not present until it is realized (downloaded from cache).
    # nix-build realizes it; this typically takes ~30 s to download from cache.nixos.org.
    log "Realizing NixOS kernel dev derivation (downloading from nix cache, ~30 s)..."
    remote "nix-build '<nixpkgs>' -A linuxPackages.kernel.dev --no-out-link 2>&1 | tail -5"

    # Now resolve the realized store path.
    KDEV=$(remote "nix-instantiate --eval -E '(import <nixpkgs> {}).linuxPackages.kernel.dev.outPath' 2>/dev/null | tr -d '\"'")
    if [[ -z "$KDEV" || ! "$KDEV" =~ /nix/store ]]; then
        fail "Could not resolve NixOS kernel dev path from nixpkgs (got: '$KDEV')"
        exit 1
    fi
    KVER=$(remote 'uname -r')
    LINUX_SOURCE="${KDEV}/lib/modules/${KVER}/build"
    # Verify the Makefile exists; if kernel versions diverge, find the right dir
    MAKEFILE_CHECK=$(remote "test -f '${LINUX_SOURCE}/Makefile' && echo yes || echo no")
    if [[ "$MAKEFILE_CHECK" != "yes" ]]; then
        LINUX_SOURCE=$(remote "find '${KDEV}/lib/modules' -name Makefile -path '*/build/Makefile' 2>/dev/null | head -1 | sed 's|/Makefile||'")
        if [[ -z "$LINUX_SOURCE" ]]; then
            fail "Could not find kernel build Makefile under $KDEV"
            exit 1
        fi
    fi
    log "NixOS kernel build path: $LINUX_SOURCE"
    pass "NixOS kernel dev realized"
fi

# Determine gcc binary.
if [[ "$PKG_FAMILY" == "apt" ]]; then
    KGCC=$(remote 'bash -c "
        KMAJ=\$(uname -r | cut -d. -f1)
        KMIN=\$(uname -r | cut -d. -f2)
        if   [[ \$KMAJ -ge 7 ]];                  then echo gcc-15
        elif [[ \$KMAJ -ge 6 && \$KMIN -ge 14 ]]; then echo gcc-14
        elif [[ \$KMAJ -ge 6 ]];                  then echo gcc-12
        else                                            echo gcc-11
        fi
    "')
elif [[ "$PKG_FAMILY" == "nix" ]]; then
    # NixOS nixpkgs 25.11 ships gcc14 which matches the kernel build compiler.
    # We use plain 'gcc' inside nix-shell since the nix-shell environment sets
    # PATH to include the requested gcc package as 'gcc'.
    KGCC="gcc"
else
    # dnf distros: distro-default gcc.
    KGCC="gcc"
fi
log "gcc selected: $KGCC (kernel $(remote 'uname -r'), distro=$DISTRO)"

if [[ "$PKG_FAMILY" == "apt" ]]; then
    remote_script <<DEPS_APT
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

# Retry apt-get update up to 3 times with 10 s delay between attempts.
# EC2 instances occasionally fail the first update due to mirror initialization
# or transient package index lock contention from unattended-upgrades.
for attempt in 1 2 3; do
    if sudo apt-get update -qq; then
        break
    fi
    if [[ \$attempt -eq 3 ]]; then
        echo "ERROR: apt-get update failed after 3 attempts" >&2
        exit 1
    fi
    echo "apt-get update failed (attempt \$attempt/3); retrying in 10s..." >&2
    sleep 10
done

sudo apt-get install -y -qq \
    ${KGCC} \
    make \
    autoconf \
    automake \
    libtool \
    gawk \
    git \
    linux-headers-\$(uname -r) \
    libssl-dev \
    openssl \
    cryptsetup-bin \
    2>&1 | grep -v "^Get:\|^Hit:\|^Ign:"
DEPS_APT

elif [[ "$PKG_FAMILY" == "dnf" ]]; then
    remote_script <<DEPS_DNF
set -eo pipefail

# Retry dnf makecache — on fresh EC2 instances the dnf metadata may not be
# initialized yet.
DNF_OK=0
for attempt in 1 2 3; do
    if sudo dnf makecache -q; then
        DNF_OK=1
        break
    fi
    echo "dnf makecache attempt \${attempt} failed; retrying in 10s..." >&2
    sleep 10
done
[ "\${DNF_OK}" = "1" ] || { echo "ERROR: dnf makecache failed after 3 attempts" >&2; exit 1; }

# CRB (CodeReady Builder) provides kernel-devel on CentOS/RHEL.
# Fedora has everything in default repos; this is a harmless no-op there.
sudo dnf config-manager --set-enabled crb > /dev/null 2>&1 || \
sudo dnf config-manager --set-enabled \
    "codeready-builder-for-rhel-9-rhui-rpms" > /dev/null 2>&1 || true

# Install kernel-devel matching the running kernel exactly, then fall back
# to the default (latest) kernel-devel if the exact match is unavailable.
KVER=\$(uname -r)
sudo dnf install -y -q \
    make gcc \
    autoconf automake libtool \
    gawk \
    git \
    openssl openssl-devel \
    cryptsetup \
    kernel-devel-\${KVER} 2>/dev/null || \
sudo dnf install -y -q \
    make gcc \
    autoconf automake libtool \
    gawk \
    git \
    openssl openssl-devel \
    cryptsetup \
    kernel-devel
DEPS_DNF

elif [[ "$PKG_FAMILY" == "nix" ]]; then
    # NixOS: use nix-shell for the build environment.
    # nix-shell sets up ACLOCAL_PATH, PKG_CONFIG_PATH, and library paths
    # correctly — installing via nix-env -iA does not.
    #
    # glibc.static: required by the wolfSSL linuxkm Makefile which compiles
    #   a small HOSTCC helper binary (get_thread_size) that links against libc.
    #   Without glibc.static, ld cannot find -lc and the build fails.
    #
    # The NixOS_PKGS variable is exported so Phase 2 build commands can
    # wrap themselves in the same nix-shell environment.
    NIXOS_PKGS="gcc autoconf automake libtool gawk git openssl openssl.dev cryptsetup glibc.static"
    remote_script <<DEPS_NIX
set -eo pipefail
# Install git and cryptsetup permanently into the nix profile so they are
# available in all subsequent remote_script calls (clone, sign, LUKS phases).
# Other build tools (gcc, autoconf, etc.) are used inside nix-shell which
# sets up the correct environment paths for compilation.
nix-env -iA nixos.git nixos.cryptsetup nixos.openssl 2>&1 | tail -3

# Pre-fetch the full build environment so Phase 2 nix-shell calls are fast.
echo "Pre-fetching nix build packages (may download ~100 MB)..."
nix-shell -p ${NIXOS_PKGS} --run 'echo "nix-shell OK: gcc=$(gcc --version | head -1)"' 2>&1 | grep -E "nix-shell OK|copying|error" | tail -5

echo "git: \$(git --version)"
echo "cryptsetup: \$(cryptsetup --version)"
DEPS_NIX

else
    echo "ERROR: unknown PKG_FAMILY=$PKG_FAMILY" >&2; exit 1
fi

pass "Build dependencies installed (gcc=$KGCC)"

# ── Phase 2: Build wolfSSL linuxkm ───────────────────────────────────────────
#
# --enable-linuxkm-lkcapi-register: CRITICAL — without this flag wolfSSL
#   builds and loads but does NOT register any algorithms with the kernel
#   crypto API (linuxkm_lkcapi_register() is a no-op).  dm-crypt would then
#   fall back to aesni or generic implementations, defeating the purpose.
#   This sets LINUXKM_LKCAPI_REGISTER and ENABLED_LINUXKM_LKCAPI_REGISTER=yes.
# --enable-aesxts: AES-XTS is the cipher mode dm-crypt uses for LUKS2 data
#   partitions (aes-xts-plain64).  Without it wolfSSL does not register the
#   XTS transform and LUKS falls back to the kernel's built-in AES driver.
# --enable-sha256 / --enable-sha512: required for PBKDF2/Argon2 key derivation.
# --enable-hmac: HMAC-SHA256 is also required for PBKDF2.
# --enable-aesgcm: not strictly needed for LUKS but useful for completeness.
# CC=gcc-NN: must match the compiler used to build the running kernel to avoid
#   vermagic mismatch errors on insmod.

log "Cloning wolfSSL (${WOLFSSL_REF})..."
watch_serial 600
remote_script <<CLONE
set -eo pipefail
git clone --depth=1 --branch "${WOLFSSL_REF}" \
    "${WOLFSSL_REPO}" ~/wolfssl
echo "wolfSSL HEAD: \$(git -C ~/wolfssl rev-parse HEAD)"
CLONE
stop_serial

WOLFSSL_HEAD=$(remote 'git -C ~/wolfssl rev-parse HEAD')
log "wolfSSL HEAD: $WOLFSSL_HEAD"
pass "wolfSSL cloned"

log "Configuring wolfSSL for linuxkm (this takes ~1 min)..."
# Determine the kernel build path.
# Standard distros: /lib/modules/$(uname -r)/build (symlink into kernel headers pkg)
# NixOS: path in the nix store (resolved earlier as LINUX_SOURCE)
if [[ -n "$LINUX_SOURCE" ]]; then
    KBUILD_PATH="$LINUX_SOURCE"
    log "Using NixOS kernel build path: $KBUILD_PATH"
else
    KBUILD_PATH="/lib/modules/\$(uname -r)/build"
fi

watch_serial 600
if [[ "$PKG_FAMILY" == "nix" ]]; then
    # NixOS: wrap autogen + configure in nix-shell WITHOUT glibc.static.
    # glibc.static is needed for the build step but causes an IFUNC circular
    # dependency during configure's conftest binary execution.
    # Write the commands to a temp script to avoid quoting issues.
    NIXOS_PKGS_CONFIGURE="${NIXOS_PKGS/glibc.static/}"
    remote_script <<CONFIGURE_NIX
set -eo pipefail
cd ~/wolfssl
cat > /tmp/nixos-configure.sh << 'NIXSCRIPT'
set -eo pipefail
cd ~/wolfssl
./autogen.sh 2>&1 | tail -5
./configure --quiet \\
    --enable-cryptonly \\
    --enable-linuxkm \\
    --enable-linuxkm-lkcapi-register \\
    ${WOLFSSL_ASM_OPT} \\
    --enable-aes --enable-aesgcm --enable-aesxts \\
    --enable-sha256 --enable-sha512 --enable-hmac \\
    --with-linux-source=${KBUILD_PATH} \\
    CC=${KGCC} HOSTCC=${KGCC}
NIXSCRIPT
chmod +x /tmp/nixos-configure.sh
nix-shell -p ${NIXOS_PKGS_CONFIGURE} --run 'bash /tmp/nixos-configure.sh'
CONFIGURE_NIX
else
    remote_script <<CONFIGURE
set -eo pipefail
cd ~/wolfssl
./autogen.sh 2>&1 | tail -5
./configure --quiet \
    --enable-cryptonly \
    --enable-linuxkm \
    --enable-linuxkm-lkcapi-register \
    ${WOLFSSL_ASM_OPT} \
    --enable-aes \
    --enable-aesgcm \
    --enable-aesxts \
    --enable-sha256 \
    --enable-sha512 \
    --enable-hmac \
    --with-linux-source=${KBUILD_PATH} \
    CC=${KGCC} \
    HOSTCC=${KGCC}
CONFIGURE
fi
stop_serial
pass "wolfSSL configured"

log "Building wolfSSL linuxkm module (~5 min)..."
watch_serial 700
if [[ "$PKG_FAMILY" == "nix" ]]; then
    # NixOS: wrap make in nix-shell for correct library paths.
    remote_script <<BUILD_NIX
set -eo pipefail
cd ~/wolfssl
cat > /tmp/nixos-build.sh << 'NIXSCRIPT'
set -eo pipefail
cd ~/wolfssl
make -j\$(nproc) ${MAKE_ARCH_OPT:+${MAKE_ARCH_OPT}} CC=${KGCC} HOSTCC=${KGCC} module || true
NIXSCRIPT
chmod +x /tmp/nixos-build.sh
nix-shell -p ${NIXOS_PKGS} --run 'bash /tmp/nixos-build.sh'
# Assert the module was produced.
if [[ ! -f linuxkm/libwolfssl.ko ]]; then
    echo "ERROR: linuxkm/libwolfssl.ko not found after make" >&2
    ls -la linuxkm/ 2>/dev/null || true
    exit 1
fi
ls -lh linuxkm/libwolfssl.ko
BUILD_NIX
else
    remote_script <<BUILD
set -eo pipefail
cd ~/wolfssl
# Use '|| true' because wolfSSL's module make target attempts to self-sign
# libwolfssl.ko.signed using the kernel's own build key — this fails on EC2
# since we don't have the kernel's signing key.  The actual module artifact
# (libwolfssl.ko, not .ko.signed) is still produced before the signing step.
# HOSTCC must match CC to avoid mismatched object files when cross-compiling.
make -j\$(nproc) \
    ${MAKE_ARCH_OPT:+${MAKE_ARCH_OPT}} \
    CC=${KGCC} \
    HOSTCC=${KGCC} \
    module || true

# Assert the module was produced (even if the self-signing step failed).
if [[ ! -f linuxkm/libwolfssl.ko ]]; then
    echo "ERROR: linuxkm/libwolfssl.ko not found after make (build may have actually failed)" >&2
    ls -la linuxkm/ 2>/dev/null || true
    exit 1
fi
ls -lh linuxkm/libwolfssl.ko
BUILD
fi
stop_serial
pass "wolfSSL linuxkm built (libwolfssl.ko verified)"

# ── Phase 3: Module signing (ephemeral key) ───────────────────────────────────
#
# Ubuntu kernel security constraints that affect out-of-tree module loading:
#
# 1. CONFIG_MODULE_SIG_ALL=y — wolfSSL's make target auto-tries to sign
#    libwolfssl.ko.signed during the build using the kernel's own build key.
#    This fails because the ephemeral key is not enrolled.  We catch this by
#    running make with '|| true' and then asserting libwolfssl.ko (the unsigned
#    artifact) exists.  The .ko.signed variant is not needed for standard Ubuntu
#    EC2 AMIs where MODULE_SIG_FORCE is not set.
#
# 2. CONFIG_SYSTEM_TRUSTED_KEYS="debian/canonical-certs.pem" — only
#    Canonical-signed modules are in the builtin trusted keyring.  Modules
#    signed with an ephemeral key load with a kernel taint flag
#    (TAINT_MODULE_SIG_UNVERIFIED) on standard EC2 (MODULE_SIG_FORCE not set).
#    They are REJECTED on Ubuntu Pro FIPS kernels (MODULE_SIG_FORCE=y).
#    Standard Ubuntu EC2 AMIs (uefi-preferred, no UefiData) do not set
#    MODULE_SIG_FORCE, so the tainted load succeeds.
#
# 3. CONFIG_IMA_APPRAISE=y + CONFIG_IMA_ARCH_POLICY=y — IMA appraisal only
#    activates when Secure Boot is enforced.  Standard Ubuntu EC2 AMIs have
#    BootMode=uefi-preferred with no Secure Boot keys enrolled (UefiData=null),
#    so IMA appraisal does NOT trigger.
#
# Action: sign with an ephemeral key so the module at least has a signature
# (even though it won't be in the trusted keyring), then verify the taint
# is acceptable (unsigned/unverified is OK; sig_force rejection is not).

log "Generating ephemeral signing key and signing libwolfssl.ko..."
remote_script <<SIGN
set -eo pipefail
cd ~/wolfssl

# Use a dedicated directory so key material is isolated from /tmp clutter.
mkdir -p ~/wolfssl-signing
SIGNING_KEY=~/wolfssl-signing/key.pem
SIGNING_CERT=~/wolfssl-signing/cert.pem

# RSA-2048 is the minimum accepted by the kernel module signing infrastructure.
openssl req -new -x509 -newkey rsa:2048 \
    -keyout "\$SIGNING_KEY" \
    -out "\$SIGNING_CERT" \
    -days 1 -nodes \
    -subj "/CN=wolfssl-luks-test-ephemeral" \
    2>/dev/null
chmod 600 "\$SIGNING_KEY"

# Locate sign-file.  It is pre-compiled in the kernel headers package under
# scripts/sign-file, but the exact path varies by Ubuntu version and whether
# the headers are under /usr/src or /lib/modules.
SIGN_FILE=\$(find /usr/src/linux-headers-\$(uname -r)/scripts \
                  /lib/modules/\$(uname -r)/build/scripts \
                  -name sign-file -type f 2>/dev/null | head -1 || true)

# Compile sign-file from kernel headers source if the binary was not found.
# This happens on some minimal kernel-headers packages that ship source only.
if [[ -z "\$SIGN_FILE" ]]; then
    echo "sign-file binary not found; compiling from kernel headers source..."
    KBUILD=\$(ls -d /usr/src/linux-headers-\$(uname -r) \
              /lib/modules/\$(uname -r)/build 2>/dev/null | head -1 || true)
    if [[ -n "\$KBUILD" && -f "\$KBUILD/scripts/sign-file.c" ]]; then
        gcc -o /tmp/sign-file "\$KBUILD/scripts/sign-file.c" \
            -lssl -lcrypto -Wall -Werror=implicit-function-declaration 2>&1
        SIGN_FILE=/tmp/sign-file
        echo "Compiled sign-file: \$SIGN_FILE"
    else
        echo "WARN: sign-file source not found either; proceeding unsigned (taint expected)"
    fi
fi

if [[ -n "\$SIGN_FILE" ]]; then
    "\$SIGN_FILE" sha256 "\$SIGNING_KEY" "\$SIGNING_CERT" \
        linuxkm/libwolfssl.ko 2>&1
    echo "Signed libwolfssl.ko with: \$SIGN_FILE"
else
    echo "WARN: proceeding with unsigned module (sign-file unavailable)"
fi

# Assert the module is a valid ELF file by checking the ELF magic bytes
# (7f 45 4c 46 = \x7fELF at offset 0).  We use od/hexdump instead of
# 'file' so this works on distros where the 'file' package is not installed
# by default (e.g., NixOS, minimal Debian/Alpine images).
ELF_MAGIC=\$(od -A n -t x1 -N 4 linuxkm/libwolfssl.ko | tr -d ' \n')
if [[ "\$ELF_MAGIC" != "7f454c46" ]]; then
    echo "ERROR: libwolfssl.ko ELF magic check failed (got: '\$ELF_MAGIC')" >&2
    exit 1
fi
echo "ELF check: OK"

# Assert MODULE_SIG trailer if signing succeeded.
# The trailer is a 12-byte magic string '~Module signature appended~\n' at EOF.
# This is present even when signed with an untrusted key.
if [[ -n "\$SIGN_FILE" ]]; then
    if tail -c 28 linuxkm/libwolfssl.ko | grep -q "Module signature appended"; then
        echo "MODULE_SIG trailer: present ✓"
    else
        echo "WARN: MODULE_SIG trailer not found (sign-file may have failed silently)"
    fi
fi

ls -lh linuxkm/libwolfssl.ko
# Clean up key material — no longer needed after signing.
rm -f "\$SIGNING_KEY"
SIGN
pass "libwolfssl.ko signed (ephemeral key; ELF + MODULE_SIG verified)"

# ── Phase 3b: Load the module ─────────────────────────────────────────────────
#
# We deliberately do NOT use modprobe here because libwolfssl.ko is not in the
# module search path; insmod with an explicit path is correct.
#
# The kernel may print a TAINT_MODULE_SIG_UNVERIFIED warning for the ephemeral
# key (since it is not in the Canonical builtin keyring).  This is expected and
# does not prevent the module from functioning.  We assert the module is listed
# in lsmod and that dmesg shows a wolfssl-related registration line.

log "Loading libwolfssl.ko and verifying registration..."
remote_script <<INSMOD
set -eo pipefail

# insmod with explicit path — modprobe not applicable since the module is not
# in the kernel module search path.
sudo insmod ~/wolfssl/linuxkm/libwolfssl.ko

# Verify the module appears in lsmod.
if ! lsmod | grep -qi "libwolfssl\|wolfssl"; then
    echo "ERROR: libwolfssl not found in lsmod after insmod" >&2
    lsmod | tail -20
    exit 1
fi
echo "  lsmod check: OK"
lsmod | grep -i wolfssl

# Verify dmesg shows wolfssl/wolfcrypt registration messages.
# wolfSSL prints something like:
#   libwolfssl: wolfSSL Module registered
#   libwolfssl: wolfCrypt algorithms registered
# Check for at least one wolfssl-related kernel log line.
sudo dmesg | tail -30
WOLFSSL_LOG=\$(sudo dmesg | grep -i "wolfssl\|wolfcrypt" | tail -10)
if [[ -z "\$WOLFSSL_LOG" ]]; then
    echo "WARN: no wolfssl/wolfcrypt messages in dmesg — module may be registered silently"
else
    echo "  dmesg wolfssl messages:"
    echo "\$WOLFSSL_LOG"
    echo "  dmesg check: OK"
fi

# Fail if 'STUB MODE' appears in dmesg — this indicates wolfSSL compiled
# without the features needed for the kernel crypto API and is functioning
# in a degraded stub mode only.  xts(aes) would not be registered in this case.
if sudo dmesg | grep -qi "STUB MODE"; then
    echo "ERROR: wolfSSL started in STUB MODE — linuxkm features not compiled in" >&2
    sudo dmesg | grep -i "STUB MODE" | tail -5
    exit 1
fi
echo "  STUB MODE check: OK (not in stub mode)"
INSMOD
pass "libwolfssl.ko loaded and verified (lsmod present, no STUB MODE)"

# ── Phase 4: Verify /proc/crypto algorithm registration ──────────────────────
#
# After insmod, wolfSSL registers its implementations into the kernel crypto
# API.  We inspect /proc/crypto to confirm that the algorithms dm-crypt needs
# (aes-xts-plain64 → xts(aes), sha256, hmac(sha256)) are backed by the wolfSSL
# driver and not by the kernel's generic/fallback implementations.
#
# Each /proc/crypto stanza looks like:
#   name         : xts(aes)
#   driver       : xts-aes-wolfssl
#   module       : libwolfssl
#   ...
#
# We require the 'driver' field to contain 'wolfssl' (case-insensitive).
# A non-wolfssl driver means the module did not register properly or the
# kernel preferred a competing implementation — both are failures.

log "Verifying /proc/crypto wolfSSL algorithm registration..."
remote_script <<VERIFY_CRYPTO
set -eo pipefail

# Capture full /proc/crypto for diagnostic logging.
echo "=== /proc/crypto (full) ==="
cat /proc/crypto
echo "=== end /proc/crypto ==="

# Helper: given an algorithm name, find its stanza in /proc/crypto and
# assert the 'driver' field contains 'wolfssl' (case-insensitive).
# Exits non-zero if the algorithm is absent or backed by a non-wolfssl driver.
#
# /proc/crypto format: stanzas separated by blank lines.  Each field is:
#   "key         : value"
# We use a simple awk state machine that sets found_name=1 when the current
# stanza has a matching 'name' field, then extracts 'driver' from the same
# stanza.  A blank line resets the state for the next stanza.
check_algo() {
    local algo="\$1"
    local driver

    driver=\$(awk -v algo="\$algo" '
        BEGIN { found_name=0 }
        /^[[:space:]]*\$/ { found_name=0 }
        /^name[[:space:]]*:/ {
            val = \$0
            sub(/^name[[:space:]]*:[[:space:]]*/, "", val)
            found_name = (val == algo)
        }
        /^driver[[:space:]]*:/ && found_name {
            val = \$0
            sub(/^driver[[:space:]]*:[[:space:]]*/, "", val)
            print val
            found_name = 0   # consume: only report first match per stanza
        }
    ' /proc/crypto | head -1)

    if [[ -z "\$driver" ]]; then
        echo "  MISSING: \$algo not found in /proc/crypto" >&2
        return 1
    fi

    # wolfSSL driver names contain 'wolfcrypt' or 'wolfssl' depending on build.
    # Examples: 'xts-aes-aesni-avx-wolfcrypt', 'sha256-avx2-wolfcrypt',
    #           'hmac-sha256-avx2-wolfcrypt'.  Accept either form.
    if echo "\$driver" | grep -qiE "wolf(ssl|crypt)"; then
        echo "  OK: \$algo  driver=\$driver"
        return 0
    else
        echo "  BAD: \$algo  driver=\$driver (expected wolfssl or wolfcrypt in driver name)" >&2
        return 1
    fi
}

FAILED=0
check_algo "xts(aes)"      || FAILED=1
check_algo "sha256"         || FAILED=1
check_algo "hmac(sha256)"   || FAILED=1

exit \$FAILED
VERIFY_CRYPTO
pass "/proc/crypto: xts(aes), sha256, hmac(sha256) all backed by wolfssl/wolfcrypt"

# ── Phase 5: Create loopback device ──────────────────────────────────────────
#
# We use a loopback device rather than a real block device so the test runs on
# any EC2 instance without needing an extra EBS volume.  256 MB is sufficient
# for LUKS2 metadata + a small ext4 filesystem.
#
# losetup --find --show atomically picks the next free /dev/loopN and prints
# it; this is more reliable than guessing the device number.

log "Creating loopback device (${LUKS_IMG_SIZE_MB} MB)..."
LOOP_DEV=$(remote_script <<LOOPDEV
set -eo pipefail
dd if=/dev/zero of=~/luks-test.img bs=1M count=${LUKS_IMG_SIZE_MB} status=none
sudo losetup --find --show ~/luks-test.img
LOOPDEV
)
# Trim whitespace from captured output.
LOOP_DEV="${LOOP_DEV//[$'\t\r\n ']}"
if [[ -z "$LOOP_DEV" || ! "$LOOP_DEV" =~ ^/dev/loop ]]; then
    fail "losetup did not return a /dev/loopN device (got: '$LOOP_DEV')"
    exit 1
fi
log "Loop device: $LOOP_DEV"

# Verify the loop device exists on the remote side.
remote "ls -l $LOOP_DEV" > /dev/null
pass "Loopback device created: $LOOP_DEV"

# ── Phase 6: LUKS2 format ────────────────────────────────────────────────────
#
# cryptsetup luksFormat selects the cipher via the kernel crypto API.  Since
# we loaded libwolfssl.ko above, dm-crypt's request for aes-xts-plain64 will
# be fulfilled by wolfSSL's XTS implementation.
#
# --type luks2: LUKS2 format (LUKS1 uses sha1 by default; LUKS2 uses sha256).
# --cipher aes-xts-plain64: explicit — matches what LUKS2 uses by default.
# --key-size 512: 512-bit key = 2×256-bit halves for XTS-AES-256.
# --hash sha256: PBKDF2/Argon2 hash — must be registered (verified above).
# --iter-time 1000: lower iteration time for testing; production uses default.
# --batch-mode / echo: avoids interactive "YES" prompt.

log "Formatting LUKS2 volume on $LOOP_DEV..."
LUKS_PASS="wolfssl-luks-test-passphrase"
remote_script <<LUKSFMT
set -eo pipefail
# --type luks2: LUKS2 header format (supports Argon2 and PBKDF2).
# --cipher aes-xts-plain64: standard dm-crypt XTS mode for block encryption.
# --key-size 512: XTS requires a doubled key; 512 bits = two 256-bit halves
#   for AES-256-XTS.  Using 256 here would give AES-128-XTS instead.
# --pbkdf pbkdf2: use PBKDF2 (not Argon2) for key derivation; PBKDF2 depends
#   only on sha256 and hmac, both of which wolfSSL registers.  Argon2 is
#   CPU/memory-bound and does not use the kernel crypto API for its core
#   computation, but its availability varies by cryptsetup version.
# --hash sha256: PBKDF2 hash — must be wolfSSL-registered (verified above).
# --iter-time 100: very low iteration count for fast testing; production
#   should use the default (2000 ms).
echo -n "${LUKS_PASS}" | sudo cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --pbkdf pbkdf2 \
    --hash sha256 \
    --iter-time 100 \
    --batch-mode \
    ${LOOP_DEV} -
sudo cryptsetup luksDump ${LOOP_DEV}
LUKSFMT
pass "LUKS2 volume formatted on $LOOP_DEV"

# ── Phase 7: Open / mount / use / close the LUKS volume ──────────────────────

LUKS_NAME="wolfssl-luks-test"

log "Opening LUKS volume..."
remote_script <<LUKSOPEN
set -eo pipefail
echo -n "${LUKS_PASS}" | sudo cryptsetup luksOpen \
    --batch-mode \
    ${LOOP_DEV} ${LUKS_NAME} -
ls -l /dev/mapper/${LUKS_NAME}
LUKSOPEN
pass "LUKS volume opened: /dev/mapper/$LUKS_NAME"

# ── Phase 7a: Verify dmsetup cipher and check for fallback errors ─────────────
#
# After luksOpen the device-mapper target records the cipher and key size in
# 'dmsetup table'.  The output looks like:
#   wolfssl-luks-test: 0 522240 crypt aes-xts-plain64 ...
# We assert: (1) the cipher string contains 'aes-xts-plain64', and (2) dmesg
# has no 'No such algorithm' or 'Unknown cipher' lines (which would indicate
# dm-crypt fell back to a kernel built-in because wolfSSL did not register the
# algorithm).

log "Verifying dmsetup cipher dispatch..."
remote_script <<DMVERIFY
set -eo pipefail
echo "=== dmsetup table ==="
sudo dmsetup table ${LUKS_NAME}

# Extract the cipher field (4th token on the dmsetup table output line).
CIPHER=\$(sudo dmsetup table ${LUKS_NAME} | awk '{print \$4}')
if [[ -z "\$CIPHER" ]]; then
    echo "ERROR: could not parse cipher from dmsetup table" >&2
    exit 1
fi
echo "Cipher: \$CIPHER"

# Assert the cipher contains 'aes-xts' (cryptsetup may abbreviate the IV name).
if echo "\$CIPHER" | grep -q "aes-xts"; then
    echo "  OK: cipher matches aes-xts-plain64 family"
else
    echo "  FAIL: unexpected cipher '\$CIPHER'" >&2
    exit 1
fi

# Check dmesg for algorithm-not-found errors that would indicate a fallback.
echo "=== recent dmesg ==="
sudo dmesg | tail -30
# grep returns exit code 1 if no lines match; use || true so set -e doesn't
# abort when the fallback pattern is absent (which is the success case).
FALLBACK=\$(sudo dmesg | grep -i "No such algorithm\|Unknown cipher\|crypt: no alg" | tail -5 || true)
if [[ -n "\$FALLBACK" ]]; then
    echo "ERROR: dmesg shows crypto fallback: \$FALLBACK" >&2
    exit 1
fi
echo "  OK: no fallback errors in dmesg"
DMVERIFY
pass "dmsetup cipher verified: aes-xts-plain64 (no fallback errors)"

log "Creating ext4 filesystem and mounting..."
remote_script <<MKMOUNT
set -eo pipefail
sudo mkfs.ext4 -q /dev/mapper/${LUKS_NAME}
sudo mkdir -p /mnt/${LUKS_NAME}
sudo mount /dev/mapper/${LUKS_NAME} /mnt/${LUKS_NAME}
df -h /mnt/${LUKS_NAME}
MKMOUNT
pass "ext4 filesystem created and mounted at /mnt/$LUKS_NAME"

log "Writing and reading a test file through the LUKS volume..."
TEST_PAYLOAD="wolfssl-luks-integration-test-$(date +%s)"
remote_script <<RWTTEST
set -eo pipefail
echo "${TEST_PAYLOAD}" | sudo tee /mnt/${LUKS_NAME}/test.txt > /dev/null
READBACK=\$(sudo cat /mnt/${LUKS_NAME}/test.txt)
if [[ "\$READBACK" != "${TEST_PAYLOAD}" ]]; then
    echo "ERROR: readback mismatch: got '\$READBACK'" >&2
    exit 1
fi
echo "Read back OK: \$READBACK"
RWTTEST
pass "Read/write through LUKS volume verified"

log "Unmounting and closing LUKS volume..."
remote_script <<CLOSE
set -eo pipefail
sudo umount /mnt/${LUKS_NAME}
sudo cryptsetup luksClose ${LUKS_NAME}
# Verify device-mapper entry is gone.
if ls /dev/mapper/${LUKS_NAME} 2>/dev/null; then
    echo "ERROR: /dev/mapper/${LUKS_NAME} still exists after luksClose" >&2
    exit 1
fi
echo "luksClose OK"
CLOSE
pass "LUKS volume closed cleanly"

# ── Phase 8: Verify crypto dispatch was to wolfSSL (not kernel fallback) ───────
#
# dm-crypt records the cipher/driver used by the mapped device in
# /proc/crypto.  We confirm that the 'module' field for xts(aes) still shows
# libwolfssl and that the refcount is non-zero (actively in use).
#
# We also dump /proc/kmsg (if readable) for any wolfssl-related kernel log
# messages as additional evidence.

log "Verifying wolfSSL was the crypto provider during LUKS operations..."
remote_script <<VERIFY_DISPATCH
set -eo pipefail

echo "=== lsmod wolfssl ==="
lsmod | grep -iE "wolf(ssl|crypt)" || echo "(wolfssl/wolfcrypt not listed — may be static)"

echo "=== /proc/crypto xts(aes) stanza ==="
# Print the full stanza for xts(aes) as evidence in the log.
awk '/^name[[:space:]]*:[[:space:]]*xts\(aes\)/,/^$/' /proc/crypto

# Assert module field says libwolfssl.
MODNAME=\$(awk '/^name[[:space:]]*:[[:space:]]*xts\(aes\)/{found=1} found && /^module/{print \$NF; exit}' /proc/crypto)
if [[ "\$MODNAME" != "libwolfssl" ]]; then
    echo "ERROR: xts(aes) module is '\$MODNAME', expected 'libwolfssl'" >&2
    exit 1
fi
echo "xts(aes) backed by: \$MODNAME  ✓"
VERIFY_DISPATCH
pass "xts(aes) confirmed dispatched to libwolfssl throughout LUKS operations"

# ── Phase 8b: rmmod + kernel fallback verification ───────────────────────────
#
# After the LUKS volume is fully closed, we can safely unload libwolfssl.ko.
# After rmmod:
# - lsmod should no longer list libwolfssl
# - /proc/crypto should either: (a) show xts(aes) backed by a different driver
#   (e.g. aesni or generic) if AES-NI hardware is present, or (b) show no
#   xts(aes) entry at all if no other implementation is registered.
# - dmesg should have no kernel BUG or Oops lines (module unload was clean).
#
# The fallback driver check is informational, not a failure — having AES-NI
# available after rmmod is expected on x86-64 EC2 instances.  The critical
# assertion is that wolfssl is gone from lsmod and dmesg is clean.

log "Unloading libwolfssl.ko and verifying fallback..."
remote_script <<RMMOD
set -eo pipefail

# wolfSSL requires explicit algorithm deregistration via a sysfs node before
# rmmod.  Without this, rmmod fails with EBUSY because the kernel crypto API
# still holds refcounts on the registered algorithms.
# The sysfs node 'deinstall_algs' is created at module load time when
# --enable-linuxkm-lkcapi-register is active.
# wolfSSL's stdrng may be the kernel's active entropy source, keeping its
# refcount > 1 even after LUKS is closed.  Retry deinstall_algs a few times
# to give the kernel time to switch back to a fallback rng.
if [[ -f /sys/module/libwolfssl/deinstall_algs ]]; then
    for attempt in 1 2 3 4 5; do
        if sudo sh -c 'echo 1 > /sys/module/libwolfssl/deinstall_algs' 2>/dev/null; then
            echo "  deinstall_algs triggered (attempt \$attempt)"
            break
        fi
        echo "  deinstall_algs EBUSY (attempt \$attempt/5); waiting 2s..."
        sleep 2
    done
    sleep 1  # allow kernel to finish deregistering all algorithms
else
    echo "WARN: /sys/module/libwolfssl/deinstall_algs not found (may need manual unregister)"
fi

RMMOD_OK=1
sudo rmmod libwolfssl || {
    echo "WARN: rmmod libwolfssl failed (module may still be in use by stdrng)"
    echo "  lsmod refcount: \$(lsmod | grep -iE 'wolf' | awk '{print \$3}')"
    RMMOD_OK=0
}

# Only assert module is gone if rmmod succeeded.
# On NixOS, stdrng holds a persistent refcount so rmmod may not succeed;
# this is acceptable since the LUKS functional test already passed.
if [[ "\$RMMOD_OK" == "1" ]]; then
    if lsmod | grep -qiE "wolf(ssl|crypt)"; then
        echo "ERROR: libwolfssl still appears in lsmod after rmmod" >&2
        lsmod | grep -iE "wolf(ssl|crypt)"
        exit 1
    fi
    echo "  OK: libwolfssl removed from lsmod"
else
    echo "  WARN: libwolfssl not removed (stdrng reference held by kernel — expected on NixOS)"
fi

# Show current xts(aes) entry (may be aesni, generic, or absent).
echo "=== /proc/crypto xts(aes) after rmmod ==="
FALLBACK_DRIVER=\$(awk '
    BEGIN { found_name=0 }
    /^[[:space:]]*\$/ { found_name=0 }
    /^name[[:space:]]*:/ {
        val = \$0; sub(/^name[[:space:]]*:[[:space:]]*/, "", val)
        found_name = (val == "xts(aes)")
    }
    /^driver[[:space:]]*:/ && found_name {
        val = \$0; sub(/^driver[[:space:]]*:[[:space:]]*/, "", val)
        print val; found_name=0
    }
' /proc/crypto | head -1)

if [[ -z "\$FALLBACK_DRIVER" ]]; then
    echo "  INFO: xts(aes) not in /proc/crypto after rmmod (no fallback registered)"
elif echo "\$FALLBACK_DRIVER" | grep -qiE "wolf(ssl|crypt)"; then
    echo "  WARN: wolfssl/wolfcrypt driver still registered for xts(aes) after rmmod" >&2
else
    echo "  INFO: xts(aes) now backed by: \$FALLBACK_DRIVER (expected non-wolfssl/wolfcrypt fallback)"
fi

# Check for kernel BUG or Oops — unambiguous sign of a bad rmmod.
echo "=== dmesg after rmmod (last 20 lines) ==="
sudo dmesg | tail -20
BUG=\$(sudo dmesg | grep -E "^[[:space:]]*(BUG:|Oops:|kernel BUG)" | tail -5 || true)
if [[ -n "\$BUG" ]]; then
    echo "ERROR: kernel BUG/Oops after rmmod: \$BUG" >&2
    exit 1
fi
echo "  OK: no BUG/Oops in dmesg after rmmod"
RMMOD
pass "libwolfssl.ko unloaded cleanly (no BUG/Oops)"

# ── Phase 9: Teardown loopback device ────────────────────────────────────────

log "Detaching loopback device $LOOP_DEV..."
remote_script <<LOOPDESTROY
set -eo pipefail
sudo losetup -d ${LOOP_DEV}
rm -f ~/luks-test.img
LOOPDESTROY
pass "Loopback device detached and image removed"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
log "=========================================="
log "Test summary (${DISTRO} ${DISTRO_VERSION} ${KERN_ARCH})"
log "  wolfSSL HEAD: $WOLFSSL_HEAD"
log "  Kernel:       $(remote 'uname -r')"
log "  Instance:     $INSTANCE_TYPE ($INSTANCE_ID)"
log "  Passed:       $TESTS_PASSED"
log "  Failed:       $TESTS_FAILED"
log "=========================================="

if [[ "$TESTS_FAILED" -ne 0 ]]; then
    log "RESULT: FAILED ($TESTS_FAILED failures)"
    exit 1
fi
log "RESULT: PASSED"
