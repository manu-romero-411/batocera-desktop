# shellcheck shell=bash
# bd-common.sh - funciones compartidas de batocera-desktop
# Se hace `source` desde libexec/bd-session y bin/batocera-desktop.

BD_CONF="${BD_CONF:-/etc/batocera-desktop.conf}"
BD_UNIT=batocera-desktop
BD_ACTION_FILE=/run/batocera-desktop.action
BD_LOGDIR=/var/log/batocera-desktop

bd_log()  { printf '[batocera-desktop] %s\n' "$*" >&2; }
bd_warn() { printf '[batocera-desktop] AVISO: %s\n' "$*" >&2; }
bd_die()  { printf '[batocera-desktop] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- config
bd_load_config() {
    if [[ -e $BD_CONF ]]; then
        # el fichero se ejecuta como root: exigir que no lo pueda escribir nadie más
        if [[ $EUID -eq 0 && -z ${BD_TEST:-} ]]; then
            local own perm
            own=$(stat -c %u "$BD_CONF"); perm=$(stat -c %a "$BD_CONF")
            [[ $own -eq 0 && ${perm: -1} != [2367] && ${perm: -2:1} != [2367] ]] \
                || bd_die "$BD_CONF debe ser de root y no escribible por otros"
        fi
        # shellcheck disable=SC1090
        . "$BD_CONF"
    fi
    : "${BD_BOOT_DIR:=/boot/batocera}"      # copia de la partición BATOCERA (contiene boot/batocera)
    : "${BD_USERDATA:=/batocera}"           # será /userdata dentro de Batocera
    : "${BD_RUN:=/run/batocera-desktop}"
    : "${BD_OVERLAY_SIZE:=1G}"              # tmpfs de la capa escribible del rootfs (RAM solo si se usa)
    : "${BD_TMP_SIZE:=2G}"
    : "${BD_EXTRA_BINDS:=}"                 # "origen:destino[:ro] ..." p.ej. "/pcgrande:/pcgrande"
    : "${BD_BIND_MEDIA:=1}"
    : "${BD_BIND_MODULES:=1}"
    : "${BD_BOARD:=x86-64-v3}"
    : "${BD_UPDATE_URL:=https://updates.batocera.org}"
    : "${BD_UPDATE_TYPE:=stable}"
    : "${BD_GPU:=auto}"                     # auto | nvidia | mesa
    : "${BD_AUDIO:=host}"                   # host | none
    : "${BD_BT:=host}"                      # host | exclusive | off
    : "${BD_SERVICES:=S12populateshare S50triggerhappy S97joycond S31emulationstation S99userservices}"
    : "${BD_ON_SHUTDOWN:=exit}"             # exit | host  (qué hace "Apagar" en ES)
    : "${BD_PIDNS:=1}"
    : "${BD_WLR_RENDERER:=gles2}"
    : "${BD_DRM_DEVICES:=}"                    # modo drm: tarjetas para wlroots, p.ej. /dev/dri/card1 (vacío = Batocera decide)
    : "${BD_RESOLUTION:=1920x1080}"          # tamaño por defecto de la ventana de Batocera (anidado)
    : "${BD_LABWC_DEBUG:=1}"
    : "${BD_XKB_LAYOUT:=}"
    : "${BD_XKB_VARIANT:=}"
    : "${BD_NVIDIA_HOST_EGL_PLATFORM:=0}"   # 1 = usar también libnvidia-egl-* del host
    : "${BD_NVIDIA_VERSION_FILE:=/sys/module/nvidia/version}"
    : "${BD_START_TIMEOUT:=90}"
    BD_ROOT="$BD_RUN/root"
}

# ------------------------------------------------- resolución de rutas segura
# bd_rpath ROOT RUTA -> imprime la ruta del host equivalente a RUTA dentro de
# ROOT, resolviendo los symlinks *dentro* de ROOT (un symlink absoluto como
# /var/run -> /run apunta a ROOT/run, nunca al /run del host).
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
            ((++n > 40)) && { bd_warn "demasiados symlinks resolviendo $path"; return 1; }
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

# bd_rleaf ROOT RUTA -> como bd_rpath pero el ÚLTIMO componente se trata literalmente
# (no se sigue si es un symlink). Para reemplazar ficheros/enlaces: /sbin/reboot es
# un symlink a /bin/busybox y NO debemos escribir a través de él.
bd_rleaf() {
    local parent
    parent=$(bd_rpath "$1" "$(dirname -- "$2")") || return 1
    printf '%s\n' "$parent/$(basename -- "$2")"
}

# bd_mkdir RUTA_EN_ROOT
bd_mkdir() { local p; p=$(bd_rpath "$BD_ROOT" "$1") && mkdir -p "$p"; }

# bd_bind ORIGEN RUTA_EN_ROOT [ro] [rec]
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

# bd_put ORIGEN RUTA_EN_ROOT MODO : copia un fichero a la capa escribible
bd_put() {
    local dst
    dst=$(bd_rleaf "$BD_ROOT" "$2") || return 1
    mkdir -p "${dst%/*}"
    rm -f -- "$dst"
    install -m "${3:-0755}" -- "$1" "$dst"
}

# bd_ln DESTINO_DEL_LINK_EN_ROOT TARGET : symlink (target tal como lo verá el chroot)
bd_ln() {
    local dst
    dst=$(bd_rleaf "$BD_ROOT" "$1") || return 1
    mkdir -p "${dst%/*}"
    ln -sfn -- "$2" "$dst"
}

# ----------------------------------------------- actualizaciones (como el initrd)
# Reproduce lo que hace package/batocera/boot/batocera-initramfs/init
bd_boot_apply_pending() {
    local b=$BD_BOOT_DIR img p
    [[ -d $b/boot ]] || return 0
    for img in batocera rufomaculata; do
        if [[ -e $b/boot/$img.update ]]; then
            bd_log "aplicando actualización pendiente: boot/$img.update"
            mv -f -- "$b/boot/$img.update" "$b/boot/$img" || bd_die "no se pudo reemplazar boot/$img"
            # igual que el initrd: el overlay guardado se descarta al actualizar
            if [[ -e $b/boot/overlay ]]; then mv -f -- "$b/boot/overlay" "$b/boot/overlay.old"; fi
        fi
    done
    if [[ -f $b/boot.stale ]]; then
        while IFS= read -r p || [[ -n $p ]]; do
            case $p in ''|\#*|overlays/mipi-panel.dtbo) continue ;; esac
            case $p in
                /*|.|..|../*|*/..|*/../*|./*) bd_warn "ruta 'stale' insegura ignorada: $p"; continue ;;
            esac
            if [[ -e $b/$p || -L $b/$p ]]; then
                bd_log "borrando fichero obsoleto: $p"
                rm -rf -- "${b:?}/$p"
            fi
        done <"$b/boot.stale"
        rm -f -- "$b/boot.stale"
    fi
}

# ------------------------------------------------------------------- GPU
# Detecta el driver NVIDIA del host. Rellena NV_VER.
bd_nvidia_detect() {
    NV_VER=""
    if [[ -r $BD_NVIDIA_VERSION_FILE ]]; then
        NV_VER=$(<"$BD_NVIDIA_VERSION_FILE")
        NV_VER=${NV_VER//[[:space:]]/}
    fi
    [[ -n $NV_VER ]]
}

# Localiza las librerías *userspace* del driver del host que coinciden con la
# versión del módulo del kernel. Rellena NV_LINK[nombre]=ruta_real
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

# Nodo render DRI cuyo driver PCI es $1 (p.ej. nvidia)
bd_render_node() {
    local n drv
    for n in /sys/class/drm/renderD*; do
        [[ -e $n/device/driver ]] || continue
        drv=$(basename "$(readlink -f "$n/device/driver")")
        [[ $drv == "$1" ]] && { printf '/dev/dri/%s\n' "${n##*/}"; return 0; }
    done
    return 1
}

# Monta en el chroot (en /run/bd-nvidia) las libs del host SIN copiarlas:
# se hace bind-mount (ro) de los directorios del host y se crean symlinks.
# Requiere NV_VER/NV_LINK (bd_nvidia_collect) y /run del chroot ya montado.
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
                || { bd_warn "no se pudo montar $dir"; return 1; }
            ((i++))
        fi
        ln -sfn "/run/bd-nvidia/host/${idxof[$dir]}/${real##*/}" "$S/lib64/$base"
    done
    # Enlazar en /usr/lib (capa escribible) como hace batocera-nvidia con sus propias libs:
    # el soname y el nombre versionado -> ldconfig los registra y glvnd/Vulkan los encuentran.
    L=$(bd_rpath "$BD_ROOT" /usr/lib) || return 1
    mkdir -p "$L"
    for base in "${!NV_LINK[@]}"; do
        if [[ $base == *".so.$NV_VER" ]]; then
            ln -sfn "/run/bd-nvidia/lib64/$base" "$L/$base"
        elif [[ ! -e $L/$base && ! -L $L/$base ]]; then
            ln -s "/run/bd-nvidia/lib64/$base" "$L/$base"
        fi
    done
    # GBM: libgbm busca <driver>_gbm.so ; para nvidia-drm es nvidia-drm_gbm.so
    g=libnvidia-allocator.so.1
    [[ -n ${NV_LINK[$g]:-} ]] || g="libnvidia-allocator.so.$NV_VER"
    bd_mkdir /usr/lib/gbm
    bd_ln /usr/lib/gbm/nvidia-drm_gbm.so "/run/bd-nvidia/lib64/$g"
    # Vendor EGL (glvnd): solo NVIDIA, así no hay caída silenciosa a llvmpipe
    cat >"$S/10_nvidia.json" <<'EOF'
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libEGL_nvidia.so.0"
    }
}
EOF
    # ICD Vulkan: el JSON del host (api_version correcta), con library_path por soname
    icd=""
    for f in /usr/share/vulkan/icd.d/nvidia_icd.json /etc/vulkan/icd.d/nvidia_icd.json \
             /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json; do
        [[ -r $f ]] && { icd=$f; break; }
    done
    if [[ -n $icd ]]; then
        sed -E 's#("library_path"[[:space:]]*:[[:space:]]*)"[^"]*"#\1"libGLX_nvidia.so.0"#' "$icd" >"$S/nvidia_icd.json"
    else
        bd_warn "no encuentro nvidia_icd.json en el host; genero uno mínimo"
        printf '{"file_format_version":"1.0.0","ICD":{"library_path":"libGLX_nvidia.so.0","api_version":"1.3.0"}}\n' >"$S/nvidia_icd.json"
    fi
    if [[ -d $(bd_rpath "$BD_ROOT" /usr/share/vulkan/icd.d) ]]; then
        bd_ln /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json /run/bd-nvidia/nvidia_icd.json
    fi
    return 0
}

# ------------------------------------------------------------- utilidades
bd_chroot_proc() {   # ¿hay un proceso con ese comm dentro del chroot?
    local p c r name=${1:0:15}
    for p in "$BD_ROOT"/proc/[0-9]*; do
        [[ -r $p/comm ]] || continue
        read -r c <"$p/comm" 2>/dev/null || continue
        [[ $c == "$name" ]] || continue
        r=$(readlink "$p/root" 2>/dev/null) || continue
        [[ $r == "$BD_ROOT" ]] && return 0
    done
    return 1
}

bd_kill_chroot_procs() {   # señal
    local p r
    for p in "$BD_ROOT"/proc/[0-9]*; do
        r=$(readlink "$p/root" 2>/dev/null) || continue
        [[ $r == "$BD_ROOT" ]] || continue
        kill "-$1" "${p##*/}" 2>/dev/null
    done
}
