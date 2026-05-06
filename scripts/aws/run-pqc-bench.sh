#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# scripts/aws/run-pqc-bench.sh
#
# Provisions an EC2 instance, builds wolfSSL with PQC flags, runs the PQC
# benchmark suite, normalises the output, and downloads the results.
# Tears everything down unless KEEP_INSTANCE=1.
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
#     ARM64             — set to 1 for ARM64/Graviton (c7g.2xlarge)
#     INSTANCE_TYPE     — override default instance type
#     KEEP_INSTANCE     — set to 1 to leave instance running for debugging
#     SSH_KEY_PATH      — where to store ephemeral SSH key (default: /tmp)
#     OUTPUT_DIR        — local dir for downloaded results (default: ./results)
#     WOLFSSL_REPO      — default: https://github.com/wolfSSL/wolfssl
#     WOLFSSL_REF       — default: master
#     DISK_SIZE_GB      — override default disk size (default: 30)
#
# ============================================================================
# USAGE
# ============================================================================
#
#   # x86_64 benchmark (AL2023, c7i.2xlarge):
#   ./scripts/aws/run-pqc-bench.sh AdministratorAccess-921772462201
#
#   # ARM64/Graviton benchmark:
#   ARM64=1 ./scripts/aws/run-pqc-bench.sh <profile>
#
#   # Custom wolfSSL branch:
#   WOLFSSL_REF=feature/pqc-benchmark ./scripts/aws/run-pqc-bench.sh <profile>
#
#   # Keep instance alive for debugging:
#   KEEP_INSTANCE=1 ./scripts/aws/run-pqc-bench.sh <profile>
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
ARM64="${ARM64:-0}"
KEEP_INSTANCE="${KEEP_INSTANCE:-0}"
SSH_KEY_PATH="${SSH_KEY_PATH:-/tmp}"
DISK_SIZE_GB="${DISK_SIZE_GB:-30}"
WOLFSSL_REPO="${WOLFSSL_REPO:-https://github.com/wolfSSL/wolfssl}"
WOLFSSL_REF="${WOLFSSL_REF:-master}"
OUTPUT_DIR="${OUTPUT_DIR:-./results}"

# ── Architecture settings ─────────────────────────────────────────────────────

if [[ "$ARM64" == "1" ]]; then
    : "${INSTANCE_TYPE:=c7g.2xlarge}"   # Graviton 3: 8 vCPU / 16 GB
    ARCH_SUFFIX="-arm64"
    KERN_ARCH="aarch64"
    # AL2023 arm64 AMI (owner: Amazon; same release as x86 image used in verify)
    AMI_OWNER="137112412989"
    AMI_NAME_PATTERN="al2023-ami-2023*-kernel-6*-arm64"
    INSTANCE_USER="ec2-user"
else
    : "${INSTANCE_TYPE:=c7i.2xlarge}"   # Intel Sapphire Rapids: 8 vCPU / 16 GB, AVX-512
    ARCH_SUFFIX=""
    KERN_ARCH="x86_64"
    # AL2023 x86_64 AMI
    AMI_OWNER="137112412989"
    AMI_NAME_PATTERN="al2023-ami-2023*-kernel-6*-x86_64"
    INSTANCE_USER="ec2-user"
fi

# ── AWS CLI shorthand ─────────────────────────────────────────────────────────

A="--profile $AWS_PROFILE --region $AWS_REGION"

# ── Run ID and ephemeral resource names ──────────────────────────────────────

RUN_ID="pqc-bench-${KERN_ARCH}-$(date +%Y%m%d-%H%M%S)"
KEY_NAME="$RUN_ID"
SG_NAME="$RUN_ID"
KEY_FILE="$SSH_KEY_PATH/${RUN_ID}.pem"

INSTANCE_ID=""
SG_ID=""
PUBLIC_IP=""
SERIAL_PID=""

# ── Logging helpers ───────────────────────────────────────────────────────────

log()  { echo "=== $(date +%H:%M:%S) $*"; }
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; }

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
# Used to stream live output during long phases (build, benchmark run).
# Best-effort: failures do not abort the script.

watch_serial() {
    local duration="${1:-300}"
    local serial_key
    serial_key=$(mktemp /tmp/serial-XXXXXX)
    rm -f "$serial_key"
    ssh-keygen -t rsa -b 2048 -N "" -f "$serial_key" -q

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

    timeout "$duration" \
        ssh -i "$serial_key" \
            -p 9001 \
            -o StrictHostKeyChecking=no \
            -o ServerAliveInterval=10 \
            -o ServerAliveCountMax=12 \
            "${INSTANCE_ID}.port0@serial-console.ec2-instance-connect.${AWS_REGION}.aws" \
        2>/dev/null &
    SERIAL_PID=$!
    rm -f "$serial_key" "${serial_key}.pub"
}

stop_serial() {
    if [[ -n "${SERIAL_PID:-}" ]]; then
        kill "$SERIAL_PID" 2>/dev/null || true
        wait "$SERIAL_PID" 2>/dev/null || true
    fi
    SERIAL_PID=""
}

# ── Cleanup ───────────────────────────────────────────────────────────────────

cleanup() {
    local rc=$?
    echo ""
    log "Cleanup"

    stop_serial

    if [[ "$KEEP_INSTANCE" == "1" && -n "$INSTANCE_ID" ]]; then
        log "KEEP_INSTANCE=1 — instance left running"
        log "  Instance: $INSTANCE_ID ($PUBLIC_IP)"
        log "  SSH:      ssh -i $KEY_FILE ${INSTANCE_USER}@$PUBLIC_IP"
        log "  Terminate: aws ec2 terminate-instances $A --instance-ids $INSTANCE_ID"
        return $rc
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

    log "Cleanup complete"
    return $rc
}

trap cleanup EXIT

# ── Phase 0: Provision EC2 ────────────────────────────────────────────────────

log "Verifying AWS credentials (profile: $AWS_PROFILE, region: $AWS_REGION)"
CALLER=$(aws sts get-caller-identity $A --query 'Arn' --output text)
log "Authenticated as: $CALLER"

log "Finding latest AL2023 ${KERN_ARCH} AMI..."
AMI_ID=$(aws ec2 describe-images $A \
    --owners "$AMI_OWNER" \
    --filters \
        "Name=name,Values=${AMI_NAME_PATTERN}" \
        "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)
if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    echo "ERROR: No AMI found (owner=$AMI_OWNER pattern=$AMI_NAME_PATTERN)"
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
    --description "pqc-bench ($RUN_ID)" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress $A \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 > /dev/null

log "Launching $INSTANCE_TYPE instance (AL2023 ${KERN_ARCH})..."
INSTANCE_ID=$(aws ec2 run-instances $A \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --block-device-mappings \
        "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${DISK_SIZE_GB},\"VolumeType\":\"gp3\"}}]" \
    --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=$RUN_ID},{Key=Project,Value=pqc-bench}]" \
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

log "Waiting for SSH..."
watch_serial 180
wait_for_ssh 60
stop_serial

KVER=$(remote 'uname -r')
log "Connected. Kernel: $KVER"
pass "EC2 instance provisioned: $INSTANCE_ID (kernel $KVER)"

# ── Phase 1: Install build dependencies ──────────────────────────────────────
# AL2023 uses dnf. We need the same toolchain as a local build:
# gcc, make, autoconf, automake, libtool, git, python3.
# No kernel-devel needed — this is a userspace build only.

log "Installing build dependencies..."
remote_script <<'DEPS'
set -euo pipefail

# Retry dnf makecache — fresh EC2 instances may have uninitialized metadata.
for attempt in 1 2 3; do
    if sudo dnf makecache -q; then break; fi
    echo "dnf makecache attempt ${attempt} failed; retrying in 10s..." >&2
    sleep 10
    [[ $attempt -eq 3 ]] && { echo "ERROR: dnf makecache failed after 3 attempts" >&2; exit 1; }
done

sudo dnf install -y -q \
    gcc gcc-c++ \
    make \
    autoconf automake libtool \
    git \
    python3 \
    kernel-tools   # provides cpupower for governor pinning

echo "gcc: $(gcc --version | head -1)"
echo "python3: $(python3 --version)"
echo "git: $(git --version)"
DEPS
pass "Build dependencies installed"

# ── Phase 1b: Pin CPU governor to performance ─────────────────────────────────
# EC2 instances default to 'powersave' or 'schedutil' which allows the CPU to
# clock down between operations, producing variable and artificially low
# benchmark numbers.  'performance' holds the CPU at its maximum sustained
# clock for the duration of the run.
#
# c7i (Sapphire Rapids): sustained 3.2 GHz all-core
# c7g (Graviton3):       sustained 2.6 GHz all-core
#
# cpupower is best-effort: some instance types or kernels may not expose the
# governor interface.  A warning is printed but the run continues — the
# benchmark result header will note whether pinning succeeded.

log "Pinning CPU governor to performance..."
GOVERNOR_SET=$(remote_script <<'GOVERNOR'
set -uo pipefail

NCPU=$(nproc)
echo "CPUs: $NCPU  arch: $(uname -m)"

# Check current governor before changing
CURRENT=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
echo "Current governor: $CURRENT"

if [[ "$CURRENT" == "unknown" ]]; then
    echo "WARN: cpufreq governor interface not available on this instance/kernel"
    echo "GOVERNOR_OK=0"
else
    sudo cpupower frequency-set -g performance 2>&1 || {
        echo "WARN: cpupower frequency-set failed (non-fatal)"
        echo "GOVERNOR_OK=0"
        exit 0
    }
    AFTER=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    echo "Governor set to: $AFTER"
    if [[ "$AFTER" == "performance" ]]; then
        echo "GOVERNOR_OK=1"
    else
        echo "GOVERNOR_OK=0"
    fi
fi
GOVERNOR
)
if echo "$GOVERNOR_SET" | grep -q "GOVERNOR_OK=1"; then
    pass "CPU governor pinned to performance"
else
    echo "  WARN: CPU governor not pinned (results may show clock variability)" >&2
fi

# ── Phase 2: Clone wolfSSL ────────────────────────────────────────────────────

log "Cloning wolfSSL (repo=${WOLFSSL_REPO} ref=${WOLFSSL_REF})..."
watch_serial 120
remote_script <<CLONE
set -euo pipefail
git clone --depth=10 --branch "${WOLFSSL_REF}" \
    "${WOLFSSL_REPO}" ~/wolfssl 2>&1 | tail -5
echo "HEAD: \$(git -C ~/wolfssl rev-parse HEAD)"
CLONE
stop_serial

WOLFSSL_HEAD=$(remote 'git -C ~/wolfssl rev-parse HEAD')
log "wolfSSL HEAD: $WOLFSSL_HEAD"
pass "wolfSSL cloned (${WOLFSSL_REF} @ ${WOLFSSL_HEAD:0:12})"

# ── Phase 3: Copy benchmark scripts onto the instance ────────────────────────
# The scripts live in wolfcrypt/benchmark/ on the cloned branch.
# If they don't exist yet (e.g. building from upstream master before the PR
# merges), copy them from the local PQC-LEO repo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PQC_LEO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

REMOTE_BENCH_DIR="\$HOME/wolfssl/wolfcrypt/benchmark"

BENCH_SH_LOCAL="$PQC_LEO_ROOT/../../WORK/wolfssl/wolfcrypt/benchmark/pqc_bench.sh"
PARSE_PY_LOCAL="$PQC_LEO_ROOT/../../WORK/wolfssl/wolfcrypt/benchmark/pqc_parse.py"

# Check if scripts already exist on the remote (cloned from the branch).
BENCH_EXISTS=$(remote "test -f ${REMOTE_BENCH_DIR}/pqc_bench.sh && echo yes || echo no")
PARSE_EXISTS=$(remote "test -f ${REMOTE_BENCH_DIR}/pqc_parse.py && echo yes || echo no")

if [[ "$BENCH_EXISTS" == "no" ]]; then
    if [[ -f "$BENCH_SH_LOCAL" ]]; then
        log "pqc_bench.sh not in cloned branch — copying from local..."
        scp -o StrictHostKeyChecking=no -i "$KEY_FILE" \
            "$BENCH_SH_LOCAL" \
            "${INSTANCE_USER}@${PUBLIC_IP}:${REMOTE_BENCH_DIR}/pqc_bench.sh"
        remote "chmod +x ${REMOTE_BENCH_DIR}/pqc_bench.sh"
        pass "pqc_bench.sh copied from local"
    else
        echo "ERROR: pqc_bench.sh not found in clone or locally at $BENCH_SH_LOCAL" >&2
        exit 1
    fi
else
    pass "pqc_bench.sh present in cloned branch"
fi

if [[ "$PARSE_EXISTS" == "no" ]]; then
    if [[ -f "$PARSE_PY_LOCAL" ]]; then
        log "pqc_parse.py not in cloned branch — copying from local..."
        scp -o StrictHostKeyChecking=no -i "$KEY_FILE" \
            "$PARSE_PY_LOCAL" \
            "${INSTANCE_USER}@${PUBLIC_IP}:${REMOTE_BENCH_DIR}/pqc_parse.py"
        remote "chmod +x ${REMOTE_BENCH_DIR}/pqc_parse.py"
        pass "pqc_parse.py copied from local"
    else
        echo "ERROR: pqc_parse.py not found in clone or locally at $PARSE_PY_LOCAL" >&2
        exit 1
    fi
else
    pass "pqc_parse.py present in cloned branch"
fi

# ── Phase 4: Build and run benchmarks ────────────────────────────────────────
# pqc_bench.sh handles configure + make + benchmark runs in one call.
# This is the longest phase: configure ~1 min, build ~3–5 min, benchmarks
# ~10–20 min depending on instance type and algorithm set.
# Stream serial console output for live visibility.

log "Running PQC benchmarks (configure + build + run, expect 20-30 min)..."
watch_serial 2400   # 40 min ceiling — serial console is best-effort
remote_script <<'BENCH_RUN'
set -euo pipefail
cd ~/wolfssl

# taskset -c 0-3: pin to the first 4 physical cores on a single socket.
# c7i and c7g are single-socket so this is largely a no-op, but it prevents
# the OS scheduler from migrating the benchmark process mid-run, which can
# cause cache-cold restarts and inflated timing variance on SLH-DSA sign
# (which takes ~1 second per call and is sensitive to migrations).
# We use 4 cores rather than all 8 so the benchmark's single-threaded timed
# loops aren't fighting the build parallelism from a concurrent make -j8.
# The build step (make -j$(nproc)) runs before taskset takes effect.
taskset -c 0-3 \
    ./wolfcrypt/benchmark/pqc_bench.sh \
        --output ~/pqc_results_raw.csv \
    2>&1 | tee ~/pqc_bench.log
echo "pqc_bench.sh exit: $?"
BENCH_RUN
stop_serial
pass "pqc_bench.sh completed"

# ── Phase 5: Normalise output ─────────────────────────────────────────────────

log "Normalising CSV output (wolfssl and pqcleo formats)..."
remote_script <<'NORMALISE'
set -euo pipefail
cd ~/wolfssl

# wolfssl normalised format
python3 wolfcrypt/benchmark/pqc_parse.py \
    --format=wolfssl \
    --output ~/pqc_results_wolfssl.csv \
    ~/pqc_results_raw.csv
echo "wolfssl CSV rows: $(wc -l < ~/pqc_results_wolfssl.csv)"

# pqcleo pipe-delimited format for cross-library comparison
python3 wolfcrypt/benchmark/pqc_parse.py \
    --format=pqcleo \
    --output ~/pqc_results_pqcleo.psv \
    ~/pqc_results_raw.csv
echo "pqcleo PSV rows: $(wc -l < ~/pqc_results_pqcleo.psv)"
NORMALISE
pass "Output normalised"

# ── Phase 6: Download results ─────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"

# Tag output files with run ID so multiple runs don't clobber each other.
LOCAL_PREFIX="${OUTPUT_DIR}/${RUN_ID}"

log "Downloading results to ${OUTPUT_DIR}/..."
scp -o StrictHostKeyChecking=no -i "$KEY_FILE" \
    "${INSTANCE_USER}@${PUBLIC_IP}:~/pqc_results_raw.csv" \
    "${LOCAL_PREFIX}_raw.csv"

scp -o StrictHostKeyChecking=no -i "$KEY_FILE" \
    "${INSTANCE_USER}@${PUBLIC_IP}:~/pqc_results_wolfssl.csv" \
    "${LOCAL_PREFIX}_wolfssl.csv"

scp -o StrictHostKeyChecking=no -i "$KEY_FILE" \
    "${INSTANCE_USER}@${PUBLIC_IP}:~/pqc_results_pqcleo.psv" \
    "${LOCAL_PREFIX}_pqcleo.psv"

scp -o StrictHostKeyChecking=no -i "$KEY_FILE" \
    "${INSTANCE_USER}@${PUBLIC_IP}:~/pqc_bench.log" \
    "${LOCAL_PREFIX}_bench.log"

pass "Results downloaded"

# ── Write a metadata sidecar ──────────────────────────────────────────────────
# Record the run environment alongside the result files so numbers are
# self-describing when shared or archived.

GOVERNOR_FINAL=$(remote \
    'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown')
CPU_MODEL=$(remote \
    'grep "^model name\|^Model name\|^CPU part" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs')

cat > "${LOCAL_PREFIX}_meta.txt" <<META
run_id:        $RUN_ID
date:          $(date -u +%Y-%m-%dT%H:%M:%SZ)
instance_type: $INSTANCE_TYPE
architecture:  $KERN_ARCH
cpu_model:     $CPU_MODEL
kernel:        $KVER
governor:      $GOVERNOR_FINAL
wolfssl_repo:  $WOLFSSL_REPO
wolfssl_ref:   $WOLFSSL_REF
wolfssl_head:  $WOLFSSL_HEAD
taskset:       0-3
META

# ── Summary ───────────────────────────────────────────────────────────────────

DATA_ROWS=$(tail -n +2 "${LOCAL_PREFIX}_wolfssl.csv" | wc -l | tr -d ' ')

echo ""
log "=========================================="
log "Run: $RUN_ID"
log "  Architecture:  $KERN_ARCH ($INSTANCE_TYPE)"
log "  CPU:           $CPU_MODEL"
log "  Governor:      $GOVERNOR_FINAL"
log "  wolfSSL:       ${WOLFSSL_REF} @ ${WOLFSSL_HEAD:0:12}"
log "  Kernel:        $KVER"
log "  Data rows:     $DATA_ROWS"
log "  Raw CSV:       ${LOCAL_PREFIX}_raw.csv"
log "  Wolfssl CSV:   ${LOCAL_PREFIX}_wolfssl.csv"
log "  PQC-LEO PSV:   ${LOCAL_PREFIX}_pqcleo.psv"
log "  Build log:     ${LOCAL_PREFIX}_bench.log"
log "  Metadata:      ${LOCAL_PREFIX}_meta.txt"
log "=========================================="
log "RESULT: PASSED"
