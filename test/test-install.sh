#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Installer tests: install, uninstall (keeps data), purge (deletes everything, refuses dangerous paths).
# Needs root; touches /opt/batocera-desktop, /etc/batocera-desktop.conf, /usr/local/bin ... (a sandbox/VM is best).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PFX=$(dirname "$HERE")
pass=0; fail=0
ok(){ echo "  PASS $1"; ((pass++)); }; ko(){ echo "  FAIL $1"; ((fail++)); }
t(){ if eval "$2"; then ok "$1"; else ko "$1"; fi; }
T=$(mktemp -d /tmp/bdinst.XXXXXX)
id nobody >/dev/null || exit 2
[ -e /etc/batocera-desktop.conf ] && { echo "refusing: /etc/batocera-desktop.conf exists (real install?)"; exit 2; }

echo "== install"
bash "$PFX/install.sh" --user nobody >/dev/null 2>&1
t "software installed" "[ -x /opt/batocera-desktop/libexec/bd-session ] && [ -x /usr/local/bin/batocera-desktop ]"
t "installed uninstaller present" "[ -x /opt/batocera-desktop/uninstall.sh ]"
t "sudoers rule installed and limited" "grep -q 'bd-session launch \*$' /etc/sudoers.d/batocera-desktop"
t "config installed" "[ -f /etc/batocera-desktop.conf ]"
t "BD_USER set from --user" "[ \"\$(grep -c '^BD_USER=nobody\$' /etc/batocera-desktop.conf)\" = 1 ] && ! grep -q '^#BD_USER=' /etc/batocera-desktop.conf"
t "udev rule for hotkeygen installed" "[ -f /etc/udev/rules.d/99-batocera-hotkeygen.rules ]"
bash "$PFX/install.sh" --user daemon >/dev/null 2>&1
t "reinstall with another --user updates BD_USER (single line, rest kept)" "[ \"\$(grep -c '^BD_USER=' /etc/batocera-desktop.conf)\" = 1 ] && grep -q '^BD_USER=daemon\$' /etc/batocera-desktop.conf && grep -q '^BD_TTY_MIN\|^#BD_TTY_MIN=8' /etc/batocera-desktop.conf"
(unset SUDO_USER; bash "$PFX/install.sh" --user nobody >/dev/null 2>&1)
t "invalid user name is refused" "! bash \"$PFX/install.sh\" --user 'x;y' >/dev/null 2>&1 && grep -q '^BD_USER=nobody\$' /etc/batocera-desktop.conf"
if [ -d /run/systemd/system ]; then t "systemd unit installed" "[ -f /etc/systemd/system/batocera-desktop.service ]"; fi
t "CLI help works" "batocera-desktop help | grep -q purge"

echo "== uninstall keeps config and data"
mkdir -p $T/boot/boot $T/data/roms; echo img > $T/boot/boot/batocera; echo save > $T/data/roms/save1
printf 'BD_BOOT_DIR=%s\nBD_USERDATA=%s\n' $T/boot $T/data > /etc/batocera-desktop.conf
bash /opt/batocera-desktop/uninstall.sh --uninstall >/dev/null 2>&1
t "software gone" "[ ! -e /opt/batocera-desktop ] && [ ! -e /usr/local/bin/batocera-desktop ] && [ ! -e /etc/sudoers.d/batocera-desktop ] && [ ! -e /etc/udev/rules.d/99-batocera-hotkeygen.rules ]"
t "config, image and userdata kept" "[ -f /etc/batocera-desktop.conf ] && [ -f $T/boot/boot/batocera ] && [ -f $T/data/roms/save1 ]"

echo "== purge"
bash "$PFX/install.sh" --user nobody >/dev/null 2>&1
printf 'BD_BOOT_DIR=%s\nBD_USERDATA=%s\n' $T/boot $T/data > /etc/batocera-desktop.conf
mkdir -p /var/log/batocera-desktop; touch /var/log/batocera-desktop/x.log
t "wrong confirmation aborts, nothing deleted" "! (echo nope | bash /opt/batocera-desktop/uninstall.sh --purge >/dev/null 2>&1) && [ -f $T/data/roms/save1 ] && [ -d /opt/batocera-desktop ]"
echo DELETE | bash /opt/batocera-desktop/uninstall.sh --purge >/dev/null 2>&1
t "purge removes software, config, image, userdata, logs" "[ ! -e /opt/batocera-desktop ] && [ ! -e /etc/batocera-desktop.conf ] && [ ! -e $T/boot ] && [ ! -e $T/data ] && [ ! -e /var/log/batocera-desktop ]"

echo "== purge safety"
bash "$PFX/install.sh" --user nobody >/dev/null 2>&1
for bad in / /etc /usr /home /var /root /boot; do
    printf 'BD_BOOT_DIR=%s\nBD_USERDATA=%s/x\n' "$bad" $T > /etc/batocera-desktop.conf
    t "refuses BD_BOOT_DIR=$bad" "! bash /opt/batocera-desktop/uninstall.sh --purge --yes >/dev/null 2>&1 && [ -d /etc ] && [ -d /usr ]"
done
mkdir -p $T/mnt $T/same; mount --bind $T/mnt $T/mnt 2>/dev/null
if mountpoint -q $T/mnt; then
    printf 'BD_BOOT_DIR=%s\nBD_USERDATA=%s\n' $T/mnt $T/same > /etc/batocera-desktop.conf
    t "refuses a mount point" "! bash /opt/batocera-desktop/uninstall.sh --purge --yes >/dev/null 2>&1"
    umount $T/mnt
fi
printf 'BD_BOOT_DIR=%s\nBD_USERDATA=%s\n' $T/same $T/same > /etc/batocera-desktop.conf
t "refuses identical boot dir and userdata" "! bash /opt/batocera-desktop/uninstall.sh --purge --yes >/dev/null 2>&1"
bash /opt/batocera-desktop/uninstall.sh --uninstall >/dev/null 2>&1; rm -f /etc/batocera-desktop.conf; rm -rf "$T"
echo; echo "Result: $pass OK, $fail FAILURES"; [ $fail -eq 0 ]
