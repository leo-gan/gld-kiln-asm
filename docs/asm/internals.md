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

## 3. Verification Matrix

Run `./scripts/run-tests.sh` to execute all verification gates:

1. **Compile-time C/ASM ABI layout assertions:** `_Static_assert` verifies every `offsetof` and `sizeof` across `kiln_arena_t`, `kiln_read_opts_t`, `kiln_result_t`, `kiln_str_t`, `kiln_point_t`, `kiln_message_t`, `kiln_dict_entry_t`, `kiln_tensor_t`, `kiln_tensor_dir_t`, and `kiln_id_tensors_t`.
2. **Frozen golden binaries (3/3):** Byte-exact decode + re-encode against `testdata/golden/point.kiln`, `message.kiln`, and `message.frame.kiln`, plus FNV-1a-64 hash verification and all 8 normative error codes.
3. **Normative v2 conformance vectors (46/46):** Full field-by-field validation, byte-exact re-encoding, and owned-arena decoding over all accept vectors in `testdata/kiln-v2-cases.json`, exact `kiln_err_t` matching on every reject vector, and **zero arena bytes allocated** verified on all 7 hostile-allocation cases.
4. **Additional `KLNT` & UTF-8 edge tests:** 65 B AVX2 `bool` accept & corrupt-byte reject, descriptor `reserved0`/`reserved1` `FRAME` reject, nonzero inter-payload gap `TYPE` reject, 10k `f64` round-trip, RFC 3629 boundary sequences (overlong, surrogates, `U+10FFFF` / `U+110000`, truncated).
5. **Mode & Example checks:** `MODE=nolibc` zero-libc ELF check + `--self-test`, `examples/roundtrip.c` build+run, `c_ref` `-Wall -Wextra -Werror` build, and `VERSION` consistency across `VERSION`, `include/kiln_asm.h`, and `arch/x86_64/abi_c.s`.

See [API & ABI Reference](api.md) and [Experiments](../experiments.md) for the public interface and measured performance numbers.
