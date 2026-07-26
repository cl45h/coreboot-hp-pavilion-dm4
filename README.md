# coreboot para HP Pavilion dm4-3000 series (placa 1793)

Port de coreboot para una notebook que no estaba soportada, más el exploit que permite
flashearla sin programador externo.

> **English summary:** coreboot mainboard port for the HP Pavilion dm4-3000 series
> (board ID 1793, Sandy Bridge / HM67). Includes an S3 boot script exploit that unlocks
> the SPI flash boot block, allowing the firmware to be replaced entirely in software,
> with no SOIC-8 clip or external programmer needed. Detailed write-ups are in `docs/`
> (Spanish).

---

## Estado

Probado y funcionando en una HP Pavilion dm4-3099se.

| | |
|:---|:---|
| Arranque | ✅ SeaBIOS → GRUB → Linux / Windows |
| RAM | ✅ raminit nativo de coreboot, sin blob de MRC |
| Video | ✅ libgfxinit nativo, LVDS 1600x900 + backlight |
| Audio | ✅ codec IDT |
| WiFi / Ethernet / USB | ✅ |
| Teclado / touchpad | ✅ |
| Batería y adaptador | ✅ |
| Tapa | ✅ |
| Teclas Fn | ✅ volumen y luz de teclado (las maneja el EC en hardware) |
| Temperaturas CPU | ✅ |
| Métodos `_Qxx` del EC | ❌ no portados |
| Suspend a S3 | ⚠️ sin probar bajo coreboot |
| Intel ME | ⚠️ intacto y activo, ver más abajo |

## Hardware

| | |
|:---|:---|
| Placa | 1793 (`$BID01793` en el firmware) |
| CPU | Intel Core i7-2630QM, Sandy Bridge |
| PCH | HM67, Cougar Point serie 6 |
| Video | Intel HD 3000, panel LVDS |
| SPI flash | Macronix MX25L32xx, 4 MB |
| Firmware original | InsydeH2O F.0C (2013-01-21) |

## Uso

```bash
git clone https://review.coreboot.org/coreboot.git
cd coreboot
cp -r /ruta/a/este/repo/src/mainboard/hewlett_packard/* src/mainboard/hewlett_packard/
make crossgcc-i386 CPUS=$(nproc)
make menuconfig     # Mainboard -> Hewlett-Packard -> HP Pavilion dm4 Notebook PC
make
```

Conviene usar SeaBIOS como payload. Es lo que hace falta si tenés dual boot con Windows en
MBR, y además arranca GRUB sin dramas. Activá también `CONSOLE_CBMEM` y `USBDEBUG`, que si
algo falla son la única forma de enterarte de por qué.

## Flasheo

El firmware de HP protege el boot block con el registro `PR0` del controlador SPI, sobre el
rango `0x3a1000-0x3fffff`. Justo ahí es donde va el bootblock de coreboot. Si no saltás esa
protección, no queda otra que un programador SPI externo.

`tools/exploit_auto.py` lo resuelve por software. La idea: el firmware aplica las protecciones
recién *después* de replayear el boot script de S3, así que hay una ventana en la que `PR0`
todavía vale cero. El exploit se mete ahí y cierra `FLOCKDN` antes que el firmware, con los
registros vacíos. Cuando el firmware después intenta escribir `PR0`, su escritura se descarta
sin decir nada.

```bash
sudo python3 tools/exploit_auto.py     # instala el stub en el boot script
sudo rtcwake -m mem -s 20              # suspende y resume: acá se dispara
sudo python3 tools/spi_check.py        # PR0 tiene que quedar en 0x00000000

sudo flashrom -p internal:laptop=force_I_want_a_brick \
              --ifd -i bios --noverify-all -w build/coreboot.rom
```

Tres cosas que te van a hacer perder tiempo si no las sabés:

**No le pases `-c <chip>` a flashrom.** El `FLOCKDN` que cerramos temprano congela también el
menú de opcodes del SPI, así que flashrom cae a hardware sequencing, no puede hacer `RDID` y
termina usando un "Opaque flash chip". Si le forzás el modelo, falla con
`No EEPROM/flash device found`.

**`--noverify-all` no es opcional.** Sin eso flashrom quiere leer el chip entero antes de
escribir, incluida la región del ME que es ilegible, y aborta con `Transaction error`.

**El efecto vive en RAM.** Cada arranque en frío reconstruye el boot script, así que si vas a
flashear de nuevo tenés que repetir el suspend/resume.

Ahora, la buena noticia: **una vez que coreboot arranca, el exploit no hace falta nunca más.**
coreboot usa `BOOTMEDIA_LOCK_NONE` y no programa los registros PR, o sea que el flash queda
abierto para siempre. Reflashear pasa a ser un comando y listo.

### Sacá un backup antes

```bash
sudo flashrom -p internal:laptop=force_I_want_a_brick \
              --ifd -i bios -r backup_bios_region.bin
```

Guardalo en otra máquina, no en la que vas a flashear. Si algo sale mal y el equipo no postea,
ese archivo más un clip SOIC-8 te devuelven el firmware original.

## Intel ME

Sigue activo. coreboot no lo toca, simplemente lo deja donde está.

**No se puede desactivar por software en esta placa**, y no es una limitación de coreboot sino
del hardware. El flash descriptor le niega al host lectura *y* escritura de la región del ME.
Esos permisos los repuebla el chipset leyendo el descriptor en cada arranque, y el descriptor
también es de solo lectura para el host. Ni el exploit ni coreboot ni nada que corra en el CPU
puede cambiarlos.

Para eso hace falta un programador SPI externo. Si en algún momento lo vas a usar, aprovechá
el viaje y hacé dos cosas juntas: corré `me_cleaner` y escribí un descriptor desbloqueado. A
partir de ahí queda todo flasheable por software, ME incluido.

## Herramientas

| | |
|:---|:---|
| `tools/exploit_auto.py` | localiza el boot script de S3 e instala el exploit de `FLOCKDN` |
| `tools/spi_check.py` | lee las protecciones del SPI: `BIOS_CNTL`, `HSFS`, `FRAP`, `PR0-4` y el layout del flash |
| `tools/bs2.py` | parser del boot script de S3 |
| `tools/spd_probe.py` | sondea las direcciones SPD en el SMBus sin necesidad de `i2c-tools` |

## Documentación

`docs/WRITEUP_completo_coreboot_dm4.md` cuenta el proceso entero: el reconocimiento, el SoftPaq
cifrado que no llevó a ningún lado, el mapa del flash, cómo salió el exploit, el port con las
seis correcciones que hubo que hacer a mano, y los tres intentos de flasheo.

`docs/WRITEUP_s3_bootscript_pr0_bypass.md` es el exploit en detalle, con el shellcode comentado,
la evidencia y las mitigaciones.

Si vas a portar otra placa, leelos antes. Documentan cosas que ninguna herramienta te va a
decir, como el bug del panel eDP/LVDS que te deja la pantalla apagada sin explicación, o el
registro `LGMR` que no aparece en ningún log de `autoport` y sin el cual la batería figura
como ausente.

## Advertencia

Tocar el firmware puede dejarte el equipo inutilizable. Esto está probado en *una* máquina. Si
tenés otra variante de la dm4-3000, fijate al menos el mapa de SPD y los tiempos del panel
antes de flashear, que están documentados en el writeup.

Tené un clip SOIC-8 a mano. No para flashear, sino para poder equivocarte.

## Licencia

GPL-2.0-only, igual que coreboot.

El ASL de la batería en `acpi/ec.asl` está derivado del DSDT del firmware original de HP, y
`data.vbt` es el Video BIOS Table extraído del mismo equipo. Van incluidos porque el hardware
no anda sin ellos, siguiendo la práctica habitual de los ports de coreboot.

---

*By cl45h, Aguante RemoteExecution, siempre <3*
