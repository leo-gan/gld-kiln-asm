# Quickstart & Examples

## Prerequisites

- Linux `x86_64` CPU with `AVX2` (all Intel Haswell+ / AMD Excavator+ processors)
- GNU Binutils (`as`, `ld`, `ar`, `readelf`), GNU `make`, and `gcc` (C11)
- `python3` (used by `bench/run_bench.sh` to aggregate median tables)

## Building Both Modes

A single `MODE` variable switches between the System V C-ABI static library and the zero-libc standalone ELF binary:

```bash
# Run the full local/CI gate (version check, cabi 46/46 tests, example, nolibc zero-libc check, c_ref build)
./scripts/run-tests.sh
```

Or invoke each mode directly:

```bash
# 1. C-callable static & shared libraries (lib/libkiln_asm.a, lib/libkiln_asm.so, include/kiln_asm.h)
make MODE=cabi
make MODE=cabi test

# 2. Standalone zero-libc static ELF (bin/kiln_bench_nolibc)
make MODE=nolibc
make MODE=nolibc test
```

`make MODE=nolibc test` automatically runs `readelf -d bin/kiln_bench_nolibc` to assert zero `NEEDED` dynamic libraries and executes `./bin/kiln_bench_nolibc --self-test` to verify byte-exact golden `Point` (`8 B`), `Message` (`37 B`), framed `Message` (`53 B`), and `10k f64 KLNT` (`80,192 B`) round-trips.

## Linking `libkiln_asm.a` from C

Build and run the bundled example (`examples/roundtrip.c`):

```bash
make MODE=cabi example
./bin/example_roundtrip
```

Or link directly from your own C11 translation unit:

```bash
gcc -std=c11 -O3 -march=native -Iinclude examples/roundtrip.c lib/libkiln_asm.a -o roundtrip
./roundtrip
```

Expected output:

```text
Point: x=9 y=-4 (8 B)
Message (framed): len=53 hash=0xd6646445f41ce803 s1=hi s2=z arena=3 B
KLNT v2: name=weights dtype=f32 shape=[2] values=[1.0, -2.0] block=264 B
```

## Generating Custom Schema Codecs (`gld-kilngen-asm`)

`codegen/gld-kilngen-asm` compiles any schema in the normative [Kiln v2 JSON Schema subset](https://leo-gan.github.io/gld-kiln/spec/#dynamic-values) (plus embedded `tensors` fields via `"format": "kiln-tensors"` or `"x-kiln": "tensors"`) into self-contained x86-64 GAS Assembly (`.s`) and C11 headers (`.h`) with compile-time `_Static_assert` layout verification, FNV-1a-64 schema hashes, framed wrappers, and batch codecs:

```bash
# Generate codecs for one or more schemas (+ linker version script for .so builds)
./codegen/gld-kilngen-asm --prefix bench --emit-map \
    --schema path/to/message.json \
    --schema path/to/request.json \
    --out build/gen

# Assemble and link into a single zero-libc shared library for cross-language FFI
as --64 -o build/gen/message.o build/gen/message.s
as --64 -o build/gen/request.o build/gen/request.s
ld -shared -Bsymbolic --version-script=build/gen/message.map \
    -z noexecstack -z relro -z now -soname libkiln_asm_bench.so \
    -o libkiln_asm_bench.so build/gen/message.o build/gen/request.o \
    --whole-archive lib/libkiln_asm.a --no-whole-archive
```

Run the bundled codegen verification suite (golden parity, all 13 scalars, `str`, `bytes`, `opt<T>`, `list<T>`, `dict<str,V>`, embedded `KLNT` v2 `tensors`, negative CLI checks, and Python `ctypes` FFI against the generated `.so`):

```bash
make MODE=cabi test-codegen
```

## Running Paired Benchmarks

Run the 3-trial pinned comparison across `MODE=nolibc`, `MODE=cabi`, and `c_ref` (`gcc -O3 -march=native`):

```bash
make bench
# Customize pinned core or trial count:
BENCH_CORE=2 BENCH_RUNS=5 ./bench/run_bench.sh
```

See [API & ABI Reference](api.md), [Implementation & Verification](internals.md), and [Experiments](../experiments.md) for detailed contracts and measured results.
