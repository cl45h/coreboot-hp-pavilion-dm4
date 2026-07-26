# De "¿se le podrá poner libreboot?" a coreboot andando

**HP Pavilion dm4-3099se (placa 1793). De InsydeH2O F.0C a coreboot**

Sin abrir la máquina y sin programador externo. Acá está todo lo que hice, incluidas las
partes donde me equivoqué, que son las que más sirven.

---

## Cómo empezó

La pregunta era simple: *¿se le puede meter libreboot o coreboot a esta notebook vieja?* Una
dm4 de 2011 con Slackware y dual boot con Windows, que hace rato quería tocar.

La primera respuesta que encontré fue un baldazo. En HP, coreboot solo soporta la línea business
(EliteBook, ProBook), porque cada placa hay que portearla a mano. Los Pavilion de consumo no
están. El único Pavilion en todo el árbol de coreboot es un m6-1035dx, que encima es AMD.

Y libreboot quedó afuera de entrada por algo que conviene entender bien: **libreboot no es un
firmware, es una distribución de coreboot.** Agarra coreboot, lo configura, le mete un payload,
compila y publica ROMs listas para una lista cortita de placas. No se "portea a libreboot": se
portea a **coreboot**, y libreboot decide después si lo empaqueta. Esta placa no está en esa
lista ni va a estar nunca.

Así que el proyecto real era otro: **escribir un port de coreboot desde cero, y encima
encontrar la forma de flashearlo.**

---

## Primero, contra qué estaba peleando

| | |
|:---|:---|
| Placa | **1793** (grabado en el firmware como `$BID01793.F0C`) |
| CPU | i7-2630QM, **Sandy Bridge** |
| PCH | **HM67**, Cougar Point serie 6 |
| Video | solo Intel HD 3000, **sin GPU dedicada** |
| SPI flash | Macronix MX25L32xx, **4 MB** |
| Firmware | InsydeH2O **F.0C** (2013-01-21), la última que sacó HP |
| Arranque | LEGACY/MBR con GRUB, dual boot Windows |

El chipset resultó ser buena noticia: Sandy Bridge + BD82x6x es de lo más transitado de coreboot
(lo comparten el ThinkPad X220, el T420 y decenas más), así que el código base estaba maduro y
probado. Y no tener GPU dedicada me sacaba de encima el peor dolor de cabeza de los ports de
laptop.

### El SoftPaq, y un callejón sin salida

El firmware oficial todavía está: `ftp.hp.com` sigue sirviendo `sp60639.exe`. Adentro está
`01793F0C.bin`, la imagen del BIOS.

Pero venía **cifrada**, y me comí un rato largo descartando hipótesis:

- **No era XOR.** Lo parecía porque las zonas de relleno decodificaban bien, pero eso pasa con
  cualquier cifrado determinístico sobre plaintext constante. Casi me lo creo.
- **No era sustitución.** El histograma de las islas de datos daba entropía **7.9995/8** con
  distribución plana como una mesa.
- El periodo de 128 bytes decía **cifrado de bloque con la cadena reiniciada cada 128 B**
  (CBC o CFB).

`iscflash.dll` exportaba todos sus símbolos C++ y traía OpenSSL 0.9.8g adentro, así que me
armé un barrido de clave por plaintext conocido (validando 7 bloques consecutivos, cero falsos
positivos) sobre los 8 binarios del SoftPaq × 9 combinaciones de cifrado.

**Ni un hit.** La clave se deriva en runtime o vive adentro del firmware.

Ahí lo dejé, y fue lo mejor que hice: el dump de la máquina real me daba lo mismo y mejor. A
veces hay que saber cuándo soltar.

---

## El mapa del flash

Leyendo directo los registros del controlador SPI (`SPIBAR = RCBA + 0x3800 = 0xFED1F800`)
apareció el terreno completo:

```
BIOS_CNTL (LPC 0xDC) = 0x00     BIOSWE=0  BLE=0  SMM_BWP=0
HSFS      (+0x04)    = 0xe008   FLOCKDN=1
PR0       (+0x74)    = 0x83ff03a1  -> protege 0x3a1000-0x3fffff
FRAP      (+0x50)    = 0x00000a0b
```

| región | rango | podés leer | podés escribir |
|:---|:---|:---:|:---:|
| descriptor | `0x000000-0x000fff` | sí | no |
| ME | `0x001000-0x17ffff` | **no** | **no** |
| BIOS | `0x180000-0x3fffff` | sí | sí |

Dos cosas de acá definieron todo lo que vino después.

**`BLE = 0`**: HP nunca activó el lock por SMI. La escritura al flash no pasa por SMM.

**`PR0` protegía exactamente `0x3a1000-0x3fffff`**, que resultó ser, con precisión de byte, el
firmware volume del boot block. Lo verifiqué contra su cabecera `_FVH`. Ahí vive el reset vector
(`0xFFFFFFF0` mapea al offset `0x3ffff0` del chip), o sea **justo** el lugar donde coreboot
necesita poner su bootblock.

Podés escribir el 85% de la región BIOS y nada de lo que sirve. Qué casualidad, ¿no?

Encima esto explicaba algo que había visto en el `platform.ini` del flasher de HP:
`[ForceFlash] BB_PEI=0`. Su propio actualizador **no toca el boot block**. No es que no quiera,
no puede. Están en la misma que yo.

---

## El exploit

### Lo que no funcionó

Lo primero que probé fue el ataque clásico al boot script de S3 (Wojtczuk & Kallenberg, 2015):
el firmware graba una tabla de operaciones para repetir al resumir, y esa tabla vive en memoria
ACPI NVS, que el sistema operativo puede escribir. La idea era encontrar la entrada que
reprograma `PR0` y parchearla.

Lo testeé sin arriesgar nada: `rtcwake -m mem` y a releer los registros al volver. El `dmesg`
confirmó que fue S3 de verdad (`suspend entry (deep)`, `Preparing to enter system sleep state
S3`, `Low-level resume complete`) y al volver **`PR0` estaba idéntico**. El firmware lo reaplica
en el resume.

Después mapeé la tabla entera: **903 entradas** en `0xacf5e000-0xacf62ab5`. 477 `PCI_WRITE`,
247 `MEM_WRITE`, 147 `MEM_READ_WRITE`, **25 `DISPATCH`**, 5 `IO_WRITE`.

Y el resultado fue negativo: **el boot script no escribe `PR0` ni `FLOCKDN`**. Chequeado sobre
las 903. Toca los VSCC del SPI y decenas de registros RCBA, pero las protecciones no.

**No había nada que parchear.** El ataque clásico no aplicaba.

### Lo que sí funcionó

Pero mapear la tabla no fue al pedo. De esas 25 entradas `DISPATCH` (el opcode que salta a
ejecutar código en una dirección física guardada **en la propia tabla**), 24 apuntaban todas al
mismo lado: `0xACEBC260`. Que resultó ser DRAM marcada `Reserved`, o sea escribible desde el
sistema, con código x86 de 32 bits real ahí adentro:

```asm
0xACEBC260:  ff 74 24 08     push dword [esp+8]
             ff 74 24 08     push dword [esp+8]
             e8 1e 11 00 00  call ...
             59 59           pop ecx / pop ecx
             e9 bc 01 00 00  jmp  ...
```

(la número 25 apuntaba a `0xFFFAF998`, adentro del boot block protegido, esa ni la miré)

Eso es **ejecución de código arbitrario en el contexto de resume del firmware**. Pero servía
solo si se cumplía algo que yo no sabía: ¿cuándo aplica el firmware las protecciones, antes o
después del boot script?

**Lo medí en vez de adivinar.** Reapunté los punteros de la primera y la última entrada
`DISPATCH` a stubs míos de 45 bytes que leían `HSFS` y `PR0`, dejaban el valor en memoria y
saltaban a la rutina original para no romper el resume.

| | primer DISPATCH | último DISPATCH | corriendo normal |
|:---|:---|:---|:---|
| `HSFS` | `0x6008` | `0x6008` | `0xe008` |
| `PR0` | `0x00000000` | `0x00000000` | `0x83ff03a1` |

`0x6008` tiene el bit 15 (`FLOCKDN`) **en cero**. Ahí estaba: **el firmware aplica las
protecciones DESPUÉS de terminar el boot script.** La ventana existía.

Limpiar `PR0` desde ahí no servía, porque el firmware lo reescribe al final. Pero `FLOCKDN` es
un bit de **una sola escritura**: una vez en 1 congela los registros `PR` hasta el próximo
reset, no importa quién intente escribirlos después.

Entonces: **le cierro el candado yo primero, con los registros vacíos.**

```asm
    push eax
    push edx
    mov  edx, 0xFED1F874        ; PR0
    mov  eax, [edx]
    mov  [RES+0], eax           ; PR0 antes
    mov  edx, 0xFED1F804        ; HSFS
    mov  ax,  0x8000            ; FLOCKDN
    mov  [edx], ax              ; <<< aca se cierra
    movzx eax, word [edx]
    mov  [RES+4], eax
    mov  edx, 0xFED1F874
    mov  eax, [edx]
    mov  [RES+8], eax           ; PR0 despues
    mov  dword [RES+12], 0xC0FFEE03
    pop  edx
    pop  eax
    push 0xACEBC260             ; rutina original
    ret
```

64 bytes, colgados del puntero de la última entrada `DISPATCH`. Un `rtcwake -m mem -s 20`.

**Resultado:**

```
antes del suspend:  HSFS = 0xe008   PR0 = 0x83ff03a1
despues del resume: HSFS = 0xe008   PR0 = 0x00000000
```

La escritura del firmware a `PR0` se fue a la mierda en silencio. Y flashrom lo confirmó solo:
desapareció el `PR0: Warning ... read-only` y la región BIOS entera pasó a figurar como
`read-write`.

**Boot block liberado, sin tocar un tornillo.**

Un detalle que importa: el exploit **no pisa** la rutina en `0xACEBC260`. La llaman 24 veces y
si la rompés se te va todo el resume al carajo. Solo reapunto **una** entrada, y el stub salta a
la original cuando termina.

Ah, y una advertencia que me salió cara: durante el research se me ocurrió recorrer todas las
regiones `Reserved` de `/proc/iomem` buscando el boot script. Mala idea. Ahí adentro hay MMIO y
SMRAM, y con **leer** alcanza para tirarte la máquina. Me la reseteó en el acto y me regaló un
fsck. Leé solo rangos que hayas verificado que son DRAM.

### Sobre si esto es novedoso

No lo es, y lo aclaro antes de que me lo digan. Es el ataque al boot script de S3 de 2015, que
en su momento generó advisories de CERT/CC y varios fabricantes. Lo que hay acá es una instancia
concreta, medida y sin parchear, con PoC que anda.

Para CVE las chances son bajas: producto muerto, clase conocida, y arrancás desde ring 0. Lo que
sí podría ser juicy es si el mismo patrón está en toda la familia de HP de consumo con InsydeH2O
de esa época. Ahí sería un bug de plataforma. Pero eso no lo verifiqué, tengo una sola máquina.

---

## El port

### Lo que se hace solo

`autoport` de coreboot cubre justo este chipset (`sandybridge.go` + `bd82x6x.go`). Corre en la
máquina con el firmware original, lee el estado real del hardware y te escupe el esqueleto:
GPIOs, devicetree, subsystem IDs, mapa de puertos USB, tabla de verbs del codec de audio.

Dos escollos que me hicieron renegar antes de poder correrlo:

- El `go` de Slackware es **gccgo disfrazado** (te reporta go1.18, es GCC 15.3) y se caga en los
  genéricos que usa autoport. Lo compilé en otra máquina con Go de verdad y copié el binario
  estático.
- `autoport` invoca `superiotool`, que **escribe** a los puertos de configuración del Super I/O.
  En una laptop eso es riesgo al pedo, y encima acá no aportaba nada (el EC no es un Super I/O
  clásico). Lo reemplacé por un stub que sale con éxito y listo.

Ah, y cuando te pregunta si sondear los registros de gráficos, **decile que no**. La propia
herramienta te avisa que puede colgar la máquina.

### Lo que hubo que arreglar a mano

Acá estuvo el laburo real. `autoport` te da un esqueleto, no un port.

**El mapa de SPD.** Generaba el default genérico `{0x50, 0x51, 0x52, 0x53}`. Sondeé el bus SMBus
i801 con un script propio usando el ioctl `I2C_SMBUS` (para no instalar `i2c-tools`) y había SPD
solo en `0x50` y `0x52`: un módulo por canal. El valor correcto era `{0x50, 0x00, 0x52, 0x00}`.
Con el genérico, el raminit se ponía a buscar módulos que no existen.

**Panel power y backlight.** Todos los registros en cero. Los leí del hardware con la pantalla
encendida (BAR0 de la GPU = `0xc0000000`) y los decodifiqué contra el código de coreboot:

```
PP_ON_DELAYS  = 0x03e807d0  -> up=1000, backlight_on=2000, port_select=0 (LVDS)
PP_OFF_DELAYS = 0x01f407d0  -> down=500, backlight_off=2000
PP_DIVISOR    = 0x00186912  -> cycle=18
BLC_PWM_CPU_CTL  = 0x00000288
BLC_PWM_PCH_CTL2 = 0x02880000
```

**★ El bug del panel, que casi me arruina el intento.** Revisando todo antes de flashear
encontré esto:

```
CONFIG_GFX_GMA_PANEL_1_PORT="eDP"
```

El panel de esta máquina es **LVDS**, confirmado por `/sys/class/drm/card0-LVDS-1/status` y por
el `PANEL_PORT_SELECT=0` que había decodificado. Con eDP, libgfxinit habría inicializado un
puerto que no existe y **la pantalla no encendía**. Faltaba un `select GFX_GMA_PANEL_1_ON_LVDS`
que tanto el X220 como el Dell Latitude tienen y autoport no genera.

Si no lo agarraba en esa revisión, gastaba el intento sin entender por qué.

**La VBT.** Ni el X220 ni el Dell la omiten. Intenté sacarla del firmware y no salió (está
adentro de módulos UEFI comprimidos), pero Linux la expone en debugfs:
`/sys/kernel/debug/dri/0000:00:02.0/i915_vbt`. Salió una `$VBT SANDYBRIDGE-M` de 6144 bytes,
válida. A veces la solución fácil está ahí nomás.

**`Port_List`.** La plantilla de autoport quedó vieja: el tipo de libgfxinit ahora pide 21
elementos. Faltaba `others => Disabled`.

**`DRAM_RESET_GATE_GPIO = 60`.** Autoport lo marca como dudoso. Lo verifiqué contra el propio
`gpio.c` leído del hardware: HP configura ese pin como `GPIO_MODE_GPIO` + `GPIO_DIR_OUTPUT`,
que es exactamente lo que `southbridge_gate_memory_reset()` necesita. Confirmado, no adivinado.

### Cosas que salieron mejor de lo que esperaba

Varias que tenía anotadas como problema no lo fueron:

- **El blob del MRC no hace falta.** coreboot tiene raminit nativo para Sandy Bridge
  (`USE_NATIVE_RAMINIT`, default `y`, con un comentario que dice literal *"You should answer Y"*).
- **La option ROM de video tampoco**, gracias a libgfxinit.
- **me_cleaner no es requisito de coreboot.** El ME vive en su región y coreboot ni la toca.
- **El modo SATA no importaba.** El controlador estaba en RAID y el BIOS de HP ni siquiera te
  deja cambiarlo, pero coreboot lo pone en AHCI por su cuenta (`/* Default to AHCI */`).
- **El EC no era `kbc1126`** (el driver que hizo viables los ports de los EliteBook), pero el
  **DSDT del firmware original documenta el protocolo entero**: mapa de RAM con campos
  nombrados, la ventana `ECMA` en `0xFE802000`, y unos 25 métodos `_Qxx`. O sea que la
  documentación que necesitaba estaba adentro de la máquina.

---

## Flashear

Tres intentos. Los dos primeros fallaron **sin escribir un byte**, y las razones valen oro:

**1.** `No EEPROM/flash device found`. Resulta que el `FLOCKDN` que cerramos temprano congela
también el **menú de opcodes del SPI**, antes de que el firmware lo programe
(`OPMENU0 = OPMENU1 = PREOP = 0`). flashrom se cae a *hardware sequencing*, no puede hacer
`RDID` y usa un "Opaque flash chip". Si le pasás `-c <chip>` falla. **Solución: no pasarle `-c`.**

**2.** `Transaction error`. Por defecto flashrom lee el chip entero antes de escribir, y la
región ME es ilegible. **Solución: `--noverify-all`**, que verifica solo lo que escribe. Y esto
flashrom te lo venía diciendo en el mensaje de arriba, que yo estaba ignorando como un campeón.

**3.** El que anduvo:

```bash
flashrom -p internal:laptop=force_I_want_a_brick --ifd -i bios --noverify-all -w coreboot.rom
```

```
Updating flash chip contents... Erase/write done from 180000 to 3fffff
Verifying flash... VERIFIED.
```

Después leí la región de vuelta y la comparé contra la ROM por mi cuenta: byte por byte idéntica,
reset vector incluido.

Y acá viene el momento incómodo: apretar reset sabiendo que si el raminit no levanta, la máquina
no postea y me toca la pinza. Que era literalmente lo que estaba tratando de evitar desde el
principio jajaja.

---

## Arrancó al primer intento

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

Entrenó los dos módulos Kingston desde cero, sin blob de MRC. Video, audio, red, teclado,
touchpad, tapa y las teclas Fn andando.

Faltaba una sola cosa: la batería.

---

## La batería, que fue su propia aventura

El firmware original resuelve la batería con `BAT0` (`PNP0C0A`) y `ADP1` (`ACPI0003`), apoyados
en dos helpers `GBIF` y `GBST`. Unas 350 líneas de ASL.

El análisis de dependencias encontró 7 referencias externas, y una parecía que iba a hundir todo:

```asl
Method (RBEC, 1) {
    Return (TRPS (0x10, Arg0))      ; trampa SMI al handler SMM de HP
}
```

Bajo coreboot ese handler no existe. Pero mirando dónde se usaba, me salvó el patrón:

```asl
If (ECON)  { ...lectura directa del EC... }
Else       { Local0 = RBEC (0x88) }
```

`RBEC` estaba **siempre** en la rama `Else`. Y `ECON` significa "el EC está disponible por la
interfaz ACPI normal", que bajo coreboot es verdad. Con `ECON = 1`, ese camino no se ejecuta
nunca. Zafé.

El resto se resolvió solo: `BATM` era un `Mutex` declarado en el mismo bloque (mi script de
dependencias no lo detectó porque no buscaba esa palabra clave), `GWET`/`WMID` una notificación
WMI que se puede omitir, y `SMA4` solo elige un multiplicador para el umbral de aviso de batería
baja.

### ★ El LGMR, el que no salía de ningún log

Con el ASL portado y compilando limpio, Linux enumeró los cuatro devices ACPI. **El adaptador
andaba.** La batería, no:

```
ACPI: battery: Slot [BAT0] (battery absent)
```

O sea que el ASL estaba bien: Linux consultaba `_STA` y recibía "ausente". El problema estaba
más abajo. Leyendo la ventana `ECMA` directo, todo daba `0xff`:

```
ECMA+0x08 = 0xff        <- no son datos, es memoria sin decodificar
BSRC = BSFC = BSVO = 65535
```

**Esa ventana no es una interfaz nativa del chipset.** Se abre programando el **LGMR** (LPC
Generic Memory Range, registro `0x98` del device LPC). HP lo configuraba, coreboot no.

Y acá está lo jodido: **el `LGMR` no aparece en ningún log que genere `autoport`**. Ni en
`inteltool`, ni en `lspci`, ni en `acpidump`. Salió únicamente de perseguir el síntoma hasta el
registro, comparando lo que decía ACPI contra lo que decía el EC de verdad.

```
LGMR (LPC cfg 0x98) con coreboot = 0x00000000
```

Lo probé en caliente con `setpci`, sin reflashear ni reiniciar:

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

(el registro solo decodifica los bits 31:16, así que la ventana es de 64 KB alineada: base
`0xFE800000` cubre `0xFE802000`; bit 0 = enable)

De paso me enteré de que la batería conserva 5918 mAh de los 8850 de diseño. Un 67% después de
14 años, no está tan mal la vieja.

### Y todavía faltaba una

Con la batería ya visible, quedaba un detalle: **el widget no se movía**. Enchufabas el cargador
y ACPI seguía reportando lo de antes.

Dos causas juntas. Una, `_PSR` y `_STA` cacheaban el resultado en `ACST`/`B0ST`: leían una vez y
después devolvían siempre lo mismo. Dos, faltaban los manejadores `_Qxx`, que son los eventos que
el EC dispara y que en el firmware de HP resetean esos caches y llaman a `Notify()`.

Los porté todos (`_Q40`, `_Q41`, `_Q48`, `_Q4C`, `_Q50`, `_Q51`, `_Q52`, `_Q53`) omitiendo las
llamadas a rutinas de HP que acá no existen, y de paso saqué el cacheo para que aunque un evento
no llegue el valor se relea igual. Cinturón y tiradores.

---

## Cómo quedó

| | |
|:---|:---|
| Firmware | **coreboot**, port propio, payload SeaBIOS |
| RAM | raminit nativo, sin blobs |
| Video | libgfxinit nativo + VBT sacada del hardware |
| Blobs propietarios | **solo el ME**, que quedó intacto |
| Dual boot | Windows y Slackware, sin tocar nada |

**Anda**: video 1600x900 con backlight, WiFi, audio, teclado, touchpad, tapa, teclas Fn,
temperaturas de CPU, batería y cargador.

**Falta**: probar el suspend a S3 bajo coreboot.

**Y algo que cambia todo para adelante:** coreboot usa `BOOTMEDIA_LOCK_NONE` y no programa los
registros PR. Con coreboot corriendo, `BIOS_CNTL = 0x09` (BIOSWE ya en 1) y `PR0 = 0`.

El flash quedó **abierto para siempre**. Reflashear ya no necesita el exploit ni el
suspend/resume ni nada: un comando y chau. Aquel primer arranque exitoso convirtió "tengo un
intento" en "tengo los que quiera".

La pinza no salió del cajón.

---

## El Intel ME, lo único que no pude

Sigue **activo**. Del log de coreboot:

```
ME: FW Partition Table      : OK
ME: Firmware Init Complete  : YES
ME: Current Working State   : Normal
ME: Current Operation State : M0 with UMA
ME: Error Code              : No Error
```

coreboot no lo toca, lo deja donde está. Y **no se puede desactivar por software en esta
máquina**, por una razón de hardware que se mantuvo firme todo el camino:

El descriptor le niega al host **lectura y escritura** de la región ME (`FREG2: Management
Engine region is locked`). Ni siquiera podés leerla para procesarla con `me_cleaner`. Y el
descriptor, que es quien impone eso, también es de solo lectura para el host.

El exploit limpió `PR0`, pero los permisos de región vienen de `FRAP`, que el hardware repuebla
desde el descriptor **en cada arranque**. Ningún resume, ningún SMM y ningún exploit los cambia.
Fue lo único que marqué como imposible por software en el primer análisis, y se mantuvo así
hasta el final.

**Con un programador externo (clip SOIC-8 + Raspberry Pi) se resuelve, y conviene hacer dos
cosas de una:**

1. **`me_cleaner`** sobre la región ME. En Sandy Bridge (ME 7/8) no se puede borrar del todo
   (sin un ME mínimamente funcional la plataforma se apaga a los 30 minutos), pero sí dejarlo
   reducido a su módulo de arranque y sin hacer nada más.
2. **Escribir un descriptor desbloqueado** que le dé al host acceso total a todas las regiones.
   A partir de ahí queda **todo flasheable por software para siempre**, ME incluido.

Una sola sesión con el clip te compra permanentemente lo que hoy no tenés. Algún día.
