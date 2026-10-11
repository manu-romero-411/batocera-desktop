#!/usr/bin/env bash
# Instalador de batocera-desktop.  sudo ./install.sh --user TU_USUARIO     |   sudo ./install.sh --uninstall
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
DEST=/opt/batocera-desktop
user=${SUDO_USER:-}
mode=install
while (($#)); do case $1 in --user) user=$2; shift 2;; --uninstall) mode=uninstall; shift;; *) echo "uso: $0 --user USUARIO | --uninstall"; exit 1;; esac; done
[[ $EUID -eq 0 ]] || { echo "Ejecuta con sudo"; exit 1; }

if [[ $mode == uninstall ]]; then
    systemctl stop batocera-desktop 2>/dev/null || true
    rm -rf "$DEST" /usr/local/bin/batocera-desktop /etc/sudoers.d/batocera-desktop \
           /usr/share/applications/batocera-desktop.desktop /etc/modules-load.d/batocera-desktop.conf
    echo "Desinstalado (se conservan /etc/batocera-desktop.conf, tu boot dir y userdata)."; exit 0
fi

[[ -n $user && $user != root ]] || { echo "Indica --user TU_USUARIO"; exit 1; }
id "$user" >/dev/null
for c in unshare chroot systemd-run flock sudo xz; do command -v "$c" >/dev/null || { echo "falta $c"; exit 1; }; done

rm -rf "$DEST"; mkdir -p "$DEST"
cp -a "$SRC"/bin "$SRC"/lib "$SRC"/libexec "$SRC"/share "$DEST"/
chown -R root:root "$DEST"; chmod -R go-w "$DEST"
ln -sfn "$DEST/bin/batocera-desktop" /usr/local/bin/batocera-desktop
[[ -e /etc/batocera-desktop.conf ]] || install -m 0644 -o root -g root "$SRC/etc/batocera-desktop.conf" /etc/batocera-desktop.conf
install -m 0644 "$SRC/share/desktop/batocera-desktop.desktop" /usr/share/applications/batocera-desktop.desktop
install -m 0644 "$SRC/share/desktop/modules-load.conf" /etc/modules-load.d/batocera-desktop.conf
modprobe -a uinput uhid joydev 2>/dev/null || true

tmp=$(mktemp)
cat >"$tmp" <<SUD
# batocera-desktop: arrancar/parar la sesión sin contraseña. 'shell/update/install' SÍ piden contraseña.
$user ALL=(root) NOPASSWD: $DEST/libexec/bd-session launch *, $DEST/libexec/bd-session stop
SUD
visudo -cf "$tmp" >/dev/null
install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/batocera-desktop; rm -f "$tmp"

[[ -d /batocera/chroot_scripts ]] && echo "AVISO: quedan los scripts antiguos en /batocera/chroot_scripts (ya no se usan; puedes borrarlos)."
echo "Instalado. Siguientes pasos:"
echo "  1) revisa /etc/batocera-desktop.conf"
echo "  2) batocera-desktop install --download   (si aún no tienes imagen x86-64-v3 en el boot dir)"
echo "  3) batocera-desktop doctor"
echo "  4) batocera-desktop start"
