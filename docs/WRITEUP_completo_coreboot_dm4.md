# De "¿se le podrá poner libreboot?" a coreboot corriendo

**HP Pavilion dm4-3099se (placa 1793). De InsydeH2O F.0C a coreboot**

Una sesión. Sin abrir la máquina. Sin programador externo.

---

## El punto de partida

La pregunta original era simple: *¿se le puede instalar libreboot o coreboot a una notebook
vieja?* El equipo: una HP Pavilion dm4 de 2011 con Slackware, dual boot con Windows.

La primera respuesta honesta fue desalentadora. En HP, coreboot solo soporta la línea business
(EliteBook, ProBook) porque cada placa es un port a mano. Los Pavilion de consumo no están, y el
único Pavilion del árbol de coreboot es un m6-1035dx, que además es AMD.

Y libreboot quedó descartado de entrada por una razón estructural que conviene tener clara:
**libreboot no es un firmware, es una distribución de coreboot.** Toma coreboot, lo configura, le
agrega un payload y publica ROMs listas para una lista corta de placas. No se "portea a libreboot":
se portea a coreboot, y libreboot decide después si lo empaqueta. Esta placa no está ni va a estar
en esa lista.

Así que el proyecto real era: **escribir un port de coreboot para una placa sin soporte, y
encontrar la forma de flashearlo.**

---

## Reconocimiento

Lo primero fue saber contra qué estábamos.

| | |
|:---|:---|
| Placa | **1793** (grabado en el firmware como `$BID01793.F0C`) |
| CPU | i7-2630QM, **Sandy Bridge** |
| PCH | **HM67**, Cougar Point serie 6 |
| Video | solo Intel HD 3000, **sin GPU dedicada** |
| SPI flash | Macronix MX25L32xx, **4 MB** |
| Firmware | InsydeH2O **F.0C** (2013-01-21), la última que publicó HP |
| Arranque | LEGACY/MBR con GRUB, dual boot Windows |

El chipset resultó ser una buena noticia: Sandy Bridge + BD82x6x es de lo más transitado de
coreboot (lo comparten el ThinkPad X220, el T420 y decenas más), así que el código base estaba
maduro. Y la ausencia de GPU dedicada eliminaba el peor dolor de cabeza de los ports de laptop.

### El SoftPaq, y un callejón sin salida

El firmware oficial seguía disponible: `ftp.hp.com` todavía sirve `sp60639.exe`. Adentro,
`01793F0C.bin`, la imagen del BIOS.

Pero venía **cifrada**. El análisis descartó las hipótesis fáciles una por una:

- **No era XOR.** Lo parecía porque las zonas de relleno decodificaban bien, pero eso pasa con
  cualquier cifrado determinístico sobre plaintext constante.
- **No era sustitución.** El histograma de las islas de datos daba entropía **7.9995/8** con
  distribución plana.
- El periodo de 128 bytes indicaba **cifrado de bloque con la cadena reiniciada cada 128 B**
  (CBC o CFB).

`iscflash.dll` exportaba todos sus símbolos C++ y traía OpenSSL 0.9.8g embebido. Un barrido de
clave por plaintext conocido, validando 7 bloques consecutivos con cero falsos positivos, sobre los
8 binarios del SoftPaq × 9 combinaciones de cifrado no dio **ni un hit**. La clave se deriva en
runtime o vive en el firmware.

Ese camino se abandonó, y fue la decisión correcta: el dump de la máquina real daba lo mismo y
mejor.

---

## El mapa del flash

Leyendo directamente los registros del controlador SPI (`SPIBAR = RCBA + 0x3800 = 0xFED1F800`)
apareció el terreno completo:

```
BIOS_CNTL (LPC 0xDC) = 0x00     BIOSWE=0  BLE=0  SMM_BWP=0
HSFS      (+0x04)    = 0xe008   FLOCKDN=1
PR0       (+0x74)    = 0x83ff03a1  -> protege 0x3a1000-0x3fffff
FRAP      (+0x50)    = 0x00000a0b
```

| región | rango | host lee | host escribe |
|:---|:---|:---:|:---:|
| descriptor | `0x000000-0x000fff` | sí | no |
| ME | `0x001000-0x17ffff` | **no** | **no** |
| BIOS | `0x180000-0x3fffff` | sí | sí |

Dos hallazgos definieron todo lo que vino después.

**`BLE = 0`**: HP nunca habilitó el lock por SMI. La escritura al flash no estaba mediada por SMM.

**`PR0` protegía exactamente `0x3a1000-0x3fffff`**, que resultó ser, con precisión de byte, el
firmware volume del boot block, verificado contra su cabecera `_FVH`. Ahí vive el reset vector
(`0xFFFFFFF0` → offset `0x3ffff0` del chip), o sea el lugar exacto donde coreboot necesita poner
su bootblock.

Traducción: se podía escribir el 85% de la región BIOS, pero no la parte que importaba.

Esto además explicaba el `platform.ini` del flasher de HP, que traía `[ForceFlash] BB_PEI=0`: su
propio actualizador **no toca el boot block**, porque no puede.

---

## El exploit

### Lo que no funcionó

La primera hipótesis fue el ataque clásico al boot script de S3 (Wojtczuk & Kallenberg, 2015):
el firmware graba una tabla de operaciones para replayear al resumir de S3, y esa tabla vive en
memoria ACPI NVS, escribible desde el sistema operativo. La idea era encontrar la entrada que
reprograma `PR0` y parchearla.

Un test de riesgo cero lo descartó: suspender con `rtcwake -m mem` y releer los registros.
El `dmesg` confirmó S3 real (`suspend entry (deep)`, `Preparing to enter system sleep state S3`,
`Low-level resume complete`) y al volver **`PR0` estaba idéntico**. El firmware reaplica la
protección en el resume.

Después vino el mapeo completo de la tabla: **903 entradas** en `0xacf5e000-0xacf62ab5`.
Distribución: 477 `PCI_WRITE`, 247 `MEM_WRITE`, 147 `MEM_READ_WRITE`, **25 `DISPATCH`**,
5 `IO_WRITE`.

Y el resultado fue negativo: **el boot script no escribe `PR0` ni `FLOCKDN`**. Verificado sobre las
903 entradas. Sí toca los VSCC del SPI y decenas de registros RCBA, pero no las protecciones.
El ataque clásico **no aplicaba: no había nada que parchear.**

### Lo que sí funcionó

Pero el mapeo reveló otra cosa. De las 25 entradas `DISPATCH` (el opcode que transfiere ejecución
a una dirección física guardada en la propia tabla), **24 apuntaban a `0xACEBC260`**, que resultó
ser DRAM marcada `Reserved`, escribible desde el sistema operativo, con código x86 de 32 bits real:

```asm
0xACEBC260:  ff 74 24 08     push dword [esp+8]
             ff 74 24 08     push dword [esp+8]
             e8 1e 11 00 00  call ...
             59 59           pop ecx / pop ecx
             e9 bc 01 00 00  jmp  ...
```

(la entrada 25 apuntaba a `0xFFFAF998`, dentro del boot block protegido en flash, intocable)

Eso daba **ejecución de código arbitrario en el contexto de resume del firmware**. La pregunta era
si servía de algo, y eso dependía de un dato que nadie tenía: ¿en qué momento aplica el firmware
las protecciones, antes o después del boot script?

**Se midió.** Se reapuntaron los punteros de la primera y la última entrada `DISPATCH` hacia stubs
propios de 45 bytes que leían `HSFS` y `PR0`, dejaban el valor en memoria y saltaban a la rutina
original para no romper el resume.

| | primer DISPATCH | último DISPATCH | runtime normal |
|:---|:---|:---|:---|
| `HSFS` | `0x6008` | `0x6008` | `0xe008` |
| `PR0` | `0x00000000` | `0x00000000` | `0x83ff03a1` |

`0x6008` tiene el bit 15, `FLOCKDN`, **en cero**. El firmware aplica las protecciones *después*
de terminar el boot script. **La ventana existía.**

Limpiar `PR0` desde ahí no servía: el firmware lo reescribe al terminar. Pero `FLOCKDN` es un bit
de **una sola escritura**: una vez en 1 congela los registros `PR` hasta el próximo reset, sin
importar quién intente escribirlos después.

De ahí salió la jugada: **cerrar el candado antes que el firmware, con `PR0` todavía en cero.**

```asm
    push eax
    push edx
    mov  edx, 0xFED1F874        ; PR0
    mov  eax, [edx]
    mov  [RES+0], eax           ; evidencia: PR0 antes
    mov  edx, 0xFED1F804        ; HSFS
    mov  ax,  0x8000            ; FLOCKDN
    mov  [edx], ax              ; <<< el disparo
    movzx eax, word [edx]
    mov  [RES+4], eax
    mov  edx, 0xFED1F874
    mov  eax, [edx]
    mov  [RES+8], eax           ; evidencia: PR0 despues
    mov  dword [RES+12], 0xC0FFEE03
    pop  edx
    pop  eax
    push 0xACEBC260             ; rutina original
    ret
```

64 bytes, enganchados en el puntero de la última entrada `DISPATCH`. Un `rtcwake -m mem -s 20`.

**Resultado:**

```
antes del suspend:  HSFS = 0xe008   PR0 = 0x83ff03a1
despues del resume: HSFS = 0xe008   PR0 = 0x00000000
```

La escritura del firmware a `PR0` se ignoró silenciosamente. flashrom lo confirmó de forma
independiente: desapareció el `PR0: Warning ... read-only` y la región BIOS entera pasó a
figurar `read-write`.

**El boot block quedó escribible sin tocar el hardware.**

Detalle de implementación que importa: el exploit **no sobrescribe** la rutina en `0xACEBC260`.
La invocan 24 veces y romperla rompe el resume completo. Solo se reapunta el puntero de **una**
entrada, y el stub salta a la rutina original al terminar.

### Honestidad sobre la novedad

La clase de vulnerabilidad no es nueva: es el ataque al boot script de S3 de 2015, que generó
advisories de CERT/CC y varios fabricantes. Lo que aporta este trabajo es una instancia concreta,
medida y sin parchear en un modelo específico, con PoC funcional confirmado por herramienta
independiente. Las perspectivas de CVE son bajas: producto fuera de soporte, clase conocida y punto
de partida ring 0. El ángulo con recorrido sería verificar el mismo patrón en toda la familia de
HP consumo con InsydeH2O de esa generación, cosa que este trabajo no hizo.

---

## El port

### Lo que se automatizó

`autoport` de coreboot cubre exactamente este chipset (`sandybridge.go` + `bd82x6x.go`). Corre en
la máquina con el firmware original, lee el estado real del hardware, y genera el esqueleto:
GPIOs, devicetree, subsystem IDs, mapa de puertos USB, tabla de verbs del codec de audio.

Dos escollos operativos:
- El `go` de Slackware es **gccgo disfrazado** (reporta go1.18, es GCC 15.3) y falla con los
  genéricos de autoport. Se compiló el binario en otra máquina con Go real y se copió estático.
- `autoport` invoca `superiotool`, que **escribe** a los puertos de configuración del Super I/O.
  En una laptop eso es riesgo innecesario, y acá no aportaba nada (el EC no es un Super I/O
  clásico). Se reemplazó por un stub que sale con éxito.

También hubo que responder **no** al prompt de sondeo de registros de gráficos, que la propia
herramienta advierte que puede colgar la máquina.

### Lo que hubo que corregir a mano

Acá estuvo el trabajo real. `autoport` genera un esqueleto, no un port.

**Mapa de SPD.** Generaba el default genérico `{0x50, 0x51, 0x52, 0x53}`. Un sondeo del bus SMBus
i801, con un script propio usando el ioctl `I2C_SMBUS` para no instalar `i2c-tools`, mostró SPD solo
en `0x50` y `0x52`: un módulo por canal. El valor correcto era `{0x50, 0x00, 0x52, 0x00}`.
Con el genérico, el raminit habría buscado módulos inexistentes.

**Panel power y backlight.** Todos los registros en cero. Se leyeron del hardware con la pantalla
encendida (BAR0 de la GPU = `0xc0000000`) y se decodificaron contra el código de coreboot:

```
PP_ON_DELAYS  = 0x03e807d0  -> up=1000, backlight_on=2000, port_select=0 (LVDS)
PP_OFF_DELAYS = 0x01f407d0  -> down=500, backlight_off=2000
PP_DIVISOR    = 0x00186912  -> cycle=18
BLC_PWM_CPU_CTL  = 0x00000288
BLC_PWM_PCH_CTL2 = 0x02880000
```

**★ El bug del panel.** La revisión final encontró lo que habría arruinado el intento:

```
CONFIG_GFX_GMA_PANEL_1_PORT="eDP"
```

El panel de esta máquina es **LVDS**, confirmado por `/sys/class/drm/card0-LVDS-1/status` y por el
`PANEL_PORT_SELECT=0` que decodificamos. Con eDP, libgfxinit habría inicializado un puerto
inexistente y **la pantalla no habría encendido**. Faltaba un `select GFX_GMA_PANEL_1_ON_LVDS` que
tanto el X220 como el Dell Latitude tienen y autoport no generó.

**La VBT.** Ni el X220 ni el Dell prescinden de ella. El intento de extraerla del firmware falló
(está dentro de módulos UEFI comprimidos), pero Linux la expone en debugfs:
`/sys/kernel/debug/dri/0000:00:02.0/i915_vbt`. Salió una `$VBT SANDYBRIDGE-M` de 6144 bytes, válida.

**`Port_List`.** La plantilla de autoport quedó vieja: el tipo de libgfxinit ahora exige 21
elementos. Faltaba `others => Disabled`.

**`DRAM_RESET_GATE_GPIO = 60`.** Marcado como dudoso por autoport. Se verificó contra el propio
`gpio.c` leído del hardware: HP configura ese pin como `GPIO_MODE_GPIO` + `GPIO_DIR_OUTPUT`,
exactamente lo que `southbridge_gate_memory_reset()` necesita.

### Lo que resultó mejor de lo esperado

Varias cosas que anticipábamos como problemas no lo fueron:

- **El blob del MRC no hace falta.** coreboot tiene raminit nativo para Sandy Bridge
  (`USE_NATIVE_RAMINIT`, default `y`, con un comentario que dice literalmente *"You should answer Y"*).
- **La option ROM de video tampoco**, gracias a libgfxinit.
- **me_cleaner no es requisito de coreboot.** El ME vive en su región y coreboot ni la toca.
- **El modo SATA no importaba.** El controlador estaba en RAID y el BIOS de HP ni siquiera expone
  la opción para cambiarlo, pero coreboot lo pone en AHCI por su cuenta (`/* Default to AHCI */`).
- **El EC no era `kbc1126`** (el driver que hizo viables los ports de los EliteBook), pero el
  **DSDT del firmware original documenta el protocolo completo**: mapa de RAM con campos
  nombrados, la ventana `ECMA` en `0xFE802000`, y ~25 métodos `_Qxx`.

---

## El flasheo

Tres intentos. Los dos primeros fallaron **sin escribir un byte**, y las razones valen la pena:

**1.** `No EEPROM/flash device found`. Nuestro `FLOCKDN` temprano congela también el **menú de
opcodes del SPI**, antes de que el firmware lo programe (`OPMENU0 = OPMENU1 = PREOP = 0`).
flashrom cae a *hardware sequencing*, no puede hacer `RDID`, y usa un "Opaque flash chip".
Pasarle `-c <chip>` lo hace fallar. **Solución: no pasar `-c`.**

**2.** `Transaction error`. Por defecto flashrom lee el chip entero antes de escribir, y la región
ME es ilegible. **Solución: `--noverify-all`**, que verifica solo lo que escribe.

**3.** El que funcionó:

```bash
flashrom -p internal:laptop=force_I_want_a_brick --ifd -i bios --noverify-all -w coreboot.rom
```

```
Updating flash chip contents... Erase/write done from 180000 to 3fffff
Verifying flash... VERIFIED.
```

Verificación independiente: la región BIOS leída del chip resultó **byte por byte idéntica** a la
ROM, y el reset vector coincidía.

---

## El resultado

**Arrancó al primer intento.**

```
BIOS vendor : coreboot
BIOS version: 67777cbc8df9
```

Del log de coreboot:

```
Starting Sandy Bridge RAM training (full initialization).
Selected DRAM frequency: 666 MHz
Selected CAS latency   : 8T
Done dimm mapping / memory map / jedec reset / MRS commands
PASSED! Tell ME that DRAM is ready
GMA: Found valid VBT in CBFS
Replaying EC dump ...done
```

Entrenó los dos módulos Kingston desde cero, sin blob de MRC.

**Funciona**: video 1600x900 con backlight, WiFi, audio, temperaturas de CPU, teclado, touchpad,
tapa, y las teclas Fn (volumen y luz de teclado, que el EC maneja en hardware).

**Faltaba**: el reporte de batería.

---

## La batería

El firmware original resolvía la batería con `BAT0` (`PNP0C0A`) y `ADP1` (`ACPI0003`), apoyados en
dos helpers `GBIF` y `GBST`. Unas 350 líneas de ASL.

El análisis de dependencias encontró 7 referencias externas, y una amenazaba con hundir todo:

```asl
Method (RBEC, 1) {
    Return (TRPS (0x10, Arg0))      ; trampa SMI al handler SMM de HP
}
```

Bajo coreboot ese handler no existe. Pero el patrón de uso lo salvó:

```asl
If (ECON)  { ...lectura directa del EC... }
Else       { Local0 = RBEC (0x88) }
```

`RBEC` estaba **siempre** en la rama `Else`. Y `ECON` significa "el EC está disponible por la
interfaz ACPI normal", que bajo coreboot es verdad. Con `ECON = 1`, ese camino nunca se ejecuta.

El resto se resolvió solo: `BATM` era un `Mutex` declarado en el mismo bloque, `GWET`/`WMID` una
notificación WMI omitible, y `SMA4` solo elige un multiplicador para el umbral de aviso de batería
baja.

Los datos de la batería, además, no estaban en la RAM del EC sino en la ventana mapeada en memoria
`ECMA` (`0xFE802000`):

```
0x80: BSRC(carga actual) BSFC(carga plena) BSVO(voltaje) BSCM ...
0x90: BSDC(capacidad diseño) BSDV(voltaje diseño) BSSN(serie) ...
```

### ★ El LGMR, el hallazgo que no salía de ningún log

Con el ASL portado y compilando limpio, Linux enumeró los cuatro devices ACPI
(`PNP0C09` EC, `PNP0C0A` batería, `PNP0C0D` tapa, `ACPI0003` adaptador). El adaptador
**funcionaba**. La batería reportaba:

```
ACPI: battery: Slot [BAT0] (battery absent)
```

El ASL estaba bien: Linux consultaba `_STA` y recibía "ausente". El problema estaba más abajo.
Leyendo la ventana `ECMA` directamente, todo daba `0xff`:

```
ECMA+0x08 = 0xff        <- no son datos, es memoria sin decodificar
BSRC = BSFC = BSVO = 65535
```

**Esa ventana no es una interfaz nativa del chipset.** Se abre programando el **LGMR** (LPC
Generic Memory Range, registro `0x98` del device LPC). El firmware de HP lo configuraba;
coreboot no, porque **el `LGMR` no aparece en ninguno de los logs que genera `autoport`**:
ni en `inteltool`, ni en `lspci`, ni en `acpidump`. Salió únicamente de perseguir el síntoma
hasta el registro.

```
LGMR (LPC cfg 0x98) con coreboot = 0x00000000
```

Se probó en caliente con `setpci`, sin reflashear ni reiniciar:

```
setpci -s 00:1f.0 0x98.l=0xfe802001

ECMA+0x08 = 0x2d   NB0A(presente)=1  NB0N=0
carga actual = 5918 mAh    carga plena = 5918 mAh
voltaje      = 12656 mV    cap. diseño = 8850 mAh
```

Datos reales. El fix permanente fue una línea en `early_init.c`:

```c
pci_write_config32(PCI_DEV(0, 0x1f, 0), 0x98, 0xfe800001);
```

(el registro solo decodifica los bits 31:16, así que la ventana es de 64 KB alineada:
base `0xFE800000` cubre `0xFE802000`; bit 0 = enable)

Tras reflashear:

```
BAT0: present=1  status=Discharging  capacity=100  voltage=12.525V
ADP1: online=0
```

Como dato de color, la batería reporta capacidad plena de 5918 mAh contra 8850 de diseño:
conserva el 67% de su capacidad original, razonable para 2011.

---

## Estado final

| | |
|:---|:---|
| Firmware | **coreboot**, port propio, payload SeaBIOS |
| RAM | raminit nativo, sin blobs |
| Video | libgfxinit nativo + VBT extraída del hardware |
| Blobs propietarios | **solo el ME**, que se dejó intacto |
| Dual boot | Windows y Slackware, sin cambios |

**Funciona**: video 1600x900 con backlight, WiFi, audio, teclado, touchpad, tapa, teclas Fn
(volumen y luz de teclado, que el EC maneja en hardware), temperaturas de CPU, **batería y
adaptador de corriente**.

**Falta**: los métodos `_Qxx` del EC (eventos SCI para hotkeys específicas) y probar el suspend
a S3 bajo coreboot.

---

## El Intel ME: lo único que quedó fuera de alcance

El ME sigue **activo y corriendo normal**. Del log de coreboot:

```
ME: FW Partition Table      : OK
ME: Firmware Init Complete  : YES
ME: Current Working State   : Normal
ME: Current Operation State : M0 with UMA
ME: Error Code              : No Error
```

coreboot no lo toca: lo deja donde está. Y **no se puede desactivar por software en esta
máquina**, por una razón de hardware que se mantuvo constante durante todo el trabajo:

El descriptor le niega al host **lectura y escritura** de la región ME (`FREG2: Management
Engine region is locked`). Ni siquiera se puede leer para extraerla y procesarla con
`me_cleaner`. Y el descriptor, que impone eso, también es de solo lectura para el host.

El exploit de S3 limpió `PR0`, pero los permisos de región vienen de `FRAP`, que el hardware
repuebla desde el descriptor **en cada arranque**. Ningún resume, ningún SMM y ningún exploit
los altera. Fue lo único que se marcó como imposible por software desde el primer análisis, y
se mantuvo así hasta el final.

**Con un programador externo (clip SOIC-8 + Raspberry Pi) se resuelve, y conviene hacer dos
cosas en la misma sesión:**

1. **`me_cleaner`** sobre la región ME. En Sandy Bridge (ME 7/8) no se puede eliminar del todo
   (sin un ME mínimamente funcional la plataforma se apaga a los 30 minutos), pero sí reducirlo
   a su módulo de arranque, sin funcionalidad activa.
2. **Escribir un descriptor desbloqueado** que le dé al host acceso total a todas las regiones.
   A partir de ahí **todo queda flasheable por software para siempre**, ME incluido.

Una sola sesión con el clip compra permanentemente lo que hoy no se tiene.

**Y algo que cambia el proyecto hacia adelante:** coreboot usa `BOOTMEDIA_LOCK_NONE` y no programa
los registros PR. Con coreboot corriendo, `BIOS_CNTL = 0x09` (BIOSWE ya en 1) y `PR0 = 0`.

El flash quedó **permanentemente abierto**. Reflashear ya no necesita el exploit, ni el
suspend/resume, ni nada: un solo comando. El primer arranque exitoso convirtió "un intento" en
"intentos ilimitados".

La Pomona nunca salió del cajón.

---

## Archivos

```
WRITEUP_s3_bootscript_pr0_bypass.md   el exploit en detalle
coreboot/                             árbol con el port
  src/mainboard/hewlett_packard/hp_pavilion_dm4_notebook_pc/
restore/
  COREBOOT_v1_FUNCIONANDO.rom         primera version que arrancó
  RESTORE_PRIMARY_bios_region.bin     BIOS de HP, estado previo al flasheo
  BACKUP_ORIGINAL_F0C_bios_region.bin backup original
dump/                                 dumps del flash, DSDT, ACPI NVS
scratchpad/
  exploit_auto.py                     exploit, con localización dinámica
  spd_probe.py                        sondeo SMBus sin i2c-tools
  bs2.py                              parser del boot script de S3
```
