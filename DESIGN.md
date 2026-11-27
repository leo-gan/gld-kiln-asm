# `gld-kiln-asm` — Kickoff Design & Architecture

`gld-kiln-asm` is a from-scratch **pure x86-64 Assembly (GNU `as`, Intel syntax)** implementation of the **Kiln Wire Format, Version 2** ([normative specification](https://leo-gan.github.io/gld-kiln/spec/)). Its primary goal is to establish the **true bare-metal hardware floor** on Linux x86-64 and measure the exact cycle delta between pure Assembly, C `-O3 -march=native`, and the other 11 Kiln language ports.

> [!IMPORTANT]
> **No forked specification:** This repository does not maintain a second copy of the Kiln v2 specification. The normative standard lives at `https://leo-gan.github.io/gld-kiln/spec/`. Only the conformance fixtures (`testdata/kiln-v2-cases.json` and `testdata/golden/*.kiln`) are copied here for self-contained testing.

---

## 1. Target Machine & Toolchain

| Parameter | Baseline Target |
| :--- | :--- |
| **Architecture** | `x86_64` Linux (little-endian, System V AMD64 ABI) |
| **Reference CPU** | 12th Gen Intel Core i7-12800H (Alder Lake: `AVX2`, `BMI1`, `BMI2`, `ERMS`, `FSRM`, `VPCLMULQDQ`, `GFNI`; **no AVX-512**) |
| **Assembler & Linker** | GNU `as` (`.intel_syntax noprefix`) + GNU `ld` |
| **Reference Compiler** | `gcc -O3 -march=native` (for `c_ref/` baseline and `tests/` harness) |
| **Measurement Protocol** | Single pinned core (`taskset -c 2`), warmup + hot-loop mean/best/p50 over `CLOCK_MONOTONIC` / `rdtscp` |

---

## 2. Experimental Build Switch (`MODE`)

A single `Makefile` switch selects the execution/ABI mode over the **same core x86-64 codec kernels**, enabling controlled apples-to-apples experiments on ABI, allocator, and FFI overhead:

| Mode | Output Artifact | Runtime & Memory Model | What It Measures |
| :--- | :--- | :--- | :--- |
| **`MODE=nolibc`** | Standalone static ELF binary (`bin/kiln_bench_nolibc`) | **Zero libc** (`readelf -d` shows no `NEEDED` libs). Entry at `_start`, raw Linux syscalls (`write=1`, `mmap=9`, `clock_gettime=228`, `exit_group=231`), static/mmap bump arena, benchmark loop inside Assembly (zero FFI boundary). | Absolute hardware floor with zero ABI/runtime/allocator tax. |
| **`MODE=cabi`** | Static library (`lib/libkiln_asm.a`) + C header (`include/kiln_asm.h`) | System V AMD64 C-callable wrappers over the core kernels, selectable allocator (caller-provided bump arena vs. `malloc`). Linkable from C tests and `GLD.SerializerBenchmark`. | Real-world FFI/ABI cost and drop-in library integration. |
| **`MODE=hybrid`** *(Future — Option 3)* | `lib/libkiln_hybrid.a` | C `-O3 -march=native` for inlined struct specialization + explicit AVX2 intrinsics / Assembly micro-kernels. | Whether C + intrinsics closes the gap with pure Assembly. |

---

## 3. Core Architecture

### 3.1 Two-Layer Assembly Design

To keep both `MODE=nolibc` and `MODE=cabi` clean and avoid duplicating codec logic:

1. **Internal Register-Pinned Kernels (`arch/x86_64/core_*.s`):**
   - Non-standard internal register contract kept live across nested calls:
     - `r12` = wire cursor pointer (`src` on decode, `dst` on encode)
     - `r13` = wire end pointer (`end`, for single-compare bounds checks)
     - `r14` = scratch/arena bump pointer (decode) or writer capacity end (encode)
     - `r15` = nesting `depth` / `flags` (`bit 0`: `check_utf8`, caps loaded from a context block when needed)
   - **Carry-Flag (`CF`) error signaling:** `clc` on success; on failure, set `eax = kiln_err_t`, `rdx = byte_offset`, `stc`, `ret`. Callers check with a single `jc` (zero struct return overhead).
2. **Thin Mode Shells:**
   - `arch/x86_64/nolibc_entry.s` — `_start`, bump arena (`mmap`), integer-to-ASCII printer (`write`), timing harness (`clock_gettime` syscall or `rdtsc`/`rdtscp` calibrated against `clock_gettime`), inline-macro hot loops.
   - `arch/x86_64/abi_c.s` — System V AMD64 prologues/epilogues saving/restoring `r12`–`r15`, loading cursor state from `kiln_writer_t*` / `kiln_reader_t*`, calling internal kernels, translating `CF` + `eax` into C return codes.

### 3.2 Normative Error Codes (Kiln v2)

| Code | Name | Meaning |
| ---: | :--- | :--- |
| `0` | `KILN_OK` | Success |
| `1` | `KILN_ERR_FRAME` | Bad magic (`KLN0`/`KLNT`), version `≠ 2`, profile `≠ 0`, reserved/flag bits |
| `2` | `KILN_ERR_SCHEMA` | `KLN0` FNV-1a-64 schema hash mismatch |
| `3` | `KILN_ERR_LIMIT` | Exceeded `max_count`/`max_bytes` cap or `u64` overflow |
| `4` | `KILN_ERR_EOF` | Truncated input or pre-allocation `count × min(T) > remaining` |
| `5` | `KILN_ERR_TYPE` | Invalid `bool`/`opt` tag, unsorted/duplicate `dict` key, invalid `KLNT` metadata/alignment/padding/nibble/quant links |
| `6` | `KILN_ERR_UTF8` | Invalid RFC 3629 UTF-8 bytes |
| `7` | `KILN_ERR_TRAILING` | Unread bytes remaining after standalone root value/directory |
| `8` | `KILN_ERR_DEPTH` | Nesting depth `> max_depth` (default `64`) |

### 3.3 Planned Assembly Optimizations (Measured Individually)

Every optimization is gated behind an isolated A/B measurement so we know which techniques actually move the needle on Alder Lake:

1. **Unaligned LE scalar loads/stores** (`mov` 16/32/64-bit directly, zero byte shifting).
2. **Pre-sized leaf struct encode:** One size calculation + single capacity check, then straight-line unchecked pointer stores.
3. **32-byte trailing writer slop (opt-in flag):** Allows branchless unconditional 16/32-byte `vmovdqu` copies for short strings (`0..32 B`) followed by `add r12, len`.
4. **Fused single-pass AVX2 UTF-8 validation + copy:** Load into `xmm`/`ymm`, check ASCII via `vpmovmskb` + `test` while writing to destination; branch to full RFC 3629 validator (Keiser–Lemire AVX2 lookup for long non-ASCII, scalar fallback for short) only when any high bit is set.
5. **Pre-allocated bump arena vs. zero-copy views vs. `malloc`:** Explicitly separated rows in benchmarks so allocator cost is never conflated with codec cost.
6. **Tensor bulk copy (`KLNT`):** Compare `rep movsb` (ERMS/FSRM) vs. unrolled AVX2 `vmovdqu` vs. non-temporal `vmovntdq` on the 2 MiB `f64` workload.

---

## 4. Benchmark Parity Rules (Anti-Cheating Contract)

To ensure an honest comparison against `c_ref/` (`gcc -O3 -march=native`) and `gld-kiln` (Mojo):

1. **No constant folding or hoisting:** Both `c_ref` and Assembly must encode/decode **runtime-populated structs** passed through an optimization barrier (`asm volatile("" : "+r"(ptr) : : "memory")` in C; non-constant input array in Assembly) — fixing the constant-folding/loop-hoisting artifact present in `gld-kiln/experiments/E15-c-ceiling/kiln_message.c`.
2. **Identical wire workloads (matching `gld-kiln/experiments/decode_small.mojo`):**
   - `Point` (`8 B`: `i32, i32`)
   - Single `Message` (`44 B`: `bool, i32, i64, f64, str("hello"), bool, i32, str("world")`)
   - `Batch` of 100 `Message` records (`4,404 B`: `u32(100)` + 100 × `44 B`)
   - `KLNT` v2 tensor directory: 10k `f64` (`80,192 B`) and 2 MiB `f64` (`2,097,344 B`)
3. **Explicitly labeled decode semantics:** Always report **Owned (arena)**, **Owned (`malloc`)**, and **Zero-copy View** separately, each with **UTF-8 checked** and **Trusted (`check_utf8=0`)**.

---

## 5. Repository Layout

```text
gld-kiln-asm/
├── DESIGN.md                  # This document
├── README.md                  # Overview, spec summary table, quickstart, baseline results
├── LICENSE                    # MIT (from gld-kiln template)
├── VERSION                    # Semantic version (0.1.0)
├── .gitignore                 # Ignore build/, bin/, lib/, site/, *.o, *.a
├── Makefile                   # MODE=nolibc | MODE=cabi (future: MODE=hybrid)
├── mkdocs.yml                 # Material for MkDocs config (templated from gld-kiln)
├── requirements-docs.txt      # Pinned mkdocs + mkdocs-material (from gld-kiln)
├── .github/
│   └── workflows/
│       ├── ci.yml             # Build & test MODE=cabi + MODE=nolibc + mkdocs build --strict
│       ├── pages.yml          # GitHub Pages deploy on push to main
│       └── publish.yml        # GitHub Release workflow (libkiln_asm.a, kiln_asm.h, kiln_bench_nolibc, SHA256SUMS)
├── arch/
│   └── x86_64/
│       ├── defs.inc           # Error codes, profile/flag constants, cursor macros
│       ├── wire.s             # Core Frozen primitives + pre-alloc guards + KLN0 frame
│       ├── utf8.s             # AVX2 ASCII fast-path + RFC 3629 UTF-8 validator
│       ├── tensor.s           # KLNT v2 encoder + 12-step normative validator/decoder
│       ├── codecs_bench.s     # Specialized Point, Message, Batch[100] codecs
│       ├── abi_c.s            # System V AMD64 wrappers (MODE=cabi)
│       └── nolibc_entry.s     # _start, raw syscalls, bump arena, bench loop (MODE=nolibc)
├── include/
│   └── kiln_asm.h             # Public C API for libkiln_asm.a
├── examples/
│   └── roundtrip.c            # Minimal runnable C example linking libkiln_asm.a
├── c_ref/
│   └── kiln_c_ref.c           # Apples-to-apples C (-O3 -march=native) reference
├── tests/
│   └── test_conformance.c     # Runs golden/*.kiln + all 46 vectors in kiln-v2-cases.json
├── scripts/
│   └── run-tests.sh           # Unified CI/local test entry point (cabi + nolibc + examples)
├── bench/
│   └── run_bench.sh           # Pinned taskset -c 2 runner printing comparison tables
├── testdata/
│   ├── kiln-v2-cases.json     # Copied from gld-kiln/spec/kiln-v2-cases.json
│   └── golden/                # Copied point.kiln, message.kiln, message.frame.kiln
└── docs/
    ├── index.md               # Site landing page (templated from gld-kiln/docs/index.md)
    ├── experiments.md         # Recorded A/B results (nolibc vs cabi vs c_ref vs Mojo)
    └── asm/
        ├── quickstart.md      # Build, MODE switch, and runnable examples
        ├── api.md             # C ABI (include/kiln_asm.h) & internal register contract
        └── internals.md       # Architecture, SIMD/UTF-8 design, conformance verification
```

*(Clean seams for later: Option 2 adds `codegen/` for `gld-kilngen-asm`; Option 3 adds `hybrid/` under `MODE=hybrid`.)*

### 5.1 Documentation, CI/CD & Transferable Artifacts (Template: `../gld-kiln`)

Documentation, CI/CD, and repository hygiene artifacts are templated directly from the sibling `gld-kiln` repository so `gld-kiln-asm` looks, tests, and publishes identically to the rest of the Kiln ecosystem:

| Template Source (`gld-kiln`) | Target in `gld-kiln-asm` | Adaptation Rules |
| :--- | :--- | :--- |
| `LICENSE`, `requirements-docs.txt` | Verbatim | Identical MIT license and pinned MkDocs/Material versions (`mkdocs==1.6.1`, `mkdocs-material==9.6.22`). |
| `.gitignore`, `VERSION` | Adapted | Exclude `build/`, `bin/`, `lib/`, `site/`, `*.o`, `*.a`; track version `0.1.0` (matching sibling `gld-kiln-*` ports). |
| `README.md`, `mkdocs.yml`, `docs/` | Adapted | Same Material theme (`indigo`/`teal`), extensions, and section structure (`index.md`, `asm/{quickstart,api,internals}.md`, `experiments.md`). **Do not fork** `docs/spec/` or `docs/comparison.md` — link to canonical `https://leo-gan.github.io/gld-kiln/spec/` and `/comparison/`. |
| `.github/workflows/ci.yml` | Adapted for x86-64 GNU toolchain | `ubuntu-latest` jobs: (1) build & verify `MODE=cabi` (golden + 46/46 vectors + `examples/roundtrip.c`), (2) build & verify `MODE=nolibc` (zero `NEEDED` libs via `readelf -d` + self-check), (3) `mkdocs build --strict`. |
| `.github/workflows/pages.yml` | Verbatim structure | Deploy MkDocs site to GitHub Pages (`https://leo-gan.github.io/gld-kiln-asm/`) on push to `main` and `workflow_dispatch`. |
| `.github/workflows/publish.yml` | Adapted for GitHub Releases | `gld-kiln` publishes a Mojo `.conda` package to `prefix.dev`. For `gld-kiln-asm`, `publish.yml` builds and attaches `libkiln_asm.a`, `include/kiln_asm.h`, `kiln_bench_nolibc`, and `SHA256SUMS` to GitHub Releases. |
| `scripts/run-tests.sh`, `examples/roundtrip.mojo` | `scripts/run-tests.sh`, `examples/roundtrip.c` | Unified local/CI test script and runnable consumer example. |
| `pixi.toml`, `conda.recipe/`, `spec/kiln-wire-v2.md` | **Not transferred** | Mojo-specific packaging is unnecessary for GNU `as`/`ld`/`gcc`; normative spec stays single-source in `gld-kiln`. |

---

## 6. Execution Plan & Verification Gates

1. **Phase 1 — Skeleton, Build Switch & Golden Frozen Round-Trip**
   - Implement `defs.inc`, `wire.s` (Frozen scalars, `str`, `list`, `opt`, `dict`, `KLN0` frame + FNV-1a-64), `utf8.s` (scalar + SWAR/AVX2 ASCII), `codecs_bench.s`, `abi_c.s`, and `nolibc_entry.s`.
   - **Verify:**
     - `make MODE=cabi test` produces byte-identical output to `testdata/golden/point.kiln`, `message.kiln`, and `message.frame.kiln`, and passes Frozen error cases (`EOF`, `LIMIT`, `TYPE`, `UTF8`, `TRAILING`, `SCHEMA`, `FRAME`, `DEPTH`).
     - `make MODE=nolibc` links cleanly with zero dynamic dependencies (`readelf -d bin/kiln_bench_nolibc` has no `NEEDED` entries) and self-verifies the golden bytes before timing.

2. **Phase 2 — Full `KLNT` v2 Tensor Directory & 46-Vector Conformance**
   - Implement `tensor.s` covering the full 12-step normative validation order (19 dtypes, packed 4-bit high-nibble checks, quantization schemes 1 & 2, opaque blocks `4096..32767`, greedy 64-byte alignment, zero-gap checks, embedded `tensors` field).
   - **Verify:** All **46/46 vectors** in `testdata/kiln-v2-cases.json` match expected accept/reject and exact `kiln_err_t` code at reference cap `16,777,216`.

3. **Phase 3 — Apples-to-Apples C Reference & Microarchitectural Experiments**
   - Implement `c_ref/kiln_c_ref.c` with identical runtime structs, arena/view modes, and optimization barriers.
   - Run `bench/run_bench.sh` under `taskset -c 2` comparing `nolibc` vs `cabi` vs `c_ref (-O3 -march=native)` across `Point`, `Message` (`n=1`), `Batch` (`n=100`), and `2 MiB f64 KLNT`.
   - Iterate A/B micro-optimizations (32 B writer slop, fused AVX2 UTF-8+copy, `rep movsb` vs AVX2 vs `vmovntdq`) and record results in `docs/experiments.md`.
   - **Verify:** All 46 conformance vectors + golden tests still pass after every optimization step.

4. **Phase 4 — Documentation, CI/CD & Transferable Project Artifacts**
   - Create `LICENSE`, `.gitignore`, `VERSION`, `README.md`, `mkdocs.yml`, `requirements-docs.txt`, `examples/roundtrip.c`, `scripts/run-tests.sh`, `docs/` (`index.md`, `asm/{quickstart,api,internals}.md`, `experiments.md`), and `.github/workflows/{ci.yml,pages.yml}` (plus `publish.yml` if enabled) using `../gld-kiln` as the template.
   - Ensure the default git branch matches CI triggers (`main`).
   - **Verify:**
     - `scripts/run-tests.sh` passes end-to-end (`MODE=cabi` tests, `MODE=nolibc` static-link + self-test, `examples/roundtrip.c` build + run).
     - `mkdocs build --strict` succeeds with zero warnings (when MkDocs is installed locally, and enforced in `ci.yml`).

---

## 7. Future Roadmap (Out of Scope for Initial Kickoff)

- **Option 2 (`gld-kilngen-asm`):** AOT compiler reading the Kiln JSON Schema subset and emitting specialized `.s` codecs under `arch/x86_64/gen/`.
- **Option 3 (`MODE=hybrid`):** C `-O3 -march=native` schema codecs paired with AVX2 intrinsics / Assembly micro-kernels, directly benchmarked against `MODE=nolibc` and `MODE=cabi`.

---

## 8. Confirmed Decisions (Session 1)

1. **Timing primitive in `MODE=nolibc`:** Measure **both** `SYS_clock_gettime(CLOCK_MONOTONIC)` (direct ns comparability with C/Mojo) **and** `rdtscp` cycle counts (sub-20 ns resolution bypassing the ~23 ns timer floor).
2. **Scope order:** **Full** order — Phase 1 (Frozen + dual switch) → Phase 2 (full 46/46 `KLNT` v2 conformance) → Phase 3 (apples-to-apples benchmarks & A/B micro-opts) → Phase 4 (docs, CI/CD & release workflow).
3. **Release workflow (`publish.yml`):** **Included now** — GitHub Release workflow building and attaching `libkiln_asm.a`, `include/kiln_asm.h`, `kiln_bench_nolibc`, and `SHA256SUMS`.
