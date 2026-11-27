# Kiln Assembly (`gld-kiln-asm`)

`gld-kiln-asm` is a from-scratch **pure x86-64 Assembly (GNU `as`, Intel syntax)** implementation of the **Kiln Wire Format, Version 2**. It pairs register-pinned Assembly codec kernels with an experimental `MODE` build switch (`MODE=nolibc` vs `MODE=cabi`) to measure the bare-metal hardware floor, System V C-ABI boundary cost, and allocator overhead against an apples-to-apples `gcc -O3 -march=native` reference.

## Summary

| Property | Value |
| --- | --- |
| **Wire Specification** | Kiln Wire Format, Version 2 ([Normative Specification](https://leo-gan.github.io/gld-kiln/spec/)) |
| **Profiles** | Frozen (`0`, normative default) + embedded `KLNT` v2 tensor directory (`tensors`) |
| **Optional Framing** | 16-byte `KLN0` header with FNV-1a-64 canonical schema hash |
| **Conformance Suite** | **46/46** vectors (`testdata/kiln-v2-cases.json`) + **3/3** Frozen golden binaries (`testdata/golden/`) |
| **Build Modes** | `MODE=cabi` (`lib/libkiln_asm.a` + `include/kiln_asm.h`) · `MODE=nolibc` (`bin/kiln_bench_nolibc`, 0 `NEEDED` libs) |
| **Version** | `0.1.0` |
| **License** | MIT |

## Core Invariants

1. **Single normative specification:** `gld-kiln-asm` never forks the Kiln wire spec; it validates byte-for-byte against the copied normative fixtures (`testdata/kiln-v2-cases.json` and `testdata/golden/`) and links directly to [leo-gan.github.io/gld-kiln/spec/](https://leo-gan.github.io/gld-kiln/spec/).
2. **Two-layer Assembly architecture:** Core codec logic lives once in register-pinned `arch/x86_64/*.s` kernels (`r12`–`r15`, `rbx`, `CF` error signaling), wrapped by thin `MODE=nolibc` and `MODE=cabi` shells.
3. **Fail-closed pre-allocation safety:** Hostile counts and overflowing `KLNT` directory lengths are rejected (`LIMIT` / `EOF`) before touching the bump arena (`0` bytes allocated across all 7 hostile conformance vectors).
4. **Honest empirical methodology:** Every micro-optimization is A/B benchmarked on `taskset -c 2` with both `CLOCK_MONOTONIC` nanoseconds and serialized `rdtscp` cycle counts against `c_ref` (`gcc -O3 -march=native`).

## Documentation Map

- **[Quickstart & Examples](asm/quickstart.md)** — Building `MODE=cabi` and `MODE=nolibc`, running conformance tests, and linking `libkiln_asm.a`.
- **[API & ABI Reference](asm/api.md)** — Complete `include/kiln_asm.h` reference and the internal x86-64 register contract.
- **[Implementation & Verification](asm/internals.md)** — SIMD/SWAR UTF-8 fusion, 12-step `KLNT` v2 validation, zero-libc ELF details, and conformance verification.
- **[Experiments](experiments.md)** — Paired benchmark tables (`nolibc` vs `cabi` vs `c_ref`), A/B micro-optimization deltas, and reproduction commands.
- **[Overview & Comparison](https://leo-gan.github.io/gld-kiln/comparison/)** — Kiln vs. JSON, Protobuf, FlatBuffers, Cap'n Proto, Safetensors, GGUF, and Arrow (in `gld-kiln`).

## Measured Baseline (`i7-12800H`, `taskset -c 2`)

On an Intel Core i7-12800H (`powersave` governor, `taskset -c 2`, median of 3 runs), the 44-byte eight-field `Message` encodes in **`2.7 ns`** (`7.7 cyc`) and decodes into an owned bump arena with RFC 3629 UTF-8 validation in **`3.5 ns`** (`9.9 cyc`) under `MODE=nolibc` (`8.5 ns` under `MODE=cabi`, vs `9.6 ns` in `c_ref -O3`). A 100-record batch (`4,404 B`) encodes in **`274–282 ns`** and decodes (owned arena, UTF-8 checked) in **`346–349 ns`** (`2.45×` faster than `c_ref`'s `854 ns`). See [Experiments](experiments.md) for the complete 21-row comparison and threats to validity.
