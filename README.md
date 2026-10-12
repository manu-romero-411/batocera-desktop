# batocera-desktop

Run a complete [Batocera](https://batocera.org) (EmulationStation, emulators, gamepads, Bluetooth, audio, self-updates) **on a Linux desktop**, with the host's GPU driver (proprietary NVIDIA or Mesa Intel/AMD):

* **started by hand inside a Wayland desktop** → a fullscreen window (Alt+Tab back to your desktop), Batocera's own labwc nested in your compositor;
* **started by hand on a text console**, or **as a systemd service** → full screen on a free console, Batocera's labwc owns the displays (like a real Batocera).

It replaces the old `batocera-chroot` scripts. Design notes, findings and limits: [`docs/ANALYSIS.md`](docs/ANALYSIS.md).

> **Status: experimental.** Developed and tested against a fake Batocera in a sandbox; **not yet validated on real hardware** (NVIDIA, audio, Bluetooth, the real systemd unit). Read "Known limits" first.

## Requirements
* Debian 13 or similar: systemd (optional), sudo, util-linux, python3, xz, curl.
* Batocera image **x86-64-v3 (v43+)**: the one that ships labwc/Wayland.
* PipeWire with the PulseAudio server (`pipewire-pulse`) for audio.
* NVIDIA: `nvidia-drm.modeset=1` and the driver's userspace libraries installed on the host.
* Nested mode: a Wayland session (KDE, GNOME, sway, Hyprland…). X11 is not supported.

## Install
```bash
sudo ./install.sh --user YOUR_USER
batocera-desktop install --download     # if /var/batocera has no x86-64-v3 image yet
batocera-desktop doctor                 # everything OK? otherwise it says what is missing
batocera-desktop start
```
Configuration: `/etc/batocera-desktop.conf` (paths, extra disks `BD_EXTRA_BINDS="/games:/games"`, audio, Bluetooth, …; every option is documented in the file).

## Usage
The `batocera-desktop` command does **setup and manual start only**. Running Batocera as a service is systemd's job (see below).

| Command | |
|---|---|
| `start [--mode auto\|nested\|drm] [--windowed]` | run Batocera now, in this terminal; **Ctrl+C ends it** |
| `doctor` | host + image + GPU + service diagnostics |
| `shell [cmd]` | root shell inside the Batocera environment |
| `update` | stock `batocera-upgrade` inside; applied the next time Batocera starts (or "Restart" in ES) |
| `install [--download\|--file F]` | install/reinstall the Batocera image |
| `uninstall` / `purge` | remove the software / remove everything |

Inside ES: **Shutdown** closes Batocera and returns to where you started it (`BD_ON_SHUTDOWN=host` powers the PC off); **Restart** restarts the session (applies updates). Closing the nested window also ends the session. Logs: Batocera's in `<userdata>/system/logs/`, services' in `/var/log/batocera-desktop/`.

### Manual start (`batocera-desktop start`)
It runs in the foreground of your terminal; there is nothing to stop or restart: Ctrl+C (or "Shutdown" in ES) closes it and cleans up. The mode comes from where you run it:
* **Wayland session** → *nested*: the CLI asks your compositor to make the window fullscreen (KDE via a KWin script, sway, Hyprland; elsewhere use the compositor's own fullscreen shortcut) and removes that rule when Batocera ends. `--windowed` or `BD_FULLSCREEN=0` disables it.
* **Text console** (Ctrl+Alt+F3, log in; no Wayland/X11) → *drm*: full screen on that VT. In drm mode Batocera owns that VT's keyboard, so Ctrl+C does not reach your shell: use ES "Shutdown", or from another VT/ssh run `sudo pkill -INT -f 'bd-session run'`.
* **X11 session**: refused (not supported). `--mode` forces one of the two.

### The systemd service
`install.sh` installs `batocera-desktop.service`. It is **drm only** and never windowed: it takes the **first free console from tty8 up** (tty1-6 are text consoles and tty7 is usually X11/lightdm; no logind session on it, nothing holding it open; `BD_TTY_MIN` changes the start), switches to it, and switches back to the previous VT when Batocera ends. Use plain systemd:
```bash
sudo systemctl start batocera-desktop      # Batocera appears on the first free console
sudo systemctl stop batocera-desktop       # clean shutdown
sudo systemctl enable batocera-desktop     # also at boot (graphical.target)
sudo chvt 1                                # go back to your desktop; chvt N returns to Batocera
```
Audio comes from the PipeWire of `BD_USER` (config; by default the logged-in regular user, else uid 1000), started on demand when nobody is logged in. If audio is missing, `journalctl -u batocera-desktop` says why (`NO audio` warnings) and `batocera-desktop doctor` shows the user and socket. While the service owns a VT it runtime-masks `getty@ttyN` so logind does not draw a login prompt over it. To use Batocera *instead of* your display manager, disable the display manager yourself (`systemctl disable sddm`) and enable this service; the service itself does not touch other units.

## Audio and volume keys
* Batocera has no PipeWire of its own here: its `batocera-audio`/`pactl` talk to your session's PipeWire. Changing the volume, mute, output device or card profile **in Batocera changes it on the host**, and vice versa.
* When the session starts, the host's current device/profile/volume are copied into `batocera.conf` (in your SHARE/userdata; the read-only image is never touched), so ES shows the host state. Disable with `BD_AUDIO_SYNC=0`.
* Hotkeys and volume keys: Batocera 43 does not hardcode the gamepad hotkeys in RetroArch's config any more. `hotkey+start/a/b/x/y…` on a pad are turned into key codes by **evmapy** (`hotkeys.keys`), and **hotkeygen** (`S90hotkeygen`, started by default) maps those codes to actions for the running emulator, and also handles the volume/brightness/screenshot keys. Without that service the pad hotkey does nothing in games. hotkeygen reads every `/dev/input/event*` (it grabs nothing): inside a *window* it also reacts to your host keyboard's volume keys while your desktop does too.
* triggerhappy (power/Ctrl+Alt+F-keys) runs only in **drm** mode (`BD_TRIGGERHAPPY=auto`). `BD_VOLUME_KEYS=auto` adds volume keys to it only when hotkeygen is *not* started (two handlers would double the step); `BD_VOLUME_STEP` is that step.

## Updating Batocera
From ES (*Updates*) or `batocera-desktop update`: it is the original `batocera-upgrade`; it leaves `batocera.update`/`rufomaculata.update`/`boot.stale`, and the next session start applies them exactly like the initrd does. It can be done with the session running.

## Latency
Nested mode runs two compositors in series (Batocera's, then yours): expect about **one extra frame** versus bare metal. That is an estimate, not a measurement. For latency-sensitive games use **drm mode** (a text console, or the service): no host compositor is involved and the path is the same as on a real Batocera. Details and ways to measure: [`docs/ANALYSIS.md`](docs/ANALYSIS.md#5-latency).

## Uninstall
```bash
batocera-desktop uninstall      # software only: keeps /etc config, the Batocera image and your userdata
batocera-desktop purge          # EVERYTHING
```
`purge` removes: the program, the systemd unit, sudoers rule, menu entry, `/etc/batocera-desktop.conf`, the Batocera image directory (`BD_BOOT_DIR`), **your userdata (`BD_USERDATA`: roms, BIOS, saves, `batocera.conf`)**, logs, and the legacy `batocera-chroot` leftovers. It lists what it will delete with sizes and requires typing `DELETE` (or `--yes`). Safeguards: it refuses system directories (`/`, `/etc`, `/usr`, `/var`, `/home`, …), home directories, mount points, anything with active mounts below it (stop the session first), and identical boot/userdata paths. It works from the config's paths, so back up first if your roms live there. The same works from the source tree: `sudo ./install.sh --purge`.

## Tests
`sudo test/run-tests.sh` (root, `mksquashfs`, `busybox-static`): 58 checks with a fake Batocera. `sudo test/test-install.sh`: installer/uninstaller/purge (touches `/opt`, `/etc`, `/usr/local`: use a VM or container). If something fails on your machine: `batocera-desktop doctor`, `batocera-desktop logs`, `<userdata>/system/logs/display.log` and `batocera-desktop shell cat /var/log/labwc.log` while it runs. On Intel test with `BD_GPU=mesa` (or simply no nvidia module: auto).

## Known limits
Requires the x86-64-v3 image; no X11 sessions; unmeasured nested latency; the NVIDIA/audio/Bluetooth/systemd-service paths are untested on real hardware; Batocera's services run as root (keep `BD_USERDATA` root-owned, since `start` uses passwordless sudo). Full list: [`docs/ANALYSIS.md`](docs/ANALYSIS.md#7-known-risks-and-limits).

## License
GPL-3.0-or-later, like Batocera itself. See [`LICENSE`](LICENSE).
