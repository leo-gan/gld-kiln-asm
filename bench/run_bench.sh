#!/usr/bin/env bash
set -euo pipefail

CORE="${BENCH_CORE:-2}"
RUNS="${BENCH_RUNS:-3}"

echo "=== Building MODE=nolibc, MODE=cabi, and c_ref (-O3 -march=native) ==="
make --no-print-directory MODE=nolibc all check-nolibc
make --no-print-directory MODE=cabi all
make --no-print-directory c_ref

echo ""
echo "=== Machine & Toolchain ==="
CPU_MODEL="$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/, "", $2); print $2; exit}')"
GOV="$(cat /sys/devices/system/cpu/cpu${CORE}/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
GCC_VER="$(gcc --version | head -n 1)"
AS_VER="$(as --version | head -n 1)"
echo "CPU      : ${CPU_MODEL}"
echo "Core/Gov : taskset -c ${CORE} (governor: ${GOV})"
echo "Compiler : ${GCC_VER}"
echo "Assembler: ${AS_VER}"
echo "Trials   : ${RUNS} (reporting median ns and median cycles)"
echo ""

TMP_CSV="$(mktemp)"
trap 'rm -f "${TMP_CSV}"' EXIT

for r in $(seq 1 "${RUNS}"); do
    taskset -c "${CORE}" ./bin/kiln_bench_nolibc | tail -n +2 >> "${TMP_CSV}"
    taskset -c "${CORE}" ./bin/kiln_bench_cabi   | tail -n +2 >> "${TMP_CSV}"
    taskset -c "${CORE}" ./bin/kiln_bench_cref   | tail -n +2 >> "${TMP_CSV}"
done

python3 - "${TMP_CSV}" <<'PY'
import csv, statistics, sys
from collections import defaultdict

rows = defaultdict(lambda: {"ns": [], "cyc": [], "bytes": 0})
order = []
seen = set()

with open(sys.argv[1], newline="") as f:
    for mode, wl, b, ns, cyc, sink in csv.reader(f):
        if wl not in seen:
            seen.add(wl)
            order.append(wl)
        key = (wl, mode)
        rows[key]["bytes"] = int(b)
        rows[key]["ns"].append(float(ns))
        rows[key]["cyc"].append(float(cyc))

print(f"{'Workload':<28} {'Bytes':>9} | {'nolibc (ns / cyc)':>20} | {'cabi (ns / cyc)':>20} | {'c_ref (ns / cyc)':>20} | {'nolibc vs c_ref':>15}")
print("-" * 124)

for wl in order:
    b = 0
    vals = {}
    for m in ("nolibc", "cabi", "c_ref"):
        d = rows.get((wl, m))
        if d and d["ns"]:
            b = d["bytes"]
            vals[m] = (statistics.median(d["ns"]), statistics.median(d["cyc"]))
        else:
            vals[m] = None

    def fmt(v):
        if v is None:
            return "—"
        return f"{v[0]:7.1f} / {v[1]:8.1f}"

    delta = "—"
    if vals["nolibc"] and vals["c_ref"] and vals["c_ref"][0] > 0:
        ratio = vals["c_ref"][0] / vals["nolibc"][0]
        pct = (vals["nolibc"][0] - vals["c_ref"][0]) / vals["c_ref"][0] * 100.0
        delta = f"{ratio:5.2f}x ({pct:+5.1f}%)"

    print(f"{wl:<28} {b:>9} | {fmt(vals['nolibc']):>20} | {fmt(vals['cabi']):>20} | {fmt(vals['c_ref']):>20} | {delta:>15}")
PY
