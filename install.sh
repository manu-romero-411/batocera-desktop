#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# batocera-desktop installer / uninstaller
#
#   sudo ./install.sh --user YOUR_USER     install
#   sudo ./install.sh --uninstall          remove the software only (keeps config, image, userdata)
#   sudo ./install.sh --purge [--yes]      remove EVERYTHING: software, config, Batocera image,
#                                          userdata (roms, saves, bios!), logs, legacy scripts
#
# The installed copy is available as `batocera-desktop uninstall` / `batocera-desktop purge`.
set -eu

SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
DEST=/opt/batocera-desktop
CONF=/etc/batocera-desktop.conf
user=${SUDO_USER:-}
user_explicit=0
mode=install
assume_yes=0
ORIG_ARGS=("$@")

die() { echo "ERROR: $*" >&2; exit 1; }

while (($#)); do
    case $1 in
        --user)      user=${2:-}; user_explicit=1; shift 2 ;;
        --uninstall) mode=uninstall; shift ;;
        --purge)     mode=purge; shift ;;
        --yes|-y)    assume_yes=1; shift ;;
        -h|--help)   sed -n '2,10p' "$0"; exit 0 ;;
        *) die "usage: $0 --user USER | --uninstall | --purge [--yes]" ;;
    esac
done
[[ $EUID -eq 0 ]] || die "run with sudo"

# When running from the installed copy, re-exec from a temp file: we are about to delete ourselves.
if [[ $mode != install && $SRC == "$DEST" ]]; then
    tmp=$(mktemp /tmp/bd-uninstall.XXXXXX)
    cp -- "$SRC/uninstall.sh" "$tmp"
    exec bash "$tmp" "${ORIG_ARGS[@]}"
fi

remove_software() {
    # stop and disable the service
    systemctl disable --now batocera-desktop 2>/dev/null || true
    rm -rf "$DEST"
    rm -f /etc/systemd/system/batocera-desktop.service /etc/systemd/system/*.wants/batocera-desktop.service
    rm -rf /etc/systemd/system/batocera-desktop.service.d /var/lib/batocera-desktop   # leftovers of older versions
    [[ -d /run/systemd/system ]] && systemctl daemon-reload 2>/dev/null
    rm -f /usr/local/bin/batocera-desktop \
          /etc/sudoers.d/batocera-desktop \
          /usr/share/applications/batocera-desktop.desktop \
          /etc/modules-load.d/batocera-desktop.conf \
          /etc/udev/rules.d/99-batocera-hotkeygen.rules \
          /run/batocera-desktop.lock /run/batocera-desktop.action /run/batocera-desktop.vtkb
    rm -rf /run/batocera-desktop
    rm -f /tmp/bd-uninstall.*
}

# ------------------------------------------------------------------ uninstall
if [[ $mode == uninstall ]]; then
    remove_software
    echo "Uninstalled. Kept: $CONF, the Batocera image and your userdata."
    echo "Use '--purge' to remove those too."
    exit 0
fi

# ---------------------------------------------------------------------- purge
if [[ $mode == purge ]]; then
    BD_BOOT_DIR=/boot/batocera
    BD_USERDATA=/batocera
    if [[ -r $CONF ]]; then
        # read only the two paths, in a subshell, without trusting anything else in the file
        eval "$(
            # shellcheck disable=SC1090
            . "$CONF" >/dev/null 2>&1
            printf 'BD_BOOT_DIR=%q\nBD_USERDATA=%q\n' "${BD_BOOT_DIR:-/boot/batocera}" "${BD_USERDATA:-/batocera}"
        )"
    fi

    # Safety: never delete anything that is not a dedicated, non-system directory.
    check_dir() {  # check_dir PATH -> prints the resolved path or fails
        local p
        p=$(realpath -m -- "$1")
        case $p in
            /|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/usr/*|/etc/*|/proc/*|/sys/*|/dev/*)
                echo "refusing to delete system path: $p" >&2; return 1 ;;
        esac
        if [[ $p == /home/* && $p != /home/*/* ]]; then echo "refusing to delete a home directory: $p" >&2; return 1; fi
        if mountpoint -q -- "$p" 2>/dev/null; then
            echo "refusing: $p is a mount point (empty it by hand if you really want that)" >&2; return 1
        fi
        if grep -qs " $p/" /proc/mounts; then
            echo "refusing: something is mounted below $p (is a session still running?)" >&2; return 1
        fi
        printf '%s\n' "$p"
    }

    boot_dir=$(check_dir "$BD_BOOT_DIR") || exit 1
    data_dir=$(check_dir "$BD_USERDATA") || exit 1
    [[ $boot_dir != "$data_dir" ]] || die "boot dir and userdata point to the same path"

    legacy=()
    [[ -d /batocera/chroot_scripts ]] && legacy+=(/batocera/chroot_scripts)
    for h in /home/*; do
        [[ -f $h/.local/share/applications/batocera-chroot.desktop ]] && legacy+=("$h/.local/share/applications/batocera-chroot.desktop")
    done

    echo "PURGE: the following will be PERMANENTLY deleted:"
    echo "  software       $DEST, /usr/local/bin/batocera-desktop, systemd unit, sudoers rule, menu entry, modules-load.d file, udev rule"
    echo "  config         $CONF"
    echo "  Batocera image $boot_dir   ($(du -sh "$boot_dir" 2>/dev/null | cut -f1))"
    echo "  userdata       $data_dir   ($(du -sh "$data_dir" 2>/dev/null | cut -f1))  <-- roms, BIOS, SAVES, batocera.conf"
    echo "  logs           /var/log/batocera-desktop"
    for l in "${legacy[@]}"; do echo "  legacy         $l"; done
    echo
    if [[ $assume_yes -ne 1 ]]; then
        read -r -p "Type DELETE to continue: " ans
        [[ $ans == DELETE ]] || die "aborted, nothing was deleted"
    fi

    systemctl stop batocera-desktop 2>/dev/null || true
    # a session may have been mounted just now: re-check before deleting data
    if grep -qs -e " $boot_dir/" -e " $data_dir/" -e " /run/batocera-desktop/" /proc/mounts; then
        die "mounts still active under the data paths; aborting (nothing deleted)"
    fi
    remove_software
    rm -rf --one-file-system -- "${boot_dir:?}" "${data_dir:?}" /var/log/batocera-desktop "$CONF"
    for l in "${legacy[@]}"; do rm -rf -- "$l"; done
    echo "Purged. (Kernel modules uinput/uhid/joydev stay loaded until the next reboot; harmless.)"
    exit 0
fi

# -------------------------------------------------------------------- install
[[ -n $user && $user != root ]] || die "pass --user YOUR_USER"
[[ $user =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || die "invalid user name: '$user'"
id "$user" >/dev/null
for c in unshare chroot flock sudo xz visudo python3; do command -v "$c" >/dev/null || die "missing command: $c"; done

rm -rf "$DEST"; mkdir -p "$DEST"
cp -a "$SRC"/bin "$SRC"/lib "$SRC"/libexec "$SRC"/share "$DEST"/
install -m 0755 "$SRC/install.sh" "$DEST/uninstall.sh"
chown -R root:root "$DEST"; chmod -R go-w "$DEST"
if [[ -d /run/systemd/system ]]; then
    sed "s#@PREFIX@#$DEST#g" "$SRC/share/systemd/batocera-desktop.service" >/etc/systemd/system/batocera-desktop.service
    chmod 0644 /etc/systemd/system/batocera-desktop.service
    systemctl daemon-reload
else
    echo "NOTE: systemd not running; use 'batocera-desktop start --no-systemd'."
fi
ln -sfn "$DEST/bin/batocera-desktop" /usr/local/bin/batocera-desktop
[[ -e $CONF ]] || install -m 0644 -o root -g root "$SRC/etc/batocera-desktop.conf" "$CONF"

# set_conf KEY VALUE: set KEY=VALUE in the config: replace the active line, else the commented
# "#KEY=" example, else append. The file is sourced as root: only write validated values.
set_conf() {
    local k=$1 v=$2 t
    t=$(mktemp)
    if grep -q "^$k=" "$CONF"; then
        awk -v k="$k" -v v="$v" 'BEGIN{p="^" k "="} $0 ~ p && !d {print k "=" v; d=1; next} {print}' "$CONF" >"$t"
    elif grep -q "^#$k=" "$CONF"; then
        awk -v k="$k" -v v="$v" 'BEGIN{p="^#" k "="} $0 ~ p && !d {print k "=" v; d=1; next} {print}' "$CONF" >"$t"
    else
        { cat "$CONF"; printf '%s=%s\n' "$k" "$v"; } >"$t"
    fi
    install -m 0644 -o root -g root "$t" "$CONF"; rm -f "$t"
}
# BD_USER = the desktop user whose PipeWire gives the service its audio. An explicit --user always
# wins; a user taken from $SUDO_USER only fills it in when the config has no BD_USER yet.
if ((user_explicit)) || ! grep -q '^BD_USER=.' "$CONF"; then
    set_conf BD_USER "$user"
    echo "BD_USER=$user written to $CONF"
fi
install -m 0644 "$SRC/share/desktop/batocera-desktop.desktop" /usr/share/applications/batocera-desktop.desktop
install -m 0644 "$SRC/share/desktop/modules-load.conf" /etc/modules-load.d/batocera-desktop.conf
install -D -m 0644 "$SRC/share/udev/99-batocera-hotkeygen.rules" /etc/udev/rules.d/99-batocera-hotkeygen.rules
command -v udevadm >/dev/null && udevadm control --reload 2>/dev/null || true
modprobe -a uinput uhid joydev 2>/dev/null || true

tmp=$(mktemp)
cat >"$tmp" <<SUD
# batocera-desktop: start the session without a password. shell/update/install/purge DO ask for it.
$user ALL=(root) NOPASSWD: $DEST/libexec/bd-session launch *
SUD
visudo -cf "$tmp" >/dev/null
install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/batocera-desktop; rm -f "$tmp"

[[ -d /batocera/chroot_scripts ]] && echo "NOTE: old scripts remain in /batocera/chroot_scripts (no longer used; 'batocera-desktop purge' removes them)."
echo "Installed. Next steps:"
echo "  1) review $CONF"
echo "  2) batocera-desktop install --download   (if you have no x86-64-v3 image in the boot dir yet)"
echo "  3) batocera-desktop doctor"
echo "  4) batocera-desktop start        (inside Wayland: fullscreen window; on a text console: full screen; Ctrl+C ends it)"
echo "  5) optional service (drm on the first free console from tty8; audio from BD_USER=$(sed -n 's/^BD_USER=//p' "$CONF" | head -1)):"
echo "     sudo systemctl start batocera-desktop     /     sudo systemctl enable batocera-desktop"
