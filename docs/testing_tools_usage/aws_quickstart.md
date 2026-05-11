<!--
Copyright (c) 2026 Mark Atwood
SPDX-License-Identifier: MIT
-->

# AWS Quickstart for PQC-LEO Benchmarks <!-- omit from toc -->

## Overview <!-- omit from toc -->

This guide walks a researcher new to AWS through the first-time setup
needed to run the PQC-LEO AWS benchmark drivers. It covers AWS CLI
installation, the four supported authentication methods, IAM permission
basics, the optional Ubuntu Pro token, a first-run walkthrough, and
common first-run gotchas.

When you finish this guide you will be able to run:

```sh
AWS_PROFILE=myprofile ./scripts/aws/run-pqc-bench-all.sh
```

For full reference documentation (every env var, output schema, cleanup
verification commands, troubleshooting), see
[`scripts/aws/README.md`](../../scripts/aws/README.md). This document is
the onboarding entry point only.

### Contents <!-- omit from toc -->

- [1. Install the AWS CLI](#1-install-the-aws-cli)
- [2. Authenticate to AWS](#2-authenticate-to-aws)
  - [2a. IAM Identity Center / SSO (recommended)](#2a-iam-identity-center--sso-recommended)
  - [2b. IAM access keys (personal accounts)](#2b-iam-access-keys-personal-accounts)
  - [2c. Instance profile (running from inside AWS)](#2c-instance-profile-running-from-inside-aws)
  - [2d. `AWS_PROFILE` env var patterns](#2d-aws_profile-env-var-patterns)
- [3. Verify authentication](#3-verify-authentication)
- [4. IAM permissions](#4-iam-permissions)
- [5. Optional: Ubuntu Pro token (for Ubuntu target)](#5-optional-ubuntu-pro-token-for-ubuntu-target)
- [6. First-run walkthrough](#6-first-run-walkthrough)
- [7. Common first-run gotchas](#7-common-first-run-gotchas)

---

## 1. Install the AWS CLI

AWS CLI v2 is required. The v1 CLI (still available via `pip install awscli`)
lacks the `aws sso` subcommand used by the recommended auth flow.

**Linux (Ubuntu/Debian):**

```sh
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip
unzip -q /tmp/awscli.zip -d /tmp
sudo /tmp/aws/install
rm -rf /tmp/awscli.zip /tmp/aws
```

(ARM64 hosts: substitute `linux-aarch64` for `linux-x86_64`.)

**Linux (Fedora/RHEL/AL2023):**

```sh
sudo dnf install awscli2
```

**macOS:**

```sh
brew install awscli
```

Verify the install:

```sh
aws --version
# aws-cli/2.x.x Python/3.x.x ...
```

If you see `aws-cli/1.x`, the v1 CLI is on your PATH ahead of v2. Either
uninstall it (`pip uninstall awscli`) or re-order PATH so the v2 install
location wins.

---

## 2. Authenticate to AWS

AWS supports several auth mechanisms. Pick the one matching the AWS
account type you have access to. **You only need to do one of these.**

### 2a. IAM Identity Center / SSO (recommended)

This is the standard for organisation-managed AWS accounts (most
employer/research-group accounts). It uses short-lived credentials
that refresh via your organisation's SSO portal.

```sh
aws configure sso
```

The prompts walk through:

| Prompt | What to enter |
|---|---|
| SSO session name | Anything memorable, e.g. `mycorp` |
| SSO start URL | The URL from your IT/SSO admin, e.g. `https://mycorp.awsapps.com/start/` |
| SSO region | The region your IdP is hosted in, e.g. `us-east-1` |
| SSO registration scopes | Accept the default (`sso:account:access`) |
| Account selection | Use the arrow keys to pick the account you have access to |
| Role selection | Use the arrow keys to pick the role (e.g. `AdministratorAccess`) |
| Default client region | The region you'll run benchmarks in (e.g. `us-west-2`) |
| Output format | `json` (recommended) |
| Profile name | Anything memorable, e.g. `mycorp-admin` |

After setup, this creates a `[profile <name>]` block in
`~/.aws/config`. Refresh expired credentials with:

```sh
aws sso login --profile mycorp-admin
```

A browser tab opens; approve and return to the terminal.

### 2b. IAM access keys (personal accounts)

For personal AWS accounts (or service-user-style provisioning),
generate static access keys:

1. Sign in to the AWS console.
2. Navigate to **IAM → Users → \<your user\> → Security credentials**.
3. **Access keys → Create access key.**
4. Pick "Command Line Interface (CLI)" use case.
5. Copy both the Access Key ID and Secret Access Key. AWS shows the
   secret **only once**; save them in a password manager.

Configure the CLI:

```sh
aws configure --profile myprofile
```

| Prompt | What to enter |
|---|---|
| AWS Access Key ID | The Access Key ID from step 4 |
| AWS Secret Access Key | The Secret Access Key from step 4 |
| Default region name | `us-west-2` (or your preference) |
| Default output format | `json` |

This writes `~/.aws/credentials` (keys) and `~/.aws/config` (region,
output format).

**Security:**

- Never commit `~/.aws/credentials` to git.
- Never share keys in chat/email/screen-share.
- Rotate keys every 90 days; AWS surfaces stale keys in IAM.
- For long-lived environments, prefer SSO or instance profile.

### 2c. Instance profile (running from inside AWS)

If you run the PQC-LEO scripts from an EC2 instance (e.g. a workstation
host inside AWS), and that instance has an attached IAM role, the AWS
CLI uses that role automatically — no configuration needed.

Most PQC-LEO researchers run benchmarks from a laptop or build server,
so this path is rare. Mentioned for completeness.

### 2d. `AWS_PROFILE` env var patterns

Once a profile is configured (any of 2a–2c), the scripts read it via
`$AWS_PROFILE`. Options:

```sh
# Per-shell:
export AWS_PROFILE=myprofile
./scripts/aws/run-pqc-bench-all.sh

# Per-command (inline):
AWS_PROFILE=myprofile ./scripts/aws/run-pqc-bench-all.sh

# Positional argument (interchangeable with $AWS_PROFILE):
./scripts/aws/run-pqc-bench-all.sh myprofile
```

List configured profiles:

```sh
aws configure list-profiles
```

---

## 3. Verify authentication

Before running benchmarks, sanity-check that the AWS CLI can talk to
AWS and identify you:

```sh
aws sts get-caller-identity --profile myprofile
```

Expected output (one line, formatted as JSON):

```json
{
    "UserId": "AIDA...",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/AdministratorAccess/myname@mycorp.com"
}
```

If this fails:

- **`SSOSession token expired`** — run `aws sso login --profile <name>`.
- **`Unable to locate credentials`** — the profile name is wrong, or
  `~/.aws/credentials` / `~/.aws/config` was never written.
  Re-run `aws configure` or `aws configure sso`.
- **`InvalidClientTokenId`** — the access key was deleted, rotated, or
  belongs to a different account. Regenerate.

---

## 4. IAM permissions

The benchmark scripts call ~10 AWS API actions across EC2, SSM, and STS.
`AdministratorAccess` covers all of them; for a least-privilege policy
see the IAM permissions table in
[`scripts/aws/README.md`](../../scripts/aws/README.md#iam-permissions).

The minimum is:

- `sts:GetCallerIdentity`
- `ssm:GetParameter` on `/aws/service/ami-amazon-linux-latest/*`
- `ec2:RunInstances`, `TerminateInstances`, `DescribeInstances`, `DescribeVpcs`
- `ec2:CreateKeyPair`, `DeleteKeyPair`
- `ec2:CreateSecurityGroup`, `AuthorizeSecurityGroupIngress`, `DeleteSecurityGroup`
- `ec2:CreateTags`
- `ec2-instance-connect:SendSerialConsoleSSHPublicKey`

If your role lacks any of these, the scripts fail at the relevant step
with an `AccessDenied` error naming the missing action.

---

## 5. Optional: Ubuntu Pro token (for Ubuntu target)

The benchmark scripts default to Amazon Linux 2023, which needs no
extra subscription. If you instead target Ubuntu (`TARGET_DISTRO=ubuntu`,
introduced in PR #3.10), the build is faster with **esm-infra** kernel
patches enabled. Canonical offers a free Ubuntu Pro personal tier
(up to 5 machines).

To enable it on benchmark instances:

1. Sign in to <https://ubuntu.com/pro/dashboard>.
2. Copy your Ubuntu Pro token (a long alphanumeric string).
3. Set it in your shell:

   ```sh
   export UA_TOKEN=C1...
   ```

4. Run the benchmark with the Ubuntu target:

   ```sh
   TARGET_DISTRO=ubuntu UA_TOKEN=$UA_TOKEN ./scripts/aws/run-pqc-bench-all.sh
   ```

The script passes `$UA_TOKEN` to the launched instance via user-data
and runs `pro attach $UA_TOKEN` early in the cloud-init phase. The
token never lands on disk in clear text after the instance is
terminated (it's only in the in-memory user-data store).

If `TARGET_DISTRO=al2023` (the default), `UA_TOKEN` is unused.

---

## 6. First-run walkthrough

A typical first benchmark, with all defaults:

```sh
# Set your AWS profile once per shell.
export AWS_PROFILE=myprofile

# Confirm auth works.
aws sts get-caller-identity

# Launch a single-library (wolfSSL) benchmark on x86_64.
./scripts/aws/run-pqc-bench.sh
```

What you'll see in the terminal:

1. **Phase 0: Provision EC2.** ~30–60 s. Resolves the AMI from SSM,
   creates an ephemeral key pair and security group, launches the
   instance, waits for it to be `running`, then polls SSH until ready.
2. **Phase 1: Setup.** ~2–3 min. Installs build deps via `dnf`, pins
   the CPU governor to `performance`, sets `taskset` affinity to
   cores 0–3.
3. **Phase 2: Clone wolfSSL.** ~5 s. Shallow clone of `WOLFSSL_REPO` at
   `WOLFSSL_REF`.
4. **Phase 3: Copy benchmark scripts.** ~5 s. `scp`s `pqc_bench.sh`
   (and `pqc_parse.py` from PQC-LEO's vendored copy) to the instance.
5. **Phase 4: Build + run benchmarks.** **15–25 min.** The longest
   phase. `pqc_bench.sh` runs `./configure`, `make`, and the full
   benchmark sweep. The serial console is streamed locally so you can
   tail progress.
6. **Phase 5: Normalise output.** ~5 s. Runs `pqc_parse.py` to produce
   wolfssl-format CSV and PQC-LEO PSV.
7. **Phase 6: Download.** ~10 s. `scp`s artefacts to `./results/`.
8. **Cleanup.** ~30 s. Terminates the instance, deletes the security
   group (with retry) and key pair, removes the local PEM.

When complete, look in `./results/`:

```
results/
├── pqc-bench-x86_64-20260512-143022_raw.csv
├── pqc-bench-x86_64-20260512-143022_wolfssl.csv
├── pqc-bench-x86_64-20260512-143022_pqcleo.psv
├── pqc-bench-x86_64-20260512-143022_bench.log
└── pqc-bench-x86_64-20260512-143022_meta.txt
```

The `_meta.txt` file is plain text and self-describing — keep it with
the CSVs so you can identify the hardware, kernel, and source revisions
that produced any given result set.

---

## 7. Common first-run gotchas

### Region not set

If `AWS_REGION` is empty and your profile has no default region, AWS
calls fail with `You must specify a region`. Either:

```sh
export AWS_REGION=us-west-2
```

or set `region = us-west-2` under `[profile myprofile]` in
`~/.aws/config`.

### SSO session expired

SSO sessions live ~8 hours by default. When they expire, the next
AWS call fails with a token error. Refresh:

```sh
aws sso login --profile myprofile
```

The script's `aws sts get-caller-identity` verification step catches
this at start-up, before provisioning, so you never waste billing
on a half-launched run.

### Missing default VPC

`aws ec2 describe-vpcs --filters Name=is-default,Values=true` must
return a VPC. If your account was set up without one (rare on personal
accounts, common on tightly-managed enterprise accounts):

```sh
aws ec2 create-default-vpc --region us-west-2
```

Or ask your AWS admin. The scripts do not currently take a `VPC_ID`
override.

### Billing alerts not configured

A typical PQC-LEO benchmark run is <$1. But a stuck `KEEP_INSTANCE=1`
session can rack up costs. Before your first run, set a CloudWatch
billing alarm:

1. Open the **Billing → Budgets** console.
2. **Create budget → Use a template → Monthly cost budget.**
3. Set the threshold to (say) $20, with an email alert at 80%.

This catches forgotten `KEEP_INSTANCE=1` runs and accidental
`c7i.metal` typos before they become expensive.

### SSH timeout right after instance launch

The instance can take 60–90 seconds to finish cloud-init's first boot.
The script polls SSH for up to 3 minutes; if it still fails, the most
likely cause is that the auto-detected SSH ingress CIDR doesn't match
your actual public IP (NAT, VPN, corporate proxy).

Set `SSH_CIDR` explicitly to your egress IP `/32`:

```sh
SSH_CIDR=$(curl -fsS https://checkip.amazonaws.com)/32 \
    ./scripts/aws/run-pqc-bench.sh
```

…or, for the duration of a debug session, widen to your office CIDR.

### `dnf` lock contention during build

AL2023 runs unattended package upgrades shortly after boot. If this
hits during the build phase, you'll see `Waiting for process with pid
N to finish.`. The build retries with backoff; usually only the second
attempt is needed. If it consistently fails, set
`KEEP_INSTANCE=1`, SSH in, and run `dnf upgrade -y` manually before
the script next attempts the build.

### Missing `pqc_bench.sh` on the wolfSSL clone

The benchmark driver `pqc_bench.sh` is not yet upstream in
`wolfSSL/wolfssl`. With the default `WOLFSSL_REPO`/`WOLFSSL_REF`
(upstream master), the cloned tree does not carry the script. Either:

1. Override `WOLFSSL_REPO`/`WOLFSSL_REF` to point at the fork branch
   that carries `pqc_bench.sh`, e.g.

   ```sh
   WOLFSSL_REPO=https://github.com/<you>/wolfssl \
   WOLFSSL_REF=feature/pqc-benchmark \
       ./scripts/aws/run-pqc-bench-all.sh
   ```

2. For `run-pqc-bench.sh` (single-library) only, set `PQC_BENCH_SH`
   to a local path. The script `scp`s it onto the remote instance
   as a fallback.

See [`scripts/aws/README.md`](../../scripts/aws/README.md#environment-variables)
for the full env-var reference.

---

Once you've completed a successful first run, you don't need to revisit
this guide. From here on, `scripts/aws/README.md` is your reference for
everything the drivers do.
