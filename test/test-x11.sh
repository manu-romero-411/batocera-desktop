#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Variant guards + X11 plumbing, no squashfs needed. Needs root (loop mounts are NOT used here).
set -u
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SESS=$PFX/libexec/bd-session

# fixtures: a plain amd64 machine without GMA (-> x86_64 ok, v3 not), and an Atom N450
printf 'model name\t: Intel(R) Pentium(R) CPU G3220\nflags\t\t: fpu sse2 lm\n' >$T/cpu-plain
printf 'model name\t: Intel(R) Atom(TM) CPU N450   @ 1.66GHz\nflags\t\t: fpu sse2 lm\n' >$T/cpu-atom
mkdir -p $T/pci
mkconf() { # NAME VARIANT
    cat >$T/$1.conf <<X
BD_VARIANT=$2
BD_BOOT_DIR=$T/boot
BD_USERDATA=$T/userdata
BD_RUN=$T/run
X
}
env_for() { echo "BD_TEST=1 BD_CONF=$T/$1.conf BD_CPUINFO=$T/$2 BD_PCI_ROOT=$T/pci BD_UNAME_M=x86_64"; }

section "install guard"
mkconf a x86_64
mkdir -p $T/pkg/boot; echo junk >$T/pkg/boot/batocera; echo x86-64-v3 >$T/pkg/boot/batocera.board
tar -C $T/pkg -cJf $T/wrong.tar.xz boot
t "x86_64 refused on an Atom N450 (before touching anything)" \
  "! env $(env_for a cpu-atom) $SESS install --variant x86_64 --file $T/wrong.tar.xz 2>$T/err; grep -q 'cannot install variant' $T/err; [[ ! -e $T/boot ]]"
t "v3 refused on a CPU without AVX2" \
  "! env $(env_for a cpu-plain) $SESS install --variant v3 --file $T/wrong.tar.xz 2>$T/err; grep -q 'x86-64-v3 features' $T/err"
t "5.26-amd64 refused on a machine that can run x86_64" \
  "! env $(env_for a cpu-plain) $SESS install --variant 5.26-amd64 --file $T/wrong.tar.xz 2>$T/err; grep -q 'reserved for machines with only Intel GMA' $T/err"
t "image with the wrong board is removed and the install cancelled" \
  "! env $(env_for a cpu-plain) $SESS install --variant x86_64 --file $T/wrong.tar.xz 2>$T/err; grep -q \"board is 'x86-64-v3'\" $T/err; [[ ! -e $T/boot/boot ]]"
echo x86_64 >$T/pkg/boot/batocera.board; tar -C $T/pkg -cJf $T/right.tar.xz boot
t "image with the right board installs and records the variant" \
  "env $(env_for a cpu-plain) $SESS install --variant x86_64 --file $T/right.tar.xz 2>$T/err; [[ \$(cat $T/boot/.bd-variant) == x86_64 ]]"

section "start guards"
t "run refuses a variant that does not fit the hardware" \
  "! env $(env_for a cpu-atom) $SESS run 2>$T/err; grep -q 'cannot run on this machine' $T/err"
mkconf b v3; 
t "run refuses v3 on a CPU without AVX2 even if the config says so" \
  "! env $(env_for b cpu-plain) $SESS run 2>$T/err; grep -q 'cannot run on this machine' $T/err"
printf 'model name\t: x\nflags\t\t: fpu lm avx avx2 bmi1 bmi2 f16c fma abm movbe xsave\n' >$T/cpu-v3
t "run refuses BD_VARIANT=v3 over an x86_64 image" \
  "! env $(env_for b cpu-v3) $SESS run 2>$T/err; grep -q 'installed as .x86_64. but BD_VARIANT is .v3.' $T/err"
t "launch refuses nested mode for an X11 variant" \
  "! env $(env_for a cpu-plain) SUDO_UID=1000 $SESS launch --mode nested --xdg /run/user/1000 --wayland wayland-0 2>$T/err; grep -q 'X11-only' $T/err"
mkconf c bogus
t "unknown BD_VARIANT in the config is an error" \
  "! env $(env_for c cpu-plain) $SESS doctor 2>$T/err; grep -q 'unknown BD_VARIANT' $T/err"

section "Xorg shim"
mkdir -p $T/root/usr/bin
printf '#!/bin/sh\necho "REAL:$*"\n' >$T/root/usr/bin/Xorg; chmod +x $T/root/usr/bin/Xorg
(
  BD_PREFIX=$PFX; . "$PFX/lib/bd-common.sh"
  BD_ROOT=$T/root; BD_TTY=/dev/tty9; BD_AUDIO=none; mkdir -p $T/root/run
  bd_inject_xorg
  bd_inject_xorg                      # twice: the original must not be lost (saved overlay case)
) 2>/dev/null
t "Xorg is wrapped and the original kept as Xorg.real" "grep -q bd-shim-xorg $T/root/usr/bin/Xorg && grep -q REAL: $T/root/usr/bin/Xorg.real"
t "VT number written for the shim" "[[ \$(cat $T/root/run/bd-vt) == 9 ]]"
export BD_XORG_REAL=$T/root/usr/bin/Xorg.real BD_VTFILE=$T/root/run/bd-vt BD_DISPLAY_LOG=$T/disp.log BD_FORCE_LOGFILE=$T/Xorg.log
t "shim replaces a hard-coded display and vt1 with :1 and our VT" "[[ \$(sh $T/root/usr/bin/Xorg :0 -nolisten tcp vt1 -nocursor) == 'REAL:-nolisten tcp -nocursor :1 -logfile $T/Xorg.log vt9' ]]"
t "shim appends display, log file and our VT when none were given" "[[ \$(sh $T/root/usr/bin/Xorg :1) == 'REAL::1 -logfile $T/Xorg.log vt9' ]]"
t "shim logs what it executes with a level tag" "grep -q '^\[INFO\] bd-xorg: exec ' $T/disp.log"


section "X11 GPU setup (NVIDIA / AMD / Intel)"
G=$T/gpu; mkdir -p $G/pci/0000:00:02.0 $G/pci/0000:0a:00.0 $G/pci/0000:03:00.0 $G/xdir
mk_pci() { echo "0x$2" >$G/pci/$1/vendor; echo 0x030000 >$G/pci/$1/class; echo 0x0001 >$G/pci/$1/device; ln -sfn /sys/bus/pci/drivers/$3 $G/pci/$1/driver; }
mk_pci 0000:00:02.0 8086 i915; mk_pci 0000:0a:00.0 10de nvidia; mk_pci 0000:03:00.0 1002 amdgpu
echo fake >$G/xdir/nvidia_drv.so; echo fake >$G/xdir/libglxserver_nvidia.so.615.12.01; ln -s libglxserver_nvidia.so.615.12.01 $G/xdir/libglxserver_nvidia.so
(
  BD_PREFIX=$PFX; . "$PFX/lib/bd-common.sh"; BD_PCI_ROOT=$G/pci; BD_X11_DRIVER=modesetting; BD_X11_BUSID=
  [[ $(bd_pci_busid /sys/bus/pci/devices/0000:0a:00.0) == PCI:10:0:0 ]] && echo busid-hex-to-decimal
  [[ $(bd_nvidia_busid) == PCI:10:0:0 ]] && echo nvidia-busid-found
  NV_VER=615.12.01 BD_NVIDIA_XDIRS="$G/nowhere $G/xdir" bd_nvidia_xcollect && [[ $NV_XDRV == $G/xdir/nvidia_drv.so && $NV_XGLX == $G/xdir/libglxserver_nvidia.so.615.12.01 ]] && echo xmodules-found
  NV_VER=999.1 BD_NVIDIA_XDIRS="$G/xdir" bd_nvidia_xcollect || echo xmodules-version-mismatch-refused
  BD_GPU_MODE=nvidia bd_x11_gpu_conf $G/nv.conf /usr/lib/xorg/modules
  BD_GPU_MODE=mesa   bd_x11_gpu_conf $G/auto.conf; [[ ! -e $G/auto.conf ]] && echo mesa-autodetect-no-conf
  BD_GPU_MODE=mesa BD_X11_BUSID=PCI:3:0:0 BD_X11_DRIVER=amdgpu bd_x11_gpu_conf $G/amd.conf
  BD_GPU_MODE=mesa BD_X11_BUSID='x";rm' bd_x11_gpu_conf $G/bad.conf 2>/dev/null; [[ ! -e $G/bad.conf || ! $(grep -c rm $G/bad.conf) -gt 0 ]] && echo bad-busid-not-written
) >$G/out 2>&1
for k in busid-hex-to-decimal nvidia-busid-found xmodules-found xmodules-version-mismatch-refused mesa-autodetect-no-conf bad-busid-not-written; do
  t "$k" "grep -qx $k $G/out"; done
t "NVIDIA conf: nvidia driver pinned to its BusID, host module path first, image path kept" \
  "grep -q 'Driver \"nvidia\"' $G/nv.conf && grep -q 'BusID \"PCI:10:0:0\"' $G/nv.conf && [[ \$(grep -n ModulePath $G/nv.conf | head -1) == *bd-nvidia/xorg* ]] && grep -q 'ModulePath \"/usr/lib/xorg/modules\"' $G/nv.conf"
t "AMD pinned: amdgpu driver on its BusID, no NVIDIA module path" \
  "grep -q 'Driver \"amdgpu\"' $G/amd.conf && grep -q 'BusID \"PCI:3:0:0\"' $G/amd.conf && ! grep -q nvidia $G/amd.conf"

summary "x11 tests"
