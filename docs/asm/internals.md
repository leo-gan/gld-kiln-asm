# Implementation & Verification

## 1. Two-Layer Assembly Architecture

Every codec kernel in `arch/x86_64/` is written once in Intel-syntax GNU Assembly (`.intel_syntax noprefix`) with zero libc references and compiled into both modes:

| Source File | Role |
| :--- | :--- |
| `arch/x86_64/defs.inc` | Normative constants, C/ASM shared struct offsets, syscall numbers, and `KILN_FAIL` / `KILN_OK_RET` macros. |
| `arch/x86_64/utf8.s` | 32 B AVX2 `vpmovmskb` → 8 B SWAR → 4..7 B overlapping `DWORD` SWAR → scalar RFC 3629 UTF-8 validator, plus single-pass fused validate+copy (`kiln_core_utf8_copy`). |
| `arch/x86_64/wire.s` | Safe branchless small-copy buckets (`1..32 B`), A/B bulk copy kernels (`rep movsb` / AVX2 `vmovdqu` / `vmovntdq`), FNV-1a-64 token mixer, §4.2 overflow-checked pre-allocation guard (`mul` checking `rdx != 0`), §5.2 `KLN0` framing, bump arena, depth guard, and `dict<str,i64>`. |
| `arch/x86_64/codecs_bench.s` | Specialized Frozen codecs (`Point`, `Message` with inlined 0..8 B SWAR UTF-8+copy fast path, framed `Message`, `Batch`, `opt<i32>`, and Frozen list codecs). |
| `arch/x86_64/tensor.s` | Full 12-step normative `KLNT` v2 validator/decoder, canonical encoder, and embedded/framed `struct{id:i64,batch:tensors,}`. |
| `arch/x86_64/abi_c.s` | Thin System V AMD64 C-ABI bridge (`MODE=cabi`). Uses RIP-relative 32-bit `.rodata` offset tables (`.long label - table`) so `libkiln_asm.a` links PIE-clean with zero `DT_TEXTREL` warnings. |
| `arch/x86_64/nolibc_entry.s` | Standalone `_start` entry (`MODE=nolibc`), raw Linux syscalls (`write=1`, `mmap=9`, `clock_gettime=228`, `exit_group=231`), serialized `lfence; rdtscp` cycle timing, golden `--self-test`, and in-Assembly hot loops. |

All assembly translation units emit `.section .note.GNU-stack,"",@progbits` and link with `-z noexecstack`, ensuring a non-executable `GNU_STACK RW` ELF header.

## 2. Key Engineering Details

### Fused Short-String UTF-8 Validation & Copy

In `codecs_bench.s`, `DEC_MSG_STR_FAST` decodes 0..8 byte ASCII strings directly inside `kiln_core_dec_message` without any `call`/`ret` or stack frame:

- For `4 ≤ len ≤ 8`, two overlapping 32-bit loads (`[r12 + 4]` and `[r12 + len]`) cover all bytes without ever reading outside `[body, body + len)`.
- A single `or` + `test 0x80808080` validates ASCII across all 4..8 bytes in one branch.
- In owned mode (`FLAG_OWNED`), those exact two register values are written straight into the bump arena `r14` before advancing `r14` and `r12` — touching every byte once.
- Strings `> 8 B` or containing any non-ASCII byte fall back cold to `kiln_core_dec_str` with `r12` untouched so full AVX2 + RFC 3629 validation and exact error byte offsets are preserved.

### 12-Step Normative `KLNT` v2 Validation

`kiln_core_dec_tensors` in `arch/x86_64/tensor.s` implements [spec §7.2](https://leo-gan.github.io/gld-kiln/spec/#check-order) verbatim in order:

1. **Pre-allocation Steps 1–7:** Magic/length (`EOF`/`FRAME`), version/flags/reserved (`vmovdqu` + `vptest` over 32 B `reserved1`), count/name caps (`LIMIT`), `count × 128 + name_bytes == directory_bytes` (`LIMIT`/`TYPE`), `64 + directory_bytes ≤ rem` (`EOF`), `align64` + `payload_bytes` overflow (`LIMIT`) and fit (`EOF`), and zero header-to-payload padding (`TYPE`) — all checked **before** allocating any descriptor array from `r14`.
2. **Steps 8–12:** Descriptor reserved bytes (`ptest` over 16 B `reserved1`), all-or-none `FLAG_NAME` & gapless name/layout heap walk + UTF-8 + duplicate tensor-name rejection, `rank ≤ 8` & zero shape tail & overflow-checked shape product (`mul`), closed standard dtypes `1..19` vs opaque `4096..32767` (`byte_length % block_size == 0`), greedy 64-byte placement & zero inter-payload gaps, AVX2 `bool` domain check (`vptest` against `0xFE`), odd packed 4-bit high-nibble check, overflow-free quantization group-count check (`(shape[a] - 1) / g + 1`) for Schemes 1 & 2, and standalone `TRAILING` check.

### Zero-Libc Static ELF (`MODE=nolibc`)

Linking `bin/kiln_bench_nolibc` with `ld -static -nostdlib --gc-sections -z noexecstack` produces a **~40 KB** static ELF64 executable with:

- **0 `NEEDED` dynamic libraries** (verified automatically by `make MODE=nolibc test` via `readelf -d`)
- No `PT_INTERP` or `PT_DYNAMIC` program headers
- Non-executable `GNU_STACK` (`RW`)

## 3. Hardware Acceleration: SIMD and GPU Scope

### SIMD Usage and Tradeoffs

`gld-kiln-asm` uses SIMD selectively — combining **AVX2** (256-bit `ymm`), **AVX/SSE** (128-bit `xmm`), and **SWAR** (32/64-bit GPR bitmasks) only where the data is wide and homogeneous enough to beat scalar instructions:

| Source | ISA / Technique | Scope |
| :--- | :--- | :--- |
| `arch/x86_64/utf8.s` | AVX2 (`vmovdqu` + `vpmovmskb`) + SWAR (`0x8080...`) | 32 B/iter ASCII validation and fused validate+copy (`len >= 32`), stepping down to 8 B / 4 B SWAR. Non-ASCII bytes fall back to the scalar RFC 3629 validator. |
| `arch/x86_64/wire.s` | AVX / AVX2 (`vmovdqu`, `vmovntdq` + `sfence`) | Overlapping 16 B `xmm` copy for `17..32 B`; opt-in 128 B/iter unrolled `vmovdqu` (`KILN_OPT_COPY_AVX2`) and non-temporal `vmovntdq` (`KILN_OPT_COPY_NT`) for `KLNT` bulk payloads. |
| `arch/x86_64/tensor.s` | AVX2 / SSE4.1 (`vptest`, `ptest`, `vpxor`) | 32 B/iter `bool` tensor domain validation (`0xFE` mask), 32 B header and 16 B descriptor reserved-byte zero checks, and 1–4 store zero-initialization of headers and 128 B descriptors. |
| `arch/x86_64/codecs_bench.s` | GPR SWAR (default) / AVX2 (`KILN_OPT_SLOP32`) | Inlined overlapping 4 B SWAR UTF-8+copy for 0..8 B strings; opt-in 32 B `vmovdqu` slop copy on encode. |

Paired A/B measurements in [Experiments](../experiments.md) define where vector instructions pay off versus where scalar/SWAR wins:

- **Where SIMD pays off:** Wide homogeneous scans (`>= 32 B` ASCII strings, `bool` tensors, fixed reserved blocks) run at cache/memory bandwidth; non-temporal `vmovntdq` improves 2 MiB `KLNT` encode by ~5% over `rep movsb` (`69.7–70.9 µs` vs `73.8–74.4 µs`) by avoiding cache read-for-ownership traffic; and 4..8 B GPR SWAR delivered a **3.0×–3.6×** decode speedup on `Message`/`Batch[100]` without `vzeroupper` overhead.
- **Where wide AVX2 does not pay off:** On short strings (5 B in `Message`), `KILN_OPT_SLOP32` (`vmovdqu ymm` + `vzeroupper`) was slightly slower than overlapping 32-bit GPR stores (`2.8 ns` vs `2.7 ns`) while adding a 32 B buffer-slop requirement. Heterogeneous scalar structs (`Point`, `Message`) already encode in ~8 cycles via straight-line unaligned `mov` instructions, and plain cached `vmovdqu` barely differs from Alder Lake `rep movsb` (`72.8 µs` vs `73.8 µs`) once memory-bandwidth bound.
- **Potential future SIMD extensions:** Long non-ASCII UTF-8 payloads (Keiser–Lemire AVX2 lookup in `utf8.s`) and long byte-slice comparisons in `kiln_core_cmp_bytes` (`wire.s`, currently 1 byte/iter) remain scalar and are the primary candidates if those workloads become hot.

### Why CPU-Only (No GPU Offload) and `KLNT` GPU Interop

Executing Kiln wire encoding or decoding on a GPU is out of scope and counterproductive for this workload:

1. **Launch latency exceeds codec runtime by orders of magnitude:** `gld-kiln-asm` encodes/decodes a `Message` in `2.7–3.5 ns`, processes `Batch[100]` (`4.4 KB`) in `274–349 ns`, and validates a 2 MiB `KLNT` directory (zero-copy view) in `22.5 ns`. A single GPU kernel launch alone costs `~3–10 µs`.
2. **Bus transfer vs. CPU memory bandwidth:** A single CPU core copies a 2 MiB `KLNT` payload at `~30 GB/s` (`~70 µs`). Round-tripping 2 MiB across PCIe Gen4 x16 (`~25 GB/s` usable) takes `~160+ µs` in transfer time alone before any kernel executes.
3. **Sequential, branchy wire parsing:** Frozen records with variable-length strings have no per-record offset index (record `i+1` starts after parsing record `i`), and validation combines near-zero arithmetic intensity with dense bounds, depth, ordering, and UTF-8 checks. Moreover, `MODE=nolibc` intentionally has zero dynamic library dependencies; driving a GPU requires host runtime/driver APIs (`CUDA`, `HIP`, `Vulkan`, `OpenCL`).

**Recommended GPU integration pattern (`KLNT` v2):** Rather than running the wire parser on a GPU, keep `gld-kiln-asm` on the CPU as a nanosecond-scale metadata validator and zero-copy directory parser. Because `KLNT` v2 guarantees 64-byte payload alignment and contiguous little-endian ML tensors (`f16`, `bf16`, `f8*`, packed 4-bit `i4`/`u4`/`e2m1`), a host application linking `libkiln_asm.a` can validate the directory in ~22 ns (zero-copy view) and stream the validated payload slices straight from pinned host memory (`cudaMemcpyAsync`) or NVMe (GPUDirect Storage) into VRAM, keeping GPU kernels focused on compute or dequantization of VRAM-resident tensors.

## 4. Verification Matrix

Run `./scripts/run-tests.sh` to execute all verification gates:

1. **Compile-time C/ASM ABI layout assertions:** `_Static_assert` verifies every `offsetof` and `sizeof` across `kiln_arena_t`, `kiln_read_opts_t`, `kiln_result_t`, `kiln_str_t`, `kiln_point_t`, `kiln_message_t`, `kiln_dict_entry_t`, `kiln_tensor_t`, `kiln_tensor_dir_t`, and `kiln_id_tensors_t`.
2. **Frozen golden binaries (3/3):** Byte-exact decode + re-encode against `testdata/golden/point.kiln`, `message.kiln`, and `message.frame.kiln`, plus FNV-1a-64 hash verification and all 8 normative error codes.
3. **Normative v2 conformance vectors (46/46):** Full field-by-field validation, byte-exact re-encoding, and owned-arena decoding over all accept vectors in `testdata/kiln-v2-cases.json`, exact `kiln_err_t` matching on every reject vector, and **zero arena bytes allocated** verified on all 7 hostile-allocation cases.
4. **Additional `KLNT` & UTF-8 edge tests:** 65 B AVX2 `bool` accept & corrupt-byte reject, descriptor `reserved0`/`reserved1` `FRAME` reject, nonzero inter-payload gap `TYPE` reject, 10k `f64` round-trip, RFC 3629 boundary sequences (overlong, surrogates, `U+10FFFF` / `U+110000`, truncated).
5. **Mode & Example checks:** `MODE=nolibc` zero-libc ELF check + `--self-test`, `examples/roundtrip.c` build+run, `c_ref` `-Wall -Wextra -Werror` build, and `VERSION` consistency across `VERSION`, `include/kiln_asm.h`, and `arch/x86_64/abi_c.s`.

See [API & ABI Reference](api.md) and [Experiments](../experiments.md) for the public interface and measured performance numbers.
