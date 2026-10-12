#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# batocera-desktop installer
#
#   sudo ./install.sh --user YOUR_USER [--variant v3|x86_64|5.26-amd64|5.26-i386]
#                                          (no --variant: asks, showing which ones fit this machine)
#
# To remove it, use ./uninstall.sh (the installed copy is `batocera-desktop uninstall|purge`).
set -eu

SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
DEST=/opt/batocera-desktop
CONF=/etc/batocera-desktop.conf
user=${SUDO_USER:-}
user_explicit=0
variant=""

# shellcheck source=lib/log.sh
. "$SRC/lib/log.sh"

while (($#)); do
    case $1 in
        --user)      user=${2:-}; user_explicit=1; shift 2 ;;
        --variant)   variant=${2:-}; shift 2 ;;
        --uninstall|--purge) die "removal moved to ./uninstall.sh: run 'sudo ./uninstall.sh $1'" ;;
        -h|--help)   sed -n '3,8p' "$0"; exit 0 ;;
        *) die "usage: $0 --user USER [--variant V]" ;;
    esac
done
[[ $EUID -eq 0 ]] || die "run with sudo"

# -------------------------------------------------------------------- install
[[ -n $user && $user != root ]] || die "pass --user YOUR_USER"
[[ $user =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || die "invalid user name: '$user'"
id "$user" >/dev/null
# Which Batocera build? Decided and VALIDATED before anything is copied: a wrong one is an error.
# shellcheck source=lib/bd-variants.sh
. "$SRC/lib/bd-variants.sh"
bd_hw_probe
if [[ -z $variant && -r $CONF ]]; then variant=$(sed -n 's/^BD_VARIANT=["'"'"']\?\([^"'"'"'#[:space:]]*\).*/\1/p' "$CONF" | tail -1); fi
if [[ -z $variant ]]; then
    [[ -t 0 ]] || die "no --variant given and no terminal to ask on. Valid: ${BD_VARIANTS[*]}. Run './install.sh --user $user --variant X' (see: batocera-desktop detect)"
    echo "This machine:"; bd_hw_report; echo
    echo "Which Batocera build do you want to use?"
    i=1; for v in "${BD_VARIANTS[@]}"; do
        if bd_variant_check "$v"; then m="OK "; else m="NO "; fi
        printf '  %d) [%s] %s\n' "$i" "$m" "$(bd_variant_label "$v")"; ((i++))
    done
    read -r -p "Number (1-${#BD_VARIANTS[@]}): " ans
    [[ $ans =~ ^[1-4]$ ]] || die "invalid choice"
    variant=${BD_VARIANTS[ans-1]}
fi
bd_variant_check "$variant" || die "variant '$variant' cannot be installed on this machine: $BD_WHY. Recommended here: $(bd_variant_recommend)"
log_info "Variant: $variant ($(bd_variant_label "$variant"))"
for c in unshare chroot flock sudo xz visudo python3; do command -v "$c" >/dev/null || die "missing command: $c"; done

rm -rf "$DEST"; mkdir -p "$DEST"
cp -a "$SRC"/bin "$SRC"/lib "$SRC"/libexec "$SRC"/share "$DEST"/
install -m 0755 "$SRC/uninstall.sh" "$DEST/uninstall.sh"
chown -R root:root "$DEST"; chmod -R go-w "$DEST"
if [[ -d /run/systemd/system ]]; then
    sed "s#@PREFIX@#$DEST#g" "$SRC/share/systemd/batocera-desktop.service" >/etc/systemd/system/batocera-desktop.service
    chmod 0644 /etc/systemd/system/batocera-desktop.service
    systemctl daemon-reload
else
    log_warn "systemd is not running: the service was not installed (manual start still works)"
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
    log_info "BD_USER=$user written to $CONF"
fi
set_conf BD_VARIANT "$variant"
log_info "BD_VARIANT=$variant written to $CONF"
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

[[ -d /batocera/chroot_scripts ]] && log_warn "old scripts remain in /batocera/chroot_scripts (no longer used; 'batocera-desktop purge' removes them)"
log_ok "Installed"
echo "Next steps:"
echo "  1) review $CONF"
case $variant in
    5.26-*) echo "  2) batocera-desktop install --variant $variant --img batocera-5.26-....img.gz   (or --file boot.tar.xz)" ;;
    *)      echo "  2) batocera-desktop install --variant $variant --download   (if the boot dir has no image yet)" ;;
esac
echo "  3) batocera-desktop doctor"
echo "  4) batocera-desktop start        (inside Wayland: fullscreen window; on a text console: full screen; Ctrl+C ends it)"
echo "  5) optional service (drm on the first free console from tty8; audio from BD_USER=$(sed -n 's/^BD_USER=//p' "$CONF" | head -1)):"
echo "     sudo systemctl start batocera-desktop     /     sudo systemctl enable batocera-desktop"
