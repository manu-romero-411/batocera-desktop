#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# batocera-desktop uninstaller
#
#   sudo ./uninstall.sh [--uninstall]      remove the software only (keeps config, image, userdata)
#   sudo ./uninstall.sh --purge [--yes]    remove EVERYTHING: software, config, Batocera image,
#                                          userdata (roms, saves, bios!), logs, legacy scripts
#
# The installed copy is what `batocera-desktop uninstall` / `batocera-desktop purge` run.
set -eu

SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
DEST=/opt/batocera-desktop
CONF=/etc/batocera-desktop.conf
mode=uninstall
assume_yes=0

# shellcheck source=lib/log.sh
. "$SRC/lib/log.sh"

while (($#)); do
    case $1 in
        --uninstall) mode=uninstall; shift ;;
        --purge)     mode=purge; shift ;;
        --yes|-y)    assume_yes=1; shift ;;
        -h|--help)   sed -n '3,8p' "$0"; exit 0 ;;
        *) die "usage: $0 [--uninstall | --purge [--yes]]" ;;
    esac
done
[[ $EUID -eq 0 ]] || exec sudo -- "$SRC/uninstall.sh" "$@"

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
}

# ------------------------------------------------------------------ uninstall
if [[ $mode == uninstall ]]; then
    remove_software
    log_ok "Uninstalled (kept: $CONF, the Batocera image and your userdata)"
    log_info "Use '--purge' to remove those too"
    exit 0
fi

# ---------------------------------------------------------------------- purge
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
            log_err "refusing to delete system path: $p"; return 1 ;;
    esac
    if [[ $p == /home/* && $p != /home/*/* ]]; then
        log_err "refusing to delete a home directory: $p"; return 1
    fi
    if mountpoint -q -- "$p" 2>/dev/null; then
        log_err "refusing: $p is a mount point (empty it by hand if you really want that)"; return 1
    fi
    if grep -qs " $p/" /proc/mounts; then
        log_err "refusing: something is mounted below $p (is a session still running?)"; return 1
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

log_warn "PURGE: the following will be PERMANENTLY deleted:"
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
log_ok "Purged"
log_info "Kernel modules uinput/uhid/joydev stay loaded until the next reboot (harmless)"
