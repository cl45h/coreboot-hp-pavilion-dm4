#!/usr/bin/env python3
"""Busca escrituras a registros del SPI dentro del boot script de S3.

SOLO lee ACPI NVS y ACPI Tables, que son DRAM normal. Rangos hardcodeados
a proposito: NO se recorre /proc/iomem ni ninguna region 'Reserved', porque
leer MMIO o SMRAM por /dev/mem puede tirar la maquina.
"""
import os, mmap, struct, sys

REGIONS = [
    (0xacebf000, 0xacfbefff, 'ACPI NVS'),
    (0xacfbf000, 0xacffefff, 'ACPI Tables'),
]

TARGETS = {
    0xFED1F800: 'SPIBAR base',
    0xFED1F804: 'HSFS (FLOCKDN)',
    0xFED1F850: 'FRAP',
    0xFED1F874: 'PR0  <<<< EL OBJETIVO',
    0xFED1F878: 'PR1',
    0xFED1F87C: 'PR2',
}

# opcodes del boot script EFI
OPC = {0x00: 'IO_WRITE', 0x01: 'IO_READ_WRITE', 0x02: 'MEM_WRITE',
       0x03: 'MEM_READ_WRITE', 0x04: 'PCI_WRITE', 0x05: 'PCI_READ_WRITE',
       0x06: 'SMBUS', 0x07: 'STALL', 0x08: 'DISPATCH', 0x09: 'DISPATCH2',
       0x0A: 'MEM_POLL', 0x0B: 'INFO', 0x0C: 'PCI2_WRITE',
       0x0D: 'PCI2_READ_WRITE', 0x0E: 'IO_POLL', 0xAA: 'TABLE', 0xFF: 'TERMINATE'}

fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
hits = 0
for base, end, name in REGIONS:
    size = end - base + 1
    print(f"[*] leyendo {name}: 0x{base:08x}-0x{end:08x} ({size//1024} KB)", flush=True)
    m = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    buf = m[:]
    m.close()
    for addr, label in TARGETS.items():
        for width, pk in ((4, '<I'), (8, '<Q')):
            pat = struct.pack(pk, addr)
            pos = 0
            while True:
                pos = buf.find(pat, pos)
                if pos < 0:
                    break
                hits += 1
                phys = base + pos
                pre = buf[max(0, pos-8):pos]
                post = buf[pos+width:pos+width+16]
                # el header del boot script es {u16 opcode; u8 length}
                guess = ''
                for back in range(3, 13):
                    if pos - back >= 0:
                        op = buf[pos-back]
                        if op in OPC and buf[pos-back+1] == 0:
                            guess = f"  op={OPC[op]} len={buf[pos-back+2]} @-{back}"
                            break
                print(f"  *** {label}  ({width}B) fisica 0x{phys:010x}{guess}", flush=True)
                print(f"      antes={pre.hex()}  despues={post.hex()}", flush=True)
                pos += 1
os.close(fd)
print(f"\ntotal hits: {hits}", flush=True)
if not hits:
    print("=> el boot script no reprograma el SPI por escritura a memoria directa,", flush=True)
    print("   o la tabla esta en otro lado / comprimida.", flush=True)
