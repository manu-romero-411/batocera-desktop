#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Eligibility matrix of the four variants against simulated CPUs / GPUs. No root needed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PFX=$(dirname "$HERE")
. "$PFX/lib/bd-variants.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0

V3F="fpu sse sse2 ssse3 sse4_2 lm avx avx2 bmi1 bmi2 f16c fma abm movbe xsave"
NOAVX="fpu sse sse2 ssse3 sse4_2 lm"
AVXONLY="fpu sse sse2 ssse3 sse4_2 lm avx f16c fma xsave"   # Piledriver-like: no AVX2/BMI2
B64="fpu sse sse2 lm"
B32="fpu sse sse2"

# mk NAME "model" "flags" "vendor:device[:driver] ..." [uname]   (all display controllers, PCI class 0300)
mk() {
    local n=$1 d=$T/$1 i=0 p pv pd pdrv
    mkdir -p "$d/pci"
    printf 'processor\t: 0\nmodel name\t: %s\nflags\t\t: %s\n' "$2" "$3" >"$d/cpuinfo"
    for p in $4; do
        mkdir -p "$d/pci/0000:00:0$i.0"
        IFS=: read -r pv pd pdrv <<<"$p"
        echo "0x$pv" >"$d/pci/0000:00:0$i.0/vendor"; echo 0x030000 >"$d/pci/0000:00:0$i.0/class"
        echo "0x$pd" >"$d/pci/0000:00:0$i.0/device"
        [[ -n ${pdrv:-} ]] && ln -s "/sys/bus/pci/drivers/$pdrv" "$d/pci/0000:00:0$i.0/driver"
        ((i++))
    done
    echo "${5:-x86_64}" >"$d/uname"
}
# expect NAME  v3 x86_64 5.26-amd64 5.26-i386   (each Y or N)
expect() {
    local n=$1; shift
    BD_CPUINFO=$T/$n/cpuinfo BD_PCI_ROOT=$T/$n/pci BD_UNAME_M=$(<"$T/$n/uname") bd_hw_probe
    local v got want i=1
    for v in "${BD_VARIANTS[@]}"; do
        want=${!i}; ((i++))
        if bd_variant_check "$v"; then got=Y; else got=N; fi
        if [[ $got == "$want" ]]; then ((pass++)); else ((fail++)); echo "  FAIL $n: $v expected $want got $got ($BD_WHY)"; fi
    done
    echo "  $n -> recommended $(bd_variant_recommend)"
}

mk haswell   "Intel(R) Core(TM) i5-4590 CPU @ 3.30GHz"        "$V3F"   "8086:0412:i915"
mk zen       "AMD Ryzen 5 3600 6-Core Processor"              "$V3F"   ""
mk celeron   "Intel(R) Celeron(R) G1840 CPU @ 2.80GHz"        "$NOAVX" "8086:0412:i915"
mk piledrv   "AMD FX(tm)-8350 Eight-Core Processor"           "$AVXONLY" ""
mk n450      "Intel(R) Atom(TM) CPU N450   @ 1.66GHz"         "$B64"   "8086:a011:i915"
mk n2800     "Intel(R) Atom(TM) CPU N2800   @ 1.86GHz"        "$B64"   "8086:0be1:gma500_gfx"
mk d525      "Intel(R) Atom(TM) CPU D525   @ 1.80GHz"         "$B64"   ""             # GPU hidden: CPU rule still catches it
mk n270      "Intel(R) Atom(TM) CPU N270   @ 1.60GHz"         "$B32"   "8086:27ae:i915" i686
mk pentiumm  "Intel(R) Pentium(R) M processor 1.70GHz"        "$B32"   "8086:2582:i915" i686
mk core2gma  "Intel(R) Core(TM)2 Duo CPU T7500 @ 2.20GHz"     "$B64"   "8086:2a02:i915"
mk baytrail  "Intel(R) Atom(TM) CPU Z3735F @ 1.33GHz"         "$NOAVX" "8086:0f31:i915"
mk n100      "Intel(R) N100"                                  "$V3F"   "8086:46d1:i915"
mk gma500drv "Intel(R) Atom(TM) CPU Z530 @ 1.60GHz"           "$B64"   "8086:ffff:gma500_gfx"
mk kern32    "Intel(R) Core(TM) i5-4590 CPU @ 3.30GHz"        "$V3F"   "8086:0412:i915" i686
mk hybrid    "Intel(R) Core(TM)2 Duo CPU P8600 @ 2.40GHz"     "$B64"   "8086:2a42:i915 10de:0a29:nvidia"

mk core2nv   "Intel(R) Core(TM)2 Quad CPU Q9550 @ 2.83GHz"    "$B64"   "8086:2e22:i915 10de:1c82:nvidia"
mk core2amd  "Intel(R) Core(TM)2 Duo CPU E8400 @ 3.00GHz"     "$B64"   "1002:6819:amdgpu"
mk core2gma2 "Intel(R) Core(TM)2 Duo CPU E8400 @ 3.00GHz"     "$B64"   "8086:2e22:i915 8086:2e23:i915"
mk ion2      "Intel(R) Atom(TM) CPU D525   @ 1.80GHz"         "$B64"   "8086:a011:i915 10de:0a64:nvidia"
mk weaknv    "Intel(R) Core(TM)2 Duo CPU E8400 @ 3.00GHz"     "$B64"   "8086:2e22:i915 10de:0421:nvidia"
mk nogpu     "Intel(R) Core(TM)2 Duo CPU E8400 @ 3.00GHz"     "$B64"   ""
#            v3 x86_64 526-amd64 526-i386
expect haswell   Y Y N N
expect zen       Y Y N N
expect celeron   N Y N N
expect piledrv   N Y N N
expect n450      N N Y N
expect n2800     N N Y N
expect d525      N N Y N
expect n270      N N N Y
expect pentiumm  N N N Y
expect core2gma  N N Y N
expect baytrail  N Y N N
expect n100      Y Y N N
expect gma500drv N N Y N
expect kern32    N N N N
expect hybrid    N Y N N     # GMA + GeForce: the capable GPU wins
expect core2nv   N Y N N
expect core2amd  N Y N N
expect core2gma2 N N Y N     # two GMA controllers, nothing else
expect ion2      N Y N N     # Atom D525 + NVIDIA ION2: capable GPU wins over the CPU name
BD_WEAK_GPU_IDS=" 10de:0421 " expect weaknv N N Y N   # user marked that GeForce as too weak
expect weaknv    N Y N N
expect nogpu     N Y N N     # no GPU visible, not an Atom -> x86_64

BD_WHY=""; bd_variant_check bogus && { echo "  FAIL bogus accepted"; ((fail++)); } || ((pass++))
echo "variant tests: $pass passed, $fail failed"
((fail == 0))
