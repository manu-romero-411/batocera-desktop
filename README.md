# batocera-desktop

Batocera completo (EmulationStation, emuladores, mandos, Bluetooth, audio, actualizaciones) **dentro de tu escritorio Linux Wayland**, como una ventana: labwc (el de Batocera) anidado en tu compositor, con aceleración 3D del driver del host (NVIDIA propietario o Mesa Intel/AMD).
Sustituye a los scripts `batocera-chroot` originales. Análisis y diseño: [`docs/ANALISIS.md`](docs/ANALISIS.md).

## Requisitos
* Debian 13 (systemd, sudo, util-linux), sesión **Wayland** (KDE/GNOME…) con PipeWire.
* Imagen Batocera **x86-64-v3 (v43+)**: es la que trae labwc/Wayland.
* NVIDIA: `nvidia-drm.modeset=1` (por defecto en 615) y las librerías userspace del driver instaladas en el host.

## Instalación
```bash
sudo ./install.sh --user TU_USUARIO
batocera-desktop install --download     # si aún no tienes la imagen x86-64-v3 en /boot/batocera
batocera-desktop doctor                 # todo en OK (o dime qué falla)
batocera-desktop start                  # también hay lanzador "Batocera" en el menú
```
Configuración en `/etc/batocera-desktop.conf` (rutas, discos extra `BD_EXTRA_BINDS="/pcgrande:/pcgrande"`, audio, BT…). Los valores por defecto (`/boot/batocera`, `/batocera`) coinciden con tus scripts viejos, así que tu instalación actual se reutiliza.

## Modos
* **nested** (por defecto dentro de un escritorio Wayland): Batocera es una ventana de tu compositor; tamaño por defecto `BD_RESOLUTION` (1920x1080).
* **drm** (por defecto si lanzas `batocera-desktop start` desde una consola `/dev/ttyN` sin Wayland): labwc de Batocera maneja la pantalla directamente (DRM/KMS) en esa VT. Cambias de VT con Ctrl+Alt+Fn y vuelves con la misma; `batocera-desktop stop` (desde otra VT) o *Apagar* en ES lo cierran. Fuerza uno con `--mode`.

## Uso
| Comando | |
|---|---|
| `start` / `stop` / `restart` / `status` | ciclo de vida (sin contraseña) |
| `logs [-f]` | journal de la sesión; logs de Batocera en `/batocera/system/logs/`, de servicios en `/var/log/batocera-desktop/` |
| `update` | `batocera-upgrade` dentro del entorno; luego `restart` (o "Reiniciar" en ES) |
| `shell [cmd]` | shell root en el entorno Batocera |
| `doctor` | diagnóstico host + imagen + GPU |

En ES: **Apagar** = cierra Batocera y vuelve al escritorio (`BD_ON_SHUTDOWN=host` apaga el PC); **Reiniciar** = reinicia la sesión (aplica actualizaciones). Cerrar la ventana también termina la sesión.

## Actualizar Batocera
Desde el menú de ES (*Actualizaciones*) o `batocera-desktop update`: es el `batocera-upgrade` original; deja `batocera.update`/`rufomaculata.update`/`boot.stale` y el siguiente arranque de sesión los aplica, exactamente como el initrd. Se puede hacer con la sesión en marcha.

## Pruebas de ayuda a depurar
`sudo test/run-tests.sh` (root, `mksquashfs`, `busybox-static`): 31 comprobaciones con un Batocera falso. Si algo falla en tu máquina: `batocera-desktop doctor`, `batocera-desktop logs`, y `/batocera/system/logs/display.log` + `/var/log/labwc.log` (visible con `batocera-desktop shell cat /var/log/labwc.log` mientras corre).
Para el test en Intel: `BD_GPU=mesa` (o simplemente sin módulo nvidia: auto).
