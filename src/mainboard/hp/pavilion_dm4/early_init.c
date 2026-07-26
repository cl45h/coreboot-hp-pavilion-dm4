/* SPDX-License-Identifier: GPL-2.0-only */
/* By cl45h, Aguante RemoteExecution, siempre <3 */

#include <bootblock_common.h>
#include <device/pci_ops.h>
#include <southbridge/intel/bd82x6x/pch.h>

void bootblock_mainboard_early_init(void)
{
	/* LPC_EN: habilita el decode de 0x60/0x64 (teclado) y 0x62/0x66 (EC) */
	pci_write_config16(PCI_DEV(0, 0x1f, 0), 0x82, 0x3f03);
	pci_write_config16(PCI_DEV(0, 0x1f, 0), 0x80, 0x0010);

	/*
	 * LGMR (LPC Generic Memory Range, cfg 0x98).
	 *
	 * El EC expone una ventana de datos en 0xFE802000 -- de ahi salen la
	 * informacion de bateria (BSRC/BSFC/BSVO/BSDC/BSDV) y los bits de
	 * presencia NB0A/NB0N que usa el ASL. No es una interfaz nativa del
	 * chipset: hay que abrirle el decode por LPC, cosa que el firmware
	 * original hacia y autoport no detecto.
	 *
	 * El registro solo decodifica los bits 31:16, o sea que la ventana es de
	 * 64 KB alineada: base 0xFE800000 cubre 0xFE802000. Bit 0 = enable.
	 *
	 * Sin esto la ventana lee 0xff y la bateria figura como ausente.
	 */
	pci_write_config32(PCI_DEV(0, 0x1f, 0), 0x98, 0xfe800001);
}
