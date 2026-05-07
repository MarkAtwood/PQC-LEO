#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# scripts/aws/run-pqc-bench-all.sh
#
# Provisions an EC2 instance and benchmarks every available PQC library:
#   - wolfSSL  (native ML-KEM, ML-DSA, SLH-DSA-SHAKE + SLH-DSA-SHA2)
#   - liboqs   (native ML-KEM, ML-DSA, SLH-DSA all parameter sets)
#   - OpenSSL  (ML-KEM, ML-DSA via built-in provider; SLH-DSA via oqs-provider)
#   - CIRCL    (ML-KEM, ML-DSA, SLH-DSA pure-Go)
#
# Normalises all output to a common CSV schema via pqc_parse.py, then merges
# into a single comparison CSV. Downloads all artefacts locally.
#
# ============================================================================
# PREREQUISITES
# ============================================================================
#
#   1. AWS CLI v2 installed and configured:
#        aws configure sso && aws sso login --profile <profile>
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
#     WOLFSSL_REPO      — default: https://github.com/MarkAtwood/wolfssl
#     WOLFSSL_REF       — default: feature/pqc-benchmark
#     LIBOQS_REF        — liboqs git ref (default: main)
#     OPENSSL_REF       — OpenSSL git ref (default: master)
#     CIRCL_REF         — CIRCL git ref (default: master)
#     BENCH_SECS        — seconds per operation for liboqs (default: 3)
#     DISK_SIZE_GB      — override default disk size (default: 40)
#
# ============================================================================
# USAGE
# ============================================================================
#
#   # x86_64 (c7i.2xlarge, Intel Sapphire Rapids):
#   ./scripts/aws/run-pqc-bench-all.sh AdministratorAccess-921772462201
#
#   # ARM64/Graviton (c7g.2xlarge):
#   ARM64=1 ./scripts/aws/run-pqc-bench-all.sh <profile>
#
#   # Keep instance alive for debugging:
#   KEEP_INSTANCE=1 ./scripts/aws/run-pqc-bench-all.sh <profile>
#
# ============================================================================

set -euo pipefail

# ── Parameters ────────────────────────────────────────────────────────────────

AWS_PROFILE="${1:-${AWS_PROFILE:-}}"
if [[ -z "$AWS_PROFILE" ]]; then
    echo "ERROR: AWS_PROFILE not set.  Usage: $0 <aws-profile>"; exit 1
fi

AWS_REGION="${AWS_REGION:-us-west-2}"
ARM64="${ARM64:-0}"
KEEP_INSTANCE="${KEEP_INSTANCE:-0}"
SSH_KEY_PATH="${SSH_KEY_PATH:-/tmp}"
DISK_SIZE_GB="${DISK_SIZE_GB:-40}"
OUTPUT_DIR="${OUTPUT_DIR:-./results}"
WOLFSSL_REPO="${WOLFSSL_REPO:-https://github.com/MarkAtwood/wolfssl}"
WOLFSSL_REF="${WOLFSSL_REF:-feature/pqc-benchmark}"
LIBOQS_REF="${LIBOQS_REF:-main}"
OPENSSL_REF="${OPENSSL_REF:-master}"
CIRCL_REF="${CIRCL_REF:-master}"
BENCH_SECS="${BENCH_SECS:-3}"

# ── Architecture ──────────────────────────────────────────────────────────────

if [[ "$ARM64" == "1" ]]; then
    : "${INSTANCE_TYPE:=c7g.2xlarge}"
    KERN_ARCH="aarch64"
    AMI_OWNER="137112412989"
    AMI_NAME_PATTERN="al2023-ami-2023*-kernel-6*-arm64"
    INSTANCE_USER="ec2-user"
else
    : "${INSTANCE_TYPE:=c7i.2xlarge}"
    KERN_ARCH="x86_64"
    AMI_OWNER="137112412989"
    AMI_NAME_PATTERN="al2023-ami-2023*-kernel-6*-x86_64"
    INSTANCE_USER="ec2-user"
fi

# ── AWS CLI shorthand ─────────────────────────────────────────────────────────

A="--profile $AWS_PROFILE --region $AWS_REGION"

# ── Run ID ────────────────────────────────────────────────────────────────────

RUN_ID="pqc-all-${KERN_ARCH}-$(date +%Y%m%d-%H%M%S)"
KEY_NAME="$RUN_ID"
SG_NAME="$RUN_ID"
KEY_FILE="$SSH_KEY_PATH/${RUN_ID}.pem"

INSTANCE_ID=""
SG_ID=""
PUBLIC_IP=""
SERIAL_PID=""

# ── Helpers ───────────────────────────────────────────────────────────────────

log()  { echo "=== $(date +%H:%M:%S) $*"; }
pass() { echo "  PASS: $*"; }

remote() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=6 \
        -i "$KEY_FILE" "${INSTANCE_USER}@$PUBLIC_IP" "$@"
}

remote_script() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=6 \
        -i "$KEY_FILE" "${INSTANCE_USER}@$PUBLIC_IP" 'bash -s'
}

wait_for_ssh() {
    local attempts="${1:-36}"
    for i in $(seq 1 "$attempts"); do
        if remote 'true' 2>/dev/null; then return 0; fi
        sleep 5
    done
    echo "ERROR: SSH not available after $((attempts * 5)) s"; return 1
}

watch_serial() {
    local duration="${1:-300}"
    local sk; sk=$(mktemp /tmp/serial-XXXXXX); rm -f "$sk"
    ssh-keygen -t rsa -b 2048 -N "" -f "$sk" -q
    aws ec2-instance-connect send-serial-console-ssh-public-key $A \
        --instance-id "$INSTANCE_ID" --serial-port 0 \
        --ssh-public-key "$(cat "${sk}.pub")" 2>/dev/null || { rm -f "$sk" "${sk}.pub"; SERIAL_PID=""; return 0; }
    timeout "$duration" ssh -i "$sk" -p 9001 \
        -o StrictHostKeyChecking=no -o ServerAliveInterval=10 -o ServerAliveCountMax=12 \
        "${INSTANCE_ID}.port0@serial-console.ec2-instance-connect.${AWS_REGION}.aws" \
        2>/dev/null &
    SERIAL_PID=$!
    rm -f "$sk" "${sk}.pub"
}

stop_serial() {
    [[ -n "${SERIAL_PID:-}" ]] && { kill "$SERIAL_PID" 2>/dev/null || true; wait "$SERIAL_PID" 2>/dev/null || true; }
    SERIAL_PID=""
}

cleanup() {
    local rc=$?
    echo ""; log "Cleanup"
    stop_serial
    if [[ "$KEEP_INSTANCE" == "1" && -n "$INSTANCE_ID" ]]; then
        log "KEEP_INSTANCE=1 — leaving instance running"
        log "  SSH: ssh -i $KEY_FILE ${INSTANCE_USER}@$PUBLIC_IP"
        log "  Terminate: aws ec2 terminate-instances $A --instance-ids $INSTANCE_ID"
        return $rc
    fi
    [[ -n "$INSTANCE_ID" ]] && {
        aws ec2 terminate-instances $A --instance-ids "$INSTANCE_ID" \
            --query 'TerminatingInstances[0].CurrentState.Name' --output text 2>/dev/null || true
        aws ec2 wait instance-terminated $A --instance-ids "$INSTANCE_ID" 2>/dev/null || sleep 30
    }
    [[ -n "${KEY_NAME:-}" ]] && aws ec2 delete-key-pair $A --key-name "$KEY_NAME" 2>/dev/null || true
    [[ -n "${SG_ID:-}" ]]    && aws ec2 delete-security-group $A --group-id "$SG_ID" 2>/dev/null || true
    rm -f "$KEY_FILE"
    log "Cleanup complete"; return $rc
}
trap cleanup EXIT

# ── Phase 0: Provision ────────────────────────────────────────────────────────

log "Verifying AWS credentials (profile=$AWS_PROFILE region=$AWS_REGION)"
CALLER=$(aws sts get-caller-identity $A --query 'Arn' --output text)
log "Authenticated as: $CALLER"

log "Finding latest AL2023 ${KERN_ARCH} AMI..."
AMI_ID=$(aws ec2 describe-images $A --owners "$AMI_OWNER" \
    --filters "Name=name,Values=${AMI_NAME_PATTERN}" "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)
[[ -z "$AMI_ID" || "$AMI_ID" == "None" ]] && { echo "ERROR: AMI not found"; exit 1; }
log "AMI: $AMI_ID"

log "Creating SSH key pair: $KEY_NAME"
aws ec2 create-key-pair $A --key-name "$KEY_NAME" --key-type rsa --key-format pem \
    --query 'KeyMaterial' --output text > "$KEY_FILE"
chmod 600 "$KEY_FILE"

log "Creating security group: $SG_NAME"
VPC_ID=$(aws ec2 describe-vpcs $A --filters "Name=is-default,Values=true" \
    --query 'Vpcs[0].VpcId' --output text)
SG_ID=$(aws ec2 create-security-group $A --group-name "$SG_NAME" \
    --description "pqc-bench-all ($RUN_ID)" --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress $A --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 > /dev/null

log "Launching $INSTANCE_TYPE..."
INSTANCE_ID=$(aws ec2 run-instances $A \
    --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" \
    --block-device-mappings \
        "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${DISK_SIZE_GB},\"VolumeType\":\"gp3\"}}]" \
    --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=$RUN_ID},{Key=Project,Value=pqc-bench-all}]" \
    --query 'Instances[0].InstanceId' --output text)
log "Instance: $INSTANCE_ID"

aws ec2 wait instance-running $A --instance-ids "$INSTANCE_ID"
PUBLIC_IP=$(aws ec2 describe-instances $A --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
log "Public IP: $PUBLIC_IP"

log "Waiting for SSH..."
watch_serial 180; wait_for_ssh 60; stop_serial
KVER=$(remote 'uname -r')
log "Connected. Kernel: $KVER"
pass "EC2 instance ready: $INSTANCE_ID ($KERN_ARCH, kernel $KVER)"

# ── Phase 1: Install dependencies ────────────────────────────────────────────
# Packages needed across all libraries:
#   - wolfSSL:  gcc, make, autoconf, automake, libtool
#   - liboqs:   cmake, ninja-build, openssl-devel, python3, astyle (optional)
#   - OpenSSL:  perl (for Configure), libssl-devel already present
#   - CIRCL:    golang
# cpupower already installed (kernel6.18-tools on AL2023 6.18)

log "Installing build dependencies..."
remote_script <<'DEPS'
set -euo pipefail
for i in 1 2 3; do sudo dnf makecache -q && break || sleep 10; done
sudo dnf install -y -q \
    gcc gcc-c++ make autoconf automake libtool \
    cmake ninja-build \
    openssl-devel \
    perl \
    python3 \
    golang
echo "gcc:    $(gcc --version | head -1)"
echo "cmake:  $(cmake --version | head -1)"
echo "go:     $(go version)"
echo "python: $(python3 --version)"
DEPS
pass "Dependencies installed"

# ── Phase 1b: Pin CPU governor ───────────────────────────────────────────────

log "Pinning CPU governor to performance..."
GOV=$(remote_script <<'GOVERNOR'
set -uo pipefail
CURRENT=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)
echo "Before: $CURRENT"
if [[ "$CURRENT" != "unknown" ]]; then
    sudo cpupower frequency-set -g performance 2>&1 | head -1 || echo "WARN: cpupower failed"
    echo "After: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
fi
GOVERNOR
)
log "Governor: $GOV"
pass "CPU governor set"

# ── Phase 2: wolfSSL ─────────────────────────────────────────────────────────

log "=== wolfSSL ==="
watch_serial 2400
remote_script <<WOLFSSL
set -euo pipefail
echo "--- Cloning wolfSSL (${WOLFSSL_REF}) ---"
git clone --depth=10 --branch "${WOLFSSL_REF}" "${WOLFSSL_REPO}" ~/wolfssl 2>&1 | tail -3
echo "HEAD: \$(git -C ~/wolfssl rev-parse HEAD)"

echo "--- Building and running wolfSSL benchmarks ---"
cd ~/wolfssl
taskset -c 0-3 ./wolfcrypt/benchmark/pqc_bench.sh \
    --output ~/wolfssl_raw.csv 2>&1 | tee ~/wolfssl_bench.log

# Also run SHA-2 SLH-DSA variants (not in the default pqc_bench.sh set)
echo "--- Running SLH-DSA SHA-2 variants ---"
BENCH=./wolfcrypt/benchmark/benchmark
RAW_SHA2=~/wolfssl_slhdsa_sha2_raw.csv

{
  taskset -c 0-3 \$BENCH -csv -slhdsa-sha2-128s
  taskset -c 0-3 \$BENCH -csv -slhdsa-sha2-128f
  taskset -c 0-3 \$BENCH -csv -slhdsa-sha2-192s
  taskset -c 0-3 \$BENCH -csv -slhdsa-sha2-192f
  taskset -c 0-3 \$BENCH -csv -slhdsa-sha2-256s
  taskset -c 0-3 \$BENCH -csv -slhdsa-sha2-256f
} 2>~/wolfssl_sha2_bench.log | awk '
  /^###/ || /^!!!/ { next }
  /^"[a-z]*",Algorithm,/ { if (!h){ sub(/^"[^"]*",/,""); sub(/,$/,""); print; h=1 } next }
  /^Algorithm,/ { if (!h){ sub(/,$/,""); print; h=1 } next }
  /^[a-z][a-z]*,[A-Z]/ { sub(/^[^,]*,/,""); sub(/,$/,""); print; next }
  { n=split(\$0,f,","); if(n>=5 && f[2]~/^[[:space:]]*[0-9]+[[:space:]]*$/){ sub(/,$/,""); print } }
' > "\$RAW_SHA2"

echo "wolfSSL DONE"
WOLFSSL
stop_serial
WOLFSSL_HEAD=$(remote 'git -C ~/wolfssl rev-parse HEAD')
pass "wolfSSL done (HEAD ${WOLFSSL_HEAD:0:12})"

# ── Phase 3: liboqs ──────────────────────────────────────────────────────────

log "=== liboqs ==="
watch_serial 2400
remote_script <<LIBOQS || { echo "WARN: liboqs phase exited non-zero — continuing"; }
set -euo pipefail
echo "--- Cloning liboqs (${LIBOQS_REF}) ---"
git clone --depth=1 --branch "${LIBOQS_REF}" \
    https://github.com/open-quantum-safe/liboqs.git ~/liboqs 2>&1 | tail -3
echo "HEAD: \$(git -C ~/liboqs rev-parse HEAD)"

echo "--- Building liboqs ---"
cmake -S ~/liboqs -B ~/liboqs/build \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DOQS_BUILD_ONLY_LIB=OFF \
    -DOQS_MINIMAL_BUILD=OFF \
    2>&1 | tail -5
cmake --build ~/liboqs/build --target speed_kem speed_sig -- -j\$(nproc) 2>&1 | tail -5

echo "--- Running liboqs KEM benchmarks (all algorithms, one at a time) ---"
# speed_kem / speed_sig accept only one <alg> per invocation.
# Run each separately and append output; use || true so one failure
# doesn't abort the whole phase.
> ~/liboqs_kem.txt
for alg in ML-KEM-512 ML-KEM-768 ML-KEM-1024; do
    echo "  KEM: \$alg"
    taskset -c 0-3 ~/liboqs/build/tests/speed_kem -d ${BENCH_SECS} "\$alg" \
        >> ~/liboqs_kem.txt 2>&1 || echo "  WARN: speed_kem \$alg exited non-zero"
done

echo "--- Running liboqs signature benchmarks (all algorithms, one at a time) ---"
> ~/liboqs_sig.txt
for alg in \
    ML-DSA-44 ML-DSA-65 ML-DSA-87 \
    SLH-DSA-SHA2-128s  SLH-DSA-SHA2-128f \
    SLH-DSA-SHA2-192s  SLH-DSA-SHA2-192f \
    SLH-DSA-SHA2-256s  SLH-DSA-SHA2-256f \
    SLH-DSA-SHAKE-128s SLH-DSA-SHAKE-128f \
    SLH-DSA-SHAKE-192s SLH-DSA-SHAKE-192f \
    SLH-DSA-SHAKE-256s SLH-DSA-SHAKE-256f; do
    echo "  SIG: \$alg"
    taskset -c 0-3 ~/liboqs/build/tests/speed_sig -d ${BENCH_SECS} "\$alg" \
        >> ~/liboqs_sig.txt 2>&1 || echo "  WARN: speed_sig \$alg exited non-zero"
done

echo "liboqs DONE"
LIBOQS
stop_serial
pass "liboqs done"

# ── Phase 4: OpenSSL ─────────────────────────────────────────────────────────
# Build OpenSSL from source to get 3.5 with native ML-KEM + ML-DSA.
# Then also build oqs-provider for SLH-DSA.

log "=== OpenSSL ==="
watch_serial 3600
remote_script <<OPENSSL_BUILD || { echo "WARN: OpenSSL phase exited non-zero — continuing"; }
set -euo pipefail
echo "--- Cloning OpenSSL (${OPENSSL_REF}) ---"
git clone --depth=1 --branch "${OPENSSL_REF}" \
    https://github.com/openssl/openssl.git ~/openssl 2>&1 | tail -3
echo "HEAD: \$(git -C ~/openssl rev-parse HEAD)"

echo "--- Configuring OpenSSL ---"
# ML-KEM and ML-DSA are enabled by default in OpenSSL 3.5+; no extra flags needed.
# no-shared: build static binary so it runs without LD_LIBRARY_PATH
# no-tests: skip test compilation to save time
cd ~/openssl
./Configure --prefix=\$HOME/openssl-install \
    no-shared no-tests \
    2>&1 | tail -5

echo "--- Building OpenSSL (~5-10 min) ---"
make -j\$(nproc) build_programs 2>&1 | tail -5

echo "--- Running OpenSSL KEM benchmarks (ML-KEM) ---"
taskset -c 0-3 apps/openssl speed -mr -seconds ${BENCH_SECS} \
    -kem-algorithms \
    > ~/openssl_kem_mr.txt 2>&1 || true

echo "--- Running OpenSSL signature benchmarks (ML-DSA) ---"
taskset -c 0-3 apps/openssl speed -mr -seconds ${BENCH_SECS} \
    -signature-algorithms \
    > ~/openssl_sig_mr.txt 2>&1 || true

# Filter to PQC only
grep -E "^\+R1[5-9]|^\+R20" ~/openssl_kem_mr.txt ~/openssl_sig_mr.txt \
    | grep -iE "ML-KEM|ML-DSA" > ~/openssl_pqc_mr.txt || true

echo "OpenSSL DONE"
echo "KEM lines: \$(grep -c '+R1[5-7]' ~/openssl_kem_mr.txt || echo 0)"
echo "SIG lines: \$(grep -c '+R1[89]\|+R20' ~/openssl_sig_mr.txt || echo 0)"
OPENSSL_BUILD
stop_serial
pass "OpenSSL done"

# ── Phase 5: CIRCL ───────────────────────────────────────────────────────────

log "=== CIRCL ==="
watch_serial 2400
remote_script <<CIRCL_BUILD || { echo "WARN: CIRCL phase exited non-zero — continuing"; }
set -euo pipefail
echo "--- Cloning CIRCL (${CIRCL_REF}) ---"
git clone --depth=1 --branch "${CIRCL_REF}" \
    https://github.com/cloudflare/circl.git ~/circl 2>&1 | tail -3
echo "HEAD: \$(git -C ~/circl rev-parse HEAD)"

echo "--- Running CIRCL KEM benchmarks (ML-KEM) ---"
cd ~/circl
taskset -c 0-3 go test \
    -bench "BenchmarkGenerateKeyPair|BenchmarkEncapsulate|BenchmarkDecapsulate" \
    -benchtime="${BENCH_SECS}s" -run='^$' \
    ./kem/schemes/ \
    2>&1 | tee ~/circl_kem.txt || echo "WARN: CIRCL KEM bench exited non-zero"

echo "--- Running CIRCL signature benchmarks (ML-DSA, SLH-DSA) ---"
taskset -c 0-3 go test \
    -bench "BenchmarkGenerateKeyPair|BenchmarkSign|BenchmarkVerify" \
    -benchtime="${BENCH_SECS}s" -run='^$' \
    ./sign/schemes/ \
    2>&1 | tee ~/circl_sig.txt || echo "WARN: CIRCL sig bench exited non-zero"

cat ~/circl_kem.txt ~/circl_sig.txt > ~/circl_all.txt
echo "CIRCL DONE"
CIRCL_BUILD
stop_serial
pass "CIRCL done"

# ── Phase 6: Normalise and merge ─────────────────────────────────────────────

log "Normalising and merging all results..."

# Copy pqc_parse.py onto the instance.
# It lives in the wolfssl working tree; use the known absolute path.
PARSE_PY="$HOME/WORK/wolfssl/wolfcrypt/benchmark/pqc_parse.py"
if [ ! -f "$PARSE_PY" ]; then
    echo "ERROR: pqc_parse.py not found at $PARSE_PY" >&2; exit 1
fi
scp -o StrictHostKeyChecking=no -i "$KEY_FILE" \
    "$PARSE_PY" "${INSTANCE_USER}@${PUBLIC_IP}:pqc_parse.py"

remote_script <<'NORMALISE'
set -euo pipefail
PARSE="python3 $HOME/pqc_parse.py"

# wolfSSL SHAKE
$PARSE --input-format=wolfssl --library=wolfSSL \
    $HOME/wolfssl_raw.csv > $HOME/norm_wolfssl_shake.csv

# wolfSSL SHA-2 SLH-DSA (append, skip header)
[ -f "$HOME/wolfssl_slhdsa_sha2_raw.csv" ] && \
    $PARSE --input-format=wolfssl --library=wolfSSL \
        $HOME/wolfssl_slhdsa_sha2_raw.csv | tail -n +2 >> $HOME/norm_wolfssl_shake.csv || true

# liboqs
cat $HOME/liboqs_kem.txt $HOME/liboqs_sig.txt > $HOME/liboqs_all.txt
$PARSE --input-format=liboqs --library=liboqs \
    $HOME/liboqs_all.txt > $HOME/norm_liboqs.csv

# OpenSSL
[ -f "$HOME/openssl_pqc_mr.txt" ] && \
    $PARSE --input-format=openssl --library=OpenSSL \
        $HOME/openssl_pqc_mr.txt > $HOME/norm_openssl.csv || echo "" > $HOME/norm_openssl.csv

# CIRCL
[ -f "$HOME/circl_all.txt" ] && \
    $PARSE --input-format=circl --library=CIRCL \
        $HOME/circl_all.txt > $HOME/norm_circl.csv || echo "" > $HOME/norm_circl.csv

# Merge: header from wolfssl file, data rows from all
HEADER=$(head -1 $HOME/norm_wolfssl_shake.csv)
echo "$HEADER" > $HOME/pqc_comparison.csv
for f in $HOME/norm_wolfssl_shake.csv $HOME/norm_liboqs.csv $HOME/norm_openssl.csv $HOME/norm_circl.csv; do
    [ -f "$f" ] && tail -n +2 "$f" >> $HOME/pqc_comparison.csv || true
done

echo "Merged rows: $(wc -l < $HOME/pqc_comparison.csv)"
NORMALISE
pass "Normalisation complete"

# ── Phase 7: Download results ─────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"
LP="${OUTPUT_DIR}/${RUN_ID}"

log "Downloading results..."

# Per-library raw + normalised
for lib in wolfssl liboqs openssl circl; do
    case "$lib" in
        wolfssl) files="wolfssl_raw.csv wolfssl_slhdsa_sha2_raw.csv wolfssl_bench.log norm_wolfssl_shake.csv" ;;
        liboqs)  files="liboqs_kem.txt liboqs_sig.txt norm_liboqs.csv" ;;
        openssl) files="openssl_pqc_mr.txt norm_openssl.csv" ;;
        circl)   files="circl_all.txt norm_circl.csv" ;;
    esac
    for f in $files; do
        scp -o StrictHostKeyChecking=no -i "$KEY_FILE" \
            "${INSTANCE_USER}@${PUBLIC_IP}:~/$f" \
            "${LP}_${f}" 2>/dev/null || echo "  WARN: $f not found"
    done
done

# Merged comparison
scp -o StrictHostKeyChecking=no -i "$KEY_FILE" \
    "${INSTANCE_USER}@${PUBLIC_IP}:~/pqc_comparison.csv" \
    "${LP}_comparison.csv"

pass "Results downloaded"

# ── Metadata sidecar ──────────────────────────────────────────────────────────

CPU_MODEL=$(remote 'grep "^model name\|^Model name\|^CPU part" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs')
GOVERNOR=$(remote 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown')
LIBOQS_HEAD=$(remote 'git -C ~/liboqs rev-parse HEAD 2>/dev/null || echo unknown')
OPENSSL_HEAD=$(remote 'git -C ~/openssl rev-parse HEAD 2>/dev/null || echo unknown')
CIRCL_HEAD=$(remote 'git -C ~/circl rev-parse HEAD 2>/dev/null || echo unknown')

cat > "${LP}_meta.txt" <<META
run_id:         $RUN_ID
date:           $(date -u +%Y-%m-%dT%H:%M:%SZ)
instance_type:  $INSTANCE_TYPE
architecture:   $KERN_ARCH
cpu_model:      $CPU_MODEL
kernel:         $KVER
governor:       $GOVERNOR
taskset:        0-3
bench_secs:     $BENCH_SECS

wolfssl_repo:   $WOLFSSL_REPO
wolfssl_ref:    $WOLFSSL_REF
wolfssl_head:   $WOLFSSL_HEAD

liboqs_ref:     $LIBOQS_REF
liboqs_head:    $LIBOQS_HEAD

openssl_ref:    $OPENSSL_REF
openssl_head:   $OPENSSL_HEAD

circl_ref:      $CIRCL_REF
circl_head:     $CIRCL_HEAD
META

# ── Summary ───────────────────────────────────────────────────────────────────

ROWS=$(tail -n +2 "${LP}_comparison.csv" 2>/dev/null | wc -l | tr -d ' ')

echo ""
log "=========================================="
log "Run: $RUN_ID"
log "  Architecture:  $KERN_ARCH ($INSTANCE_TYPE)"
log "  CPU:           $CPU_MODEL"
log "  Kernel:        $KVER"
log "  wolfSSL:       ${WOLFSSL_HEAD:0:12}"
log "  liboqs:        ${LIBOQS_HEAD:0:12}"
log "  OpenSSL:       ${OPENSSL_HEAD:0:12}"
log "  CIRCL:         ${CIRCL_HEAD:0:12}"
log "  Total rows:    $ROWS"
log "  Comparison:    ${LP}_comparison.csv"
log "  Metadata:      ${LP}_meta.txt"
log "=========================================="
log "RESULT: PASSED"
