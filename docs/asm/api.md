# API & ABI Reference

`gld-kiln-asm` exposes two clean layers over the same x86-64 codec kernels:

1. **Public C11 API (`include/kiln_asm.h`)** — System V AMD64 callable symbols archived into `lib/libkiln_asm.a` (`MODE=cabi`).
2. **Internal Register-Pinned ABI (`arch/x86_64/defs.inc`)** — non-standard internal register contract used directly by `MODE=nolibc` and bridged once at entry/exit by `arch/x86_64/abi_c.s`.

---

## 1. Error Codes (`kiln_err_t`)

Matches the closed eight-code normative error taxonomy of [Kiln Wire Format v2 §7.1](https://leo-gan.github.io/gld-kiln/spec/#errors):

| Value | Enum | `kiln_asm_err_name` | Meaning |
| ---: | :--- | :--- | :--- |
| `0` | `KILN_OK` | `"OK"` | Success |
| `1` | `KILN_ERR_FRAME` | `"FRAME"` | Invalid magic (`KLN0`/`KLNT`), profile `≠ 0`, version `≠ 2`, bad/unknown flags, nonzero reserved bytes |
| `2` | `KILN_ERR_SCHEMA` | `"SCHEMA"` | `KLN0` FNV-1a-64 schema hash mismatch |
| `3` | `KILN_ERR_LIMIT` | `"LIMIT"` | Exceeded `max_count`/`max_bytes`, output buffer/arena capacity exhausted, or `u64` arithmetic overflow |
| `4` | `KILN_ERR_EOF` | `"EOF"` | Truncated buffer or `count × min(T) > remaining` (pre-allocation reject) |
| `5` | `KILN_ERR_TYPE` | `"TYPE"` | Invalid `bool`/`opt` tag, unsorted/duplicate `dict` key, invalid `KLNT` metadata/alignment/padding/nibble/quant links |
| `6` | `KILN_ERR_UTF8` | `"UTF8"` | Invalid RFC 3629 UTF-8 byte sequence |
| `7` | `KILN_ERR_TRAILING` | `"TRAILING"` | Unread bytes remaining after standalone root value |
| `8` | `KILN_ERR_DEPTH` | `"DEPTH"` | Nesting depth `> max_depth` (default `64`) |

---

## 2. Options, Arena & Result Types

```c
typedef struct kiln_arena_t {
    uint8_t *base;
    uint8_t *cur;
    uint8_t *end;
} kiln_arena_t;

typedef struct kiln_read_opts_t {
    uint64_t max_count; /* 0 -> 16,777,216 */
    uint64_t max_bytes; /* 0 -> 16,777,216 */
    uint32_t max_depth; /* 0 -> 64 (clamped <= 255) */
    uint32_t flags;     /* bitmask of kiln_opt_flags_t */
} kiln_read_opts_t;

typedef struct kiln_result_t {
    uint64_t bytes; /* bytes written/consumed, or byte offset on error */
    uint64_t hash;  /* decoded KLN0 schema hash (0 for unframed calls) */
} kiln_result_t;
```

### Option Flags (`kiln_opt_flags_t`)

| Flag | Bit | Behavior |
| :--- | ---: | :--- |
| `KILN_OPT_TRUSTED` | `1 << 0` | Opt-in trusted mode: skips UTF-8 validation (bounds checks remain active). |
| `KILN_OPT_OWNED` | `1 << 1` | Copies decoded strings and tensor payloads into the caller's `kiln_arena_t` instead of returning zero-copy views into `src`. |
| `KILN_OPT_SLOP32` | `1 << 2` | Experimental flag asserting 32 B trailing readable/writable slop on short strings & destination buffer. |
| `KILN_OPT_EMBEDDED` | `1 << 3` | Suppresses the standalone `KILN_ERR_TRAILING` check. |
| `KILN_OPT_COPY_AVX2` | `1 << 4` | Selects unrolled 4×`vmovdqu` (128 B/iter) for `KLNT` bulk payload copies. |
| `KILN_OPT_COPY_NT` | `1 << 5` | Selects 32 B aligned non-temporal `vmovntdq` + `sfence` for `KLNT` bulk payload copies. |

Inline arena helpers: `kiln_arena_init(a, buf, cap)`, `kiln_arena_reset(a)`, `kiln_arena_used(a)`, and `kiln_tensor_init(t)`.

---

## 3. Exported C11 Functions (`libkiln_asm.a`)

### Metadata & Low-Level Primitives

- `const char *kiln_asm_version(void)` — returns `"0.1.0"`.
- `const char *kiln_asm_err_name(kiln_err_t err)` — returns normative uppercase error name.
- `const char *kiln_asm_dtype_name(uint16_t dtype)` — returns canonical name for standard dtypes `1..19` (`"f64"` .. `"e8m0"`), or `NULL` otherwise.
- `int kiln_asm_utf8_ok(const uint8_t *s, size_t n)` — returns `1` if valid RFC 3629 UTF-8, `0` otherwise.
- `uint64_t kiln_asm_fnv1a_mix_token(uint64_t h, const uint8_t *tok, size_t len)` — normative §5.3 FNV-1a-64 token mixer (with trailing `0x00` delimiter).

### Specialized Frozen Codecs

- `kiln_asm_encode_point` / `kiln_asm_decode_point` — `Point { x: i32, y: i32 }` (`8 B`, hash `0xE66AC0386103C72F`).
- `kiln_asm_encode_message` / `kiln_asm_decode_message` — 8-field `Message` (`kiln_message_t`, 64-byte cache-line-aligned struct).
- `kiln_asm_encode_message_framed` / `kiln_asm_decode_message_framed` — 16-byte `KLN0` frame + `Message` (hash `0xD6646445F41CE803`).
- `kiln_asm_encode_batch` / `kiln_asm_decode_batch` — `list<Message>` with pre-allocation `count × 34 ≤ remaining` guard.
- `kiln_asm_encode_opt_i32` / `kiln_asm_decode_opt_i32` — `opt<i32>`.
- `kiln_asm_encode_dict_i64` / `kiln_asm_decode_dict_i64` — `dict<str, i64>` enforcing strict ascending unsigned UTF-8 key order.
- `kiln_asm_encode_list_f32` / `kiln_asm_decode_list_f32` / `kiln_asm_decode_list_str` / `kiln_asm_decode_list_i64_struct` — Frozen list codecs with §4.2 pre-allocation guards.

### `KLNT` v2 Tensor Directory Codecs

- `kiln_asm_encode_tensors` / `kiln_asm_decode_tensors` — canonical `KLNT` v2 encoder and full 12-step normative validator/decoder (`kiln_tensor_dir_t`, `kiln_tensor_t`).
- `kiln_asm_encode_id_tensors` / `kiln_asm_decode_id_tensors` — embedded `struct{id:i64,batch:tensors,}`.
- `kiln_asm_encode_id_tensors_framed` / `kiln_asm_decode_id_tensors_framed` — `KLN0`-framed `struct{id:i64,batch:tensors,}` (hash `0xE58AADC7552F0D82`).

---

## 4. Internal Register-Pinned Kernel Contract (`arch/x86_64/defs.inc`)

All `kiln_core_*` symbols share a custom internal calling convention designed to eliminate per-call context/cursor spills inside hot Assembly loops:

| Register | Internal Contract |
| :--- | :--- |
| `r12` | Wire cursor pointer (`src` on decode, `dst` on encode) |
| `r13` | Wire end pointer (`src_end` / `dst_end`) |
| `r14` | Bump arena allocation pointer (`arena_cur`, decode only) |
| `r15` | Bits `0..7`: nesting depth; bit `8`: `FLAG_CHECK_UTF8`; bit `9`: `FLAG_SLOP32`; bit `10`: `FLAG_OWNED`; bit `11`: `FLAG_EMBEDDED`; bit `12`: `FLAG_COPY_AVX2`; bit `13`: `FLAG_COPY_NT` |
| `rbx` | Pointer to 40-byte `kiln_ctx_t` (`base_ptr`, `arena_end`, `max_count`, `max_bytes`, `max_depth`) |
| `CF`, `eax`, `rdx` | Return status: `CF=0, eax=0` on success; `CF=1, eax=kiln_err_t, rdx=r12-base_ptr` on failure |

Every C-ABI entry point in `arch/x86_64/abi_c.s` preserves `rbx, rbp, r12–r15`, maintains 16-byte stack alignment, and executes `vzeroupper` at the exit of every 256-bit `ymm` path. See [Implementation & Verification](internals.md) for full details.
