# shellcheck shell=bash disable=SC2034
# SPDX-License-Identifier: GPL-3.0-or-later
# bd-variants.sh - Batocera build variants: hardware probing, eligibility rules, per-variant profile.
# Sourced by bd-common.sh and install.sh. Pure bash, reads only /proc and /sys (no root needed).
#
#   v3          current, x86-64-v3 build   Wayland/labwc   CPUs with the full x86-64-v3 feature set (AVX2...)
#   x86_64      current, standard build    X11             any amd64 with at least one capable GPU (not Intel GMA)
#   5.26-amd64  Batocera 5.26 amd64        X11             amd64 whose ONLY graphics are Intel GMA (Atom netbook, old laptops)
#   5.26-i386   Batocera 5.26 i386         X11             CPUs that cannot run 64-bit code
#
# GPU rule: ALL display controllers are considered, not just the first. One capable GPU (NVIDIA, AMD,
# non-GMA Intel, anything that is not GMA) is enough for the current build: a Core 2 with an old GMA
# chipset plus a GeForce/Radeon runs x86_64. 5.26-amd64 is exactly the complement of that rule, so a
# machine that can run the current standard build can never get a 5.26 one.
# With no display controller visible at all (some VMs, broken sysfs) the Atom-netbook CPU name decides.

BD_VARIANTS=(v3 x86_64 5.26-amd64 5.26-i386)

# Intel GMA / legacy PowerVR-based PCI device IDs (vendor 8086). Written from memory of pci.ids:
# check yours with `batocera-desktop detect` and `lspci -nn`, and extend this list if needed.
#   945/965/G33/G35/Q35 GMA 950/3000/3100, GM965 X3100, GM45/G45/G41/B43 GMA 4500 (X4500),
#   Pineview GMA 3150 (N4xx/N5xx/D4xx/D5xx), Cedarview GMA 3600/3650 (N2xxx/D2xxx),
#   Poulsbo GMA 500, Oaktrail GMA 600.
BD_GMA_IDS=" 2582 258a 2592 2772 2776 27a2 27a6 27ae 2792 2972 2973 2982 2983 2992 2993 29a2 29a3 29b2 29b3 29c2 29c3 29d2 29d3 2a02 2a03 2a12 2a13 2a42 2a43 2e02 2e03 2e12 2e13 2e22 2e23 2e32 2e33 2e42 2e43 2e92 2e93 a001 a002 a011 a012 0be0 0be1 0be2 0be3 8108 8109 4100 4101 4102 4103 4104 4105 4106 4107 4108 "

# GPUs you do not consider capable enough (as "vendor:device", e.g. " 10de:0421 "): ignored by the rule above.
BD_WEAK_GPU_IDS=${BD_WEAK_GPU_IDS:-" "}

# Atom "netbook" CPUs of the old naming scheme: N4xx/N5xx/D4xx/D5xx (Pineview), N2xxx/D2xxx (Cedarview).
# Bay Trail "Atom Z3735F" etc. are deliberately NOT matched: modern x86_64 with HD graphics.
BD_ATOM_RE='Atom.*CPU[[:space:]]+(N4[0-9]{2}|N5[0-9]{2}|D4[0-9]{2}|D5[0-9]{2}|[ND]2[0-9]{3})([^0-9]|$)'

bd_variant_label() {
    case $1 in
        v3)         echo "Batocera current x86-64-v3  (Wayland/labwc; CPU with AVX2 & co)" ;;
        x86_64)     echo "Batocera current x86_64     (X11; any amd64 with a capable GPU: NVIDIA, AMD, Intel non-GMA)" ;;
        5.26-amd64) echo "Batocera 5.26 amd64         (X11; amd64 whose only graphics are Intel GMA)" ;;
        5.26-i386)  echo "Batocera 5.26 i386          (X11; 32-bit-only CPUs)" ;;
        *) return 1 ;;
    esac
}

# bd_profile VARIANT -> sets the P_* variables (returns 1 for an unknown variant)
bd_profile() {
    P_VARIANT=$1
    P_URLPATH=""; P_NESTED=0; P_LEGACY=0; P_ARCH=64; P_SERVICES=""
    case $1 in
        v3)         P_BOARDS="x86-64-v3"; P_URLPATH=x86-64-v3; P_DISPLAY=wayland; P_COMP=labwc; P_NESTED=1 ;;
        x86_64)     P_BOARDS="x86_64";    P_URLPATH=x86_64;    P_DISPLAY=x11;     P_COMP=Xorg ;;
        5.26-amd64) P_BOARDS="x86_64 x64"; P_DISPLAY=x11; P_COMP=Xorg; P_LEGACY=1 ;;
        5.26-i386)  P_BOARDS="x86 i386";   P_DISPLAY=x11; P_COMP=Xorg; P_LEGACY=1; P_ARCH=32 ;;
        *) return 1 ;;
    esac
    P_BOARD=${P_BOARDS%% *}
    # hotkeygen only exists in recent images; services that do not exist are skipped with a warning
    if ((P_LEGACY)); then
        P_SERVICES="S12populateshare S50triggerhappy S97joycond S31emulationstation S99userservices"
    else
        P_SERVICES="S12populateshare S50triggerhappy S97joycond S31emulationstation S90hotkeygen S99userservices"
    fi
    # /usr/share/batocera/batocera.version inside the image must look like this
    if ((P_LEGACY)); then P_VERSION_RE='^5\.26'; else P_VERSION_RE='^([6-9]|[1-9][0-9])'; fi
    return 0
}

# ------------------------------------------------------------------- hardware probe
# Test hooks: BD_CPUINFO, BD_PCI_ROOT, BD_UNAME_M (never needed in normal use).
bd_hw_probe() {
    local cpuinfo=${BD_CPUINFO:-/proc/cpuinfo} flags f d v id cls drv
    local -a missing=()
    HW_MACHINE=${BD_UNAME_M:-$(uname -m)}
    flags=$(sed -n 's/^flags[[:space:]]*:[[:space:]]*//p' "$cpuinfo" 2>/dev/null | head -n1)
    HW_CPU_MODEL=$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' "$cpuinfo" 2>/dev/null | head -n1)
    flags=" $flags "
    HW_LM=0; [[ $flags == *" lm "* ]] && HW_LM=1
    # x86-64-v3 = AVX AVX2 BMI1 BMI2 F16C FMA LZCNT(abm) MOVBE XSAVE. Checking the flags and not the
    # year matters: Pentium/Celeron up to Comet Lake and AMD before Excavator have no AVX2.
    for f in avx avx2 bmi1 bmi2 f16c fma abm movbe xsave; do
        [[ $flags == *" $f "* ]] || missing+=("$f")
    done
    HW_V3_MISSING="${missing[*]:-}"
    HW_V3=0; ((HW_LM && ${#missing[@]} == 0)) && HW_V3=1
    HW_ATOM=0; [[ $HW_CPU_MODEL =~ $BD_ATOM_RE ]] && HW_ATOM=1
    # every display controller (PCI class 03xx: VGA, 3D, other display)
    HW_GMA=0; HW_GMA_DEVS=""; HW_GPUS=""; HW_GPU_COUNT=0; HW_CAPABLE_GPUS=0
    HW_NVIDIA=0; HW_AMD=0; HW_INTEL_OK=0
    for d in "${BD_PCI_ROOT:-/sys/bus/pci/devices}"/*; do
        [[ -r $d/vendor && -r $d/class && -r $d/device ]] || continue
        v=$(<"$d/vendor"); cls=$(<"$d/class"); id=$(<"$d/device")
        [[ $cls == 0x03* ]] || continue
        v=${v#0x}; id=${id#0x}; drv=""
        [[ -L $d/driver ]] && drv=$(basename "$(readlink "$d/driver")")
        ((HW_GPU_COUNT++))
        if [[ $v == 8086 && ( $BD_GMA_IDS == *" $id "* || $drv == gma500_gfx ) ]]; then
            HW_GMA=1; HW_GMA_DEVS+="$v:$id "; HW_GPUS+="$v:$id(GMA) "
        elif [[ $BD_WEAK_GPU_IDS == *" $v:$id "* ]]; then
            HW_GPUS+="$v:$id(weak) "
        else
            ((HW_CAPABLE_GPUS++)); HW_GPUS+="$v:$id "
            case $v in 10de) HW_NVIDIA=1 ;; 1002) HW_AMD=1 ;; 8086) HW_INTEL_OK=1 ;; esac
        fi
    done
    if ((HW_GPU_COUNT > 0)); then HW_LEGACY_GFX=$((HW_CAPABLE_GPUS == 0))
    else HW_LEGACY_GFX=$HW_ATOM; fi
}

# bd_variant_check VARIANT -> 0 if this machine may install/run it; else 1 with BD_WHY set
bd_variant_check() {
    BD_WHY=""
    bd_profile "$1" || { BD_WHY="unknown variant '$1' (valid: ${BD_VARIANTS[*]})"; return 1; }
    local gfx=""
    if ((HW_GPU_COUNT > 0)); then gfx="only legacy graphics (${HW_GPUS% }) and no other capable GPU"
    else gfx="no GPU visible and an Atom netbook CPU ($HW_CPU_MODEL)"; fi
    if ((P_ARCH == 64)); then
        ((HW_LM)) || { BD_WHY="this CPU is 32-bit only"; return 1; }
        [[ $HW_MACHINE == x86_64 ]] || { BD_WHY="the running kernel is '$HW_MACHINE', a 64-bit kernel (x86_64) is needed for amd64 builds"; return 1; }
    fi
    case $1 in
        v3)
            ((HW_V3)) || { BD_WHY="the CPU lacks x86-64-v3 features (missing: ${HW_V3_MISSING:-?})"; return 1; } ;;
        x86_64)
            ((HW_LEGACY_GFX)) && { BD_WHY="this machine has $gfx"; return 1; } ;;
        5.26-amd64)
            ((HW_LEGACY_GFX)) || { BD_WHY="reserved for machines with only Intel GMA graphics; this one has a capable GPU (${HW_GPUS% }) and can run the current x86_64 build"; return 1; } ;;
        5.26-i386)
            ((HW_LM)) && { BD_WHY="this CPU is 64-bit capable (5.26-i386 is only for 32-bit-only CPUs)"; return 1; } ;;
    esac
    return 0
}

# the variant we would suggest on this machine
bd_variant_recommend() {
    if ((HW_LM)); then
        [[ $HW_MACHINE == x86_64 ]] || { echo "none (64-bit CPU but a 32-bit kernel: install a 64-bit host OS)"; return; }
        if ((HW_V3)); then echo v3
        elif ((HW_LEGACY_GFX)); then echo 5.26-amd64
        else echo x86_64; fi
    else echo 5.26-i386; fi
}

# human readable report
bd_hw_report() {
    local v
    echo "CPU:        ${HW_CPU_MODEL:-?}   (64-bit capable: $( ((HW_LM)) && echo yes || echo no ), kernel: $HW_MACHINE)"
    echo "x86-64-v3:  $( ((HW_V3)) && echo yes || echo "no (missing: ${HW_V3_MISSING:-n/a})" )"
    echo "GPUs:       ${HW_GPUS:-none visible}  (vendor:device; 10de=NVIDIA 1002=AMD 8086=Intel)"
    echo "Capable GPUs: $HW_CAPABLE_GPUS of $HW_GPU_COUNT;  Atom netbook CPU: $( ((HW_ATOM)) && echo yes || echo no )"
    echo "Variants:"
    for v in "${BD_VARIANTS[@]}"; do
        if bd_variant_check "$v"; then printf '  [ OK ] %-11s %s\n' "$v" "$(bd_variant_label "$v")"
        else printf '  [ NO ] %-11s %s\n         -> %s\n' "$v" "$(bd_variant_label "$v")" "$BD_WHY"; fi
    done
    echo "Recommended: $(bd_variant_recommend)"
}
