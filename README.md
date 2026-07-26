# coreboot en una HP Pavilion dm4-3099se (placa 1793)

Bueno, esto es un port de coreboot para mi notebook vieja que ya no tiene mas soporte de nadie,siempre intui que se podia instalar, ya que no habia nadie que lo instalo en esta notebook, ademas esta  el
exploit que hice para poder flashearla sin abrir la máquina(me daba paja, a pesar de que la desarme 1 millon de veces).

Hace tiempo que  queria instalarlo, y a veces hacia algun research, pero siempre la quedaba,entonces me propuse, voy a tratar de flashear lo mas que se pueda, y si se brickea, buen tocara usar la pinza xD
tambien me pregunte se le podrá poner libreboot a esta notebook vieja?" y terminó en esto.

> **English summary:** coreboot mainboard port for the HP Pavilion dm4-3000 series
> (board ID 1793, Sandy Bridge / HM67). Includes an S3 boot script exploit that unlocks the
> SPI flash boot block, so you can replace the firmware entirely in software, no SOIC-8 clip
> or external programmer needed. Write-ups are in `docs/` (Spanish).

---

## Primero lo importante: libreboot no existe para esto

Antes de que preguntes: **no se "portea a libreboot"**. Libreboot no es un firmware, es una
distribución de coreboot. Agarra coreboot, lo configura, le mete un payload y publica ROMs
listas para una lista cortita de placas. Vos porteás a **coreboot**, y libreboot después
decide si lo empaqueta o no. Esta placa no está en esa lista ni va a estar.

Y en HP, coreboot solo soporta la línea business (EliteBook, ProBook), porque cada placa hay
que portearla a mano. Los Pavilion de consumo no están. El único Pavilion en todo el árbol de
coreboot es un m6-1035dx, que encima es AMD.

O sea que había que escribir el port desde cero, y encima encontrar la forma de flashearlo.

## Qué anda y qué no

Probado en **mi** dm4-3099se. A mí me funcionó, ojo con eso.

| | |
|:---|:---|
| Arranque | ✅ SeaBIOS → GRUB → Linux / Windows |
| RAM | ✅ raminit nativo, sin blob de MRC |
| Video | ✅ libgfxinit, LVDS 1600x900 con backlight |
| Audio | ✅ codec IDT |
| WiFi / Ethernet / USB | ✅ |
| Teclado / touchpad | ✅ |
| Batería y cargador | ✅ |
| Tapa | ✅ |
| Teclas Fn | ✅ volumen y luz del teclado (esas las maneja el EC solo, ni pasan por ACPI) |
| Temperaturas de CPU | ✅ |
| Suspend a S3 | ⚠️ no lo probé con coreboot todavía |
| Intel ME | ⚠️ sigue vivo, más abajo te cuento |

## Specs de la note(conste es un frankestein, ese procesador, no deberia estar soportado, y las rams que tiene tampoco, pero esa.. es otra historia xD)

| | |
|:---|:---|
| Placa | 1793 (`$BID01793`, está grabado en el firmware) |
| CPU | i7-2630QM, Sandy Bridge |
| PCH | HM67, Cougar Point serie 6 |
| Video | Intel HD 3000, panel LVDS |
| SPI flash | Macronix MX25L32xx de 4 MB |
| BIOS original | InsydeH2O F.0C, del 2013. La última que sacó HP |

## Compilarlo

```bash
git clone https://review.coreboot.org/coreboot.git
cd coreboot
cp -r /ruta/a/este/repo/src/mainboard/hewlett_packard/* src/mainboard/hewlett_packard/
make crossgcc-i386 CPUS=$(nproc)
make menuconfig     # Mainboard -> Hewlett-Packard -> HP Pavilion dm4 Notebook PC
make
```

Usá **SeaBIOS** como payload. Si tenés dual boot con Windows en MBR es lo único que te va a
andar, y de paso arranca GRUB sin quilombo. Prendé también `CONSOLE_CBMEM` y `USBDEBUG`,
porque si algo explota son la única forma de enterarte de dónde.

---

# El exploit

Esta es la parte más copada, así que la explico acá y no te mando solo al writeup.

## El problema

El firmware de HP protege el **boot block** del flash con el registro `PR0` del controlador
SPI. Concretamente el rango `0x3a1000-0x3fffff`, que resulta ser **exactamente** donde vive
el reset vector (`0xFFFFFFF0` mapea al offset `0x3ffff0` del chip).

O sea: justo donde coreboot necesita meter su bootblock. Mirá vos qué casualidad.

```
BIOS_CNTL (LPC 0xDC) = 0x00     BIOSWE=0  BLE=0  SMM_BWP=0
HSFS      (+0x04)    = 0xe008   FLOCKDN=1
PR0       (+0x74)    = 0x83ff03a1  -> protege 0x3a1000-0x3fffff
```

Podés escribir el 85% de la región BIOS, pero no la parte que sirve. Sin saltar eso, o
comprás un programador SPI y abrís la máquina, o no hay coreboot.

Y mirá esto: el flasher de HP trae `[ForceFlash] BB_PEI=0` en su propio `platform.ini`. O sea
que **su actualizador tampoco toca el boot block**. No es que no quiera, no puede.

## Lo que NO funcionó

Lo primero que probé fue el ataque clásico al boot script de S3 (Wojtczuk & Kallenberg, 2015).
La idea es esta: cuando la máquina se suspende a S3, el firmware deja grabada una tabla con
todas las operaciones que tiene que repetir al despertar, para restaurar el estado del
chipset. Esa tabla vive en memoria ACPI NVS, que **el sistema operativo puede escribir**.
Entonces buscás la entrada que reprograma `PR0` y la parcheás.

Lo probé sin riesgo: `rtcwake -m mem`, y a leer los registros al volver. El `dmesg` confirmó
que fue S3 de verdad, y `PR0` volvió idéntico. El firmware lo reaplica en el resume.

Después mapeé la tabla entera: **903 entradas**. 477 `PCI_WRITE`, 247 `MEM_WRITE`,
147 `MEM_READ_WRITE`, 25 `DISPATCH`, 5 `IO_WRITE`.

Y el resultado fue que **el boot script no escribe `PR0` ni `FLOCKDN`**. Chequeado sobre las
903. Toca un montón de registros del RCBA y hasta los VSCC del SPI, pero las protecciones no.

O sea: no había nada que parchear. El ataque clásico no aplicaba.

## Lo que sí funcionó

Pero mapear la tabla sirvió igual. De esas 25 entradas `DISPATCH` (el opcode que salta a
ejecutar código en una dirección física guardada **en la propia tabla**), 24 apuntaban todas
al mismo lado: `0xACEBC260`. Que resultó ser DRAM marcada como `Reserved`, o sea escribible
desde el sistema, con código x86 de 32 bits ahí adentro:

```asm
0xACEBC260:  ff 74 24 08     push dword [esp+8]
             ff 74 24 08     push dword [esp+8]
             e8 1e 11 00 00  call ...
             59 59           pop ecx / pop ecx
             e9 bc 01 00 00  jmp  ...
```

(la número 25 apuntaba a `0xFFFAF998`, adentro del boot block protegido, esa ni la toqué)

Eso es **ejecución de código arbitrario en el contexto de resume del firmware**. La pregunta
era si servía de algo, y eso dependía de algo que no sabía: ¿cuándo aplica el firmware las
protecciones, antes o después de correr el boot script?

Así que lo medí. Reapunté los punteros de la primera y la última entrada `DISPATCH` a stubs
míos de 45 bytes, que leen `HSFS` y `PR0`, dejan el valor en memoria, y saltan a la rutina
original para no romper el resume.

| | primer DISPATCH | último DISPATCH | corriendo normal |
|:---|:---|:---|:---|
| `HSFS` | `0x6008` | `0x6008` | `0xe008` |
| `PR0` | `0x00000000` | `0x00000000` | `0x83ff03a1` |

`0x6008` tiene el bit 15 (`FLOCKDN`) **en cero**. Ahí está la posta: **el firmware aplica las
protecciones DESPUÉS de terminar el boot script.** O sea que existe una ventana donde todo
está abierto, y yo puedo ejecutar código adentro de esa ventana.

Ahora, limpiar `PR0` desde ahí no sirve para nada, porque el firmware lo reescribe al final.
Pero `FLOCKDN` es un bit de **una sola escritura**: una vez que lo ponés en 1, los registros
`PR` quedan congelados hasta el próximo reset, **no importa quién intente escribirlos después**.

Entonces qué hago: **le cierro el candado yo primero, con los registros todavía vacíos.**

```asm
    push eax
    push edx
    mov  edx, 0xFED1F874        ; PR0
    mov  eax, [edx]
    mov  [RES+0], eax           ; guardo PR0 antes, como evidencia
    mov  edx, 0xFED1F804        ; HSFS
    mov  ax,  0x8000            ; FLOCKDN
    mov  [edx], ax              ; <<< acá se cierra el candado
    movzx eax, word [edx]
    mov  [RES+4], eax
    mov  edx, 0xFED1F874
    mov  eax, [edx]
    mov  [RES+8], eax           ; y PR0 después
    mov  dword [RES+12], 0xC0FFEE03
    pop  edx
    pop  eax
    push 0xACEBC260             ; salto a la rutina original
    ret
```

64 bytes, colgados del puntero de la última entrada `DISPATCH`. Un `rtcwake -m mem -s 20` y
listo. Cuando el firmware quiere escribir `PR0`, su escritura se va a la mierda en silencio.

```
antes del suspend:  HSFS = 0xe008   PR0 = 0x83ff03a1
después del resume: HSFS = 0xe008   PR0 = 0x00000000
```

Y flashrom lo confirmó solo: desapareció el `PR0: Warning ... read-only` y la región BIOS
entera pasó a figurar como `read-write`. **Boot block liberado, sin tocar un tornillo.**

Un detalle que importa: el exploit **no pisa** la rutina que está en `0xACEBC260`. La llaman
24 veces y si la rompés se te va todo el resume al carajo. Solo reapunto **una** entrada, y mi
stub salta a la original cuando termina.

## ¿Esto es nuevo? Na

Para no vender humo: la clase de bug es de 2015, y en su momento hubo advisories de CERT/CC y
de varios fabricantes. Lo que tengo acá es un caso puntual, medido y sin parchear, con PoC que
anda. Nada más que eso.

Para CVE las chances son bajas. El producto está muerto hace años, la clase ya está
documentada, y encima arrancás desde ring 0.

Lo que sí puede ser juicy es ver si el mismo patrón está en toda la familia de HP de consumo
con InsydeH2O de esa época. Ahí ya no sería "una notebook vieja", sería un bug de plataforma
que se comió un montón de equipos. Pero eso no lo verifiqué, tengo una sola máquina xD o no :P?

---

## Flashear

```bash
sudo python3 tools/exploit_auto.py     # mete el stub en el boot script
sudo rtcwake -m mem -s 20              # suspende y despierta: acá se dispara
sudo python3 tools/spi_check.py        # PR0 tiene que dar 0x00000000

sudo flashrom -p internal:laptop=force_I_want_a_brick \
              --ifd -i bios --noverify-all -w build/coreboot.rom
```

Tres cosas que me hicieron perder tiempo a mí y te las ahorro:

**No le pases `-c <chip>` a flashrom.** El `FLOCKDN` que cerramos temprano congela también el
menú de opcodes del SPI, así que flashrom se cae a *hardware sequencing*, no puede hacer `RDID`
y termina usando un "Opaque flash chip". Si le forzás el modelo te tira
`No EEPROM/flash device found` y no escribe nada.

**`--noverify-all` no es opcional.** Sin eso flashrom quiere leerse el chip entero antes de
escribir, incluida la región del ME que es ilegible, y aborta con `Transaction error`.

**El efecto vive en RAM.** Cada arranque en frío reconstruye el boot script, así que si vas a
flashear de nuevo tenés que repetir el suspend/resume.

Y ahora la buena: **una vez que coreboot arranca, el exploit no lo necesitás nunca más.**
coreboot usa `BOOTMEDIA_LOCK_NONE` y no programa los registros PR, o sea que el flash queda
abierto para siempre. Reflashear pasa a ser un comando y chau.

### Hacete un backup antes, no seas ansioso

```bash
sudo flashrom -p internal:laptop=force_I_want_a_brick \
              --ifd -i bios -r backup_bios_region.bin
```

Guardalo en **otra** máquina, no en la que vas a flashear. Si algo sale mal y no postea, ese
archivo más un clip SOIC-8 te devuelven el firmware original.

## El Intel ME

Sigue vivo. coreboot no lo toca, lo deja donde está.

Y **no se puede desactivar por software en esta placa**. No es culpa de coreboot, es el
hardware: el flash descriptor le niega al host lectura *y* escritura de la región del ME. Ni
siquiera podés leerla para pasarle `me_cleaner`. Y esos permisos los repuebla el chipset
leyendo el descriptor en cada arranque, y el descriptor también es de solo lectura. Ni el
exploit, ni coreboot, ni nada que corra en el CPU los puede cambiar.

Para eso sí o sí necesitás un programador SPI externo. Y si vas a hacerlo, hacé las dos cosas
de una: corré `me_cleaner` **y** escribí un descriptor desbloqueado. Después de eso te queda
todo flasheable por software para siempre, ME incluido. Una sola vez con el clip y no lo
necesitás nunca más.

## Las herramientas

| | |
|:---|:---|
| `tools/exploit_auto.py` | busca el boot script de S3 y mete el exploit de `FLOCKDN`. Localiza todo solo, no tiene direcciones hardcodeadas |
| `tools/spi_check.py` | te muestra las protecciones del SPI: `BIOS_CNTL`, `HSFS`, `FRAP`, `PR0-4` y el layout del flash |
| `tools/bs2.py` | parsea el boot script de S3 |
| `tools/spd_probe.py` | busca las direcciones SPD en el SMBus sin que tengas que instalar `i2c-tools` |

## Los writeups

En `docs/` están los dos, y si vas a portar otra placa te conviene leerlos.

**`WRITEUP_completo_coreboot_dm4.md`** cuenta todo el proceso: el reconocimiento, el SoftPaq
cifrado que no fue a ningún lado (entropía 7.9995, barrí 8 binarios × 9 cifrados y nada), el
mapa del flash, cómo salió el exploit, el port con las seis correcciones que hubo que hacer a
mano, y los tres intentos de flasheo hasta que entró.

**`WRITEUP_s3_bootscript_pr0_bypass.md`** es el exploit en detalle, con el shellcode comentado,
la evidencia y las mitigaciones.

Ahí están las cosas que ninguna herramienta te va a decir. Dos ejemplos de los que más me
costaron:

- `autoport` te deja el panel configurado como **eDP** cuando el de esta máquina es **LVDS**.
  Con eso la pantalla no enciende y no tenés idea de por qué. Falta un
  `select GFX_GMA_PANEL_1_ON_LVDS` que ni el X220 ni el Dell Latitude omiten, pero autoport no
  genera.
- El registro **`LGMR`** (LPC cfg `0x98`) abre el decode de la ventana del EC en `0xFE802000`,
  de donde salen los datos de la batería. HP lo programaba, coreboot no, y **no aparece en
  ningún log de autoport**: ni en `inteltool`, ni en `lspci`, ni en `acpidump`. Sin eso la
  batería te figura como ausente y el ASL parece estar mal cuando en realidad está perfecto.

## Ojo

Tocar el firmware te puede dejar la máquina de pisapapeles,  no me hago cargo si se rompe tu fucking machine. Esto está probado en **mi** máquina
y a mí me anduvo, pero yo tengo *esta* dm4-3099se. Si la tuya es otra variante de la
dm4-3000, fijate por lo menos el mapa de SPD y los tiempos del panel antes de flashear, que
están los dos documentados en el writeup.

Y tené un clip SOIC-8 a mano. No para flashear, sino para poder tratar de recuperarla si la cagaste tranquilo xD.

## Licencia

GPL-2.0-only, igual que coreboot.

El ASL de la batería en `acpi/ec.asl` sale del DSDT del firmware original de HP, y `data.vbt`
es el Video BIOS Table sacado del mismo equipo. Van incluidos porque sin ellos el hardware no
anda, que es lo que hacen todos los ports de coreboot igual.

---

*By cl45h, Aguante RemoteExecution, siempre <3*
