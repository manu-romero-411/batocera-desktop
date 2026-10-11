# Análisis de los scripts originales y decisiones de la versión nueva

## 1. Qué hacían los scripts originales
`batocera-chroot` cierra la sesión XFCE/KDE → `emustation-load` monta el chroot (`chroot-setup -m`), **para sddm**, arranca por `init.d` ES, triggerhappy y userservices, y se queda bloqueado leyendo un FIFO hasta que ES "apaga"; entonces desmonta y vuelve a arrancar sddm. Es decir: Batocera **sustituye** al escritorio, no convive con él.

## 2. Problemas detectados (por gravedad)
| # | Problema | Consecuencia |
|---|----------|--------------|
| 1 | Se hace `bind` de `/var`, `/tmp`, `/opt`, `/run`, `/dev`, `/sys`, `/proc` del **host** dentro del chroot | Los `init.d` de Batocera escriben en el `/var` y `/run` del host; `/tmp/.continue`, pid-files y sockets se mezclan |
| 2 | Mismo namespace PID/UTS/proc que el host | Batocera ejecuta `hostname X`, `sysctl kernel.core_pattern=…` (S26system), `killall pipewire/wireplumber/labwc/touchegg…`: **actúan sobre el host** |
| 3 | No monta `rufomaculata` (la 2ª squashfs que el initrd une con `batocera`) | Falta parte del sistema en imágenes recientes (partida en 2 por el límite de 4 GB) |
| 4 | No reproduce el initrd: `.update` → fichero final, `overlay`→`overlay.old`, `boot.stale` | Tras `batocera-upgrade` nunca se activa la versión nueva |
| 5 | `lowerdir` único, copia del overlay con `cp -pr saved/*` (omite dotfiles) | Pérdida de ficheros ocultos del overlay guardado |
| 6 | Desmontaje con bucle `grep /proc/mounts` + `lsof` + 20 reintentos | Montajes colgados si queda un proceso; hay que limpiar a mano |
| 7 | `S06audio` arranca el PipeWire de Batocera y *exige* parar el audio del host; `audio-start` filtra "HDA Intel Duplex" (hardware concreto) | Sin sonido / conflicto con el escritorio |
| 8 | Sin NVIDIA propietario: S05nvidia de Batocera enlaza **su** driver (versión distinta a tu módulo 615) | libGL/EGL/Vulkan no inicializan o caen a llvmpipe en silencio |
| 9 | Rutas fijas (`/home/manuel/...`), `sudo` + `nohup`, `.desktop` y `install.sh` con rutas inconsistentes, `BATO_SYSTEM` montado sobre una ruta que ya está en `BATO_USERDATA` | Frágil, no portable |
| 10 | Mantiene `mount_if_not` con heurística "si el directorio tiene ficheros → bind, si no → mount" | Comportamiento ambiguo |
| 11 | Sin Bluetooth: bluetoothd del host y el de Batocera se pisarían | Mandos BT no gestionables |

## 3. Hallazgos clave en el código fuente de Batocera (rama `master`, 44-dev, y changelog v43)
* **v43 (mayo 2026): la imagen `x86-64-v3` usa Wayland + labwc.** La imagen `x86_64` clásica usa Xorg. El `labwc-launch` oficial asume DRM/KMS (`unset WAYLAND_DISPLAY`, `WLR_DRM_DEVICES`…), sin anidado.
* Batocera ya usa **PipeWire** (`pactl`, `batocera-audio` con `XDG_RUNTIME_DIR=/var/run`): el cliente solo necesita `PULSE_SERVER`/`PIPEWIRE_RUNTIME_DIR` apuntando al socket del host.
* Bluetooth: `batocera-bluetooth` y `batocera-bluetooth-agent` hablan con `org.bluez` por D-Bus y miran `/var/lib/bluetooth`: se puede compartir el `bluetoothd` del host.
* NVIDIA: `S05nvidia`/`batocera-nvidia` crea enlaces `…/libGLX_nvidia.so.0 → /var/run/nvidia/lib/…` y `/usr/lib/gbm/nvidia-drm_gbm.so` en tiempo de ejecución; sin ellos no hay NVIDIA. Los `egl_vendor.d` y `egl_external_platform.d` ya vienen en la imagen.
* Actualización: `batocera-upgrade` hace `remount,rw /boot` y `tar xvf` de `boot.tar.xz` sobre `/boot`; deja `boot/batocera.update`, `boot/rufomaculata.update`, `boot.stale`. El **initrd** los aplica en el siguiente arranque.

## 4. Arquitectura nueva
```
batocera-desktop start ──sudo (sin clave, solo launch/stop)──► systemd-run  unidad batocera-desktop
   unidad: bd-session run  (bucle; "reboot" = reinicia sesión)
     unshare --mount --uts --pid ──► bd-session inner (PID 1 del namespace)
        1. tmpfs privado → loop-mount boot/batocera + boot/rufomaculata → overlay (+ overlay guardado)
        2. /boot, /userdata, /proc, /sys(ro), /dev, /run(tmpfs propio), /tmp(tmpfs propio)
        3. del host: socket Wayland+PipeWire (/run/user/UID → /run/host-xdg), /run/udev(ro), D-Bus del sistema, /var/lib/bluetooth
        4. NVIDIA: bind(ro) de los dirs de libs del host + symlinks (sin copiar nada)
        5. se inyectan (solo en la capa en RAM): labwc-launch anidado, shims shutdown/reboot
        6. servicios stock: S04populate, S12populateshare, S50triggerhappy, S97joycond, S31emulationstation, S99userservices
        7. espera; al terminar, para servicios y el namespace desaparece (mounts incluidos)
```
Decisiones:
* **Se reutiliza el labwc de Batocera** (se actualiza con Batocera) pero con `WLR_BACKENDS=wayland`: es una ventana de tu compositor. `S31emulationstation`/`autostart` siguen siendo los originales; solo se sustituye `labwc-launch`.
* **Namespaces privados** (mount+PID+UTS): `hostname`, `sysctl`, `killall` quedan confinados, `/proc/sys` es solo lectura, y al acabar no queda nada montado. Desaparecen `chroot-unsetup` y el bucle de `umount`.
* **Updates**: se usa el `batocera-upgrade` **original** dentro del entorno (`batocera-desktop update`, o desde el menú de ES). `bd_boot_apply_pending` hace lo que el initrd, con la protección de rutas `boot.stale`. Reemplazar `boot/batocera` es seguro con la sesión corriendo (tar desenlaza y crea; el loop mantiene el inodo viejo). "Reiniciar" en ES = reinicia la sesión y aplica la versión nueva.
* **NVIDIA sin copias**: el `libGLX_nvidia.so.<versión>` que se carga es el de **tu** driver; se detecta la versión en `/sys/module/nvidia/version` y se enlazan solo ficheros `*.so.<esa versión>`. Vendor EGL y ICD Vulkan forzados a NVIDIA para evitar caída silenciosa a Mesa. En un equipo Intel/AMD no se enlaza nada (Mesa de Batocera).
* **Audio**: sin PipeWire propio. Volumen/dispositivo de ES actúan sobre el sink por defecto del host.
* **Bluetooth**: `BD_BT=host` comparte `bluetoothd` por D-Bus (emparejar un mando en ES lo deja emparejado en el host y viceversa); `exclusive` (experimental) para el del host y usa el de Batocera.
* **Mandos**: lectura directa de `/dev/input` (independiente del compositor), clasificación por la base udev del host (`/run/udev`), `uinput`/`uhid`/`joydev` cargados por `modules-load.d`.

## 5. Verificado / no verificado
**Verificado en sandbox** (`test/run-tests.sh`, 31 comprobaciones sobre un Batocera falso con busybox/squashfs, con symlinks absolutos trampa): capas squashfs+overlay, ambos `.update`, `boot.stale` (incl. ruta maliciosa), `overlay.old`, shims de apagado/reinicio, PID/UTS/mounts aislados del host, `/proc/sys` ro, enlaces NVIDIA con libs falsas, parada por SIGTERM sin residuos. El test encontró un bug real (`/sbin/reboot → busybox` se sobrescribía), ya corregido con `bd_rleaf`.

**NO verificado (necesita tu hardware):** GPU/EGL/Vulkan reales con driver 615, wlroots anidado sobre NVIDIA, audio real, BT real, la unidad `systemd-run`/sudoers, la URL de descarga `updates.batocera.org/x86-64-v3/...` (inaccesible desde mi sandbox), versión exacta de tu imagen. Por eso `batocera-desktop doctor`.

## 6. Riesgos conocidos y límites
1. **Requiere imagen x86-64-v3 (labwc, ≥ v43).** Con la x86_64 Xorg no hay labwc que anidar (habría que usar Xwayland rootful; no implementado). Migración: dentro del entorno, `batocera-upgrade --upgrade --url https://updates.batocera.org/x86-64-v3/stable/last` (el script permite x86_64↔x86-64-v3).
2. **Mezcla de versiones NVIDIA**: se usan libs del host 615 junto a `libnvidia-egl-wayland/gbm` de Batocera (otra versión). Son ABI estable, pero si falla EGL sobre Wayland prueba `BD_NVIDIA_HOST_EGL_PLATFORM=1`.
3. **Pantalla completa**: el backend Wayland de wlroots abre una ventana normal; ponla a pantalla completa con tu compositor (atajo o regla de ventana).
4. **Latencia/rendimiento**: un compositor anidado añade ~1 frame y una pasada de composición. Para mínima latencia haría falta el modo DRM/VT (no implementado: exigiría parar el escritorio y audio propio).
5. Los mandos siguen enviando eventos a ES aunque la ventana no tenga foco.
6. Resolución: si Batocera cambia de modo de vídeo por juego, el "monitor" es la ventana; usa `global.videomode=default` en `batocera.conf`.
7. Reglas udev propias de Batocera (pistolas, Steam Deck…) no se aplican (el `udevd` es el del host).
8. 32 bits (Wine/Proton 32) y CUDA: solo se enlazan libs de 64 bits.
9. **Seguridad**: `launch`/`stop` son sudo sin contraseña y ejecutan servicios de Batocera como root; quien pueda escribir en `/batocera/system/services` tendría root. Mantén `BD_USERDATA` propiedad de root.
