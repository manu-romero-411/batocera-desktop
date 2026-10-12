#!/bin/bash

rootdir=$(realpath $(dirname $0))
. "$rootdir/scripts/env-vars"

function chroot_install(){
    sudo mkdir -p /batocera/chroot_scripts
    sudo cp "$rootdir/scripts"/* "$BATO_SCRIPTS"

    echo "[Desktop Entry]
    Version=1.0
    Type=Application
    Name=Retrobox Mini - Batocera
    Comment=
    Exec=nohup $BATO_SCRIPTS/batocera-chroot
    Icon=applications-games
    Path=
    Terminal=false
    StartupNotify=false
    Categories=Game;
    " > $HOME/.local/share/applications/batocera-chroot.desktop
}

case $1 in
    -i|--install) chroot_install;;
    *) echo "Uso: $0 [-i|--install]"; exit 1;;
esac

exit 0
