#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Integration tests against a fake "Batocera" (busybox + squashfs). Needs root, mksquashfs, static busybox.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PFX=$(dirname "$HERE")
T=${TMPDIR:-/tmp}/bdtest; rm -rf "$T"; mkdir -p "$T"/{rootfs,rufo,boot/boot,userdata,xdg,fakehost/lib,logs}
pass=0; fail=0
ok(){ echo "  PASS $1"; ((pass++)); }; ko(){ echo "  FAIL $1"; ((fail++)); }
t(){ if eval "$2"; then ok "$1"; else ko "$1"; fi; }

BB=$(command -v busybox) || { echo "busybox is missing"; exit 2; }
R=$T/rootfs
mkdir -p $R/{bin,sbin,usr/bin,usr/sbin,usr/lib/gbm,usr/share/batocera,etc/init.d,etc/profile.d,run,tmp,proc,sys,dev,boot,userdata,overlay,media,var/lib,usr/share/vulkan/icd.d}
cp "$BB" $R/bin/busybox
for a in sh ash ls cat mkdir ln sleep env rm cp mv kill echo date hostname install pgrep head tail grep sed touch id readlink basename timeout; do ln -sf /bin/busybox $R/bin/$a; done
ln -sf /bin/busybox $R/usr/bin/env
ln -sf /bin/busybox $R/sbin/reboot; ln -sf /bin/busybox $R/sbin/poweroff    # absolute symlinks
ln -s /run $R/var/run                                                        # TRAP: absolute symlink
ln -s /usr/lib $R/lib                                                        # TRAP: absolute symlink
echo "44-test" > $R/usr/share/batocera/batocera.version
cat > $R/etc/init.d/S04populate <<'X'
#!/bin/sh
mkdir -p /var/lib/bluetooth /var/log /var/tmp
( sleep 0.3; touch /run/ldconfig.bg ) &
X
cat > $R/usr/bin/ldconfig <<'X'
#!/bin/sh
echo "ldconfig ran; links: $(ls /usr/lib | tr '\n' ' ')" >> /var/log/ldconfig.test
X
cat > $R/etc/init.d/S12populateshare <<'X'
#!/bin/sh
mkdir -p /userdata/system/logs /userdata/roms; echo populated > /userdata/system/pop; : > /userdata/system/batocera.conf
X
cat > $R/etc/init.d/S50triggerhappy <<'X'
#!/bin/sh
echo "$1" >> /userdata/system/thd.log
X
sed "s/thd.log/other.log/" $R/etc/init.d/S50triggerhappy > $R/etc/init.d/S97joycond
cp $R/etc/init.d/S97joycond $R/etc/init.d/S99userservices
cat > $R/etc/init.d/S14labwc <<'X'
#!/bin/sh
mkdir -p /userdata/system/.config/labwc
X
cat > $R/etc/init.d/S31emulationstation <<'X'
#!/bin/sh
case "$1" in
 start) echo start >> /userdata/system/es.log; /usr/bin/labwc-launch </dev/null >/dev/null 2>&1 & ;;
 stop)  echo stop >> /userdata/system/es.log; killall_() { for p in /proc/[0-9]*; do :; done; }; kill $(cat /run/labwc.pid 2>/dev/null) $(cat /run/es.pid 2>/dev/null) 2>/dev/null ;;
esac
X
cat > $R/usr/bin/labwc-launch <<'X'
#!/bin/sh
echo STOCK-LAUNCH > /userdata/system/stock-launch-ran
X
cat > $R/usr/bin/labwc <<'X'
#!/bin/sh
env > /userdata/system/labwc.env
echo $$ > /run/labwc.pid
( exec -a emulationstation /bin/sleep 3000 ) &
echo $! > /run/es.pid
exec /bin/sleep 3000
X
chmod +x $R/etc/init.d/S* $R/usr/bin/labwc $R/usr/bin/labwc-launch $R/usr/bin/ldconfig
cp "$BB" $R/usr/bin/labwc-real; 
cat > $R/usr/bin/labwc <<'X'
#!/bin/sh
env > /userdata/system/labwc.env
cp /bin/busybox /tmp/emulationstation; /tmp/emulationstation sleep 3000 &
echo $! > /run/es.pid
exec /bin/busybox sleep 3000
X
# trick so that comm is "labwc": run a busybox copy with that name
cat > $R/usr/bin/labwc <<'X'
#!/bin/sh
env > /userdata/system/labwc.env
cp /bin/busybox /tmp/emulationstation; /tmp/emulationstation sleep 3000 &
cp /bin/busybox /tmp/labwc; exec /tmp/labwc sleep 3000
X
chmod +x $R/usr/bin/labwc
# stock batocera-resolution (kept as .real by the nested shim) and audio tools
cat > $R/usr/bin/batocera-resolution <<'X'
#!/bin/sh
echo STOCKRES
X
cat > $R/usr/bin/pactl <<'X'
#!/bin/sh
[ "$1" = info ] && { echo "Default Sink: fake_sink"; exit 0; }
exit 0
X
cat > $R/usr/bin/batocera-audio <<'X'
#!/bin/sh
case "$1" in
  get) printf 'fake_sink\tFake Sink\n' ;;
  get-profile) printf 'output:stereo@fake_card\tStereo\n' ;;
  getSystemVolume) echo 42 ;;
  getSystemMute) echo no ;;
esac
X
cat > $R/usr/bin/batocera-settings-set <<'X'
#!/bin/sh
echo "$1=$2" >> /userdata/system/batocera.conf
X
chmod +x $R/usr/bin/batocera-resolution $R/usr/bin/pactl $R/usr/bin/batocera-audio $R/usr/bin/batocera-settings-set
mkdir -p $R/etc/default
echo "# image default" > $R/etc/default/triggerhappy
mkdir -p $R/usr/share/rufo; echo rufo > $R/usr/share/rufo/marker
mksquashfs $R $T/boot/boot/batocera -quiet -noappend >/dev/null
mkdir -p $T/rufo/usr/share/rufo; echo rufo > $T/rufo/usr/share/rufo/marker
mksquashfs $T/rufo $T/boot/boot/rufomaculata -quiet -noappend >/dev/null
echo x86-64-v3 > $T/boot/boot/batocera.board

# fake "host": nvidia libs
H=$T/fakehost/lib; V=615.12.01
for l in libGLX_nvidia libEGL_nvidia libnvidia-glcore libnvidia-eglcore libnvidia-allocator libnvidia-glsi; do echo fake > $H/$l.so.$V; done
ln -s libGLX_nvidia.so.$V $H/libGLX_nvidia.so.0; ln -s libEGL_nvidia.so.$V $H/libEGL_nvidia.so.0
ln -s libnvidia-allocator.so.$V $H/libnvidia-allocator.so.1
echo $V > $T/fakehost/nvver
printf '        libGLX_nvidia.so.0 (libc6,x86-64) => %s/libGLX_nvidia.so.0\n' $H > $T/fakehost/ldconfig.out
cat > $T/fakehost/ldc <<X
#!/bin/sh
cat $T/fakehost/ldconfig.out
X
chmod +x $T/fakehost/ldc
mkdir -p $T/xdg/pulse; touch $T/xdg/wayland-0 $T/xdg/pulse/native $T/xdg/pipewire-0

cat > $T/bd.conf <<X
BD_BOOT_DIR=$T/boot
BD_USERDATA=$T/userdata
BD_RUN=/run/bdtest
BD_NVIDIA_VERSION_FILE=$T/fakehost/nvver
BD_LDCONFIG_P=$T/fakehost/ldc
BD_BT=off
BD_BIND_MEDIA=0
BD_BIND_MODULES=0
BD_START_TIMEOUT=20
X
# the suite must not depend on the machine's CPU: pretend to be an AVX2 machine, variant v3
mkdir -p $T/pci; printf 'model name\t: test cpu\nflags\t\t: fpu lm avx avx2 bmi1 bmi2 f16c fma abm movbe xsave\n' > $T/cpuinfo
export BD_CPUINFO=$T/cpuinfo BD_PCI_ROOT=$T/pci BD_UNAME_M=x86_64
export BD_MODE=nested BD_CONF=$T/bd.conf BD_TEST=1 BD_UID=1000 BD_WAYLAND=wayland-0 BD_XDG=$T/xdg
HOSTNAME_BEFORE=$(hostname)
mkdir -p /var/run.bdguard-check

start_session(){ "$PFX/libexec/bd-session" run >"$T/logs/run.log" 2>&1 & RUNPID=$!; }
alive(){ [ -r /proc/$1/stat ] && ! grep -q ') Z' /proc/$1/stat; }
waitfor(){ for _ in $(seq 100); do eval "$1" && return 0; sleep 0.2; done; return 1; }
inns(){ # run something inside the session namespace
  local pid; pid=$(pgrep -f '^bash .*/libexec/bd-session inner$' | tail -1); nsenter -t "$pid" -m -p -u -- "$@"; }

echo "== Test 1: startup, layers, environment, NVIDIA"
start_session
t "fake labwc started" "waitfor '[ -s $T/userdata/system/labwc.env ]'"
t "services started (userdata populated)" "[ -f $T/userdata/system/pop ]"
t "stock labwc-launch replaced (nested)" "[ ! -e $T/userdata/system/stock-launch-ran ]"
t "env: WLR_BACKENDS=wayland" "grep -q '^WLR_BACKENDS=wayland' $T/userdata/system/labwc.env"
t "env: WAYLAND_DISPLAY points to the host" "grep -q '^WAYLAND_DISPLAY=/run/host-xdg/wayland-0' $T/userdata/system/labwc.env"
t "env: PULSE_SERVER of the host" "grep -q '^PULSE_SERVER=unix:/run/host-xdg/pulse/native' $T/userdata/system/labwc.env"
t "env: EGL vendor is nvidia only" "grep -q '^__EGL_VENDOR_LIBRARY_FILENAMES=/run/bd-nvidia/10_nvidia.json' $T/userdata/system/labwc.env"
t "ldconfig ran after linking NVIDIA libs" "inns chroot /run/bdtest/root /bin/cat /var/log/ldconfig.test | grep -q libGLX_nvidia.so.0"
t "soname symlink libEGL_nvidia.so.0 resolves to the host lib" "inns chroot /run/bdtest/root /bin/sh -c 'cat /usr/lib/libEGL_nvidia.so.0' | grep -q fake"
t "gbm/nvidia-drm_gbm.so linked" "inns chroot /run/bdtest/root /bin/sh -c 'cat /usr/lib/gbm/nvidia-drm_gbm.so' | grep -q fake"
t "rufomaculata mounted as 2nd layer" "inns chroot /run/bdtest/root /bin/cat /usr/share/rufo/marker | grep -q rufo"
t "HOST hostname untouched" "[ \"\$(hostname)\" = \"$HOSTNAME_BEFORE\" ]"
t "pid ns: host processes not visible" "[ \$(inns /bin/sh -c 'ls /run/bdtest/root/proc | grep -c \"^[0-9]\"') -lt 40 ]"
t "/proc/sys is read-only inside" "! inns chroot /run/bdtest/root /bin/sh -c 'echo 1 > /proc/sys/kernel/core_pattern' 2>/dev/null"
t "TRAP abs symlink: host has no /run/bd-nvidia" "[ ! -e /run/bd-nvidia ]"
t "TRAP abs symlink: host /usr/lib unchanged" "[ ! -e /usr/lib/libEGL_nvidia.so.0 ] && [ ! -e /usr/lib/gbm/nvidia-drm_gbm.so ]"
t "session mounts NOT visible on the host" "! grep -q bdtest /proc/mounts"

t "nested: triggerhappy NOT started (the host desktop handles keys)" "[ ! -e $T/userdata/system/thd.log ]"
t "nested: batocera-resolution shim installed, original kept as .real" "inns chroot /run/bdtest/root /bin/sh -c 'grep -q bd-shim-resolution /usr/bin/batocera-resolution && /usr/bin/batocera-resolution.real' | grep -q STOCKRES"
t "volume keys added to /etc/default/triggerhappy (image content kept)" "inns chroot /run/bdtest/root /bin/cat /etc/default/triggerhappy | grep -q 'setSystemVolume +5' && inns chroot /run/bdtest/root /bin/cat /etc/default/triggerhappy | grep -q 'image default'"
t "audio inherited from host into batocera.conf (volume, device, profile)" "grep -q '^audio.volume=42' $T/userdata/system/batocera.conf && grep -q '^audio.device=fake_sink' $T/userdata/system/batocera.conf && grep -q '^audio.profile=output:stereo@fake_card' $T/userdata/system/batocera.conf"
t "env: BD_MODE=nested, BD_FULLSCREEN=0" "grep -q '^BD_MODE=nested' $T/userdata/system/labwc.env && grep -q '^BD_FULLSCREEN=0' $T/userdata/system/labwc.env"

echo "== Test 2: shutdown inside ES -> back to desktop, clean"
inns chroot /run/bdtest/root /sbin/poweroff
t "session ends" "waitfor '! alive $RUNPID'"
t "no orphaned session processes" "! pgrep -f 'busybox sleep 3000|/tmp/labwc' >/dev/null"
t "S31 stop was invoked" "grep -q stop $T/userdata/system/es.log"
t "no leftover mounts" "! grep -q bdtest /proc/mounts"
wait $RUNPID 2>/dev/null

echo "== Test 3: reboot restarts the session and applies a pending update"
cp $T/boot/boot/batocera $T/boot/boot/batocera.update
echo "stale-old" > $T/boot/old-kernel; echo "boot.stale" >/dev/null
printf 'old-kernel\n../../etc/passwd\n#c\n\n' > $T/boot/boot.stale
touch $T/boot/boot/overlay
rm -f $T/userdata/system/labwc.env
start_session
t "update applied: .update is gone" "waitfor '[ ! -e $T/boot/boot/batocera.update ]'"
t "overlay renamed to overlay.old" "[ -e $T/boot/boot/overlay.old ] && [ ! -e $T/boot/boot/overlay ]"
t "boot.stale: removed old-kernel and the list" "[ ! -e $T/boot/old-kernel ] && [ ! -e $T/boot/boot.stale ]"
t "unsafe stale path did NOT delete /etc/passwd" "[ -e /etc/passwd ]"
waitfor "[ -s $T/userdata/system/labwc.env ]"
inns chroot /run/bdtest/root /sbin/reboot
t "reboot: session restarts (labwc starts again)" "waitfor '[ -s $T/userdata/system/labwc.env ]'"
t "run process still alive after reboot" "alive $RUNPID"

echo "== Test 4: clean stop via SIGTERM (like systemctl stop)"
kill -TERM $RUNPID $(pgrep -f '^bash .*/libexec/bd-session inner$') 2>/dev/null
t "terminates" "waitfor '! alive $RUNPID'"
t "no leftover mounts" "! grep -q bdtest /proc/mounts"
t "no orphans" "! pgrep -f 'busybox sleep 3000|/tmp/labwc' >/dev/null"

echo "== Test 5: enter (maintenance) runs a command"
t "enter -- cat version" "'$PFX/libexec/bd-session' enter -- /bin/cat /usr/share/batocera/batocera.version | grep -q 44-test"


echo "== Test 6: drm mode (stock launcher, key daemon on, no nested shims)"
rm -f $T/userdata/system/stock-launch-ran $T/userdata/system/thd.log
BD_MODE=drm BD_TTY=/dev/tty63 start_session
t "drm: Batocera's own labwc-launch is used" "waitfor '[ -e $T/userdata/system/stock-launch-ran ]'"
t "drm: triggerhappy started (volume keys work on a bare console)" "grep -q start $T/userdata/system/thd.log"
t "drm: batocera-resolution not replaced" "! inns chroot /run/bdtest/root /bin/sh -c 'grep -q bd-shim-resolution /usr/bin/batocera-resolution'"
kill -TERM $RUNPID $(pgrep -f '^bash .*/libexec/bd-session inner$') 2>/dev/null
t "drm: session ends on SIGTERM" "waitfor '! alive $RUNPID'"
t "drm: no leftover mounts" "! grep -q bdtest /proc/mounts"

echo "== Test 7: launch validation and manual (foreground) start"
L() { SUDO_UID=${U:-1000} "$PFX/libexec/bd-session" launch "$@" >/dev/null 2>&1; }
mkdir -p /run/user/1000; rm -f /run/user/1000/wayland-0
python3 -c "import socket;s=socket.socket(socket.AF_UNIX);s.bind('/run/user/1000/wayland-0')"
t "rejects path-like wayland name" "! L --mode nested --wayland ../x --xdg /run/user/1000"
t "rejects someone else's runtime dir" "! L --mode nested --wayland wayland-0 --xdg /run/user/0"
t "rejects a non-console tty" "! L --mode drm --tty /dev/null --xdg /run/user/1000"
t "rejects bad keyboard layout" "! L --mode nested --wayland wayland-0 --xdg /run/user/1000 --xkb-layout 'a;b'"
t "rejects root as caller" "! U=0 L --mode nested --wayland wayland-0 --xdg /run/user/0"
t "rejects an unknown mode" "! L --mode auto --xdg /run/user/1000"
rm -f $T/userdata/system/labwc.env
# background jobs of a script ignore SIGINT; a terminal's foreground job does not: reset it like a terminal would
( unset BD_MODE BD_WAYLAND BD_XDG BD_UID; SUDO_UID=1000 python3 -c 'import signal,sys,os;signal.signal(signal.SIGINT,signal.SIG_DFL);os.execv(sys.argv[1],sys.argv[1:])' "$PFX/libexec/bd-session" launch --mode nested --wayland wayland-0 --xdg /run/user/1000 --fullscreen 1 >"$T/logs/run.log" 2>&1 & echo $! > $T/runpid )
RUNPID=$(cat $T/runpid)
t "launch starts the session in the foreground" "waitfor '[ -s $T/userdata/system/labwc.env ]'"
t "launch parameters reach labwc (display + fullscreen flag)" "grep -q '^WAYLAND_DISPLAY=/run/host-xdg/wayland-0' $T/userdata/system/labwc.env && grep -q '^BD_FULLSCREEN=1' $T/userdata/system/labwc.env"
t "a second session is refused (lock)" "! ( unset BD_WAYLAND; BD_MODE=nested BD_WAYLAND=wayland-0 '$PFX/libexec/bd-session' run >/dev/null 2>&1 )"
kill -INT $RUNPID $(pgrep -f '^bash .*/libexec/bd-session inner$') 2>/dev/null
t "Ctrl+C (SIGINT) ends it" "waitfor '! alive $RUNPID'"
t "no leftover mounts" "! grep -q bdtest /proc/mounts"
rm -f /run/user/1000/wayland-0; rmdir /run/user/1000 2>/dev/null

echo "== Test 8: service start (no BD_MODE): drm on the first free VT"
rm -f $T/userdata/system/stock-launch-ran $T/userdata/system/thd.log
( unset BD_MODE BD_TTY; "$PFX/libexec/bd-session" run >"$T/logs/run.log" 2>&1 & echo $! > $T/runpid )
RUNPID=$(cat $T/runpid)
t "service picks a free console and runs the stock launcher (drm)" "waitfor '[ -e $T/userdata/system/stock-launch-ran ]' && grep -q 'using the free console tty[0-9]' $T/logs/run.log"
t "service: triggerhappy on (volume keys on a bare console)" "grep -q start $T/userdata/system/thd.log"
kill -TERM $RUNPID $(pgrep -f '^bash .*/libexec/bd-session inner$') 2>/dev/null
t "service ends on SIGTERM (systemctl stop)" "waitfor '! alive $RUNPID'"
t "no leftover mounts" "! grep -q bdtest /proc/mounts"

echo "== Test 9: free VT selection"
mkdir -p $T/fakebin
cat > $T/fakebin/loginctl <<'X'
#!/bin/sh
case "$1" in
  list-sessions) echo "c1 1000 user seat0" ;;
  show-session) echo 3 ;;
esac
X
chmod +x $T/fakebin/loginctl
fv() { PATH=$T/fakebin:$PATH bash -c ". '$PFX/lib/bd-common.sh'; bd_free_vt $1"; }
if [ -c /dev/tty4 ]; then
  t "VT with a logind session is skipped (tty3 taken -> tty4)" "[ \"\$(fv 3)\" = 4 ]"
  t "VT held open by a process is skipped" "[ \"\$( (exec 3</dev/tty5; bash -c \". '$PFX/lib/bd-common.sh'; bd_free_vt 5\") )\" != 5 ]"
else echo "  SKIP no /dev/tty4 in this environment"; fi

rmdir /var/run.bdguard-check
echo; echo "Result: $pass OK, $fail FAILURES"; [ $fail -eq 0 ]
