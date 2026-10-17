diff -ruN a/docs/ANALYSIS.md b/docs/ANALYSIS.md
--- a/docs/ANALYSIS.md	2026-10-17 12:09:30.738531175 +0000
+++ b/docs/ANALYSIS.md	2026-10-17 12:09:30.791773924 +0000
@@ -65,6 +65,7 @@
 * **NVIDIA without copies**: the `libGLX_nvidia.so.<version>` loaded is that of **your** driver, detected from `/sys/module/nvidia/version`. EGL vendor and Vulkan ICD are forced to NVIDIA to avoid a silent fall back to Mesa. On Intel/AMD nothing is linked (Batocera's Mesa).
 * **Audio**: no PipeWire of its own. (A plain PulseAudio server answers `Access denied` to other uids that lack its auth cookie, and everything in the chroot is root: the desktop user's cookie is copied (0600, private tmpfs; a read-only bind does not work because libpulse opens it read-write) to `/run/host-pulse-cookie` and passed as `PULSE_COOKIE`; pipewire-pulse does not need it.) `batocera-audio`/`pactl` inside talk to the host server, so volume, mute, default device and card profile changed in Batocera *are* the host's. At start, `bd-audio-inherit` copies the host's current device/profile/volume into `batocera.conf` (SHARE) so ES shows the same state. The read-only image is never modified. No daemon is needed for either direction.
 * **Hotkeys and volume keys**: `S90hotkeygen` is started (it was missing before: no pad hotkey in games, `hotkeygen --new-context` crashing at every launch/stop). It handles volume/mute/brightness/screenshot natively, so the triggerhappy volume injection (`BD_VOLUME_KEYS=auto`) is skipped while hotkeygen is in `BD_SERVICES` (two handlers would double the step). triggerhappy runs only in **drm** mode: in a window your desktop already handles power/volume keys (a daemon reading `/dev/input/event*` also reacts to host keys while Batocera is unfocused). hotkeygen cannot be limited that way (the pad hotkeys need it in a window too); the host's `99-batocera-hotkeygen.rules` keeps its virtual keyboard from being classified as a mouse/joystick. In drm mode both daemons still read `/dev/input` while the desktop owns another VT, and act on the same host PipeWire, so the desktop's own volume handler made every press count twice: the `batocera-audio` shim (`bd_inject_volume_gate`) ignores `setSystemVolume` unless `/sys/class/tty/tty0/active` is Batocera's VT. Not solved for nested mode (both are on screen at once; hotkeygen there still doubles the step with a desktop that handles volume keys).
+* **DNS**: `/etc/resolv.conf` in the chroot is a symlink to `/run/host-resolv.conf` (the session's private tmpfs), and `bd_sync_resolv` keeps that file equal to the host's, at preparation and then every second from the session loop (written aside and renamed). A one-shot copy at start was wrong when the service started before NetworkManager had written the DNS servers (header-only file, no `nameserver`: glibc falls back to `127.0.0.1`, ES's downloaders report no connection while `curl` from a maintenance shell works) and never followed a change of network. Written from the loop process itself because it shares the session's mount namespace: a write from another process (`shell`) may not be seen through the session's overlay mount.
 * **Start-up cost**: `bd_free_vt` scanned `/proc/*/fd/*` with one `readlink` subshell per descriptor (~1.4 ms each; thousands on a desktop), now one `find`. `S04populate` detaches `ldconfig &` on purpose ("perf issue (boot time)"); waiting for it and then running a second full `ldconfig` doubled that cost, and the NVIDIA links were already staged before it. The journal timestamps of `journalctl -u batocera-desktop` show every phase.
 * **Bluetooth**: `BD_BT=host` shares `bluetoothd` over D-Bus (pairing a pad in ES leaves it paired on the host and vice versa); `exclusive` (experimental) stops the host's and uses Batocera's.
 * **Gamepads**: direct `/dev/input` reads (compositor-independent), classification through the host udev database (`/run/udev`), `uinput`/`uhid`/`joydev` loaded via `modules-load.d`.
diff -ruN a/lib/bd-common.sh b/lib/bd-common.sh
--- a/lib/bd-common.sh	2026-10-17 12:09:30.738883951 +0000
+++ b/lib/bd-common.sh	2026-10-17 12:09:30.791320480 +0000
@@ -447,6 +447,23 @@
 }
 
 # --------------------------------------------------------------- utilities
+# bd_sync_resolv : keep the chroot's DNS configuration identical to the host's while the session
+# lives. /etc/resolv.conf inside is a symlink to /run/host-resolv.conf (the session's private tmpfs,
+# see bd_prepare); this refreshes that file whenever the host's changes (a different wifi, VPN, or
+# NetworkManager finishing after the service started). The new file is written aside and renamed, so
+# readers never see a half-written one, and glibc/libcurl notice the change by mtime/inode.
+# Cheap enough for a 1 s loop: one cmp when nothing changed.
+bd_sync_resolv() {
+    local src=${BD_HOST_RESOLV:-/etc/resolv.conf} dst=${BD_RESOLV_DST:-}
+    if [[ -z $dst ]]; then
+        dst=$(bd_rpath "$BD_ROOT" /run/host-resolv.conf) || return 1
+        BD_RESOLV_DST=$dst
+    fi
+    [[ -r $src ]] || return 0 # host has none right now: keep the last one
+    cmp -s -- "$src" "$dst" 2>/dev/null && return 0
+    cat -- "$src" >"$dst.new" 2>/dev/null && mv -f -- "$dst.new" "$dst"
+}
+
 bd_chroot_proc() {   # is there a process with that comm inside the chroot?
     local p c r alts name=${1:0:15}
     # X11: our shim execs Xorg.real, so the kernel's comm is never "Xorg" (and Debian also has
diff -ruN a/libexec/bd-session b/libexec/bd-session
--- a/libexec/bd-session	2026-10-17 12:09:30.738915548 +0000
+++ b/libexec/bd-session	2026-10-17 12:09:30.791553526 +0000
@@ -352,11 +352,13 @@
         bd_bind "$src" "$dst" "$opt" rec
     done
 
-    # resolv.conf (may be a symlink in the rootfs; replace the leaf, never write through it)
-    dst=$(bd_rleaf "$R" /etc/resolv.conf)
-    mkdir -p "${dst%/*}"
-    rm -f -- "$dst"
-    cat /etc/resolv.conf >"$dst" 2>/dev/null
+    # DNS: /etc/resolv.conf is a symlink to a file in the session's private /run, kept in step with
+    # the host's by bd_sync_resolv (now, and every second from the session loop). A one-shot copy
+    # broke whenever the service started before NetworkManager had written the DNS servers (a file
+    # with only its header and no nameserver: glibc then falls back to 127.0.0.1) and it never
+    # followed a change of network.
+    bd_ln /etc/resolv.conf /run/host-resolv.conf
+    bd_sync_resolv
     return 0
 }
 
@@ -599,6 +601,7 @@
                 break
             fi
         fi
+        bd_sync_resolv
         sleep 1 &
         wait $!
     done
