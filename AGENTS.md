# Agent Instructions — PQC-LEO wolfSSL Backend

This project adds wolfSSL as a third PQC benchmark backend to the
[crt26/PQC-LEO](https://github.com/crt26/PQC-LEO) framework.

Working branch: `feature/wolfssl-backend` (rooted on upstream commit 9ea3d22)
Epic: `PQC-LEO-s5t`

---

## Repository Layout

```
PQC-LEO/
├── modded_lib_files/        # liboqs C shims (DO NOT MODIFY — upstream files)
│   ├── test_kem_mem.c
│   └── test_sig_mem.c
├── wolfssl_lib_files/       # wolfSSL C shims (NEW — our work)
│   ├── wc_kem_bench.c       # speed benchmark, emits pipe-delimited CSV
│   ├── wc_sig_bench.c       # speed benchmark, emits pipe-delimited CSV
│   ├── wc_kem_mem.c         # Valgrind massif shim, operation-split
│   └── wc_sig_mem.c         # Valgrind massif shim, operation-split
├── scripts/
│   ├── test_scripts/
│   │   ├── pqc_performance_test.sh      # existing liboqs driver (DO NOT MODIFY)
│   │   └── wolfssl_performance_test.sh  # NEW — mirrors pqc_performance_test.sh
│   ├── parsing_scripts/
│   │   ├── parse_results.py             # extend for wolfssl mode
│   │   └── internal_scripts/
│   │       ├── performance_data_parse.py
│   │       └── results_averager.py
│   └── utility_scripts/
│       └── get_algorithms.py            # extend for wolfssl mode
├── wolfssl_alg_lists/       # NEW — generated at setup time
│   ├── kem_algs.txt
│   └── sig_algs.txt
└── setup.sh                 # extend: wolfSSL build option
```

---

## Open Issues (epic PQC-LEO-s5t)

| ID | Task |
|---|---|
| `PQC-LEO-guz` | C speed shims `wc_kem_bench.c` / `wc_sig_bench.c` |
| `PQC-LEO-4cv` | C memory shims `wc_kem_mem.c` / `wc_sig_mem.c` |
| `PQC-LEO-v7r` | `setup.sh` wolfSSL build/install option |
| `PQC-LEO-2o5` | `wolfssl_performance_test.sh` test driver |
| `PQC-LEO-75w` | Algorithm enumeration (`wolfssl_alg_lists/`) |
| `PQC-LEO-fp7` | Python parsing extension |

---

## wolfSSL Source

wolfSSL source lives at `~/WORK/wolfssl`. The installed prefix for the
benchmarking build will be `lib/wolfssl/` inside this repo (parallel to
how upstream builds liboqs into `lib/liboqs/`).

### Algorithms and wolfCrypt APIs

**ML-KEM** — native, no liboqs dependency
- Header: `wolfssl/wolfcrypt/wc_mlkem.h`
- Key type: `MlKemKey`; type constants: `WC_ML_KEM_512=0`, `WC_ML_KEM_768=1`, `WC_ML_KEM_1024=2`
- API: `wc_MlKemKey_Init()`, `wc_MlKemKey_MakeKey()`, `wc_MlKemKey_Encapsulate()`, `wc_MlKemKey_Decapsulate()`
- Configure flag: `--enable-mlkem` (enabled by default)

**ML-DSA (Dilithium)** — native, no liboqs dependency
- Header: `wolfssl/wolfcrypt/dilithium.h`
- Key type: `dilithium_key`; level set via `wc_dilithium_set_level(key, 2|3|5)`
- API: `wc_dilithium_init()`, `wc_dilithium_make_key()`, `wc_dilithium_sign_msg()`, `wc_dilithium_verify_msg()`
- Configure flag: `--enable-dilithium` (alias for `--enable-mldsa`)

**SLH-DSA** — native, no liboqs dependency
- Header: `wolfssl/wolfcrypt/wc_slhdsa.h`
- Key type: `SlhDsaKey`; param enum `SlhDsaParam`:
  - `SLHDSA_SHAKE128S=0`, `SLHDSA_SHAKE128F=1`, `SLHDSA_SHAKE192S=2`, `SLHDSA_SHAKE192F=3`,
    `SLHDSA_SHAKE256S=4`, `SLHDSA_SHAKE256F=5`
  - SHA2 variants `SLHDSA_SHA2_128S`–`SLHDSA_SHA2_256F` if built with `WOLFSSL_SLHDSA_SHA2`
- API: `wc_SlhDsaKey_Init()`, `wc_SlhDsaKey_MakeKey()`, `wc_SlhDsaKey_Sign()`, `wc_SlhDsaKey_Verify()`
- Configure flag: `--enable-slhdsa`

**Falcon** — requires liboqs (wolfSSL is a thin wrapper over OQS Falcon)
- Header: `wolfssl/wolfcrypt/falcon.h`
- `falcon.h` line 41: `#error "HAVE_FALCON requires HAVE_LIBOQS."` — confirmed liboqs-backed
- **Falcon is excluded from the wolfSSL-native benchmark path.** Do not include it.
  File issue and note if this changes in a future wolfSSL release.

### wolfSSL Build Command for Benchmarking

```bash
./configure \
    --prefix="$(pwd)/../../lib/wolfssl" \
    --enable-mlkem \
    --enable-dilithium \
    --enable-slhdsa \
    --enable-static \
    --disable-shared \
    --disable-examples \
    --disable-crypttests
make -j"$(nproc)"
make install
```

Run from `lib/wolfssl-src/` (cloned source). Do not use `--enable-falcon`
(requires liboqs, defeats the purpose of a separate wolfssl-native backend).

---

## CSV Output Contract

All wolfSSL benchmark tools must emit **pipe-delimited CSV** matching the
liboqs `speed_kem` / `speed_sig` format so the existing Python parsers work
unchanged. Column order:

**Speed (wc_kem_bench / wc_sig_bench):**
```
Algorithm | Operation | Operations | Seconds | ms/op | op/sec
```
- `Operation` values for KEM: `keygen`, `encaps`, `decaps`
- `Operation` values for SIG: `keypair`, `sign`, `verify`
- Print a one-line header row first, then one data row per operation.
- No trailing whitespace. No system-info block (unlike liboqs — the parser
  strips it, but simpler to not emit it).

**Memory (wc_kem_mem / wc_sig_mem):**
- These are Valgrind massif wrapper programs, not self-measuring.
- They perform **exactly one operation** per invocation and exit.
- Persist intermediate key material to disk between invocations using plain
  `fwrite`/`fread` (see the `oqs_fstore` / `oqs_fload` pattern in
  `modded_lib_files/test_kem_mem.c`). File paths: `/tmp/wc_bench_<alg>_{pk,sk,ct,ss}`.
- CLI: `wc_kem_mem <algname> <op>` where op: `0`=keygen, `1`=encaps, `2`=decaps
- CLI: `wc_sig_mem <algname> <op>` where op: `0`=keygen, `1`=sign, `2`=verify
- Algorithm name strings must match what appears in `wolfssl_alg_lists/kem_algs.txt`
  and `sig_algs.txt`.

---

## Algorithm Name Strings

Use these exact strings in alg list files and as the `Algorithm` column in CSV:

**KEM:**
- `ML-KEM-512`, `ML-KEM-768`, `ML-KEM-1024`

**SIG:**
- `ML-DSA-44`, `ML-DSA-65`, `ML-DSA-87`
- `SLH-DSA-SHAKE-128s`, `SLH-DSA-SHAKE-128f`, `SLH-DSA-SHAKE-192s`,
  `SLH-DSA-SHAKE-192f`, `SLH-DSA-SHAKE-256s`, `SLH-DSA-SHAKE-256f`

These match NIST FIPS 203/204/205 names and are consistent with the naming
convention PQC-LEO uses for the liboqs backend.

---

## Test Data Directory Layout

Mirrors the existing liboqs structure:

```
test_data/
├── wolfssl_alg_lists/
│   ├── kem_algs.txt
│   └── sig_algs.txt
├── up_results/wolfssl_performance/machine_<N>/
│   ├── speed_results/
│   │   ├── test_kem_speed_<run>.csv
│   │   └── test_sig_speed_<run>.csv
│   └── mem_results/
│       ├── kem_mem_metrics/
│       └── sig_mem_metrics/
└── results/wolfssl_performance/machine_<N>/
    ├── kem_speed_avg.csv
    ├── sig_speed_avg.csv
    ├── kem_mem_avg.csv
    └── sig_mem_avg.csv
```

---

## What NOT to Do

- Do not modify files in `modded_lib_files/` — these are upstream liboqs files.
- Do not modify `scripts/test_scripts/pqc_performance_test.sh` — add a new
  parallel script instead.
- Do not include Falcon in the wolfSSL-native benchmark path (requires liboqs).
- Do not add TLS benchmarking in this epic — wolfSSL TLS integration is
  out of scope for the initial backend. File a separate epic if desired.
- Do not break the existing liboqs benchmark path. The wolfSSL additions are
  purely additive.

---

## Non-Interactive Shell Commands

Always use non-interactive flags. `cp`, `mv`, `rm` may be aliased to `-i` on
this system and will hang waiting for confirmation.

```bash
cp -f src dst        # not: cp src dst
mv -f src dst        # not: mv src dst
rm -f file           # not: rm file
rm -rf dir           # not: rm -r dir
apt-get install -y   # not: apt-get install
```

---

<!-- BEGIN BEADS INTEGRATION v:1 profile:full hash:f65d5d33 -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Quick Start

```bash
bd ready --json                          # find available work
bd update <id> --claim --json            # claim atomically
bd close <id> --reason "Done" --json     # complete
bd create --title="..." --type=task --priority=2 --deps discovered-from:<id> --json
```

### Issue Types
`bug` | `feature` | `task` | `epic` | `chore`

### Priorities
`0`=critical, `1`=high, `2`=medium (default), `3`=low, `4`=backlog

### Rules
- Use bd for ALL task tracking — no markdown TODOs
- Always `--json` for programmatic use
- Link discovered work with `--deps discovered-from:<parent-id>`
- `bd ready` before asking what to work on

### Session Close Protocol

Work is NOT complete until `git push` succeeds.

```bash
bd close <finished-ids>
bd dolt push
git pull --rebase
git push
git status   # must show "up to date with origin"
```

<!-- END BEADS INTEGRATION -->
