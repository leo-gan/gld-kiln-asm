# Kiln Assembly (`gld-kiln-asm`)

`gld-kiln-asm` is a from-scratch **pure x86-64 Assembly (GNU `as`, Intel syntax)** implementation of the **Kiln Wire Format, Version 2** ([Normative Specification](https://leo-gan.github.io/gld-kiln/spec/)). A single `Makefile` build switch (`MODE=nolibc` vs `MODE=cabi`) wraps the same register-pinned codec kernels in either a zero-libc static Linux ELF binary or a System V AMD64 static library (`libkiln_asm.a`), establishing the bare-metal hardware floor alongside the other 11 Kiln language ports.

[Serialization](https://leo-gan.github.io/serialization/) is the hub for the theory, history, and cross-language benchmarks.

## Specification & Artifact Summary

| Property | Value |
| --- | --- |
| **Wire Specification** | Kiln Wire Format, Version 2 ([Normative Spec](https://leo-gan.github.io/gld-kiln/spec/) — single source in `gld-kiln`, never forked) |
| **Profiles** | Frozen (`0`, normative default) + embedded `KLNT` v2 tensor directory (`tensors`) |
| **Optional Framing** | 16-byte `KLN0` header with FNV-1a-64 canonical schema hash |
| **Conformance Suite** | **46/46** hex vectors ([`testdata/kiln-v2-cases.json`](testdata/kiln-v2-cases.json)) + **3/3** Frozen golden binaries ([`testdata/golden/`](testdata/golden/)) |
| **Build Modes** | `MODE=cabi` (`lib/libkiln_asm.a` + `include/kiln_asm.h`) · `MODE=nolibc` (`bin/kiln_bench_nolibc`, zero `NEEDED` libs) |
| **Target ISA** | Linux `x86_64` (`AVX2`, `ERMS`/`FSRM`, GNU `as` + `ld`) |
| **Documentation** | <https://leo-gan.github.io/gld-kiln-asm/> |
| **License** | MIT |

## Core Architecture

1. **Register-pinned internal kernels (`arch/x86_64/`):** `r12` (wire cursor), `r13` (wire end), `r14` (bump arena cursor), `r15` (nesting depth + feature flags), and `rbx` (`kiln_ctx_t*`), with Carry-Flag (`CF`) error signaling (`stc` / `jc`) across internal calls.
2. **Dual experimental switch (`MODE`):**
   - `MODE=nolibc` links with `ld -static -nostdlib --gc-sections -z noexecstack` (zero libc, raw Linux syscalls `write`, `mmap`, `clock_gettime`, `exit_group`, plus `rdtscp` cycle timing).
   - `MODE=cabi` archives `lib/libkiln_asm.a` with PIE-clean System V AMD64 C wrappers declared in [`include/kiln_asm.h`](include/kiln_asm.h).
3. **Pre-allocation bounds & RFC 3629 UTF-8 safety:** Every counted container and `KLNT` v2 directory verifies caps, `u64` overflow, and buffer fit before advancing the bump arena (`0` bytes allocated on all 7 hostile vectors). Short ASCII strings use an inlined overlapping 4..8 B SWAR validate-and-copy fast path; longer strings use AVX2 `vpmovmskb`.

## Quickstart

```bash
# Build & verify both modes (46/46 v2 vectors, 3/3 golden binaries, example, zero-libc check)
./scripts/run-tests.sh

# Individual targets
make MODE=cabi test          # builds lib/libkiln_asm.a and runs conformance suite
make MODE=nolibc test        # builds bin/kiln_bench_nolibc, checks readelf -d, runs --self-test
make bench                   # runs 3-trial taskset -c 2 comparison (nolibc vs cabi vs c_ref -O3)
```

Minimal C consumer ([`examples/roundtrip.c`](examples/roundtrip.c)):

```c
#include "kiln_asm.h"
#include <stdio.h>

int main(void) {
    uint8_t wire[64];
    kiln_result_t res;
    kiln_point_t in = {9, -4}, out = {0, 0};
    kiln_asm_encode_point(&in, wire, sizeof(wire), NULL, &res);
    kiln_asm_decode_point(wire, (size_t)res.bytes, &out, NULL, &res);
    printf("%d %d %llu\n", out.x, out.y, (unsigned long long)res.bytes); /* 9 -4 8 */
}
```

## Measured Baseline (`i7-12800H`, `taskset -c 2`)

Measured on an Intel Core i7-12800H (Linux `x86_64`, `powersave` governor, `taskset -c 2`, GNU `as` 2.38, `gcc` 11.4 `-O3 -march=native`; median of 3 paired trials via `make bench`):

| Workload | Wire Size | `nolibc` (`ns` / `cyc`) | `cabi` (`ns` / `cyc`) | `c_ref -O3` (`ns` / `cyc`) |
| --- | ---: | ---: | ---: | ---: |
| Single 8-field `Message` encode | `44 B` | **`2.7 ns`** / `7.7 cyc` | `7.0 ns` / `19.7 cyc` | `3.6 ns` / `10.2 cyc` |
| Single `Message` decode (view, UTF-8) | `44 B` | **`3.1 ns`** / `8.9 cyc` | `9.5 ns` / `26.7 cyc` | `6.2 ns` / `17.5 cyc` |
| Single `Message` decode (arena, UTF-8) | `44 B` | **`3.5 ns`** / `9.9 cyc` | `8.5 ns` / `24.0 cyc` | `9.6 ns` / `26.9 cyc` |
| `Batch[100]` encode | `4,404 B` | `281.5 ns` / `789 cyc` | **`274.4 ns`** / `769 cyc` | `305.6 ns` / `857 cyc` |
| `Batch[100]` decode (arena, UTF-8) | `4,404 B` | `348.7 ns` / `978 cyc` | **`345.9 ns`** / `970 cyc` | `853.5 ns` / `2,393 cyc` |
| 2 MiB `f64` `KLNT` encode (`vmovntdq`) | `2,097,344 B` | `70.9 µs` / `198.8k cyc` | **`69.7 µs`** / `195.3k cyc` | `68.4 µs` *(glibc)* |
| 2 MiB `f64` `KLNT` decode (view) | `2,097,344 B` | **`22.5 ns`** / `62.4 cyc` | `29.9 ns` / `83.8 cyc` | `16.6 ns` / `46.3 cyc` |

Full paired tables, A/B microarchitectural findings (`slop32`, fused SWAR UTF-8+copy, ERMS vs AVX2 vs `vmovntdq`, C-ABI and `malloc` taxes), and threats to validity are documented in [Experiments](docs/experiments.md).

## Documentation

- **[Quickstart & Examples](docs/asm/quickstart.md)** — Prerequisites, `MODE=cabi` / `MODE=nolibc` build targets, and runnable examples.
- **[API & ABI Reference](docs/asm/api.md)** — C11 API (`include/kiln_asm.h`) and internal x86-64 register-pinned contract.
- **[Implementation & Verification](docs/asm/internals.md)** — Architecture, SIMD/SWAR & GPU tradeoffs, 12-step `KLNT` v2 validation, and 46/46 conformance testing.
- **[Experiments](docs/experiments.md)** — Empirical evaluation comparing `nolibc`, `cabi`, and `c_ref -O3`.
- **[Normative Wire Specification (v2)](https://leo-gan.github.io/gld-kiln/spec/)** · **[Overview & Comparison](https://leo-gan.github.io/gld-kiln/comparison/)** — Canonical standard in `gld-kiln`.

## License

MIT. Copyright (c) 2026 Leonid Ganeline.
