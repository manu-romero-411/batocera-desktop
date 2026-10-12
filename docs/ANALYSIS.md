# Analysis of the original scripts and design decisions

## 1. What the original `batocera-chroot` scripts did
They closed the XFCE/KDE session, mounted the chroot (`chroot-setup -m`), **stopped the display manager**, started ES, triggerhappy and userservices through `init.d`, then blocked on a FIFO until ES "shut down", unmounted and restarted the display manager. In short: Batocera **replaced** the desktop; it did not coexist with it.

## 2. Problems found (by severity)
| # | Problem | Consequence |
|---|---------|-------------|
| 1 | The **host's** `/var`, `/tmp`, `/opt`, `/run`, `/dev`, `/sys`, `/proc` were bind-mounted into the chroot | Batocera's `init.d` scripts write into the host's `/var` and `/run`; pid files and sockets get mixed |
| 2 | Same PID/UTS/proc namespace as the host | Batocera runs `hostname X`, `sysctl kernel.core_pattern=…` (S26system), `killall pipewire/wireplumber/labwc/…`: they **act on the host** |
| 3 | `rufomaculata` (the second squashfs the initrd merges with `batocera`) was not mounted | Part of the system missing on recent images (split in two by the 4 GB limit) |
| 4 | The initrd was not reproduced: `.update` → final file, `overlay` → `overlay.old`, `boot.stale` | After `batocera-upgrade` the new version was never activated |
| 5 | Single `lowerdir`; saved overlay copied with `cp -pr saved/*` (skips dotfiles) | Hidden files of the saved overlay lost |
| 6 | Unmount loop with `grep /proc/mounts` + `lsof` + 20 retries | Stuck mounts if a process remains; manual cleanup |
| 7 | `S06audio` started Batocera's own PipeWire and *required* stopping the host's audio; `audio-start` filtered "HDA Intel Duplex" (specific hardware) | No sound / conflict with the desktop |
| 8 | No proprietary NVIDIA: Batocera's S05nvidia links **its own** driver (different version than the host module) | libGL/EGL/Vulkan fail or silently fall back to llvmpipe |
| 9 | Hard-coded paths (`/home/<user>/...`), `sudo` + `nohup`, inconsistent `.desktop`/`install.sh` paths | Fragile, not portable |
| 10 | `mount_if_not` heuristic ("directory has files → bind, else mount") | Ambiguous behaviour |
| 11 | No Bluetooth: the host's bluetoothd and Batocera's would clash | Bluetooth pads not manageable |

## 3. Key findings in Batocera's source (`master`, 44-dev, and the v43 changelog)
* **v43: the `x86-64-v3` image uses Wayland + labwc.** The classic `x86_64` image uses Xorg. The stock `labwc-launch` assumes DRM/KMS (`unset WAYLAND_DISPLAY`, `WLR_DRM_DEVICES`…), no nesting.
* Batocera already uses **PipeWire** (`pactl`, `batocera-audio` with `XDG_RUNTIME_DIR=/var/run`). `batocera-audio` is a thin wrapper over `pactl` (volume, mute, default sink, card profile), and `pactl` honours `PULSE_SERVER`: pointing it at the host's socket is enough for every change to act on the host.
* `S27audioconfig` (not run here) applies `audio.device/profile/volume` from `batocera.conf` at boot. ES itself reads the live values through `batocera-audio`.
* Bluetooth: `batocera-bluetooth` and `batocera-bluetooth-agent` talk to `org.bluez` over D-Bus and use `/var/lib/bluetooth`: the host's `bluetoothd` can be shared.
* NVIDIA: `S05nvidia`/`batocera-nvidia` create `…/libGLX_nvidia.so.0 → /var/run/nvidia/lib/…` and `/usr/lib/gbm/nvidia-drm_gbm.so` at run time; without them there is no NVIDIA. The `egl_vendor.d`/`egl_external_platform.d` files already ship in the image.
* Updates: `batocera-upgrade` does `remount,rw /boot` and untars `boot.tar.xz` over `/boot`, leaving `boot/batocera.update`, `boot/rufomaculata.update`, `boot.stale`. The **initrd** applies them on the next boot.
* Keys: the stock x86 triggerhappy key map (`multimedia_keys.conf`) has only power, Ctrl+Alt+F10/F11 and the Meta key. `S50triggerhappy` sources `/etc/default/triggerhappy` and prefers `/userdata/system/configs/multimedia_keys.conf` when it exists. **Volume keys and gamepad hotkeys live in `hotkeygen`** (init script `S90hotkeygen` in 43.1, `S30hotkeygen` after the Sept-2026 rewrite to a python/dbus package): a daemon that reads the key codes (`KEY_EXIT`, `KEY_VOLUMEUP`…) from `/etc/hotkeygen/default_mapping.conf` and runs the action of the current *context* (`hotkeygen --new-context retroarch`, called by configgen at launch/stop through `/var/run/hotkeygen.pid`). The pad combos (`hotkey+start` → `KEY_EXIT`…) are produced by evmapy from `hotkeys.keys`; RetroArch's config only has keyboard hotkeys (`input_enable_hotkey = "shift"`, `input_exit_emulator = "escape"`). If the daemon is not running, configgen's `hotkeygen` client fails with `FileNotFoundError: /var/run/hotkeygen.pid` and the hotkey does nothing in games although ES sees the button.
* wlroots' Wayland backend creates the nested window with `app_id = "wlroots"` and never requests fullscreen itself.

## 4. Architecture
Two entry points, one engine (`bd-session run`):
```
manual:   batocera-desktop start ──sudo (passwordless: only `launch`)──► bd-session launch
            validates the caller's parameters, then `exec bd-session run` in the foreground
            (nested: Wayland session around you | drm: your text console). Ctrl+C ends it.
service:  systemctl start batocera-desktop ──► bd-session run (no BD_MODE)
            drm on the first free VT >= BD_TTY_MIN, chvt to it, chvt back at the end.

bd-session run  (loop; ES "reboot" = restart the session; lock = one session at a time)
   unshare --mount --uts --pid ──► bd-session inner (PID 1 of the namespace)
      1. private tmpfs → loop-mount boot/batocera + boot/rufomaculata → overlay (+ saved overlay)
      2. /boot, /userdata, /proc, /sys (ro), /dev, /run (own tmpfs), /tmp (own tmpfs)
      3. from the host: Wayland + PipeWire sockets (/run/user/UID → /run/host-xdg), /run/udev (ro),
         system D-Bus, /var/lib/bluetooth
      4. NVIDIA: read-only bind of the host library directories + symlinks (nothing is copied)
      5. injected (RAM layer only): nested labwc-launch + batocera-resolution shim (nested mode),
         shutdown/reboot shims, volume keys for triggerhappy, audio inheritance script
      6. stock services: S04populate, S12populateshare, S50triggerhappy (drm only), S97joycond,
         S31emulationstation, S99userservices
      7. wait; at the end, stop services; the namespace vanishes (mounts included)
```

### Why this split
* **Manual start is a foreground process**: no unit, no pidfile, no stop/restart logic. The terminal owns its lifetime (Ctrl+C → `SIGINT` reaches `run` and `inner`, which shut services down and unmount). One lock file prevents two sessions (manual or service) at once.
* **The service is for the unattended case**, where there is no desktop to nest into, so it is always drm. Windowed mode needs the user's compositor socket and a compositor rule, which only make sense from the user's own session. Management (start/stop/enable/status/logs) is plain `systemctl`/`journalctl`; the CLI does not wrap it.
* **How the manual mode is chosen**: Wayland in the environment → nested; X11 → refused; a `/dev/ttyN` terminal → drm; otherwise refused.
* **Free console**: the service looks for the first VT ≥ `BD_TTY_MIN` with no logind session (`loginctl`) and no process holding `/dev/ttyN` open, runtime-masks `getty@ttyN` while it owns it (logind would otherwise start a getty over the VT on activation), and switches back to the previous VT afterwards. Audio: at start without a login, `user@UID.service` is started for `BD_USER` so the user's `pipewire-pulse` socket exists.

### Decisions
* **Batocera's own labwc is reused** (it is updated with Batocera). Nested: `WLR_BACKENDS=wayland`; only `labwc-launch` is replaced and `batocera-resolution` gets a shim (the stock one answers "unknown" because the wayland backend has no mode list). In drm mode nothing of the graphics stack is replaced.
* **Fullscreen** (manual nested start only): the CLI (as the user) asks the host compositor to fullscreen windows with app_id `wlroots`: a KWin script (loaded over D-Bus) on KDE, `for_window` on sway, `windowrulev2` on Hyprland. Alt+Tab keeps working. Other compositors: use their fullscreen shortcut.
* **Private namespaces** (mount+PID+UTS): `hostname`, `sysctl`, `killall` stay confined, `/proc/sys` is read-only, and nothing stays mounted afterwards.
* **Updates**: the **stock** `batocera-upgrade` runs inside (`batocera-desktop update`, or ES's menu). `bd_boot_apply_pending` does what the initrd does, with path protection for `boot.stale`. Replacing `boot/batocera` is safe while the session runs (tar unlinks and recreates; the loop device keeps the old inode). ES "Restart" = restart the session and apply the new version.
* **NVIDIA without copies**: the `libGLX_nvidia.so.<version>` loaded is that of **your** driver, detected from `/sys/module/nvidia/version`. EGL vendor and Vulkan ICD are forced to NVIDIA to avoid a silent fall back to Mesa. On Intel/AMD nothing is linked (Batocera's Mesa).
* **Audio**: no PipeWire of its own. `batocera-audio`/`pactl` inside talk to the host server, so volume, mute, default device and card profile changed in Batocera *are* the host's. At start, `bd-audio-inherit` copies the host's current device/profile/volume into `batocera.conf` (SHARE) so ES shows the same state. The read-only image is never modified. No daemon is needed for either direction.
* **Hotkeys and volume keys**: `S90hotkeygen` is started (it was missing before: no pad hotkey in games, `hotkeygen --new-context` crashing at every launch/stop). It handles volume/mute/brightness/screenshot natively, so the triggerhappy volume injection (`BD_VOLUME_KEYS=auto`) is skipped while hotkeygen is in `BD_SERVICES` (two handlers would double the step). triggerhappy runs only in **drm** mode: in a window your desktop already handles power/volume keys (a daemon reading `/dev/input/event*` also reacts to host keys while Batocera is unfocused). hotkeygen cannot be limited that way (the pad hotkeys need it in a window too); the host's `99-batocera-hotkeygen.rules` keeps its virtual keyboard from being classified as a mouse/joystick. In drm mode both daemons still read `/dev/input` while the desktop owns another VT, and act on the same host PipeWire, so the desktop's own volume handler made every press count twice: the `batocera-audio` shim (`bd_inject_volume_gate`) ignores `setSystemVolume` unless `/sys/class/tty/tty0/active` is Batocera's VT. Not solved for nested mode (both are on screen at once; hotkeygen there still doubles the step with a desktop that handles volume keys).
* **Start-up cost**: `bd_free_vt` scanned `/proc/*/fd/*` with one `readlink` subshell per descriptor (~1.4 ms each; thousands on a desktop), now one `find`. `S04populate` detaches `ldconfig &` on purpose ("perf issue (boot time)"); waiting for it and then running a second full `ldconfig` doubled that cost, and the NVIDIA links were already staged before it. The journal timestamps of `journalctl -u batocera-desktop` show every phase.
* **Bluetooth**: `BD_BT=host` shares `bluetoothd` over D-Bus (pairing a pad in ES leaves it paired on the host and vice versa); `exclusive` (experimental) stops the host's and uses Batocera's.
* **Gamepads**: direct `/dev/input` reads (compositor-independent), classification through the host udev database (`/run/udev`), `uinput`/`uhid`/`joydev` loaded via `modules-load.d`.

## 5. Latency
Nested mode puts two compositors in the path: Batocera's labwc composes the frame, then your host compositor composes it again with your desktop. Expect roughly **one extra frame** of latency compared with Batocera on bare metal, plus a little GPU work. This is an estimate from the architecture, **not a measurement**: nobody has measured it on this stack yet.

What helps, in order of effect:
1. **Use drm mode for latency-sensitive play** (fighting games, rhythm games, anything with tight timing). labwc drives KMS directly, exactly like a real Batocera: no host compositor involved. Run `batocera-desktop start` from a text console, or start the systemd service (it lands on a free console; `chvt` to switch).
2. In nested mode, make the window **fullscreen** (done automatically on KDE/sway/Hyprland). A fullscreen window lets the host compositor skip compositing and scan it out directly, where it supports that (KWin does for fullscreen windows; wlroots-based compositors also have direct scanout).
3. Disable vsync-adding features of the host (compositor "allow tearing", adaptive sync) if you are chasing the last frame.
4. Use wired pads or 2.4 GHz dongles: Bluetooth adds more latency than the nesting does.

To measure it yourself: film a screen showing a button press (High-speed phone camera, or a latency tester such as an LED + photodiode rig) in both modes and compare. If you do, please share numbers in an issue.

## 6. Verified / not verified
**Verified in a sandbox** (`test/run-tests.sh`, 77 checks over a fake Batocera made of busybox and squashfs, with absolute-symlink traps; `test/test-install.sh`, 23 checks): squashfs+overlay layers, both `.update` files, `boot.stale` (including a malicious path), `overlay.old`, shutdown/reboot shims (including `BD_CAN_SHUTDOWN` true/false against a fake `systemctl`), `start` mode selection (a real console always means drm, even with a desktop on another VT), PID/UTS/mount isolation, read-only `/proc/sys`, NVIDIA links with fake libs, SIGTERM stop without leftovers, drm-mode service selection (key daemon on, stock launcher), nested-mode shims, volume-key map generation, audio inheritance into `batocera.conf`, launch validation (bad paths/users/ttys/modes), foreground start ended by SIGINT, single-session lock, service-style start picking a free VT, free-VT selection (fake `loginctl`, held-open ttys), installer, uninstall and purge (including refusal of system paths and mount points).

**NOT verified (needs real hardware):** real GPU/EGL/Vulkan with the 615 driver, nested wlroots on NVIDIA, drm mode on NVIDIA, real audio/Bluetooth, **the real systemd unit** (logind/getty interaction, the runtime mask of `getty@ttyN`, `chvt` back, `user@UID.service` startup), the KWin fullscreen script (D-Bus API names differ between Plasma versions), the real `updates.batocera.org` download, and the actual latency. `batocera-desktop doctor` helps diagnose.

## 7. Known risks and limits
1. **Requires the x86-64-v3 image (labwc, ≥ v43).** With the Xorg x86_64 image there is no labwc to nest. Migration: inside the environment, `batocera-upgrade --upgrade --url https://updates.batocera.org/x86-64-v3/stable/last`.
2. **NVIDIA version mix**: host 615 libraries are used next to Batocera's `libnvidia-egl-wayland/gbm` (another version). The ABI is stable, but if EGL-on-Wayland fails try `BD_NVIDIA_HOST_EGL_PLATFORM=1`.
3. **X11 sessions are not supported** (wlroots has an X11 backend; not wired up).
4. Nested-mode gamepads keep feeding ES while the window is unfocused.
5. Resolution: nested mode has a "monitor" that is the window; if Batocera switches video mode per game it is ignored. Use `global.videomode=default` in `batocera.conf`.
6. Batocera's own udev rules (light guns, Steam Deck…) are not applied (udevd is the host's).
7. 32-bit (Wine/Proton 32) and CUDA: only 64-bit libraries are linked.
8. **Security**: `launch`/`stop` are passwordless sudo and Batocera's services run as root: whoever can write to `<userdata>/system/services` gets root. Keep `BD_USERDATA` owned by root. The service runs the same way.

## 8. Variants (v3, x86_64, 5.26-amd64, 5.26-i386)
Code: `lib/bd-variants.sh` (rules, profile table), `bd_assert_variant` in `libexec/bd-session`, `share/chroot/usr/bin/Xorg-shim`.

### Eligibility rules (hardware, read from /proc and /sys)
* **v3**: `lm` + every x86-64-v3 flag (`avx avx2 bmi1 bmi2 f16c fma abm movbe xsave`). Flags, not years: Pentium/Celeron up to Comet Lake and AMD before Excavator have no AVX2 although they are post-2013.
* **x86_64**: `lm` and not "legacy graphics". **All** display controllers (PCI class 03xx) are examined: Intel GMA ones (ID list `BD_GMA_IDS`, or driver `gma500_gfx`) are legacy, every other GPU counts as capable (NVIDIA, AMD, Intel HD, VM adapters...). One capable GPU is enough, so Core 2 + GMA + GeForce/Radeon, or Atom D525 + ION, gets x86_64. `BD_WEAK_GPU_IDS` lets you mark specific `vendor:device` GPUs as too weak. Only when no GPU is visible at all does the Atom N4xx/N5xx/D4xx/D5xx/N2xxx/D2xxx name (`BD_ATOM_RE`) decide. Bay Trail Atoms (Z37xx) are not netbook Atoms and get x86_64.
* **5.26-amd64**: `lm` **and** legacy graphics (no capable GPU). Exactly the complement of x86_64's graphics rule, so one machine can never be eligible for both.
* **5.26-i386**: no `lm` flag. (`lm` shows in /proc/cpuinfo even under a 32-bit kernel: a 64-bit CPU never gets i386.)
* amd64 variants also need a 64-bit running kernel (`uname -m` = x86_64).

### Where it is enforced
1. `install.sh` (before copying anything) and `bd-session install` (before downloading/extracting).
2. After extracting: `boot/batocera.board` must be one of the variant's boards and `usr/share/batocera/batocera.version` must match (5.26 vs 6+); otherwise the image is removed and the install cancelled. `x86_64` and `5.26-amd64` share the board name, hence the version check.
3. `.bd-variant` marker next to the image; every `run` (manual and service) re-checks hardware, marker and board.

### X11 builds: standalone only
* Mode `drm` (tty) is reused as is: manual from a text console, or the service on a free VT. The VT/keyboard handling (`bd-vt`) does not care about Wayland vs X.
* Nested is refused for X11 variants (`launch`, CLI, `run`). A nested X path is possible but untested: run `Xephyr` (or a rootful `Xwayland`) on the host, bind `/tmp/.X11-unix` into the chroot and replace the X launch with a shim that only sets `DISPLAY`. Not implemented.
* Stock Batocera starts X itself from `S31emulationstation`. We do not replace that; we only wrap `/usr/bin/Xorg` so it always gets *our* `vtN` (the stock launcher may hard-code `vt1`, which would grab the host's console). The original stays as `Xorg.real`; `/run/bd-vt` carries the number.
* The compositor process to wait for is per variant (`labwc` or `Xorg`).
* Audio is unchanged for the current X11 build: `pactl`/`batocera-audio` talk to the host's PulseAudio/PipeWire-Pulse socket through `PULSE_SERVER`. For 5.26 (probably ALSA-only), if the image has the ALSA pulse plugin an `asound.conf` routes the default PCM to that socket; otherwise a warning says it will use ALSA directly and may fight the host for the sound card.
* Hotkeygen only exists in recent images; the 5.26 service list omits it, and missing services are skipped with a warning.

### Not verified (needs a real image / hardware)
* How the current standard image launches X (the shim assumes `/usr/bin/Xorg` is the server and that the `vtN` argument is honoured); `batocera-desktop doctor` lists the files it expects.
* Everything about 5.26: that the squashfs/overlay layout and `boot/batocera.board` are as assumed (board names `x86`/`x86_64` are guesses; unknown names fail the install, edit `P_BOARDS`), the real `batocera.version` format, the `--img` partition layout (first partition = BATOCERA with `boot/`), whether an old userland runs happy in this namespace setup, and its audio.
* NVIDIA on X11 (implemented, untested on hardware): `bd_nvidia_xcollect/xstage` + `bd_x11_gpu_conf` in `lib/bd-common.sh`. Open questions: (a) the host's `nvidia_drv.so` must support the image's Xorg ABI (a legacy 340/390 driver against a recent Xorg will not load; `Xorg.0.log` says so); (b) whether `libglxserver_nvidia.so` is picked up by name through `ModulePath` or the image's own `libglx` wins; (c) an existing `/etc/X11/xorg.conf` in the image would override the snippet. The module path of the image is assumed to be `/usr/lib/xorg/modules` (or `lib64`). A hybrid laptop whose display is on the Intel GPU needs `BD_GPU=mesa`.
* Intel/AMD on X11 rely on autodetection with the image's own drivers (no config is generated unless `BD_X11_BUSID` is set). Old Mesa in a 5.26 image will not know recent AMD/Intel GPUs: for those machines use the current build.
* Intel GMA PCI IDs were written from memory of `pci.ids`; check yours with `batocera-desktop detect` and `lspci -nn`. Cedarview (GMA 3600/3650, N2xxx) has no usable 3D driver on Linux at all: it is "allowed" as 5.26-amd64 but will be slow.
* "Capable" is simply "not Intel GMA". A very old GeForce/Radeon counts as capable; use `BD_WEAK_GPU_IDS` for exceptions.
