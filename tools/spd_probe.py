#!/usr/bin/env python3
"""Sondea las direcciones de SPD en el SMBus. Solo lectura.

Equivalente a 'i2cdetect -r' limitado al rango de SPD (0x50-0x57), usando
el ioctl I2C_SMBUS directo para no depender de i2c-tools.
"""
import ctypes, fcntl, os, sys

I2C_SLAVE_FORCE = 0x0706
I2C_SMBUS       = 0x0720
I2C_SMBUS_READ  = 1
I2C_SMBUS_BYTE_DATA = 2


class SmbusData(ctypes.Union):
    _fields_ = [('byte', ctypes.c_ubyte),
                ('word', ctypes.c_ushort),
                ('block', ctypes.c_ubyte * 34)]


class SmbusIoctlData(ctypes.Structure):
    _fields_ = [('read_write', ctypes.c_ubyte),
                ('command', ctypes.c_ubyte),
                ('size', ctypes.c_uint),
                ('data', ctypes.POINTER(SmbusData))]


def read_byte(fd, cmd):
    data = SmbusData()
    arg = SmbusIoctlData(I2C_SMBUS_READ, cmd, I2C_SMBUS_BYTE_DATA, ctypes.pointer(data))
    fcntl.ioctl(fd, I2C_SMBUS, arg)
    return data.byte


BUS = '/dev/i2c-0'
if not os.path.exists(BUS):
    os.system('modprobe i2c-dev 2>/dev/null')
if not os.path.exists(BUS):
    print(f"{BUS} no existe (falta i2c-dev)"); sys.exit(1)

print(f"sondeando {BUS} (SMBus I801), direcciones 0x50-0x57\n")
found = []
for addr in range(0x50, 0x58):
    fd = os.open(BUS, os.O_RDWR)
    try:
        fcntl.ioctl(fd, I2C_SLAVE_FORCE, addr)
        b0 = read_byte(fd, 0)     # SPD byte 0
        b2 = read_byte(fd, 2)     # tipo de memoria: 0x0b = DDR3
        b3 = read_byte(fd, 3)
        # part number: bytes 128-145
        pn = bytes(read_byte(fd, i) for i in range(128, 146)).decode('ascii', 'replace').strip()
        tipo = {0x0b: 'DDR3', 0x08: 'DDR2', 0x0c: 'DDR4'}.get(b2, f'0x{b2:02x}')
        print(f"  0x{addr:02x}: PRESENTE   byte0=0x{b0:02x}  tipo={tipo}  part='{pn}'")
        found.append(addr)
    except OSError:
        print(f"  0x{addr:02x}: --")
    finally:
        os.close(fd)

print(f"\nSPD encontrados: {[hex(a) for a in found]}")
if found:
    print("\nmapa para el devicetree de coreboot (C0D0, C0D1, C1D0, C1D1):")
    slots = {0x50: 0, 0x51: 1, 0x52: 2, 0x53: 3}
    m = ['0x00'] * 4
    for a in found:
        if a in slots:
            m[slots[a]] = f'0x{a:02x}'
    print(f'    register "spd_addresses" = "{{{", ".join(m)}}}"')
