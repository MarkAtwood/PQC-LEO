# Agent Instructions — PQC-LEO (reference repo)

This repo is a **format and methodology reference** for the wolfSSL PQC benchmark work.
The primary deliverable lives in `~/WORK/wolfssl` on branch `feature/pqc-benchmark`.

Active issues are tracked **in this repo's beads database** even though the code
being written lives in `~/WORK/wolfssl`. This is the single source of truth for
`bd ready`, `bd show`, etc.

---

## Role of This Repo

`~/WORK/PQC-LEO` (branch `upstream-main`, upstream commit `9ea3d22`) is kept to:

1. Understand how liboqs formats its CSV output (so wolfSSL's output is compatible)
2. Understand how the Valgrind massif memory shims work (pattern reference)
3. Run a cross-library comparison if desired later

---

## CSV Format Reference

PQC-LEO's parser expects pipe-delimited CSV with these columns:

**Speed results:**
```
Algorithm | Operation | Operations | Seconds | ms/op | op/sec
```
- KEM operations: `keygen`, `encaps`, `decaps`
- SIG operations: `keypair`, `sign`, `verify`

**Memory results** (from ms_print on Valgrind massif output):
```
Algorithm, Operation, intits, peakBytes, Heap, extHeap, Stack
```

---

## Open Issues

Dependency order: `4n5` → `law` → `{opn, 6ua}` → `h5r`

| ID | P | Blocked by | Task |
|---|---|---|---|
| `PQC-LEO-v6o` | 1 | — | Epic: PQC benchmark driver for wolfCrypt |
| `PQC-LEO-4n5` | 1 | — | Verify wolfssl builds with PQC flags (x86 + ARM) |
| `PQC-LEO-law` | 1 | `4n5` | Write `wolfcrypt/benchmark/pqc_bench.sh` driver script |
| `PQC-LEO-opn` | 1 | `law` | Write `wolfcrypt/benchmark/pqc_parse.py` CSV normalizer |
| `PQC-LEO-6ua` | 1 | `law` | Decide and implement memory measurement approach |
| `PQC-LEO-h5r` | 2 | `law, opn, 6ua` | Write `wolfcrypt/benchmark/README-pqc.md` |

---

## Key Files for Reference

```
modded_lib_files/
├── test_kem_mem.c   # liboqs KEM massif shim — read to understand op-split pattern
└── test_sig_mem.c   # liboqs SIG massif shim

scripts/
├── test_scripts/pqc_performance_test.sh   # main test driver structure
└── parsing_scripts/
    ├── parse_results.py
    └── internal_scripts/
        ├── performance_data_parse.py      # how CSV rows are consumed
        └── results_averager.py
```

---

## Non-Interactive Shell Commands

```bash
cp -f src dst
mv -f src dst
rm -f file
rm -rf dir
apt-get install -y pkg
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

### Rules
- Use bd for ALL task tracking — no markdown TODOs
- Always `--json` for programmatic use
- `bd ready` before asking what to work on

### Session Close Protocol

```bash
bd close <finished-ids>
bd dolt push
git pull --rebase
git push
git status   # must show "up to date with origin"
```

<!-- END BEADS INTEGRATION -->
