#!/usr/bin/env python3
"""Lee los registros del SPI controller (Cougar Point / serie 6) via RCBA MMIO."""
import mmap, os, struct, subprocess

bc = subprocess.check_output(['setpci', '-s', '00:1f.0', '0xdc.b']).strip().decode()
bcv = int(bc, 16)
print(f"BIOS_CNTL = 0x{bcv:02x}   BIOSWE={bcv & 1}  BLE={(bcv >> 1) & 1}  SMM_BWP={(bcv >> 5) & 1}")

raw = subprocess.check_output(['setpci', '-s', '00:1f.0', '0xf0.l']).strip().decode()
rcba = int(raw, 16)
print(f"RCBA raw  = 0x{rcba:08x}  (enable={rcba & 1})")
rcba &= 0xFFFFC000
spibar = rcba + 0x3800
print(f"SPIBAR    = 0x{spibar:08x}\n")

page, off = spibar & ~0xFFF, spibar & 0xFFF
fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=page)
r32 = lambda o: struct.unpack('<I', m[off + o:off + o + 4])[0]
r16 = lambda o: struct.unpack('<H', m[off + o:off + o + 2])[0]

hsfs = r16(0x04)
print(f"HSFS = 0x{hsfs:04x}   FLOCKDN={'SI' if hsfs & 0x8000 else 'NO'}  "
      f"FDV={'SI' if hsfs & 0x4000 else 'NO'}  SCIP={hsfs & 1}\n")

names = ['descriptor', 'BIOS', 'ME', 'GbE', 'PDR']
frap = r32(0x50)
brra, brwa = frap & 0xFF, (frap >> 8) & 0xFF
print(f"FRAP = 0x{frap:08x}   permisos del host sobre cada region:")
for i, n in enumerate(names):
    print(f"   {n:11s} leer={'SI' if brra >> i & 1 else 'NO':3s}  escribir={'SI' if brwa >> i & 1 else 'NO'}")

print("\nlayout del flash:")
for i, n in enumerate(names):
    fr = r32(0x54 + i * 4)
    base = (fr & 0x7FFF) << 12
    limit = (((fr >> 16) & 0x7FFF) << 12) | 0xFFF
    if base > limit:
        print(f"   FREG{i} {n:11s}: no usada  (raw 0x{fr:08x})")
    else:
        print(f"   FREG{i} {n:11s}: 0x{base:07x}-0x{limit:07x}  {(limit - base + 1) // 1024} KB")

print("\nrangos protegidos:")
for i in range(5):
    pr = r32(0x74 + i * 4)
    if pr == 0:
        print(f"   PR{i} = 0x00000000  sin proteccion")
    else:
        base = (pr & 0x7FFF) << 12
        limit = (((pr >> 16) & 0x7FFF) << 12) | 0xFFF
        print(f"   PR{i} = 0x{pr:08x}  0x{base:07x}-0x{limit:07x}  "
              f"WP={'SI' if pr >> 31 & 1 else 'no'}  RP={'SI' if pr >> 15 & 1 else 'no'}")

m.close()
os.close(fd)
