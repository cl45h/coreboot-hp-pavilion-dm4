/* SPDX-License-Identifier: GPL-2.0-only */
/* By cl45h, Aguante RemoteExecution, siempre <3 */

#include <device/azalia_device.h>

const u32 cim_verb_data[] = {
	0x111d76e0,	/* Codec Vendor / Device ID: IDT */
	0x103c1793,	/* Subsystem ID */
	11,		/* Number of 4 dword sets */
	AZALIA_SUBVENDOR(0, 0x103c1793),
	AZALIA_PIN_CFG(0, 0x0a, 0x04a11020),
	AZALIA_PIN_CFG(0, 0x0b, 0x0421101f),
	AZALIA_PIN_CFG(0, 0x0c, 0x40f000f0),
	AZALIA_PIN_CFG(0, 0x0d, 0x92170110),
	AZALIA_PIN_CFG(0, 0x0e, 0x40f000f0),
	AZALIA_PIN_CFG(0, 0x0f, 0x40f000f0),
	AZALIA_PIN_CFG(0, 0x10, 0x40f000f0),
	AZALIA_PIN_CFG(0, 0x11, 0xd5a30130),
	AZALIA_PIN_CFG(0, 0x1f, 0x40f000f0),
	AZALIA_PIN_CFG(0, 0x20, 0x40f000f0),

	0x80862805,	/* Codec Vendor / Device ID: Intel */
	0x103c1793,	/* Subsystem ID */
	4,		/* Number of 4 dword sets */
	AZALIA_SUBVENDOR(3, 0x103c1793),
	AZALIA_PIN_CFG(3, 0x05, 0x18560010),
	AZALIA_PIN_CFG(3, 0x06, 0x58560020),
	AZALIA_PIN_CFG(3, 0x07, 0x58560030),

};

const u32 pc_beep_verbs[0] = {};

AZALIA_ARRAY_SIZES;
