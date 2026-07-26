/* SPDX-License-Identifier: GPL-2.0-only */
/* By cl45h, Aguante RemoteExecution, siempre <3 */

/*
 * Embedded Controller del HP Pavilion dm4-3000 (placa 1793).
 *
 * Interfaz ACPI estandar en los puertos 0x62 (datos) y 0x66 (comando/estado),
 * evento SCI en GPE 0x17. El mapa de registros se obtuvo del DSDT del firmware
 * original (InsydeH2O F.0C) y esta verificado contra el hardware.
 */

Device (EC0)
{
	Name (_HID, EISAID("PNP0C09"))
	Name (_UID, 0)
	Name (_GPE, 0x17)

	Method (_STA, 0, NotSerialized)
	{
		Return (0x0F)
	}

	Name (_CRS, ResourceTemplate()
	{
		IO (Decode16, 0x62, 0x62, 0, 1)
		IO (Decode16, 0x66, 0x66, 0, 1)
	})

	/* Puertos crudos del EC */
	OperationRegion (ECO1, SystemIO, 0x62, 1)
	Field (ECO1, ByteAcc, Lock, Preserve)
	{
		PX62, 8
	}

	OperationRegion (ECO2, SystemIO, 0x66, 1)
	Field (ECO2, ByteAcc, Lock, Preserve)
	{
		PX66, 8
	}

	/* Ventana del EC mapeada en memoria */
	OperationRegion (ECMA, SystemMemory, 0xFE802000, 0x0100)
	Field (ECMA, ByteAcc, Lock, Preserve)
	{
		Offset (0x58),
		BMAC, 4,
		BMDC, 4,
		    , 1,
		BMCM, 1
	}

	/*
	 * RAM del EC. Nombres tal cual los usa el firmware original:
	 *   BLNK  parpadeo de LED          WLLD/BTLD  LEDs de WLAN/Bluetooth
	 *   WAKS  fuente de wakeup         KLID       estado de la tapa
	 *   WLEN  WLAN habilitada          BTEN       Bluetooth habilitado
	 *   KBID  identificador de teclado MUTE       silencio
	 *   LIDW/RTCW/KEYW/TPDW  habilitacion de wake por tapa/RTC/teclado/touchpad
	 */
	OperationRegion (ERAM, EmbeddedControl, 0x00, 0xFF)
	Field (ERAM, ByteAcc, Lock, Preserve)
	{
		Offset (0x0A),
		    , 1,
		BLNK, 1,
		WLLD, 2,
		BTLD, 2,
		Offset (0x13),
		URTB, 8,
		Offset (0x4B),
		WAKS, 8,
		Offset (0x53),
		AOAS, 1,
		WLS3, 1,
		WLS4, 1,
		WLS5, 1,
		Offset (0x65),
		EXTI, 8,
		EXTD, 8,
		Offset (0x6B),
		PM1S, 8,
		PRCH, 1,
		Offset (0x70),
		    , 1,
		KLID, 1,
		    , 3,
		KACS, 1,
		Offset (0x71),
		WLEN, 1,
		BTEN, 1,
		DCKS, 1,
		MUTE, 1,
		KBID, 3,
		USBP, 1,
		    , 2,
		KEYW, 1,
		RTCW, 1,
		LIDW, 1,
		BL2W, 1,
		TPDW, 1,
		Offset (0x75),
		SWBL, 1,
		KLMA, 1,
		Offset (0x76),
		SYSC, 4,
		SYSO, 4
	}

	Method (_REG, 2, NotSerialized)
	{
		/* Arg0 == 0x03 es el espacio EmbeddedControl. Cuando queda
		   disponible, habilitar el wake por tapa. */
		If (LAnd (LEqual (Arg0, 0x03), LEqual (Arg1, One)))
		{
			Store (One, LIDW)
		}
	}

	/* Tapa del equipo */
	Device (LID0)
	{
		Name (_HID, EISAID("PNP0C0D"))

		Method (_LID, 0, NotSerialized)
		{
			Return (^^KLID)
		}

		Name (_PRW, Package () { 0x17, 0x03 })
	}

	/*
	 * ECON: bajo coreboot el EC esta siempre disponible por la interfaz ACPI
	 * estandar, asi que vale 1. El firmware de HP lo usaba para decidir entre
	 * lectura directa y una trampa SMI (RBEC/TRPS) hacia su handler SMM, que
	 * aca no existe. Con ECON=1 ese camino nunca se toma.
	 *
	 * SMA4: en el firmware original venia de su region NVS y solo elige el
	 * multiplicador del umbral de aviso de bateria baja. Se toma la rama por
	 * defecto (x0x0A).
	 */
	Name (ECON, One)
	Name (SMA4, Zero)

	Field (ECMA, ByteAcc, Lock, Preserve)
	{
	    Offset (0x08), 
	    NB0A,   1, 
	    NB0C,   1, 
	    NB0D,   1, 
	    NB0R,   1, 
	    NB0L,   1, 
	    NB0F,   1, 
	    NB0N,   1, 
	    Offset (0x09), 
	    NB1A,   1, 
	        ,   2, 
	    NB1R,   1, 
	    NB1L,   1, 
	    NB1F,   1, 
	    NB1N,   1
	}

	Field (ECMA, ByteAcc, Lock, Preserve)
	{
	    Offset (0x08), 
	    NB0S,   8, 
	    NB1S,   8
	}

	Field (ECMA, ByteAcc, Lock, Preserve)
	{
	    Offset (0x0E), 
	    SADS,   8
	}

	Field (ECMA, ByteAcc, Lock, Preserve)
	{
	    Offset (0x80), 
	    BSRC,   16, 
	    BSFC,   16, 
	    BSPE,   16, 
	    BSAC,   16, 
	    BSVO,   16, 
	        ,   15, 
	    BSCM,   1, 
	    BSCU,   16, 
	    BSTV,   16
	}

	Field (ECMA, ByteAcc, Lock, Preserve)
	{
	    Offset (0x90), 
	    BSDC,   16, 
	    BSDV,   16, 
	    BSSN,   16, 
	    BSMA,   16, 
	    Offset (0x9C), 
	    BSBS,   16, 
	    BSCY,   16
	}

	Field (ECMA, ByteAcc, Lock, Preserve)
	{
	    Offset (0xC0), 
	    BSMN,   128
	}

	Field (ECMA, ByteAcc, Lock, Preserve)
	{
	    Offset (0xD0), 
	    BSDN,   128
	}

	Field (ECMA, ByteAcc, Lock, Preserve)
	{
	    Offset (0xF0), 
	    BSCH,   128
	}

	Field (ECMA, ByteAcc, Lock, Preserve)
	{
	    Offset (0xA8), 
	    BSCV,   16, 
	    BSMD,   16, 
	    BSCC,   16, 
	    BSME,   16
	}

	Field (ERAM, ByteAcc, Lock, Preserve)
	{
	    Offset (0x02), 
	    NBID,   8, 
	    Offset (0x17), 
	        ,   5, 
	    SM0F,   1, 
	        ,   1, 
	    SM1F,   1, 
	    Offset (0x51), 
	        ,   1, 
	        ,   1, 
	    NB0T,   1, 
	    Offset (0x52)
	}

	/*
	 * Stub: el firmware original resolvia estas lecturas con una trampa SMI
	 * hacia su handler SMM (RBEC -> TRPS 0x10). Bajo coreboot ese handler no
	 * existe, pero con ECON=1 las ramas que lo invocan son inalcanzables.
	 * Se declara igual porque iasl exige que el metodo exista.
	 */
	Method (RBEC, 1, NotSerialized)
	{
	    Return (Zero)
	}

	/* Declaradas temprano: GBST las usa antes de la seccion del adaptador. */
	Name (SMAR, One)
	Name (ACSS, Zero)
	Name (ACST, 0xFF)

	Mutex (BATM, 0x07)

	Method (GBIF, 3, NotSerialized)
	{
	    If (Arg2)
	    {
	        Arg1 [One] = Ones
	        Arg1 [0x02] = Ones
	        Arg1 [0x04] = Ones
	        Arg1 [0x05] = Zero
	        Arg1 [0x06] = Zero
	    }
	    Else
	    {
	        Local0 = BSCM /* \_SB_.PCI0.LPCB.EC0_.BSCM */
	        Arg1 [Zero] = (Local0 ^ One)
	        If (Local0)
	        {
	            Local1 = (BSFC * 0x0A)
	        }
	        Else
	        {
	            Local1 = BSFC /* \_SB_.PCI0.LPCB.EC0_.BSFC */
	        }

	        Arg1 [One] = Local1
	        If (Local0)
	        {
	            Local2 = (BSFC * 0x0A)
	        }
	        Else
	        {
	            Local2 = BSFC /* \_SB_.PCI0.LPCB.EC0_.BSFC */
	        }

	        Arg1 [0x02] = Local2
	        Arg1 [0x04] = BSDV /* \_SB_.PCI0.LPCB.EC0_.BSDV */
	        Divide (Local2, 0x64, Local7, Local6)
	        If (SMA4)
	        {
	            Local3 = (Local6 * 0x0C)
	        }
	        Else
	        {
	            Local3 = (Local6 * 0x0A)
	        }

	        Arg1 [0x05] = Local3
	        If (SMA4)
	        {
	            Local4 = (0x07 * 0x02)
	        }
	        Else
	        {
	            Local4 = (0x05 * 0x02)
	        }

	        Local4 += One
	        Local4 *= Local6
	        Divide (Local4, 0x02, Local7, Local4)
	        Arg1 [0x06] = Local4
	        Arg1 [0x07] = (Local3 - Local4)
	        Arg1 [0x08] = (Local2 - Local3)
	        Local7 = BSSN /* \_SB_.PCI0.LPCB.EC0_.BSSN */
	        Name (SERN, Buffer (0x06)
	        {
	            "     "
	        })
	        Local6 = 0x04
	        While (Local7)
	        {
	            Divide (Local7, 0x0A, Local5, Local7)
	            SERN [Local6] = (Local5 + 0x30)
	            Local6--
	        }

	        Arg1 [0x0A] = SERN /* \_SB_.PCI0.LPCB.EC0_.GBIF.SERN */
	        Arg1 [0x09] = BSDN /* \_SB_.PCI0.LPCB.EC0_.BSDN */
	        Arg1 [0x0B] = BSCH /* \_SB_.PCI0.LPCB.EC0_.BSCH */
	        Arg1 [0x0C] = BSMN /* \_SB_.PCI0.LPCB.EC0_.BSMN */
	    }

	    Return (Arg1)
	}

	Method (GBST, 4, NotSerialized)
	{
	    If ((Arg1 & 0x02))
	    {
	        Local0 = 0x02
	        If ((Arg1 & 0x20))
	        {
	            Local0 = Zero
	        }
	    }
	    ElseIf ((Arg1 & 0x04))
	    {
	        Local0 = One
	    }
	    Else
	    {
	        Local0 = Zero
	    }

	    If ((Arg1 & 0x10))
	    {
	        Local0 |= 0x04
	    }

	    If ((Arg1 & One))
	    {
	        Local1 = BSAC /* \_SB_.PCI0.LPCB.EC0_.BSAC */
	        Local2 = BSRC /* \_SB_.PCI0.LPCB.EC0_.BSRC */
	        If (ACST)
	        {
	            If ((Arg1 & 0x20))
	            {
	                Local2 = BSFC /* \_SB_.PCI0.LPCB.EC0_.BSFC */
	            }
	        }

	        If (Arg2)
	        {
	            Local2 *= 0x0A
	        }

	        Local3 = BSVO /* \_SB_.PCI0.LPCB.EC0_.BSVO */
	        If ((Local1 >= 0x8000))
	        {
	            If ((Local0 & One))
	            {
	                Local1 = (0x00010000 - Local1)
	            }
	            Else
	            {
	                Local1 = Zero
	            }
	        }
	        ElseIf (((Local0 & 0x02) == Zero))
	        {
	            Local1 = Zero
	        }

	        If (Arg2)
	        {
	            Local1 *= Local3
	            Local1 /= 0x03E8    /* mA*mV -> mW */
	        }
	    }
	    Else
	    {
	        Local0 = Zero
	        Local1 = Ones
	        Local2 = Ones
	        Local3 = Ones
	    }

	    Arg3 [Zero] = Local0
	    Arg3 [One] = Local1
	    Arg3 [0x02] = Local2
	    Arg3 [0x03] = Local3
	    Return (Arg3)
	}


	Name (B0ST, 0xFF)

	Device (BAT0)
	{
	    Name (_HID, EisaId ("PNP0C0A") /* Control Method Battery */)  // _HID: Hardware ID
	    Name (_UID, One)  // _UID: Unique ID
	    Method (_PCL, 0, NotSerialized)  // _PCL: Power Consumer List
	    {
	        Return (_SB) /* \_SB_ */
	    }

	    Name (B0IP, Package (0x0D)
	    {
	        One, 
	        Ones, 
	        Ones, 
	        One, 
	        Ones, 
	        Zero, 
	        Zero, 
	        0x5A, 
	        0x5A, 
	        "Primary", 
	        "", 
	        "Lion", 
	        "Hewlett-Packard "
	    })
	    Name (B0SP, Package (0x04)
	    {
	        Zero, 
	        Ones, 
	        Ones, 
	        Ones
	    })
	    Method (_STA, 0, NotSerialized)  // _STA: Status
	    {
	        If (One)   /* siempre releer: sin esto el valor queda cacheado */
	        {
	            If (ECON)
	            {
	                Local1 = NB0A /* \_SB_.PCI0.LPCB.EC0_.NB0A */
	                If (NB0N)
	                {
	                    Local1 = Zero
	                }
	            }
	            Else
	            {
	                Local0 = RBEC (0x88)
	                Local1 = (Local0 >> Zero)
	                Local1 &= One
	                If ((Local0 & 0x40))
	                {
	                    Local1 = Zero
	                }
	            }

	            B0ST = Local1
	        }
	        Else
	        {
	            Local1 = B0ST /* \_SB_.PCI0.LPCB.EC0_.B0ST */
	        }

	        If (Local1)
	        {
	            Return (0x1F)
	        }
	        Else
	        {
	            Return (0x0F)
	        }
	    }

	    Method (_BIF, 0, NotSerialized)  // _BIF: Battery Information
	    {
	        Local6 = B0ST /* \_SB_.PCI0.LPCB.EC0_.B0ST */
	        Local7 = 0x14
	        While ((Local6 && Local7))
	        {
	            If (ECON)
	            {
	                Local1 = NB0S /* \_SB_.PCI0.LPCB.EC0_.NB0S */
	            }
	            Else
	            {
	                Local1 = RBEC (0x88)
	            }

	            If ((Local1 & 0x08))
	            {
	                Local6 = Zero
	            }
	            Else
	            {
	                Sleep (0x01F4)
	                Local7--
	            }
	        }

	        Return (GBIF (Zero, B0IP, Local6))
	    }

	    Method (_BST, 0, NotSerialized)  // _BST: Battery Status
	    {
	        Local0 = (DerefOf (B0IP [Zero]) ^ One)
	        If (ECON)
	        {
	            Local1 = NB0S /* \_SB_.PCI0.LPCB.EC0_.NB0S */
	        }
	        Else
	        {
	            Local1 = RBEC (0x88)
	        }

	        Return (GBST (Zero, Local1, Local0, B0SP))
	    }
	}



	Device (ADP1)
	{
	    Name (_HID, "ACPI0003" /* Power Source Device */)  // _HID: Hardware ID
	    Method (_PSR, 0, NotSerialized)  // _PSR: Power Source
	    {
	        If (One)   /* siempre releer: sin esto el valor queda cacheado */
	        {
	            If (ECON)
	            {
	                Local1 = KACS /* \_SB_.PCI0.LPCB.EC0_.KACS */
	            }
	            Else
	            {
	                Local0 = RBEC (0x70)
	                Local1 = (Local0 & 0x20)
	            }
	        }
	        Else
	        {
	            Local1 = ACST /* \_SB_.PCI0.LPCB.EC0_.ACST */
	        }

	        If (Local1)
	        {
	            ACST = One
	            If (ECON)
	            {
	                Local0 = SADS /* \_SB_.PCI0.LPCB.EC0_.SADS */
	            }
	            Else
	            {
	                Local0 = RBEC (0x59)
	            }

	            If (((ACST != ACSS) || (Local0 != SMAR)))
	            {
	                SMAR = Local0
	            }
	        }
	        Else
	        {
	            ACST = Zero
	        }

	        ACSS = ACST /* \_SB_.PCI0.LPCB.EC0_.ACST */
	        Return (ACST) /* \_SB_.PCI0.LPCB.EC0_.ACST */
	    }

	    Method (_PCL, 0, NotSerialized)  // _PCL: Power Consumer List
	    {
	        Return (_SB) /* \_SB_ */
	    }

	    Method (_STA, 0, NotSerialized)  // _STA: Status
	    {
	        Return (0x0F)
	    }
}

	/*
	 * Eventos SCI del EC (GPE 0x17). Sin estos, ACPI nunca se entera de que
	 * cambio el estado de la corriente o la bateria.
	 * Portados del DSDT original; se omitieron las llamadas a metodos del
	 * firmware de HP que no existen aca (PSKY, ACCL.ADAL, HDWN, PWRS).
	 */
	Method (_Q40, 0, NotSerialized)   /* cambio de informacion de bateria */
	{
	    B0ST = 0xFF
	    Notify (BAT0, 0x81)
	}

	Method (_Q41, 0, NotSerialized)
	{
	    B0ST = 0xFF
	    Notify (BAT0, 0x81)
	}

	Method (_Q48, 0, NotSerialized)   /* cambio de estado de bateria */
	{
	    Notify (BAT0, 0x80)
	}

	Method (_Q4C, 0, NotSerialized)
	{
	    If (B0ST)
	    {
	        Notify (BAT0, 0x80)
	    }
	}

	Method (_Q50, 0, NotSerialized)   /* AC enchufado */
	{
	    ACST = 0xFF
	    B0ST = 0xFF
	    Notify (ADP1, 0x80)
	    Notify (BAT0, 0x80)
	    PNOT ()
	}

	Method (_Q51, 0, NotSerialized)   /* AC desenchufado */
	{
	    ACST = 0xFF
	    B0ST = 0xFF
	    Notify (ADP1, 0x80)
	    Notify (BAT0, 0x80)
	    PNOT ()
	}

	Method (_Q52, 0, NotSerialized)   /* tapa */
	{
	    LIDS = KLID
	    Notify (LID0, 0x80)
	}

	Method (_Q53, 0, NotSerialized)
	{
	    LIDS = KLID
	    Notify (LID0, 0x80)
	}

}
