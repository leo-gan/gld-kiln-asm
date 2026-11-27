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
# 1. C-callable static library (lib/libkiln_asm.a + include/kiln_asm.h)
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

## Running Paired Benchmarks

Run the 3-trial pinned comparison across `MODE=nolibc`, `MODE=cabi`, and `c_ref` (`gcc -O3 -march=native`):

```bash
make bench
# Customize pinned core or trial count:
BENCH_CORE=2 BENCH_RUNS=5 ./bench/run_bench.sh
```

See [API & ABI Reference](api.md), [Implementation & Verification](internals.md), and [Experiments](../experiments.md) for detailed contracts and measured results.
