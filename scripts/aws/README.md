<!--
Copyright (c) 2026 Mark Atwood
SPDX-License-Identifier: MIT
-->

# AWS PQC benchmark drivers

This directory holds two scripts that provision an EC2 instance, build PQC
libraries from source, run the PQC benchmark suite, normalise the output,
download the results, and tear everything down.

| Script | Purpose |
|---|---|
| `run-pqc-bench.sh` | Single library: wolfSSL only. |
| `run-pqc-bench-all.sh` | All four libraries: wolfSSL, liboqs, OpenSSL (with oqs-provider for SLH-DSA), CIRCL. Merges results into a single comparison CSV. |

Both scripts run on x86_64 (Intel Sapphire Rapids, `c7i.2xlarge`) by default
and ARM64 (Graviton 3, `c7g.2xlarge`) when `ARM64=1` is set. Default AMI is
Amazon Linux 2023 (kernel-default), resolved via SSM Public Parameter.

For a walkthrough of first-time AWS setup (CLI install, SSO, IAM policies),
see `docs/testing_tools_usage/aws_quickstart.md`. This README is reference
documentation only.

---

## Prerequisites

### AWS CLI

AWS CLI v2 installed and authenticated. Recommended setup:

```sh
aws configure sso
aws sso login --profile <your-profile>
```

Any credential mechanism that yields a valid `AWS_PROFILE` works
(static keys, instance profile, SSO, `aws configure`). The scripts
do not assume SSO.

### IAM permissions

The invoking principal needs:

| Action | Used for |
|---|---|
| `sts:GetCallerIdentity` | Verify auth at startup. |
| `ssm:GetParameter` on `/aws/service/ami-amazon-linux-latest/*` | Resolve the AL2023 AMI. |
| `ec2:DescribeVpcs` | Find the default VPC. |
| `ec2:DescribeInstances` | Fetch instance public IP. |
| `ec2:CreateKeyPair`, `ec2:DeleteKeyPair` | Ephemeral SSH key. |
| `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`, `ec2:DeleteSecurityGroup` | Ephemeral SG with SSH ingress. |
| `ec2:CreateTags` | Tag created resources. |
| `ec2:RunInstances`, `ec2:TerminateInstances` | Launch and tear down the benchmark host. |
| `ec2-instance-connect:SendSerialConsoleSSHPublicKey` | Serial-console streaming during long runs. |

`AdministratorAccess` covers all of the above. A least-privilege policy
should grant the actions above scoped to the region in use and (where
possible) resource ARNs.

### Default VPC

The scripts use the default VPC in the target region. If the account has
no default VPC, either recreate one (`aws ec2 create-default-vpc`) or
extend the scripts to take a `VPC_ID` env var.

### Local tools

- `bash` >= 4 (associative arrays used in helpers)
- `curl` (auto-IP detection for SSH ingress)
- `ssh` and `scp` (OpenSSH)
- `awk`, `tail`, `cut`, `date` (BusyBox-compatible usage)
- The vendored `scripts/parsing_scripts/pqc_parse.py` (Python 3.10+)

---

## Cost estimate

Approximate hourly on-demand pricing in `us-west-2` (verify with
`aws pricing` for your region):

| Instance | vCPU / RAM | $/hour | Typical run | $/run |
|---|---|---|---|---|
| `c7i.2xlarge` (x86_64, Sapphire Rapids) | 8 / 16 GB | ~$0.36 | 30–60 min | $0.18–$0.36 |
| `c7g.2xlarge` (Graviton 3) | 8 / 16 GB | ~$0.29 | 30–60 min | $0.14–$0.29 |

Add ~$0.005 for the 40 GB gp3 EBS volume (single run, instantly destroyed).
EC2 spot pricing typically reduces this by 30–60% but the scripts use
on-demand for reproducibility.

`run-pqc-bench-all.sh` (4-library suite) runs ~50% longer than
`run-pqc-bench.sh` (wolfSSL only). SLH-DSA SHA2 variants account for the
majority of wall-clock time on either driver.

---

## Quick start

```sh
# x86_64 single-library (wolfSSL):
AWS_PROFILE=myprofile ./scripts/aws/run-pqc-bench.sh

# ARM64 multi-library comparison:
AWS_PROFILE=myprofile ARM64=1 ./scripts/aws/run-pqc-bench-all.sh

# Pin a specific AMI for reproducibility:
AWS_PROFILE=myprofile AMI_ID=ami-0123456789abcdef0 ./scripts/aws/run-pqc-bench.sh
```

You can pass the profile as positional `$1` instead of an env var:

```sh
./scripts/aws/run-pqc-bench.sh myprofile
```

---

## Environment variables

Defaults match what each script reads at startup. Variables marked
**(both)** apply to both `run-pqc-bench.sh` and `run-pqc-bench-all.sh`.

### Required

| Variable | Default | Scope | Notes |
|---|---|---|---|
| `AWS_PROFILE` | _(none)_ | both | Pass as `$1` instead if you prefer. Script exits with error if unset. |

### Common

| Variable | Default | Scope | Notes |
|---|---|---|---|
| `AWS_REGION` | `us-west-2` | both | |
| `ARM64` | `0` | both | Set to `1` for Graviton/`c7g.2xlarge`. |
| `INSTANCE_TYPE` | `c7i.2xlarge` (x86_64), `c7g.2xlarge` (arm64) | both | Override only if you know your benchmark profile. |
| `AMI_ID` | _(SSM-resolved)_ | both | Pin a specific AMI for fully reproducible runs. Defaults to `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-<arch>`. |
| `KEEP_INSTANCE` | `0` | both | Set to `1` to leave the instance running after the bench completes. Useful for debugging. |
| `SSH_KEY_PATH` | `/tmp` | both | Where the ephemeral PEM key is written locally. |
| `OUTPUT_DIR` | `./results` | both | Local directory for downloaded artefacts. |
| `DISK_SIZE_GB` | `30` (bench), `40` (all) | both | EBS volume size for the bench host. |

### SSH ingress hardening

| Variable | Default | Scope | Notes |
|---|---|---|---|
| `SSH_CIDR` | _(auto-detected `<myip>/32`)_ | both | The script queries `https://checkip.amazonaws.com` and authorises that address `/32`. Set explicitly if you sit behind NAT/CGNAT, or use `0.0.0.0/0` to recreate the legacy open-to-the-world behaviour (**not recommended**). |
| `SSH_CIDR_V6` | _(unset, no IPv6 rule)_ | both | If non-empty, an additional SSH ingress rule is authorised for this IPv6 CIDR. Not auto-detected. |

If auto-detection fails (no network, blocked egress, transient DNS), the
script exits with a clear error and instructs the user to set `SSH_CIDR`
explicitly. It will **not** silently fall back to `0.0.0.0/0`.

### wolfSSL source

| Variable | Default | Scope | Notes |
|---|---|---|---|
| `WOLFSSL_REPO` | `https://github.com/wolfSSL/wolfssl` | both | Set to a fork that carries `pqc_bench.sh` (the upstream wolfSSL repo does not yet ship this driver). |
| `WOLFSSL_REF` | `master` | both | Set to the branch/tag carrying the PQC benchmark machinery, e.g. `feature/pqc-benchmark`. |
| `PQC_BENCH_SH` | `$PQC_LEO_ROOT/../../WORK/wolfssl/wolfcrypt/benchmark/pqc_bench.sh` | `run-pqc-bench.sh` only | Local path used as a fallback when the cloned `WOLFSSL_REF` doesn't carry the script. |

### Multi-library extras (`run-pqc-bench-all.sh` only)

| Variable | Default | Notes |
|---|---|---|
| `LIBOQS_REF` | `main` | liboqs git ref. |
| `OPENSSL_REF` | `master` | OpenSSL git ref. |
| `CIRCL_REF` | `master` | CIRCL git ref. |
| `BENCH_SECS` | `3` | Seconds per operation in liboqs `speed_kem` / `speed_sig`. |

---

## Output structure

Results land in `$OUTPUT_DIR/` (default `./results/`). Each run is tagged
with `$RUN_ID`:

| Script | `$RUN_ID` prefix |
|---|---|
| `run-pqc-bench.sh` | `pqc-bench-<arch>-<YYYYMMDD-HHMMSS>` |
| `run-pqc-bench-all.sh` | `pqc-all-<arch>-<YYYYMMDD-HHMMSS>` |

### `run-pqc-bench.sh` output

| File | Contents |
|---|---|
| `<RUN_ID>_raw.csv` | Raw wolfSSL `pqc_bench.sh` output. |
| `<RUN_ID>_wolfssl.csv` | Normalised wolfSSL-format CSV (post-`pqc_parse.py`). |
| `<RUN_ID>_pqcleo.psv` | PQC-LEO pipe-delimited cross-library schema. |
| `<RUN_ID>_bench.log` | Stdout/stderr from the build + bench phases. |
| `<RUN_ID>_meta.txt` | Run metadata: instance type, CPU model, kernel, governor, wolfSSL repo/ref/head, taskset pin. |

### `run-pqc-bench-all.sh` output

| File | Contents |
|---|---|
| `<RUN_ID>_comparison.csv` | Merged comparison CSV: rows from wolfSSL + liboqs + OpenSSL + CIRCL, single normalised schema. |
| `<RUN_ID>_meta.txt` | Run metadata as above, plus all four library refs (`wolfssl_ref`, `liboqs_ref`, `openssl_ref`, `circl_ref`). |

The metadata file is plain text and self-describing. Always archive it
alongside the CSV so future readers can identify the hardware, kernel,
and source tree state behind each run.

### Resource tagging

Every AWS resource created by the scripts is tagged with:

| Key | Value |
|---|---|
| `Name` | `$RUN_ID` |
| `project` | `pqc-leo` |
| `run-id` | `$RUN_ID` |

Tags apply to the EC2 instance, EBS volume, key pair, and security group.
Use these for cost allocation and to audit cleanup.

---

## Cleanup verification

By default the scripts tear down all created resources via the `cleanup`
function (registered as an `EXIT` trap):

1. `aws ec2 terminate-instances`
2. `aws ec2 wait instance-terminated` (or fall back to `sleep 30`)
3. `aws ec2 delete-key-pair`
4. `delete_sg_with_retry` — retries `delete-security-group` up to 10× at
   5 s intervals (the security group can briefly hold a `DependencyViolation`
   while the terminated instance's ENI is still detaching).
5. Local PEM file removed.

If you set `KEEP_INSTANCE=1`, cleanup is skipped and the script prints:

```
KEEP_INSTANCE=1 — instance left running
  SSH:      ssh -i <key> ec2-user@<ip>
  Terminate: aws ec2 terminate-instances --instance-ids <id>
```

To confirm no resources leaked after a failed run, query the tags:

```sh
aws ec2 describe-instances \
    --filters "Name=tag:project,Values=pqc-leo" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`run-id`].Value|[0],State.Name]' \
    --output table

aws ec2 describe-key-pairs \
    --filters "Name=tag:project,Values=pqc-leo" \
    --query 'KeyPairs[].[KeyPairId,KeyName]' --output table

aws ec2 describe-security-groups \
    --filters "Name=tag:project,Values=pqc-leo" \
    --query 'SecurityGroups[].[GroupId,GroupName]' --output table
```

Any stale resources can be force-cleaned by tag-matched terminate /
delete calls.

---

## Troubleshooting

### SSH timeouts after `Waiting for instance to be running...`

Wait time can extend if `cloud-init` is still bootstrapping. The script
polls SSH for up to 3 minutes (`wait_for_ssh` with 36 × 5 s attempts).
If this fails:

- Check the instance state in the AWS console — is it `running`?
- Check the SG's inbound rule — does the source CIDR match your current
  public IP? (If you're behind NAT/CGNAT and the auto-detected IP is
  wrong, set `SSH_CIDR` explicitly.)
- Check the serial console output. The script streams it to local
  stdout via the `watch_serial` helper if available.

### `dnf` lock contention during library build

AL2023 runs unattended package upgrades shortly after boot, which can
hold `/var/lib/dnf/rpmdb_lock`. The build script retries with backoff,
but very slow upgrades can still race the bench start. Workaround:
relaunch the run; the second attempt usually wins.

### Missing default VPC

If `describe-vpcs --filters Name=is-default,Values=true` returns empty,
either:

```sh
aws ec2 create-default-vpc --region <region>
```

or set a non-default `VPC_ID` (requires script extension — not currently
supported via env var).

### `ssm:GetParameter` AccessDenied

If your IAM principal lacks SSM permissions, the AMI resolution step
fails with an explicit error pointing at the parameter name. Either:

- Grant `ssm:GetParameter` on
  `arn:aws:ssm:*::parameter/aws/service/ami-amazon-linux-latest/*`, or
- Pin the AMI yourself with `AMI_ID=ami-...` to skip the SSM lookup.

### `pqc_bench.sh: file not found` on the remote instance

`pqc_bench.sh` is not yet upstream in `wolfSSL/wolfssl`. With the
default `WOLFSSL_REPO`/`WOLFSSL_REF` (upstream master), the cloned
tree does not carry the script. Options:

1. Set `WOLFSSL_REPO`/`WOLFSSL_REF` to a fork branch that carries the
   script (`feature/pqc-benchmark` on the wolfssl PQC fork).
2. For `run-pqc-bench.sh` only, leave defaults and set `PQC_BENCH_SH`
   to a local path. The script will `scp` it onto the remote instance
   as a fallback.

### `DependencyViolation` during `delete-security-group`

This is handled by `delete_sg_with_retry` (10 attempts × 5 s). If
cleanup still fails, the script prints the SG ID and exits — delete
manually via the AWS console or `aws ec2 delete-security-group`.

---

## Security caveat: SSH ingress

The default SSH ingress rule is `<your-public-ip>/32`, auto-detected via
`https://checkip.amazonaws.com`. **The auto-detected IP is the address
AWS sees as your source**, which may differ from your local IP if you
are behind NAT or a corporate proxy.

If you set `SSH_CIDR=0.0.0.0/0` (or any wider CIDR), every host on the
internet can reach SSH/22 on the benchmark instance until cleanup
completes. AL2023 ships with key-only SSH and no password auth, so this
is not catastrophic, but it does expose the instance to enumeration and
log spam. Prefer `<myip>/32` or a tighter corporate egress CIDR.

If auto-detection fails (no outbound HTTPS, DNS error, etc.) the script
exits with a clear error message asking the user to set `SSH_CIDR`
explicitly. It will **not** silently fall back to `0.0.0.0/0`.
