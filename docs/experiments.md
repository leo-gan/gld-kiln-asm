# Empirical Evaluation and Microarchitectural Experiments

Every implementation and optimization decision in `gld-kiln-asm` is evaluated through paired measurements comparing **pure x86-64 Assembly (`MODE=nolibc`)**, **System V C-ABI Assembly (`MODE=cabi`, `libkiln_asm.a`)**, and an **apples-to-apples pure C11 baseline (`c_ref`, `gcc -O3 -march=native`)**.

---

## 1. Experimental Protocol

| Parameter | Configuration |
| :--- | :--- |
| **CPU** | 12th Gen Intel Core i7-12800H (Alder Lake: `AVX2`, `BMI1`, `BMI2`, `ERMS`, `FSRM`, `VPCLMULQDQ`, `GFNI`; no AVX-512) |
| **OS & Pinning** | Linux `x86_64`, `powersave` governor, single pinned core (`taskset -c 2`) |
| **Assembler & Linker** | GNU `as` 2.38 (`.intel_syntax noprefix`) + GNU `ld` 2.38 (`-static -nostdlib --gc-sections -z noexecstack` for `nolibc`) |
| **C Compiler** | `gcc` 11.4.0 (`-std=c11 -O3 -march=native -Wall -Wextra -Werror`) |
| **Timers** | Both `CLOCK_MONOTONIC` (nanoseconds, via raw `SYS_clock_gettime=228` in `nolibc`) and serialized `lfence; rdtscp` (CPU cycles) |
| **Summary Statistic** | Median of 3 independent paired trials per mode, each measuring hot-loop arithmetic mean after warmup |
| **Anti-Cheating Parity** | Runtime-populated structs, `asm volatile("" : "+r"(p) :: "memory")` barriers, `noinline` top-level entry points in `c_ref` (with full intra-codec inlining), and runtime sink accumulators; all 46/46 `kiln-v2-cases.json` vectors + golden binaries re-verified after every change |
| **Sources** | `arch/x86_64/nolibc_entry.s`, `bench/bench_cabi.c`, `c_ref/kiln_c_ref.c`, `bench/run_bench.sh` |

### Threats to Validity

1. **Powersave governor & turbo variance:** Measurements run on a pinned core (`taskset -c 2`) under the Linux `powersave` governor (~2.80 GHz effective TSC ratio during these runs). Relative ratios (`nolibc` vs `cabi` vs `c_ref`) within paired trials are stable; absolute nanoseconds shift under `performance` governor or different Alder Lake P/E cores.
2. **GCC IPA-CP on leaf `Point` in `c_ref`:** Even with `__attribute__((noinline))`, GCC `-O3` performs interprocedural constant propagation (`-fipa-cp`) inside the single-TU `kiln_c_ref.c`, cloning `cref_enc_point` / `cref_dec_point` with constant `cap=4096` / `len=8` and no leaf depth guard. That explains why `c_ref` `Point` (`0.5–0.6 ns`) undercuts `nolibc`'s general runtime-checked `call kiln_core_*_point` (`1.7 ns`).
3. **Algorithmic vs. ISA gains in `msg_decode_arena_utf8`:** The `2.45×–2.74×` Assembly speedup over `c_ref` on `Message` and `Batch[100]` UTF-8-checked arena decode comes largely from **fusing** 4..8 B overlapping SWAR ASCII validation with the arena copy (touching each byte once with zero calls). A hand-tuned C+intrinsics implementation (planned `MODE=hybrid`, Option 3) can adopt the same algorithm and narrow most of that gap.
4. **Reference Mojo numbers:** Mojo `1.1.0` numbers cited from `gld-kiln/docs/experiments.md` were collected on the same CPU model (`i7-12800H`, `taskset -c 2`, `powersave`) in a separate session and serve as directional ecosystem context rather than same-minute paired runs.

---

## 2. Paired Results (`MODE=nolibc` vs `MODE=cabi` vs `c_ref`)

Measured via `make bench` (median of 3 runs on `taskset -c 2`, post-Opt #2 kernels, 46/46 conformance verified):

| Workload | Wire Size | `nolibc` (`ns` / `cyc`) | `cabi` (`ns` / `cyc`) | `c_ref` `-O3` (`ns` / `cyc`) | `nolibc` vs `c_ref` |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `point_encode` | `8 B` | `1.7` / `4.9` | `3.8` / `10.6` | `0.6` / `1.8` | `0.35×` *(IPA-CP)* |
| `point_decode` | `8 B` | `1.7` / `4.7` | `3.6` / `10.2` | `0.5` / `1.4` | `0.29×` *(IPA-CP)* |
| **`msg_encode`** | `44 B` | **`2.7`** / `7.7` | `7.0` / `19.7` | `3.6` / `10.2` | **`1.33×` (−25.0%)** |
| `msg_encode_slop32` | `44 B` | `2.8` / `7.8` | `5.7` / `16.1` | — | *(A/B Opt #1)* |
| **`msg_decode_view_utf8`** | `44 B` | **`3.1`** / `8.9` | `9.5` / `26.7` | `6.2` / `17.5` | **`2.00×` (−50.0%)** |
| `msg_decode_view_trusted` | `44 B` | `2.8` / `7.9` | `9.1` / `25.7` | `2.6` / `7.5` | `0.93×` (+7.7%) |
| **`msg_decode_arena_utf8`** | `44 B` | **`3.5`** / `9.9` | `8.5` / `24.0` | `9.6` / `26.9` | **`2.74×` (−63.5%)** |
| **`msg_decode_arena_trusted`** | `44 B` | **`3.3`** / `9.3` | `7.9` / `22.2` | `4.8` / `13.4` | **`1.45×` (−31.2%)** |
| `msg_decode_malloc_utf8` | `44 B` | — | `25.2` / `70.9` | `20.8` / `58.3` | *(allocator tax)* |
| **`batch100_encode`** | `4,404 B` | `281.5` / `789.1` | **`274.4`** / `769.3` | `305.6` / `856.7` | **`1.09×` (−7.9%)** |
| **`batch100_view_utf8`** | `4,404 B` | **`322.9`** / `905.3` | `326.4` / `915.1` | `516.2` / `1,447.1` | **`1.60×` (−37.4%)** |
| `batch100_view_trusted` | `4,404 B` | `314.7` / `882.2` | `315.8` / `885.3` | `299.3` / `839.0` | `0.95×` (+5.1%) |
| **`batch100_arena_utf8`** | `4,404 B` | `348.7` / `977.5` | **`345.9`** / `969.8` | `853.5` / `2,392.5` | **`2.45×` (−59.1%)** |
| **`batch100_arena_trusted`** | `4,404 B` | **`345.0`** / `967.1` | `346.4` / `971.0` | `502.4` / `1,408.4` | **`1.46×` (−31.3%)** |
| `klnt_10k_f64_encode` | `80,192 B` | `1,296.4` / `3,633.9` | `1,261.6` / `3,536.7` | `1,238.5` / `3,471.9` | `0.96×` (+4.7%) |
| `klnt_10k_f64_decode_view` | `80,192 B` | `19.2` / `53.8` | `26.5` / `74.4` | `15.2` / `42.7` | `0.79×` (+26.3%) |
| `klnt_2m_f64_encode_erms` | `2,097,344 B` | `73,763.3` / `206,770.9` | `74,438.3` / `208,663.1` | `68,391.7` / `191,711.0` | `0.93×` (+7.9%) |
| `klnt_2m_f64_encode_avx2` | `2,097,344 B` | `72,779.6` / `204,012.9` | `73,198.4` / `205,190.2` | — | *(A/B Opt #3)* |
| `klnt_2m_f64_encode_nt` | `2,097,344 B` | `70,908.2` / `198,769.7` | `69,671.0` / `195,290.4` | — | *(A/B Opt #3)* |
| `klnt_2m_f64_decode_view` | `2,097,344 B` | `22.5` / `62.4` | `29.9` / `83.8` | `16.6` / `46.3` | `0.74×` (+35.5%) |
| `klnt_2m_f64_decode_arena` | `2,097,344 B` | `77,426.7` / `217,040.9` | `76,435.2` / `214,263.7` | `72,506.0` / `203,250.4` | `0.94×` (+6.8%) |

For ecosystem context (`gld-kiln` Mojo `1.1.0` on the same CPU model): single `Message` encode `15 ns` (`5.5×` slower than `nolibc`'s `2.7 ns`), single owned decode `28 ns` (`8.0×` slower than `nolibc`'s `3.5 ns`), `Batch[100]` encode `339 ns` (`1.2×`), `Batch[100]` owned UTF-8 decode `1,560 ns` (`4.5×` slower than `cabi`/`nolibc`'s `346–349 ns`), and `2 MiB f64 KLNT` encode `74 µs` (essentially tied at memory bandwidth).

---

## 3. Isolated A/B Microarchitectural Findings

### A/B #1 — 32-Byte Trailing Writer Slop (`KILN_OPT_SLOP32`)

| Variant (`MODE=nolibc`, 44 B `Message` encode) | Mean (`ns`) | Mean (`cyc`) | Verdict |
| :--- | ---: | ---: | :--- |
| Safe overlapping GPR copy (`2 × mov DWORD` for `4..8 B`) | **`2.7 ns`** | **`7.7 cyc`** | **Keep as default.** Zero over-read, zero `vzeroupper`, zero padding contract. |
| `FLAG_SLOP32` (`vmovdqu ymm0` + `vzeroupper`) | `2.8 ns` | `7.8 cyc` | **Reject as default** (kept opt-in for experiments). `vzeroupper` erases any branch savings on 5 B strings. |

### A/B #2 — Inlined Overlapping 4..8 B SWAR UTF-8 + Fused Arena Copy (`codecs_bench.s` + `utf8.s`)

Replacing per-string `call kiln_core_dec_str` + byte-loop ASCII scan with an inlined zero-call overlapping 4 B SWAR (`0x80808080`) validate-and-store fast path (falling back to full AVX2 + RFC 3629 for `len > 8` or non-ASCII):

| Workload (`MODE=nolibc`) | Before Opt #2 | After Opt #2 | Speedup |
| :--- | ---: | ---: | ---: |
| `msg_decode_view_utf8` (44 B) | `9.3 ns` (`26.2 cyc`) | **`3.1 ns`** (`8.9 cyc`) | **3.00×** |
| `msg_decode_arena_utf8` (44 B) | `12.5 ns` (`35.1 cyc`) | **`3.5 ns`** (`9.9 cyc`) | **3.57×** |
| `msg_decode_arena_trusted` (44 B) | `4.9 ns` (`13.9 cyc`) | **`3.3 ns`** (`9.3 cyc`) | **1.48×** |
| `batch100_view_utf8` (4,404 B) | `890.2 ns` (`2,495 cyc`) | **`322.9 ns`** (`905 cyc`) | **2.76×** |
| `batch100_arena_utf8` (4,404 B) | `1,135.2 ns` (`3,182 cyc`) | **`348.7 ns`** (`978 cyc`) | **3.26×** |

**Key insight:** With fused validate+copy in registers, RFC 3629 UTF-8 checking on ASCII strings costs only **+0.2 ns (+0.6 cycles)** per message (`3.3 ns` trusted → `3.5 ns` UTF-8 checked) and **+3.7 ns** across 100 messages (`345.0 ns` → `348.7 ns`).

### A/B #3 — 2 MiB `KLNT` Bulk Payload Copy (`ERMS` vs `AVX2` vs `vmovntdq`)

| Copy Kernel (`2,097,344 B` `KLNT` encode) | `nolibc` Mean | `cabi` Mean | Effective Bandwidth |
| :--- | ---: | ---: | ---: |
| `rep movsb` (`ERMS`/`FSRM`, default) | `73.8 µs` | `74.4 µs` | `28.4 GB/s` |
| Unrolled 4×`vmovdqu` (`128 B/iter`, `KILN_OPT_COPY_AVX2`) | `72.8 µs` | `73.2 µs` | `28.8 GB/s` |
| Non-temporal `vmovntdq` + `sfence` (`KILN_OPT_COPY_NT`) | **`70.9 µs`** | **`69.7 µs`** | **`29.6–30.1 GB/s`** |
| `c_ref` (`glibc memcpy` IFUNC) | — | `68.4 µs` (`c_ref`) | `30.7 GB/s` |

**Key insight:** At 2 MiB, all kernels saturate Alder Lake's L3/DRAM copy bandwidth within ~2–7% of glibc's IFUNC `memcpy`. Non-temporal stores (`vmovntdq`) gain ~5% over `rep movsb` by avoiding cache read-for-ownership traffic. Meanwhile, full 12-step zero-copy `KLNT` validation (`klnt_2m_f64_decode_view`) takes only **`22.5 ns`** (~93 GB/s logical throughput).

### A/B #4 — Direct Measurement of FFI/C-ABI Overhead & Allocator Tax

- **System V C-ABI boundary tax (`nolibc` vs `cabi`):**
  - Single 44 B `Message`: **`+4.3 ns` to `+6.4 ns` (`+12` to `+18` cycles)** from saving/restoring `rbx, r12–r15` and unpacking `kiln_ctx_t` per call.
  - `Batch[100]` (4,404 B): **`~0%` overhead** (`348.7 ns` `nolibc` vs `345.9 ns` `cabi`) — once work is batched behind one entry point, C-ABI cost disappears.
- **Ownership / Allocator tax (44 B `Message`, UTF-8 checked):**
  - Zero-copy view (`nolibc`): **`3.1 ns`** (`cabi`: `9.5 ns`)
  - Bump arena owned (`nolibc`): **`3.5 ns`** (`+0.4 ns` over view!) (`cabi`: `8.5 ns`)
  - Heap `malloc`/`free` per string (`cabi`): **`25.2 ns`** (**~3× slower** than bump arena; `c_ref`: `20.8 ns` vs `9.6 ns` arena).

---

## 4. Reproduction

```bash
# Verify full conformance (golden 3/3 + 46/46 kiln-v2-cases.json + KLNT edge cases + nolibc self-test)
make MODE=cabi test
make MODE=nolibc test

# Run paired 3-trial pinned benchmarks on core 2 (nolibc vs cabi vs c_ref)
make bench

# Override core or trial count
BENCH_CORE=2 BENCH_RUNS=5 ./bench/run_bench.sh
```
