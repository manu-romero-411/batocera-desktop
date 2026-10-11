#!/usr/bin/env bash
# Pruebas de integración con un "Batocera" falso (busybox + squashfs). Requiere root, mksquashfs, busybox estático.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PFX=$(dirname "$HERE")
T=${TMPDIR:-/tmp}/bdtest; rm -rf "$T"; mkdir -p "$T"/{rootfs,rufo,boot/boot,userdata,xdg,fakehost/lib,logs}
pass=0; fail=0
ok(){ echo "  PASS $1"; ((pass++)); }; ko(){ echo "  FAIL $1"; ((fail++)); }
t(){ if eval "$2"; then ok "$1"; else ko "$1"; fi; }

BB=$(command -v busybox) || { echo "falta busybox"; exit 2; }
R=$T/rootfs
mkdir -p $R/{bin,sbin,usr/bin,usr/sbin,usr/lib/gbm,usr/share/batocera,etc/init.d,etc/profile.d,run,tmp,proc,sys,dev,boot,userdata,overlay,media,var/lib,usr/share/vulkan/icd.d}
cp "$BB" $R/bin/busybox
for a in sh ash ls cat mkdir ln sleep env rm cp mv kill echo date hostname install pgrep head tail grep sed touch id readlink basename timeout; do ln -sf /bin/busybox $R/bin/$a; done
ln -sf /bin/busybox $R/usr/bin/env
ln -sf /bin/busybox $R/sbin/reboot; ln -sf /bin/busybox $R/sbin/poweroff    # abs. symlinks
ln -s /run $R/var/run                                                        # TRAMPA: absoluto
ln -s /usr/lib $R/lib                                                        # TRAMPA: absoluto
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
mkdir -p /userdata/system/logs /userdata/roms; echo populated > /userdata/system/pop
X
cat > $R/etc/init.d/S50triggerhappy <<'X'
#!/bin/sh
echo "$1" >> /userdata/system/thd.log
X
cp $R/etc/init.d/S50triggerhappy $R/etc/init.d/S97joycond
cp $R/etc/init.d/S50triggerhappy $R/etc/init.d/S99userservices
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
# labwc falso: guarda su entorno y lanza "emulationstation" falso
cat > $R/usr/bin/labwc <<'X'
#!/bin/sh
env > /userdata/system/labwc.env
echo $$ > /run/labwc.pid
( exec -a emulationstation /bin/sleep 3000 ) &
echo $! > /run/es.pid
exec /bin/sleep 3000
X
chmod +x $R/etc/init.d/S* $R/usr/bin/labwc $R/usr/bin/labwc-launch $R/usr/bin/ldconfig
# comm de labwc debe ser "labwc" y el de ES "emulationstatio": exec -a no cambia comm; usamos copias de busybox con ese nombre
cp "$BB" $R/usr/bin/labwc-real; 
cat > $R/usr/bin/labwc <<'X'
#!/bin/sh
env > /userdata/system/labwc.env
cp /bin/busybox /tmp/emulationstation; /tmp/emulationstation sleep 3000 &
echo $! > /run/es.pid
exec /bin/busybox sleep 3000
X
# truco para que comm sea "labwc": ejecutar busybox copiado con ese nombre
cat > $R/usr/bin/labwc <<'X'
#!/bin/sh
env > /userdata/system/labwc.env
cp /bin/busybox /tmp/emulationstation; /tmp/emulationstation sleep 3000 &
cp /bin/busybox /tmp/labwc; exec /tmp/labwc sleep 3000
X
chmod +x $R/usr/bin/labwc
mkdir -p $R/usr/share/rufo; echo rufo > $R/usr/share/rufo/marker
mksquashfs $R $T/boot/boot/batocera -quiet -noappend >/dev/null
mkdir -p $T/rufo/usr/share/rufo; echo rufo > $T/rufo/usr/share/rufo/marker
mksquashfs $T/rufo $T/boot/boot/rufomaculata -quiet -noappend >/dev/null
echo x86-64-v3 > $T/boot/boot/batocera.board

# "host" falso: libs nvidia
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
export BD_CONF=$T/bd.conf BD_TEST=1 BD_UID=1000 BD_WAYLAND=wayland-0 BD_XDG=$T/xdg
HOSTNAME_BEFORE=$(hostname)
mkdir -p /var/run.bdguard-check

start_session(){ "$PFX/libexec/bd-session" run >"$T/logs/run.log" 2>&1 & RUNPID=$!; }
alive(){ [ -r /proc/$1/stat ] && ! grep -q ') Z' /proc/$1/stat; }
waitfor(){ for _ in $(seq 100); do eval "$1" && return 0; sleep 0.2; done; return 1; }
inns(){ # ejecutar algo dentro del namespace de la sesión
  local pid; pid=$(pgrep -f '^bash .*/libexec/bd-session inner$' | tail -1); nsenter -t "$pid" -m -p -u -- "$@"; }

echo "== Test 1: arranque, capas, entorno, NVIDIA"
start_session
t "labwc (falso) arrancó" "waitfor '[ -s $T/userdata/system/labwc.env ]'"
t "servicios arrancados (userdata poblado)" "[ -f $T/userdata/system/pop ]"
t "labwc-launch ORIGINAL sustituido (nested)" "[ ! -e $T/userdata/system/stock-launch-ran ]"
t "env: WLR_BACKENDS=wayland" "grep -q '^WLR_BACKENDS=wayland' $T/userdata/system/labwc.env"
t "env: WAYLAND_DISPLAY apunta al host" "grep -q '^WAYLAND_DISPLAY=/run/host-xdg/wayland-0' $T/userdata/system/labwc.env"
t "env: PULSE_SERVER del host" "grep -q '^PULSE_SERVER=unix:/run/host-xdg/pulse/native' $T/userdata/system/labwc.env"
t "env: vendor EGL solo nvidia" "grep -q '^__EGL_VENDOR_LIBRARY_FILENAMES=/run/bd-nvidia/10_nvidia.json' $T/userdata/system/labwc.env"
t "ldconfig corrió tras enlazar libs NVIDIA" "inns chroot /run/bdtest/root /bin/cat /var/log/ldconfig.test | grep -q libGLX_nvidia.so.0"
t "symlink soname libEGL_nvidia.so.0 resuelve a la lib del host" "inns chroot /run/bdtest/root /bin/sh -c 'cat /usr/lib/libEGL_nvidia.so.0' | grep -q fake"
t "gbm/nvidia-drm_gbm.so enlazado" "inns chroot /run/bdtest/root /bin/sh -c 'cat /usr/lib/gbm/nvidia-drm_gbm.so' | grep -q fake"
t "rufomaculata montado como 2ª capa" "inns chroot /run/bdtest/root /bin/cat /usr/share/rufo/marker | grep -q rufo"
t "hostname del HOST intacto" "[ \"\$(hostname)\" = \"$HOSTNAME_BEFORE\" ]"
t "pid ns: ES/labwc no visibles ni mezclados" "[ \$(inns /bin/sh -c 'ls /run/bdtest/root/proc | grep -c \"^[0-9]\"') -lt 40 ]"
t "/proc/sys es de solo lectura dentro" "! inns chroot /run/bdtest/root /bin/sh -c 'echo 1 > /proc/sys/kernel/core_pattern' 2>/dev/null"
t "TRAMPA symlink abs: host sin /run/bd-nvidia" "[ ! -e /run/bd-nvidia ]"
t "TRAMPA symlink abs: host sin cambios en /usr/lib" "[ ! -e /usr/lib/libEGL_nvidia.so.0 ] && [ ! -e /usr/lib/gbm/nvidia-drm_gbm.so ]"
t "mounts de la sesión NO visibles en el host" "! grep -q bdtest /proc/mounts"

echo "== Test 2: shutdown dentro de ES -> vuelve al escritorio y limpia"
inns chroot /run/bdtest/root /sbin/poweroff
t "la sesión termina" "waitfor '! alive $RUNPID'"
t "sin procesos huérfanos de la sesión" "! pgrep -f 'busybox sleep 3000|/tmp/labwc' >/dev/null"
t "S31 stop fue invocado" "grep -q stop $T/userdata/system/es.log"
t "sin mounts residuales" "! grep -q bdtest /proc/mounts"
wait $RUNPID 2>/dev/null

echo "== Test 3: reboot reinicia la sesión y aplica actualización pendiente"
cp $T/boot/boot/batocera $T/boot/boot/batocera.update
echo "stale-old" > $T/boot/old-kernel; echo "boot.stale" >/dev/null
printf 'old-kernel\n../../etc/passwd\n#c\n\n' > $T/boot/boot.stale
touch $T/boot/boot/overlay
rm -f $T/userdata/system/labwc.env
start_session
t "update aplicado: .update desapareció" "waitfor '[ ! -e $T/boot/boot/batocera.update ]'"
t "overlay renombrado a overlay.old" "[ -e $T/boot/boot/overlay.old ] && [ ! -e $T/boot/boot/overlay ]"
t "boot.stale: borró old-kernel y se eliminó la lista" "[ ! -e $T/boot/old-kernel ] && [ ! -e $T/boot/boot.stale ]"
t "ruta stale insegura NO borró /etc/passwd" "[ -e /etc/passwd ]"
waitfor "[ -s $T/userdata/system/labwc.env ]"
inns chroot /run/bdtest/root /sbin/reboot
t "reboot: la sesión se reinicia (labwc vuelve a arrancar)" "waitfor '[ -s $T/userdata/system/labwc.env ]'"
t "el proceso run sigue vivo tras el reboot" "alive $RUNPID"

echo "== Test 4: parada limpia vía SIGTERM (como systemctl stop)"
kill -TERM $RUNPID $(pgrep -f '^bash .*/libexec/bd-session inner$') 2>/dev/null
t "termina" "waitfor '! alive $RUNPID'"
t "sin mounts residuales" "! grep -q bdtest /proc/mounts"
t "sin huérfanos" "! pgrep -f 'busybox sleep 3000|/tmp/labwc' >/dev/null"

echo "== Test 5: enter (mantenimiento) ejecuta comando"
t "enter -- cat version" "'$PFX/libexec/bd-session' enter -- /bin/cat /usr/share/batocera/batocera.version | grep -q 44-test"

rmdir /var/run.bdguard-check
echo; echo "Resultado: $pass OK, $fail FALLOS"; [ $fail -eq 0 ]
