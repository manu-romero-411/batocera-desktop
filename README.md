# batocera-desktop

Run a complete [Batocera](https://batocera.org) (EmulationStation, emulators, gamepads, Bluetooth, audio, self-updates) **on a Linux desktop**, with the host's GPU driver (proprietary NVIDIA or Mesa Intel/AMD):

* **started by hand inside a Wayland desktop** → a fullscreen window (Alt+Tab back to your desktop), Batocera's own labwc nested in your compositor;
* **started by hand on a text console**, or **as a systemd service** → full screen on a free console, Batocera's labwc owns the displays (like a real Batocera).

It replaces the old `batocera-chroot` scripts. Design notes, findings and limits: [`docs/ANALYSIS.md`](docs/ANALYSIS.md).

> **Status: experimental.** Developed and tested against a fake Batocera in a sandbox; **not yet validated on real hardware** (NVIDIA, audio, Bluetooth, the real systemd unit). Read "Known limits" first.

## Batocera variants
Four builds are supported; the installer **refuses (error, nothing installed)** one that does not fit the machine, and every start re-checks it.

| Variant | Build | Display | Allowed on |
|---|---|---|---|
| `v3` | current x86-64-v3 | Wayland/labwc: nested window **or** tty | amd64 CPU with the full x86-64-v3 set (AVX, AVX2, BMI1/2, FMA, F16C, LZCNT, MOVBE, XSAVE) |
| `x86_64` | current standard | X11: tty/standalone only | any amd64 with **at least one capable GPU** (NVIDIA, AMD, non-GMA Intel...), looking at *all* GPUs: a Core 2 with GMA plus a GeForce/Radeon qualifies |
| `5.26-amd64` | Batocera 5.26 amd64 | X11: tty only | amd64 whose **only** graphics are Intel GMA (Atom netbooks, old laptops): exactly where `x86_64` is refused |
| `5.26-i386` | Batocera 5.26 i386 | X11: tty only | CPUs that cannot run 64-bit code |

`batocera-desktop detect` shows what this machine is and which variants fit. X11 variants have no nested window; they run full screen on a text console (`batocera-desktop start` from Ctrl+Alt+F3) or on a free console through the systemd service.

### X11 builds and GPUs
Intel and AMD need nothing extra (the image's Xorg drivers + Mesa over the host kernel's DRM driver). **NVIDIA proprietary**: the host's `nvidia_drv.so` and `libglxserver_nvidia.so` (same version as the loaded kernel module) are bind-mounted read-only and a generated `xorg.conf.d` snippet selects them, pinned to the NVIDIA GPU's BusID. On hybrid machines pick the GPU with `BD_X11_BUSID` / `BD_GPU=mesa` (see the config file). `batocera-desktop doctor` checks that the host modules are found.

## Requirements
* Debian 13 or similar: systemd (optional), sudo, util-linux, python3, xz, curl.
* A Batocera image of the chosen variant (see above).
* PulseAudio or PipeWire with the PulseAudio server (`pipewire-pulse`) for audio.
* NVIDIA: `nvidia-drm.modeset=1` and the driver's userspace libraries installed on the host.
* Nested mode (`v3` only): a Wayland session (KDE, GNOME, sway, Hyprland…). Host X11 sessions are not supported for nesting.

## Install
```bash
sudo ./install.sh --user YOUR_USER                      # asks which variant (or: --variant v3|x86_64|5.26-amd64|5.26-i386)
batocera-desktop install --variant v3 --download        # current builds download from updates.batocera.org
batocera-desktop install --variant 5.26-i386 --img batocera-5.26.img.gz   # 5.26: --img or --file (no default URL)
batocera-desktop doctor                 # everything OK? otherwise it says what is missing
batocera-desktop start
```
Configuration: `/etc/batocera-desktop.conf` (paths, extra disks `BD_EXTRA_BINDS="/games:/games"`, audio, Bluetooth, …; every option is documented in the file).

## Usage
The `batocera-desktop` command does **setup and manual start only**. Running Batocera as a service is systemd's job (see below).

| Command | |
|---|---|
| `start [--tty N] [--windowed]` | run Batocera now, in this terminal; **Ctrl+C ends it** |
| `doctor` | host + image + GPU + service diagnostics |
| `shell [cmd]` | root shell inside the Batocera environment |
| `update` | stock `batocera-upgrade` inside; applied the next time Batocera starts (or "Restart" in ES) |
| `install [--download\|--file F]` | install/reinstall the Batocera image |
| `uninstall` / `purge` | remove the software / remove everything |

Inside ES: **Shutdown** closes Batocera and returns to where you started it; **Restart** restarts the session (applies updates). With `BD_CAN_SHUTDOWN=true` both act on the **host** instead (see [Shutdown and reboot](#shutdown-and-reboot-bd_can_shutdown)). Closing the nested window also ends the session. Logs: Batocera's in `<userdata>/system/logs/`, services' in `/var/log/batocera-desktop/`.

### Manual start (`batocera-desktop start`)
It runs in the foreground of your terminal; there is nothing to stop or restart: Ctrl+C (or "Shutdown" in ES) closes it and cleans up. The mode comes from where you run it (no option needed):
* **Text console** (Ctrl+Alt+F3, log in; the shell's tty is a real `/dev/ttyN`) → *drm*: full screen on **that very VT**, **regardless of any desktop (Wayland or X11) the same user has running on another VT** (its Wayland socket or `DISPLAY` is ignored: it is never nested into). In drm mode Batocera owns that VT's keyboard, so Ctrl+C does not reach your shell: use ES "Shutdown", or from another VT/ssh run `sudo pkill -INT -f 'bd-session run'`.
* **Terminal emulator inside a Wayland session** → *nested*: the CLI asks your compositor to make the window fullscreen (KDE via a KWin script, sway, Hyprland; elsewhere use the compositor's own fullscreen shortcut) and removes that rule when Batocera ends. `--windowed` or `BD_FULLSCREEN=0` disables it.
* **Terminal inside an X11 session**: refused (not supported).
* **X11 variants** (`x86_64`, `5.26-*`) have no nested mode: they need a console (or `--tty N`).

**`--tty N`** is the way to get full screen (drm) on a console **other than the one you are typing in**: over ssh, or from a terminal inside your desktop (where the automatic choice would be a nested window). It overrides the automatic choice, whatever the variant. `N` is either the console you are logged in on, or a **free** one (no login session, nothing holding it open; `tty8` and up are normally free, tty1-6 only if no getty is waiting there). On a free console Batocera does what the service does: it switches to it, keeps logind from drawing a login prompt on it meanwhile and, when it ends (Ctrl+C in the ssh terminal, ES "Shutdown"), switches back to the VT you were on. A console someone else uses is refused with an error naming a free one. The systemd service is unaffected: it always takes the first free console from `BD_TTY_MIN`.
```bash
batocera-desktop start --tty 8      # e.g. over ssh: Batocera appears on tty8 of the machine
```

### The systemd service
`install.sh` installs `batocera-desktop.service`. It is **drm only** and never windowed: it takes the **first free console from tty8 up** (tty1-6 are text consoles and tty7 is usually X11/lightdm; no logind session on it, nothing holding it open; `BD_TTY_MIN` changes the start), switches to it, and switches back to the previous VT when Batocera ends. Use plain systemd:
```bash
sudo systemctl start batocera-desktop      # Batocera appears on the first free console
sudo systemctl stop batocera-desktop       # clean shutdown
sudo systemctl enable batocera-desktop     # also at boot (multi-user.target: no desktop needed)
sudo chvt 1                                # go back to your desktop; chvt N returns to Batocera
```
Audio comes from the PipeWire of `BD_USER` (config; by default the logged-in regular user, else uid 1000), started on demand when nobody is logged in. If audio is missing, `journalctl -u batocera-desktop` says why (`NO audio` warnings) and `batocera-desktop doctor` shows the user and socket. While the service owns a VT it runtime-masks `getty@ttyN` so logind does not draw a login prompt over it. To use Batocera *instead of* your display manager, disable the display manager yourself (`systemctl disable sddm`) and enable this service; the service itself does not touch other units.

## Shutdown and reboot (`BD_CAN_SHUTDOWN`)
`BD_CAN_SHUTDOWN=false|true` in `/etc/batocera-desktop.conf` (default `false`) decides what the power commands run **inside** Batocera do. They are replaced by a shim that only signals the session; the session then acts according to this setting:

| Inside Batocera | `false` (default) | `true` |
|---|---|---|
| `shutdown` / `poweroff` / `halt` (ES menu, power key, SSH, scripts) | closes Batocera, back to the desktop / shell | `systemctl poweroff` on the **host** |
| `reboot` / `shutdown -r` | restarts the Batocera session (applies pending updates) | `systemctl reboot` on the **host** |

`true` is meant for setups where Batocera is the **front end of a server without a UI of its own** (typically Debian): enable the service (`systemctl enable batocera-desktop`; the unit is wanted by `multi-user.target`, so it starts at boot with no desktop or display manager) and the machine can be powered off or rebooted from Batocera's own menu. After a host reboot the service starts Batocera again and applies any pending update, exactly like "Restart" does with `false`. While the host goes down the console is left as it is (no login prompt flashes over it). If `systemctl` fails, the error is logged and Batocera just ends (nothing is forced). Accepted values: `true`/`false` (also `1`/`0`); anything else is a configuration error.

> Mind the nested mode: with `true`, "Shutdown" in a Batocera window started on your desktop powers off the whole machine, not just the window.

## Audio and volume keys
* Batocera has no PipeWire of its own here: its `batocera-audio`/`pactl` talk to your session's PipeWire. Changing the volume, mute, output device or card profile **in Batocera changes it on the host**, and vice versa.
* When the session starts, the host's current device/profile/volume are copied into `batocera.conf` (in your SHARE/userdata; the read-only image is never touched), so ES shows the host state. Disable with `BD_AUDIO_SYNC=0`.
* Hotkeys and volume keys: Batocera 43 does not hardcode the gamepad hotkeys in RetroArch's config any more. `hotkey+start/a/b/x/y…` on a pad are turned into key codes by **evmapy** (`hotkeys.keys`), and **hotkeygen** (`S90hotkeygen`, started by default) maps those codes to actions for the running emulator, and also handles the volume/brightness/screenshot keys. Without that service the pad hotkey does nothing in games. hotkeygen reads every `/dev/input/event*` (it grabs nothing): inside a *window* it also reacts to your host keyboard's volume keys while your desktop does too.
* triggerhappy (power/Ctrl+Alt+F-keys) runs only in **drm** mode (`BD_TRIGGERHAPPY=auto`). `BD_VOLUME_KEYS=auto` adds volume keys to it only when hotkeygen is *not* started (two handlers would double the step); `BD_VOLUME_STEP` is that step. In drm mode, Batocera's key daemons also see your keyboard while your desktop is on another VT (Ctrl+Alt+F2), so a `batocera-audio` shim drops `setSystemVolume` unless Batocera's VT is the active one (`BD_VOLUME_GATE=0` disables it); otherwise each press would change the shared volume twice.

## Updating Batocera
From ES (*Updates*) or `batocera-desktop update`: it is the original `batocera-upgrade`; it leaves `batocera.update`/`rufomaculata.update`/`boot.stale`, and the next session start applies them exactly like the initrd does. It can be done with the session running.

## Latency
Nested mode runs two compositors in series (Batocera's, then yours): expect about **one extra frame** versus bare metal. That is an estimate, not a measurement. For latency-sensitive games use **drm mode** (a text console, or the service): no host compositor is involved and the path is the same as on a real Batocera. Details and ways to measure: [`docs/ANALYSIS.md`](docs/ANALYSIS.md#5-latency).

## Uninstall
```bash
batocera-desktop uninstall      # software only: keeps /etc config, the Batocera image and your userdata
batocera-desktop purge          # EVERYTHING
```
`purge` removes: the program, the systemd unit, sudoers rule, menu entry, `/etc/batocera-desktop.conf`, the Batocera image directory (`BD_BOOT_DIR`), **your userdata (`BD_USERDATA`: roms, BIOS, saves, `batocera.conf`)**, logs, and the legacy `batocera-chroot` leftovers. It lists what it will delete with sizes and requires typing `DELETE` (or `--yes`). Safeguards: it refuses system directories (`/`, `/etc`, `/usr`, `/var`, `/home`, …), home directories, mount points, anything with active mounts below it (stop the session first), and identical boot/userdata paths. It works from the config's paths, so back up first if your roms live there. The same works from the source tree: `sudo ./uninstall.sh [--purge]`.

## Tests
`test/test-variants.sh` (no root): the eligibility matrix against simulated CPUs/GPUs. `sudo test/test-x11.sh`: install/start guards and the Xorg shim. `sudo test/run-tests.sh` (root, `mksquashfs`, `busybox-static`): 87 checks with a fake Batocera. `sudo test/test-install.sh`: installer/uninstaller/purge (touches `/opt`, `/etc`, `/usr/local`: use a VM or container). If something fails on your machine: `batocera-desktop doctor`, `<userdata>/system/logs/display.log` and `batocera-desktop shell cat /var/log/labwc.log` while it runs. On Intel test with `BD_GPU=mesa` (or simply no nvidia module: auto).

## Known limits
X11 variants are tty/standalone only (no nested window); the X11 and 5.26 paths are only unit-tested, never run against a real image (see ANALYSIS §8); unmeasured nested latency; the NVIDIA/audio/Bluetooth/systemd-service paths are untested on real hardware; Batocera's services run as root (keep `BD_USERDATA` root-owned, since `start` uses passwordless sudo). Full list: [`docs/ANALYSIS.md`](docs/ANALYSIS.md#7-known-risks-and-limits).

## Conventions
Comments, identifiers and messages are in English. Status messages go through `lib/log.sh` (`log_info`, `log_ok`, `log_warn`, `log_err`, `die`), which prints colored `[INFO]` / `[ OK ]` / `[WARN]` / `[ERR ]` tags (no color when stdout is not a terminal or `NO_COLOR` is set). Help text and reports (`usage`, `detect`, section headers of `doctor`) stay plain. The `/bin/sh` shims that run inside Batocera log to files with the same tags, without color. The test suites share `test/lib.sh`.

## License
GPL-3.0-or-later, like Batocera itself. See [`LICENSE`](LICENSE).
