diff --git a/docs/ANALYSIS.md b/docs/ANALYSIS.md
index e323d8f..03e5c37 100644
--- a/docs/ANALYSIS.md
+++ b/docs/ANALYSIS.md
@@ -66,6 +66,8 @@ bd-session run  (loop; ES "reboot" = restart the session; lock = one session at
 * **Audio**: no PipeWire of its own. (A plain PulseAudio server answers `Access denied` to other uids that lack its auth cookie, and everything in the chroot is root: the desktop user's cookie is copied (0600, private tmpfs; a read-only bind does not work because libpulse opens it read-write) to `/run/host-pulse-cookie` and passed as `PULSE_COOKIE`; pipewire-pulse does not need it.) `batocera-audio`/`pactl` inside talk to the host server, so volume, mute, default device and card profile changed in Batocera *are* the host's. At start, `bd-audio-inherit` copies the host's current device/profile/volume into `batocera.conf` (SHARE) so ES shows the same state. The read-only image is never modified. No daemon is needed for either direction.
 * **Hotkeys and volume keys**: `S90hotkeygen` is started (it was missing before: no pad hotkey in games, `hotkeygen --new-context` crashing at every launch/stop). It handles volume/mute/brightness/screenshot natively, so the triggerhappy volume injection (`BD_VOLUME_KEYS=auto`) is skipped while hotkeygen is in `BD_SERVICES` (two handlers would double the step). triggerhappy runs only in **drm** mode: in a window your desktop already handles power/volume keys (a daemon reading `/dev/input/event*` also reacts to host keys while Batocera is unfocused). hotkeygen cannot be limited that way (the pad hotkeys need it in a window too); the host's `99-batocera-hotkeygen.rules` keeps its virtual keyboard from being classified as a mouse/joystick. In drm mode both daemons still read `/dev/input` while the desktop owns another VT, and act on the same host PipeWire, so the desktop's own volume handler made every press count twice: the `batocera-audio` shim (`bd_inject_volume_gate`) ignores `setSystemVolume` unless `/sys/class/tty/tty0/active` is Batocera's VT. Not solved for nested mode (both are on screen at once; hotkeygen there still doubles the step with a desktop that handles volume keys).
 * **DNS**: `/etc/resolv.conf` in the chroot is a symlink to `/run/host-resolv.conf` (the session's private tmpfs), and `bd_sync_resolv` keeps that file equal to the host's, at preparation and then every second from the session loop (written aside and renamed). A one-shot copy at start was wrong when the service started before NetworkManager had written the DNS servers (header-only file, no `nameserver`: glibc falls back to `127.0.0.1`, ES's downloaders report no connection while `curl` from a maintenance shell works) and never followed a change of network. Written from the loop process itself because it shares the session's mount namespace: a write from another process (`shell`) may not be seen through the session's overlay mount.
+* **Brightness**: Batocera's `batocera-brightness` (ES slider, `cycle`) writes `/sys/class/backlight/*/brightness`, but `/sys` is read-only inside; `bd_bind_backlight` binds just those devices read-write over it (`BD_BACKLIGHT`). Batocera has no handler for `KEY_BRIGHTNESSUP/DOWN` (only `KEY_BRIGHTNESS_CYCLE`), so the host desktop keeps those keys and nothing doubles. But the stock triggerhappy map binds a bare `KEY_LEFTMETA` (Super) to `batocera-brightness cycle`, and the key daemons read `/dev/input` whatever VT is in front: now that the backlight is writable, tapping Super on the desktop would cycle the host's brightness. In drm mode the `batocera-brightness` shim (`bd_inject_brightness_gate`, `BD_BRIGHTNESS_GATE`) drops changes unless Batocera's VT is the active one, like the volume gate; reading the value and calls made with Batocera in front pass through.
+* **User key maps and double volume**: hotkeygen binds `KEY_VOLUMEUP/DOWN/MUTE` to `batocera-audio setSystemVolume`. A `multimedia_keys.conf` of the user that maps the same keys (e.g. to `amixer`) makes triggerhappy run a second change at every press, and the VT gate (which only filters `setSystemVolume`) does not stop it with the desktop in front: `bd_inject_triggerhappy` warns about it.
 * **Start-up cost**: `bd_free_vt` scanned `/proc/*/fd/*` with one `readlink` subshell per descriptor (~1.4 ms each; thousands on a desktop), now one `find`. `S04populate` detaches `ldconfig &` on purpose ("perf issue (boot time)"); waiting for it and then running a second full `ldconfig` doubled that cost, and the NVIDIA links were already staged before it. The journal timestamps of `journalctl -u batocera-desktop` show every phase.
 * **Bluetooth**: `BD_BT=host` shares `bluetoothd` over D-Bus (pairing a pad in ES leaves it paired on the host and vice versa); `exclusive` (experimental) stops the host's and uses Batocera's.
 * **Gamepads**: direct `/dev/input` reads (compositor-independent), classification through the host udev database (`/run/udev`), `uinput`/`uhid`/`joydev` loaded via `modules-load.d`.
diff --git a/etc/batocera-desktop.conf b/etc/batocera-desktop.conf
index 2c93f9e..3b24174 100644
--- a/etc/batocera-desktop.conf
+++ b/etc/batocera-desktop.conf
@@ -90,3 +90,10 @@ BD_CAN_SHUTDOWN=false
 # pressing volume keys there would change the (shared) volume twice. 1 = Batocera ignores its
 # volume keys unless its own VT is the active one. 0 = always act.
 #BD_VOLUME_GATE=1
+# /sys is read-only inside Batocera. 1 = make only the backlight devices (/sys/class/backlight/*)
+# writable, so batocera-brightness (ES brightness slider, "cycle" hotkey) works. 0 = leave it read-only.
+#BD_BACKLIGHT=1
+# drm: 1 = Batocera's brightness changes (batocera-brightness) are ignored while its VT is not the
+# active one, so a key bound to it (e.g. the Super key in the stock triggerhappy map) cannot change
+# the host's backlight from the desktop. 0 = always act.
+#BD_BRIGHTNESS_GATE=1
diff --git a/lib/bd-common.sh b/lib/bd-common.sh
index 8ff2a38..37772b2 100644
--- a/lib/bd-common.sh
+++ b/lib/bd-common.sh
@@ -67,6 +67,8 @@ bd_load_config() {
     : "${BD_VOLUME_KEYS:=auto}"             # add volume/mute keys to triggerhappy: auto (only if hotkeygen is not started) | 1 | 0
     : "${BD_VOLUME_STEP:=5}"
     : "${BD_VOLUME_GATE:=1}"                # drm: ignore Batocera's volume keys while its VT is not the active one
+    : "${BD_BRIGHTNESS_GATE:=1}"            # drm: ignore Batocera's brightness changes while its VT is not the active one
+    : "${BD_BACKLIGHT:=1}"                  # make /sys/class/backlight/* writable inside (batocera-brightness, ES slider)
     : "${BD_XKB_LAYOUT:=}"
     : "${BD_XKB_VARIANT:=}"
     : "${BD_NVIDIA_HOST_EGL_PLATFORM:=0}"   # 1 = also use the host's libnvidia-egl-*
@@ -220,6 +222,30 @@ bd_inject_volume_gate() {
     bd_shim_install /usr/bin/batocera-audio usr/bin/batocera-audio bd-shim-audio optional
 }
 
+# /sys is read-only inside (so Batocera's sysctl/sysrq stay away from the host), which also stops
+# batocera-brightness (ES brightness slider, "cycle" hotkey) from writing
+# /sys/class/backlight/*/brightness. Bind just the backlight devices read-write over it; call it
+# after the read-only /sys is in place. Devices that appear later (hotplug) need a new session.
+bd_bind_backlight() {
+    [[ ${BD_BACKLIGHT:-1} == 1 ]] || return 0
+    local sys=${BD_SYS:-/sys} d real
+    for d in "$sys"/class/backlight/*; do
+        [[ -e $d ]] || continue
+        real=$(readlink -f -- "$d") || continue
+        [[ $real == "$sys"/devices/* ]] || continue
+        bd_bind "$real" "$real" || log_warn "could not make the backlight $real writable"
+    done
+    return 0
+}
+
+# Same for brightness: with /sys/class/backlight writable (bd_bind_backlight), a key mapped to
+# `batocera-brightness` in Batocera's key daemons would change the HOST's backlight while the
+# desktop is in front. The shim drops any change (calls with arguments) while our VT is not active.
+bd_inject_brightness_gate() {
+    [[ ${BD_MODE:-nested} == drm && $BD_BRIGHTNESS_GATE == 1 && -n ${BD_TTY:-} ]] || return 0
+    bd_shim_install /usr/bin/batocera-brightness usr/bin/batocera-brightness bd-shim-brightness optional
+}
+
 # X11 variants: Xorg must run on OUR vt. Wrap the server (see share/chroot/usr/bin/Xorg-shim).
 bd_inject_xorg() {
     bd_shim_install /usr/bin/Xorg usr/bin/Xorg-shim bd-shim-xorg optional || return 1
diff --git a/libexec/bd-session b/libexec/bd-session
index ace9637..1b2d9a7 100755
--- a/libexec/bd-session
+++ b/libexec/bd-session
@@ -311,6 +311,7 @@ bd_mount_runtime() {
     S=$(bd_rpath "$R" /sys)
     mkdir -p "$S"
     bd_mount_ro /sys "$S"
+    bd_bind_backlight
     bd_bind /dev /dev "" rec || return 1
 
     P=$(bd_rpath "$R" /run)
@@ -367,7 +368,14 @@ bd_inject_triggerhappy() {
     # /etc/default/triggerhappy, so we extend the key map there (writable layer only; the
     # squashfs is never touched). A user-provided /userdata/system/configs/multimedia_keys.conf
     # always wins: add the volume keys to it yourself if you use one.
-    local f tmp step=$BD_VOLUME_STEP
+    local f tmp step=$BD_VOLUME_STEP uk=$BD_USERDATA/system/configs/multimedia_keys.conf
+    # A multimedia_keys.conf of the user that also maps the volume keys (amixer, batocera-audio...)
+    # runs next to hotkeygen's own binding: every press changes the volume twice, and the VT gate
+    # only covers `batocera-audio setSystemVolume`, not other commands.
+    if [[ " $BD_SERVICES " == *hotkeygen* && -f $uk ]] \
+        && grep -qE '^[[:space:]]*KEY_(VOLUME(UP|DOWN)|MUTE)([[:space:]+]|$)' "$uk"; then
+        log_warn "$uk maps the volume keys and hotkeygen (started) already does: each press changes the volume twice. Remove those lines (hotkeygen handles them, and the pad shortcuts too)"
+    fi
     # Batocera's hotkeygen already maps KEY_VOLUMEUP/DOWN/MUTE (default_mapping.conf ->
     # batocera-audio setSystemVolume): with it running, a second handler would double the step.
     if [[ $BD_VOLUME_KEYS == auto ]]; then
@@ -398,6 +406,7 @@ bd_inject_files() {
     fi
     bd_inject_vt_file
     bd_inject_volume_gate || log_warn "could not install the volume gate: volume keys may act twice while the desktop is in front"
+    bd_inject_brightness_gate || log_warn "could not install the brightness gate: brightness keys may act on the host while the desktop is in front"
     # drm/tty mode uses Batocera's own launcher and batocera-resolution (real KMS output)
     if [[ $P_DISPLAY == x11 ]]; then
         bd_inject_xorg || return 1
diff --git a/share/chroot/usr/bin/batocera-brightness b/share/chroot/usr/bin/batocera-brightness
new file mode 100755
index 0000000..8aff433
--- /dev/null
+++ b/share/chroot/usr/bin/batocera-brightness
@@ -0,0 +1,27 @@
+#!/bin/sh
+# bd-shim-brightness
+# batocera-desktop (drm mode): wraps batocera-brightness so that changes are ignored while
+# Batocera's VT is not the one on screen. Batocera's key daemons (hotkeygen, triggerhappy) read
+# /dev/input whatever VT is in front, and /sys/class/backlight is the HOST's: a key mapped to
+# "cycle" (the stock triggerhappy map has a bare KEY_LEFTMETA, the Super key) would change the
+# backlight from the desktop. Reading the value (no arguments) and any call made while Batocera
+# is in front go straight to the original. From a shell opened while the desktop is in front,
+# call batocera-brightness.real to bypass the gate.
+REAL=${BD_BRIGHTNESS_REAL:-/usr/bin/batocera-brightness.real}
+VTFILE=${BD_VTFILE:-/run/bd-vt}
+ACTIVE=${BD_ACTIVE_VT_FILE:-/sys/class/tty/tty0/active}
+LOG=/userdata/system/logs/display.log
+
+if [ $# -gt 0 ]; then
+    VT=$(cat "$VTFILE" 2>/dev/null)
+    CUR=$(cat "$ACTIVE" 2>/dev/null)
+    case "$VT" in ''|*[!0-9]*) ;; *)
+        case "$CUR" in tty[0-9]*)
+            if [ "$CUR" != "tty$VT" ]; then
+                printf '[INFO] bd-brightness: "%s" ignored (Batocera is on tty%s, the active VT is %s)\n' "$*" "$VT" "$CUR" >>"$LOG" 2>/dev/null
+                exit 0
+            fi ;;
+        esac ;;
+    esac
+fi
+exec "$REAL" "$@"
diff --git a/test/run-tests.sh b/test/run-tests.sh
index 0ce0b32..1a2ea3d 100755
--- a/test/run-tests.sh
+++ b/test/run-tests.sh
@@ -81,7 +81,12 @@ cat > $R/usr/bin/batocera-settings-set <<'X'
 #!/bin/sh
 echo "$1=$2" >> /userdata/system/batocera.conf
 X
-chmod +x $R/usr/bin/batocera-resolution $R/usr/bin/pactl $R/usr/bin/batocera-audio $R/usr/bin/batocera-settings-set
+cat > $R/usr/bin/batocera-brightness <<'X'
+#!/bin/sh
+[ $# -eq 0 ] && { echo 50; exit 0; }
+echo "$*" >> /userdata/system/bri.log
+X
+chmod +x $R/usr/bin/batocera-resolution $R/usr/bin/pactl $R/usr/bin/batocera-audio $R/usr/bin/batocera-settings-set $R/usr/bin/batocera-brightness
 mkdir -p $R/etc/default
 echo "# image default" > $R/etc/default/triggerhappy
 mkdir -p $R/usr/share/rufo; echo rufo > $R/usr/share/rufo/marker
@@ -159,6 +164,9 @@ t "nested: batocera-resolution shim installed, original kept as .real" "inns chr
 t "volume keys added to /etc/default/triggerhappy (image content kept)" "inns chroot /run/bdtest/root /bin/cat /etc/default/triggerhappy | grep -q 'setSystemVolume +5' && inns chroot /run/bdtest/root /bin/cat /etc/default/triggerhappy | grep -q 'image default'"
 t "audio inherited from host into batocera.conf (volume, device, profile)" "grep -q '^audio.volume=42' $T/userdata/system/batocera.conf && grep -q '^audio.device=fake_sink' $T/userdata/system/batocera.conf && grep -q '^audio.profile=output:stereo@fake_card' $T/userdata/system/batocera.conf"
 t "nested: batocera-audio is not wrapped (no VT gate)" "! inns chroot /run/bdtest/root /bin/sh -c 'grep -q bd-shim-audio /usr/bin/batocera-audio'"
+t "no warning about volume keys when the user has no key map" "! grep -q 'maps the volume keys' $T/logs/run.log"
+t "nested: batocera-brightness is not wrapped (no VT gate)" "! inns chroot /run/bdtest/root /bin/sh -c 'grep -q bd-shim-brightness /usr/bin/batocera-brightness'"
+t "resolv.conf inside is a link to the session's copy of the host's" "[ \"\$(inns chroot /run/bdtest/root /bin/readlink /etc/resolv.conf)\" = /run/host-resolv.conf ] && [ \"\$(inns chroot /run/bdtest/root /bin/cat /etc/resolv.conf)\" = \"\$(cat /etc/resolv.conf)\" ]"
 t "env: BD_MODE=nested, BD_FULLSCREEN=0" "grep -q '^BD_MODE=nested' $T/userdata/system/labwc.env && grep -q '^BD_FULLSCREEN=0' $T/userdata/system/labwc.env"
 
 section "Test 2: shutdown inside ES -> back to desktop, clean"
@@ -197,8 +205,13 @@ t "enter -- cat version" "'$PFX/libexec/bd-session' enter -- /bin/cat /usr/share
 
 section "Test 6: drm mode (stock launcher, key daemon on, no nested shims)"
 rm -f $T/userdata/system/stock-launch-ran $T/userdata/system/thd.log
+# a user multimedia_keys.conf that maps the volume keys next to hotkeygen: every press would count twice
+mkdir -p $T/userdata/system/configs
+printf 'KEY_VOLUMEUP\t\t1amixer set Master 5%%+\n#KEY_MUTE 1 x\nKEY_F2+KEY_LEFTMETA\t1batocera-brightness cycle\n' > $T/userdata/system/configs/multimedia_keys.conf
 BD_MODE=drm BD_TTY=/dev/tty63 start_session
 t "drm: Batocera's own labwc-launch is used" "waitfor '[ -e $T/userdata/system/stock-launch-ran ]'"
+t "drm: warns when the user's multimedia_keys.conf maps the volume keys next to hotkeygen" "grep -q 'maps the volume keys' $T/logs/run.log"
+rm -f $T/userdata/system/configs/multimedia_keys.conf
 t "drm: triggerhappy started (volume keys work on a bare console)" "grep -q start $T/userdata/system/thd.log"
 t "drm: batocera-resolution not replaced" "! inns chroot /run/bdtest/root /bin/sh -c 'grep -q bd-shim-resolution /usr/bin/batocera-resolution'"
 # volume gate: key actions only count while Batocera's VT (63 here) is the active one
@@ -210,6 +223,14 @@ t "drm: volume key ignored while the desktop VT is active" "[ ! -e $T/userdata/s
 vol tty63
 t "drm: volume key applied while Batocera's VT is active" "grep -q 'setSystemVolume +5' $T/userdata/system/vol.log"
 t "drm: other batocera-audio calls pass through the gate" "[ \"\$(inns chroot /run/bdtest/root /usr/bin/batocera-audio getSystemVolume)\" = 42 ]"
+# brightness gate: same rule
+bri() { inns chroot /run/bdtest/root /bin/sh -c "echo $1 > /tmp/active; BD_ACTIVE_VT_FILE=/tmp/active /usr/bin/batocera-brightness cycle"; }
+rm -f $T/userdata/system/bri.log
+bri tty1
+t "drm: brightness change ignored while the desktop VT is active" "[ ! -e $T/userdata/system/bri.log ]"
+bri tty63
+t "drm: brightness change applied while Batocera's VT is active" "grep -q 'cycle' $T/userdata/system/bri.log"
+t "drm: reading the brightness (no arguments) passes through the gate" "[ \"\$(inns chroot /run/bdtest/root /usr/bin/batocera-brightness)\" = 50 ]"
 kill -TERM $RUNPID $(pgrep -f '^bash .*/libexec/bd-session inner$') 2>/dev/null
 t "drm: session ends on SIGTERM" "waitfor '! alive $RUNPID'"
 t "drm: no leftover mounts" "! grep -q bdtest /proc/mounts"
@@ -345,5 +366,34 @@ t "no cookie (PipeWire setups) -> none, not an error for the session" "! HOME_FA
 t "BD_PULSE_COOKIE overrides the lookup" "[ \"\$(HOME_FAKE=$T/home pc $T/pulse-cookie 1234)\" = $T/pulse-cookie ]"
 t "BD_PULSE_COOKIE pointing nowhere -> none" "! HOME_FAKE=$T/home pc $T/nope 1234"
 
+section "Test 13: resolv.conf inside follows the host's"
+RS=$T/rs; mkdir -p $RS/root/run $RS/root/etc
+rs(){ ( . "$PFX/lib/bd-common.sh"; BD_ROOT=$RS/root; BD_HOST_RESOLV=$RS/host; bd_sync_resolv ); }
+printf '# Generated by NetworkManager\n' > $RS/host
+t "resolv: a header-only file (NetworkManager not done yet) is copied as it is" "rs && [ \"\$(cat $RS/root/run/host-resolv.conf)\" = '# Generated by NetworkManager' ]"
+printf '# Generated by NetworkManager\nnameserver 192.168.1.1\n' > $RS/host
+t "resolv: a later change of the host's file reaches the chroot" "rs && grep -q 'nameserver 192.168.1.1' $RS/root/run/host-resolv.conf"
+t "resolv: nothing is left behind (written aside and renamed)" "[ ! -e $RS/root/run/host-resolv.conf.new ]"
+rm -f $RS/host
+t "resolv: a host without resolv.conf keeps the last good one" "rs && grep -q 'nameserver 192.168.1.1' $RS/root/run/host-resolv.conf"
+
+section "Test 14: backlight devices writable inside the read-only /sys"
+cat > $T/bl-test.sh <<'X'
+set -e
+B=$1 P=$2 ON=$3
+S=$B/fakesys
+mkdir -p $S/devices/p/bl $S/class/backlight $B/root$S
+echo 3000 > $S/devices/p/bl/brightness
+ln -sfn ../../devices/p/bl $S/class/backlight/bl
+mount --bind $S $B/root$S; mount -o remount,bind,ro $B/root$S
+. "$P/lib/bd-common.sh"
+BD_ROOT=$B/root; BD_SYS=$S; BD_BACKLIGHT=$ON
+bd_bind_backlight
+echo 7 > $B/root$S/class/backlight/bl/brightness
+if touch $B/root$S/devices/p/other 2>/dev/null; then exit 1; fi
+X
+t "backlight: with BD_BACKLIGHT=1 the device is writable and the rest of /sys is not" "rm -rf $T/bl; mkdir -p $T/bl; unshare -m bash $T/bl-test.sh $T/bl $PFX 1"
+t "backlight: with BD_BACKLIGHT=0 it stays read-only" "rm -rf $T/bl; mkdir -p $T/bl; ! unshare -m bash $T/bl-test.sh $T/bl $PFX 0 2>/dev/null"
+
 echo
 summary "Result"
