# shellcheck shell=bash disable=SC2034
# SPDX-License-Identifier: GPL-3.0-or-later
# bd-common.sh - shared helpers for batocera-desktop
# Sourced by libexec/bd-session.

# shellcheck source=bd-variants.sh
. "$(dirname "${BASH_SOURCE[0]}")/bd-variants.sh"

BD_CONF="${BD_CONF:-/etc/batocera-desktop.conf}"
BD_UNIT=batocera-desktop
BD_ACTION_FILE=/run/batocera-desktop.action
BD_LOGDIR=/var/log/batocera-desktop

bd_log()  { printf '[batocera-desktop +%ss] %s\n' "$SECONDS" "$*" >&2; }
bd_warn() { printf '[batocera-desktop] WARNING: %s\n' "$*" >&2; }
bd_die()  { printf '[batocera-desktop] ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ config
bd_load_config() {
    if [[ -e $BD_CONF ]]; then
        # the file is executed as root: it must not be writable by anyone else
        if [[ $EUID -eq 0 && -z ${BD_TEST:-} ]]; then
            local own perm
            own=$(stat -c %u "$BD_CONF"); perm=$(stat -c %a "$BD_CONF")
            [[ $own -eq 0 && ${perm: -1} != [2367] && ${perm: -2:1} != [2367] ]] \
                || bd_die "$BD_CONF must be owned by root and not writable by others"
        fi
        # shellcheck disable=SC1090
        . "$BD_CONF"
    fi
    : "${BD_VARIANT:=v3}"                   # v3 | x86_64 | 5.26-amd64 | 5.26-i386  (see lib/bd-variants.sh)
    bd_profile "$BD_VARIANT" || bd_die "unknown BD_VARIANT '$BD_VARIANT' in $BD_CONF (valid: ${BD_VARIANTS[*]})"
    : "${BD_BOOT_DIR:=/boot/batocera}"      # copy of the BATOCERA partition (contains boot/batocera)
    : "${BD_USERDATA:=/batocera}"           # becomes /userdata inside Batocera
    : "${BD_RUN:=/run/batocera-desktop}"
    : "${BD_OVERLAY_SIZE:=1G}"              # tmpfs for the writable rootfs layer (RAM only when used)
    : "${BD_TMP_SIZE:=2G}"
    : "${BD_EXTRA_BINDS:=}"                 # "src:dst[:ro] ..." e.g. "/games:/games"
    : "${BD_BIND_MEDIA:=1}"
    : "${BD_BIND_MODULES:=1}"
    : "${BD_BOARD:=$P_BOARD}"
    : "${BD_UPDATE_URL:=https://updates.batocera.org}"
    : "${BD_UPDATE_TYPE:=stable}"
    : "${BD_GPU:=auto}"                     # auto | nvidia | mesa
    : "${BD_AUDIO:=host}"                   # host | none
    : "${BD_BT:=host}"                      # host | exclusive | off
    : "${BD_SERVICES:=$P_SERVICES}"
    : "${BD_URL_526_AMD64:=}"               # download URLs for the 5.26 builds (a boot.tar.xz); empty = use --file/--img
    : "${BD_URL_526_I386:=}"
    : "${BD_ON_SHUTDOWN:=exit}"             # exit | host  (what "Shutdown" does in ES)
    : "${BD_PIDNS:=1}"
    : "${BD_WLR_RENDERER:=gles2}"
    : "${BD_LABWC_DEBUG:=1}"
    : "${BD_USER:=}"                        # service start: desktop user whose PipeWire provides the audio
    : "${BD_TTY_MIN:=8}"                    # service start: first VT to consider (tty1-6 = text consoles, tty7 = usually X11/lightdm)
    : "${BD_DRM_DEVICES:=}"                 # drm mode: cards for wlroots, e.g. /dev/dri/card1 (empty = Batocera decides)
    : "${BD_RESOLUTION:=1920x1080}"         # default size of the nested Batocera window
    : "${BD_FULLSCREEN:=auto}"              # nested: ask the host compositor for a fullscreen window (auto|1|0)
    : "${BD_HOST_WINDOW_CLASS:=wlroots}"    # app_id wlroots gives its nested window (used for host window rules)
    : "${BD_AUDIO_SYNC:=1}"                 # inherit the host's audio device/profile/volume at start
    : "${BD_TRIGGERHAPPY:=auto}"            # auto (drm only) | 1 | 0   - key daemon inside Batocera
    : "${BD_VOLUME_KEYS:=auto}"             # add volume/mute keys to triggerhappy: auto (only if hotkeygen is not started) | 1 | 0
    : "${BD_VOLUME_STEP:=5}"
    : "${BD_XKB_LAYOUT:=}"
    : "${BD_XKB_VARIANT:=}"
    : "${BD_NVIDIA_HOST_EGL_PLATFORM:=0}"   # 1 = also use the host's libnvidia-egl-*
    : "${BD_NVIDIA_VERSION_FILE:=/sys/module/nvidia/version}"
    : "${BD_X11_BUSID:=}"                   # X11 variants: pin Xorg to one GPU, "PCI:bus:dev:func" (hybrid machines)
    : "${BD_X11_DRIVER:=modesetting}"       # Xorg driver used with BD_X11_BUSID when the GPU is not NVIDIA
    : "${BD_START_TIMEOUT:=90}"
    BD_ROOT="$BD_RUN/root"
}

# ------------------------------------------------------- safe path resolution
# bd_rpath ROOT PATH -> prints the host path equivalent to PATH inside ROOT,
# resolving symlinks *inside* ROOT (an absolute symlink such as /var/run -> /run
# points to ROOT/run, never to the host's /run).
bd_rpath() {
    local root=$1 path=$2 cur="" comp link n=0
    local -a todo lt
    IFS=/ read -r -a todo <<<"${path#/}"
    while ((${#todo[@]})); do
        comp=${todo[0]}
        todo=("${todo[@]:1}")
        case $comp in
            ''|.) continue ;;
            ..)   if [[ $cur == */* ]]; then cur=${cur%/*}; else cur=""; fi; continue ;;
        esac
        if [[ -L $root${cur:+/$cur}/$comp ]]; then
            ((++n > 40)) && { bd_warn "too many symlinks resolving $path"; return 1; }
            link=$(readlink "$root${cur:+/$cur}/$comp")
            [[ $link == /* ]] && cur=""
            IFS=/ read -r -a lt <<<"${link#/}"
            todo=("${lt[@]}" "${todo[@]}")
        else
            cur="${cur:+$cur/}$comp"
        fi
    done
    printf '%s\n' "$root${cur:+/$cur}"
}

# bd_rleaf ROOT PATH -> like bd_rpath but the LAST component is taken literally
# (not followed if it is a symlink). Used to replace files/links: /sbin/reboot is
# a symlink to /bin/busybox and we must NOT write through it.
bd_rleaf() {
    local parent
    parent=$(bd_rpath "$1" "$(dirname -- "$2")") || return 1
    printf '%s\n' "$parent/$(basename -- "$2")"
}

# bd_mkdir PATH_IN_ROOT
bd_mkdir() { local p; p=$(bd_rpath "$BD_ROOT" "$1") && mkdir -p "$p"; }

# bd_bind SRC PATH_IN_ROOT [ro] [rec]
bd_bind() {
    local src=$1 dst
    dst=$(bd_rpath "$BD_ROOT" "$2") || return 1
    if [[ -d $src ]]; then
        mkdir -p "$dst"
    else
        mkdir -p "${dst%/*}"
        [[ -e $dst ]] || : >"$dst"
    fi
    if [[ ${4:-} == rec ]]; then mount --rbind "$src" "$dst" || return 1
    else mount --bind "$src" "$dst" || return 1; fi
    if [[ ${3:-} == ro ]]; then mount -o remount,bind,ro "$dst" || return 1; fi
}

# bd_put SRC PATH_IN_ROOT MODE : copy a file into the writable layer
bd_put() {
    local dst
    dst=$(bd_rleaf "$BD_ROOT" "$2") || return 1
    mkdir -p "${dst%/*}"
    rm -f -- "$dst"
    install -m "${3:-0755}" -- "$1" "$dst"
}

# bd_ln LINK_PATH_IN_ROOT TARGET : symlink (TARGET as the chroot will see it)
bd_ln() {
    local dst
    dst=$(bd_rleaf "$BD_ROOT" "$1") || return 1
    mkdir -p "${dst%/*}"
    ln -sfn -- "$2" "$dst"
}

# ------------------------------------------------- updates (what the initrd does)
# Reproduces package/batocera/boot/batocera-initramfs/init
bd_boot_apply_pending() {
    local b=$BD_BOOT_DIR img p
    [[ -d $b/boot ]] || return 0
    for img in batocera rufomaculata; do
        if [[ -e $b/boot/$img.update ]]; then
            bd_log "applying pending update: boot/$img.update"
            mv -f -- "$b/boot/$img.update" "$b/boot/$img" || bd_die "cannot replace boot/$img"
            # like the initrd: the saved overlay is discarded on update
            if [[ -e $b/boot/overlay ]]; then mv -f -- "$b/boot/overlay" "$b/boot/overlay.old"; fi
        fi
    done
    if [[ -f $b/boot.stale ]]; then
        while IFS= read -r p || [[ -n $p ]]; do
            case $p in ''|\#*|overlays/mipi-panel.dtbo) continue ;; esac
            case $p in
                /*|.|..|../*|*/..|*/../*|./*) bd_warn "unsafe 'stale' path ignored: $p"; continue ;;
            esac
            if [[ -e $b/$p || -L $b/$p ]]; then
                bd_log "removing stale file: $p"
                rm -rf -- "${b:?}/$p"
            fi
        done <"$b/boot.stale"
        rm -f -- "$b/boot.stale"
    fi
}

# X11 variants: Xorg must run on OUR vt. Wrap the server (see share/chroot/usr/bin/Xorg-shim).
bd_inject_xorg() {
  local l_xorg l_x l_xinit
  [[ -n ${BD_TTY:-} ]] && echo "${BD_TTY#/dev/tty}" >"$(bd_rpath "$BD_ROOT" /run)/bd-vt" || true

  # Shim /usr/bin/Xorg
  l_xorg=$(bd_rleaf "$BD_ROOT" /usr/bin/Xorg)
  if [[ -e $l_xorg || -L $l_xorg ]]; then
    if ! grep -qs bd-shim-xorg "$l_xorg" 2>/dev/null; then
      rm -f -- "$l_xorg.real"; cp -a -- "$l_xorg" "$l_xorg.real" || return 1
    fi
    bd_put "$BD_PREFIX/share/chroot/usr/bin/Xorg-shim" /usr/bin/Xorg 0755
  fi

  # Shim /usr/bin/X (Debian symlink to Xorg.wrap)
  l_x=$(bd_rleaf "$BD_ROOT" /usr/bin/X)
  if [[ -e $l_x || -L $l_x ]]; then
    if ! grep -qs bd-shim-xorg "$l_x" 2>/dev/null; then
      rm -f -- "$l_x.real"; cp -a -- "$l_x" "$l_x.real" || true
    fi
    bd_put "$BD_PREFIX/share/chroot/usr/bin/Xorg-shim" /usr/bin/X 0755
  fi

  # Shim /usr/bin/xinit (CRÍTICO: el padre xinit también debe saber que usamos :1)
  l_xinit=$(bd_rleaf "$BD_ROOT" /usr/bin/xinit)
  if [[ -e $l_xinit || -L $l_xinit ]]; then
    if ! grep -qs bd-shim-xinit "$l_xinit" 2>/dev/null; then
      rm -f -- "$l_xinit.real"; cp -a -- "$l_xinit" "$l_xinit.real" || true
    fi
    bd_put "$BD_PREFIX/share/chroot/usr/bin/xinit-shim" /usr/bin/xinit 0755
  fi
}

# 5.26 talks to ALSA directly. If the image has the ALSA->Pulse plugin, route it to the host's
# PulseAudio/PipeWire-Pulse socket (PULSE_SERVER) so it does not fight the host for the card.
bd_inject_alsa_pulse() {
    [[ $BD_AUDIO == host ]] || return 0
    local p
    p=$(bd_rpath "$BD_ROOT" /usr/lib/alsa-lib)
    if ls "$p"/libasound_module_pcm_pulse.so >/dev/null 2>&1; then
        printf 'pcm.!default { type pulse }\nctl.!default { type pulse }\n' >"$(bd_rleaf "$BD_ROOT" /etc/asound.conf)"
    else
        bd_warn "this ${BD_VARIANT} image has no ALSA pulse plugin: it will use ALSA directly and may fight the host for the sound card (set BD_AUDIO=none, or release the card on the host)"
    fi
}

# ------------------------------------------------------------------- GPU
# Detects the host NVIDIA driver. Sets NV_VER.
bd_nvidia_detect() {
    NV_VER=""
    if [[ -r $BD_NVIDIA_VERSION_FILE ]]; then
        NV_VER=$(<"$BD_NVIDIA_VERSION_FILE")
        NV_VER=${NV_VER//[[:space:]]/}
    fi
    [[ -n $NV_VER ]]
}

# Finds the host driver *userspace* libraries matching the kernel module
# version. Sets NV_LINK[name]=real_path
bd_nvidia_collect() {
    declare -gA NV_LINK=()
    local -a dirs=()
    local line f real d base
    local re='^lib(GLX_nvidia|EGL_nvidia|GLESv1_CM_nvidia|GLESv2_nvidia|vdpau_nvidia|nvidia-[A-Za-z0-9_-]+|cuda|nvcuvid)\.so(\..+)?$'
    while IFS= read -r line; do
        f=${line##*=> }
        [[ -e $f ]] || continue
        dirs+=("$(dirname -- "$(readlink -f -- "$f")")" "$(dirname -- "$f")")
    done < <(${BD_LDCONFIG_P:-ldconfig -p} 2>/dev/null | grep -E 'lib(GLX|EGL)_nvidia\.so\.0|libnvidia-glcore|libnvidia-allocator|libcuda\.so\.1')
    dirs+=(/usr/lib/x86_64-linux-gnu/nvidia/current /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib/nvidia/current)
    while IFS= read -r d; do
        [[ -d $d ]] || continue
        for f in "$d"/lib*nvidia* "$d"/libcuda.so* "$d"/libnvcuvid.so*; do
            [[ -e $f ]] || continue
            base=${f##*/}
            [[ $base =~ $re ]] || continue
            real=$(readlink -f -- "$f") || continue
            if [[ $base == libnvidia-egl-* ]]; then
                [[ $BD_NVIDIA_HOST_EGL_PLATFORM == 1 ]] || continue
            else
                [[ ${real##*/} == *".so.$NV_VER" ]] || continue
            fi
            NV_LINK[$base]=$real
        done
    done < <(printf '%s\n' "${dirs[@]}" | sort -u)
    ((${#NV_LINK[@]} > 0))
}

# DRI render node whose PCI driver is $1 (e.g. nvidia)
bd_render_node() {
    local n drv
    for n in /sys/class/drm/renderD*; do
        [[ -e $n/device/driver ]] || continue
        drv=$(basename "$(readlink -f "$n/device/driver")")
        [[ $drv == "$1" ]] && { printf '/dev/dri/%s\n' "${n##*/}"; return 0; }
    done
    return 1
}

# Exposes the host libs in the chroot (/run/bd-nvidia) WITHOUT copying them:
# the host directories are bind-mounted read-only and symlinks are created.
# Needs NV_VER/NV_LINK (bd_nvidia_collect) and the chroot's /run already mounted.
bd_nvidia_stage() {
    local S base real dir i=0 L g icd
    local -a dirs=()
    local -A idxof=()
    S=$(bd_rpath "$BD_ROOT" /run/bd-nvidia) || return 1
    mkdir -p "$S/lib64"
    for base in "${!NV_LINK[@]}"; do
        real=${NV_LINK[$base]}; dir=${real%/*}
        if [[ -z ${idxof[$dir]:-} ]]; then
            idxof[$dir]=$i; dirs+=("$dir")
            mkdir -p "$S/host/$i"
            mount --bind "$dir" "$S/host/$i" && mount -o remount,bind,ro "$S/host/$i" \
                || { bd_warn "cannot mount $dir"; return 1; }
            ((++i))
        fi
        ln -sfn "/run/bd-nvidia/host/${idxof[$dir]}/${real##*/}" "$S/lib64/$base"
    done
    # Link into /usr/lib (writable layer) like batocera-nvidia does with its own libs:
    # soname + versioned name -> ldconfig registers them and glvnd/Vulkan find them.
    L=$(bd_rpath "$BD_ROOT" /usr/lib) || return 1
    mkdir -p "$L"
    for base in "${!NV_LINK[@]}"; do
        if [[ $base == *".so.$NV_VER" ]]; then
            ln -sfn "/run/bd-nvidia/lib64/$base" "$L/$base"
        elif [[ ! -e $L/$base && ! -L $L/$base ]]; then
            ln -s "/run/bd-nvidia/lib64/$base" "$L/$base"
        fi
    done
    # GBM: libgbm looks for <driver>_gbm.so ; for nvidia-drm that is nvidia-drm_gbm.so
    g=libnvidia-allocator.so.1
    [[ -n ${NV_LINK[$g]:-} ]] || g="libnvidia-allocator.so.$NV_VER"
    bd_mkdir /usr/lib/gbm
    bd_ln /usr/lib/gbm/nvidia-drm_gbm.so "/run/bd-nvidia/lib64/$g"
    # EGL vendor (glvnd): NVIDIA only, so there is no silent fallback to llvmpipe
    cat >"$S/10_nvidia.json" <<'EOF'
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libEGL_nvidia.so.0"
    }
}
EOF
    # Vulkan ICD: the host's JSON (correct api_version) with library_path by soname
    icd=""
    for f in /usr/share/vulkan/icd.d/nvidia_icd.json /etc/vulkan/icd.d/nvidia_icd.json \
             /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json; do
        [[ -r $f ]] && { icd=$f; break; }
    done
    if [[ -n $icd ]]; then
        sed -E 's#("library_path"[[:space:]]*:[[:space:]]*)"[^"]*"#\1"libGLX_nvidia.so.0"#' "$icd" >"$S/nvidia_icd.json"
    else
        bd_warn "nvidia_icd.json not found on the host; generating a minimal one"
        printf '{"file_format_version":"1.0.0","ICD":{"library_path":"libGLX_nvidia.so.0","api_version":"1.3.0"}}\n' >"$S/nvidia_icd.json"
    fi
    if [[ -d $(bd_rpath "$BD_ROOT" /usr/share/vulkan/icd.d) ]]; then
        bd_ln /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json /run/bd-nvidia/nvidia_icd.json
    fi
    return 0
}

# ------------------------------------------------------------ X11 builds: GPU setup
# Intel / AMD (and anything with an open driver): nothing to do. The image's own Xorg modules
# (modesetting, amdgpu, radeon, ...) and Mesa drive the GPU through the host kernel's DRM driver.
# NVIDIA proprietary: Xorg needs the HOST driver's nvidia_drv.so and libglxserver_nvidia.so (they must
# match the loaded kernel module, as the GL libraries do), plus a Device section that selects them.

# 0000:01:00.0 -> PCI:1:0:0 (decimal, as xorg.conf wants it)
bd_pci_busid() {
    local n=${1##*/}
    [[ $n =~ ^[0-9a-fA-F]{4}:([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-7])$ ]] || return 1
    printf 'PCI:%d:%d:%d\n' "$((16#${BASH_REMATCH[1]}))" "$((16#${BASH_REMATCH[2]}))" "${BASH_REMATCH[3]}"
}

# BusID of the first display controller bound to the nvidia kernel driver
bd_nvidia_busid() {
    local d
    for d in "${BD_PCI_ROOT:-/sys/bus/pci/devices}"/*; do
        [[ -L $d/driver && -r $d/class ]] || continue
        [[ $(<"$d/class") == 0x03* && $(basename "$(readlink "$d/driver")") == nvidia ]] || continue
        bd_pci_busid "$d" && return 0
    done
    return 1
}

# Finds the host's X driver + GLX server module. Sets NV_XDRV and NV_XGLX (real paths).
bd_nvidia_xcollect() {
    NV_XDRV=""; NV_XGLX=""
    local d f real
    local -a dirs
    if [[ -n ${BD_NVIDIA_XDIRS:-} ]]; then read -r -a dirs <<<"$BD_NVIDIA_XDIRS"
    else dirs=(/usr/lib/x86_64-linux-gnu/nvidia/xorg /usr/lib/x86_64-linux-gnu/nvidia/current /usr/lib/nvidia/xorg
               /usr/lib64/nvidia/xorg /usr/lib/xorg/modules/drivers /usr/lib/xorg/modules/extensions
               /usr/lib64/xorg/modules/drivers /usr/lib64/xorg/modules/extensions /usr/lib/x86_64-linux-gnu/xorg/extra-modules); fi
    for d in "${dirs[@]}"; do
        [[ -d $d ]] || continue
        [[ -z $NV_XDRV && -e $d/nvidia_drv.so ]] && NV_XDRV=$(readlink -f -- "$d/nvidia_drv.so")
        if [[ -z $NV_XGLX ]]; then
            for f in "$d/libglxserver_nvidia.so.$NV_VER" "$d/libglxserver_nvidia.so"; do
                [[ -e $f ]] || continue
                real=$(readlink -f -- "$f")
                [[ $real == *".so.$NV_VER" ]] && { NV_XGLX=$real; break; }
            done
        fi
    done
    [[ -n $NV_XDRV && -n $NV_XGLX ]]
}

# Exposes them in the chroot as /run/bd-nvidia/xorg/{nvidia_drv.so,libglxserver_nvidia.so}
# (host directories bind-mounted read-only, symlinks on top: nothing is copied).
bd_nvidia_xstage() {
    local S x i=0 dir f name
    S=$(bd_rpath "$BD_ROOT" /run/bd-nvidia) || return 1
    mkdir -p "$S/xorg"
    for f in "$NV_XDRV:nvidia_drv.so" "$NV_XGLX:libglxserver_nvidia.so"; do
        x=${f%%:*}; name=${f##*:}; dir=${x%/*}
        mkdir -p "$S/xhost/$i"
        mount --bind "$dir" "$S/xhost/$i" && mount -o remount,bind,ro "$S/xhost/$i" \
            || { bd_warn "cannot mount $dir"; return 1; }
        ln -sfn "/run/bd-nvidia/xhost/$i/${x##*/}" "$S/xorg/$name"
        ((++i))
    done
}

# Writes the xorg.conf.d snippet for this machine to $1 (path of the file, already resolved).
# $2 = the image's own Xorg module directory as seen inside the chroot.
bd_x11_gpu_conf() {
    local out=$1 moddir=${2:-/usr/lib/xorg/modules} drv bus=${BD_X11_BUSID:-}
    if [[ ${BD_GPU_MODE:-mesa} == nvidia ]]; then
        drv=nvidia
        [[ -n $bus ]] || bus=$(bd_nvidia_busid) || bus=""
    elif [[ -n $bus ]]; then
        drv=$BD_X11_DRIVER
    else
        return 0      # Intel / AMD / anything open: let Xorg autodetect with the image's own drivers
    fi
    [[ -z $bus || $bus =~ ^PCI:[0-9]+:[0-9]+:[0-9]+$ ]] || { bd_warn "BD_X11_BUSID '$bus' is not PCI:bus:dev:func: ignored"; bus=""; }
    [[ $drv =~ ^[A-Za-z0-9_]+$ ]] || { bd_warn "invalid BD_X11_DRIVER '$drv'"; return 1; }
    mkdir -p "$(dirname "$out")"
    {
        echo "# generated by batocera-desktop on every start"
        if [[ $drv == nvidia ]]; then
            printf 'Section "Files"\n    ModulePath "/run/bd-nvidia/xorg"\n    ModulePath "%s"\nEndSection\n\n' "$moddir"
        fi
        printf 'Section "Device"\n    Identifier "bd-gpu"\n    Driver "%s"\n' "$drv"
        [[ -n $bus ]] && printf '    BusID "%s"\n' "$bus"
        [[ $drv == nvidia ]] && printf '    Option "AllowEmptyInitialConfiguration" "true"\n'
        printf 'EndSection\n'
    } >"$out"
}

# --------------------------------------------------------------- utilities
bd_chroot_proc() {   # is there a process with that comm inside the chroot?
local p c r alts name=${1:0:15}
# X11: nuestro shim hace exec Xorg.real, asi que el comm del kernel nunca es
# "Xorg"; Debian ademas tiene Xorg.wrap. Aceptamos todos los nombres posibles.
alts=" $name "
[[ $name == Xorg ]] && alts=" Xorg Xorg.real Xorg.wrap Xorg.wrap.real X "
for p in "$BD_ROOT"/proc/[0-9]*; do
[[ -r $p/comm ]] || continue
read -r c <"$p/comm" 2>/dev/null || continue
[[ $alts == *" $c "* ]] || continue
r=$(readlink "$p/root" 2>/dev/null) || continue
[[ $r == "$BD_ROOT" ]] && return 0
done
return 1
}

bd_kill_chroot_procs() {   # signal
    local p r
    for p in "$BD_ROOT"/proc/[0-9]*; do
        r=$(readlink "$p/root" 2>/dev/null) || continue
        [[ $r == "$BD_ROOT" ]] || continue
        kill "-$1" "${p##*/}" 2>/dev/null
    done
}

# ------------------------------------------------------- session / VT helpers
BD_LOCK_FILE=/run/batocera-desktop.lock

bd_have_systemd() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1 \
        && systemctl cat "$BD_UNIT.service" >/dev/null 2>&1
}

# bd_running -> 0 if a session holds the lock (manual or service). Needs root.
bd_running() { ! ( exec 9>>"$BD_LOCK_FILE"; flock -n 9 ) 2>/dev/null; }

# Number of the active VT (empty if unknown)
bd_active_vt() {
    local a
    a=$(cat /sys/class/tty/tty0/active 2>/dev/null) || return 1
    [[ $a =~ ^tty([1-9][0-9]*)$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

# bd_free_vt MIN -> prints the first VT number >= MIN that is really free:
# a character device, no logind session on it, and no process holding it open.
bd_free_vt() {
    local min=${1:-8} n sess=" " sid vtnr l
    if command -v loginctl >/dev/null 2>&1; then
        while read -r sid _; do
            [[ $sid =~ ^[A-Za-z0-9]+$ ]] || continue
            vtnr=$(loginctl show-session "$sid" -p VTNr --value 2>/dev/null)
            [[ $vtnr =~ ^[0-9]+$ ]] && sess+="$vtnr "
        done < <(loginctl list-sessions --no-legend 2>/dev/null)
    fi
    # ONE find over every /proc/PID/fd. (A readlink in a subshell per descriptor costs ~1.4 ms
    # each: thousands of descriptors on a desktop = several seconds at every service start.)
    local held=" "
    while IFS= read -r l; do
        [[ $l =~ ^/dev/tty([1-9][0-9]*)$ ]] && held+="${BASH_REMATCH[1]} "
    done < <(find /proc/[0-9]*/fd -maxdepth 1 -type l -lname '/dev/tty[0-9]*' -printf '%l\n' 2>/dev/null)
    for ((n = min; n <= 63; n++)); do
        [[ -c /dev/tty$n ]] || continue
        [[ $sess == *" $n "* || $held == *" $n "* ]] && continue
        printf '%s\n' "$n"; return 0
    done
    return 1
}

# While a service session owns VT N, stop logind from starting a getty on it (runtime mask).
bd_reserve_vt() { bd_have_systemd && systemctl mask --runtime "getty@tty$1.service" >/dev/null 2>&1; return 0; }
bd_release_vt() { bd_have_systemd && systemctl unmask --runtime "getty@tty$1.service" >/dev/null 2>&1; return 0; }

# Desktop user for audio when nobody started us from their own session (service start):
# BD_USER, else the lowest regular user that has a runtime dir (logged in), else uid 1000.
bd_default_user() {
    local d u
    if [[ -n $BD_USER ]]; then printf '%s\n' "$BD_USER"; return 0; fi
    for d in $(find /run/user -mindepth 1 -maxdepth 1 -type d -regex '/run/user/[0-9]+' 2>/dev/null | sort -t/ -k4 -n); do
        u=${d##*/}
        [[ $u -ge 1000 ]] && { id -nu "$u" 2>/dev/null && return 0; }
    done
    getent passwd 1000 | cut -d: -f1 | grep . 
}

# Makes sure the user's runtime dir and PipeWire-Pulse socket exist (service start, maybe no login).
bd_ensure_user_runtime() {
    local uid=$1 i started=0
    if [[ ! -d /run/user/$uid ]]; then
        command -v systemctl >/dev/null 2>&1 && systemctl start "user@$uid.service" 2>/dev/null && started=1
        for i in $(seq 50); do [[ -d /run/user/$uid ]] && break; sleep 0.2; done
    fi
    [[ -d /run/user/$uid ]] || return 1
    # pipewire-pulse is socket-activated by the user manager: it needs a moment only if we just started it
    if ((started)); then
        for i in $(seq 25); do [[ -S /run/user/$uid/pulse/native ]] && break; sleep 0.2; done
    fi
    return 0
}

# bd_find_service NAME -> the init script to run. Batocera renumbers some services between
# releases (hotkeygen is S90 in 43.1, S30 later), so if S90hotkeygen does not exist any
# S??hotkeygen is used instead.
bd_find_service() {
    local s=$1 d f
    d=$(bd_rpath "$BD_ROOT" /etc/init.d)
    if [[ ! -x $d/$s && $s =~ ^S[0-9][0-9](.+)$ ]]; then
        for f in "$d"/S[0-9][0-9]"${BASH_REMATCH[1]}"; do
            [[ -x $f ]] && { printf '%s\n' "${f##*/}"; return 0; }
        done
    fi
    printf '%s\n' "$s"
}

# Services to start, honouring BD_TRIGGERHAPPY (auto = drm mode only).
bd_service_list() {
    local s
    for s in $BD_SERVICES; do
        if [[ $s == S50triggerhappy ]]; then
            case $BD_TRIGGERHAPPY in
                0) continue ;;
                auto) [[ ${BD_MODE:-nested} == drm ]] || continue ;;
            esac
        fi
        printf '%s\n' "$s"
    done
}
