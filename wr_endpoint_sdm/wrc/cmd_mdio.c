/*
 * cmd_mdio.c — accesso diretto ai registri MDIO del PCS + controllo autoneg.
 * Aggiunto durante il debug lab 2026-07-06 (lnk:0 con PCS sincronizzato):
 * mai piu' ciechi sullo stato MCR/MSR del PCS.
 *
 *   mdio rd <reg>        — legge il registro MDIO <reg> (0=MCR, 1=MSR, ...)
 *   mdio wr <reg> <val>  — scrive <val> nel registro <reg>
 *   mdio an <0|1>        — ep_enable(dev, 1, an): riallinea flag SW e MCR HW
 *   mdio dump            — MCR, MSR, ANAR, ANLPAR, WR_SPEC
 */

#include <string.h>
#include "wrc.h"
#include "shell.h"
#include "cmds.h"
#include "util.h"
#include "dev/endpoint.h"
#include "board.h"
#include <hw/ep_mdio_regs.h>

static void mdio_print(const char *name, int reg)
{
	pp_printf("  MDIO[0x%02x] %-7s = 0x%04x\n", reg,
		  name, ep_pcs_read(&wrc_endpoint_dev, reg));
}

int cmd_mdio(const char *args[])
{
	if (args[0] && !strcasecmp(args[0], "dump")) {
		mdio_print("MCR", 0x00);
		mdio_print("MSR", 0x04);
		mdio_print("ANAR", 0x10);
		mdio_print("ANLPAR", 0x14);
		mdio_print("WRSPEC", 0x40);
		return 0;
	}
	if (args[0] && args[1] && !strcasecmp(args[0], "rd")) {
		int reg = atoi(args[1]);
		pp_printf("MDIO[0x%02x] = 0x%04x\n", reg,
			  ep_pcs_read(&wrc_endpoint_dev, reg));
		return 0;
	}
	if (args[0] && args[1] && args[2] && !strcasecmp(args[0], "wr")) {
		int reg = atoi(args[1]);
		int val = atoi(args[2]);
		ep_pcs_write(&wrc_endpoint_dev, reg, val);
		pp_printf("MDIO[0x%02x] <= 0x%04x, riletto 0x%04x\n", reg, val,
			  ep_pcs_read(&wrc_endpoint_dev, reg));
		return 0;
	}
	if (args[0] && args[1] && !strcasecmp(args[0], "an")) {
		int an = atoi(args[1]);
		ep_enable(&wrc_endpoint_dev, 1, an);
		pp_printf("ep_enable(1, an=%d); MCR = 0x%04x\n", an,
			  ep_pcs_read(&wrc_endpoint_dev, 0x00));
		return 0;
	}
	pp_printf("uso: mdio dump | rd <reg> | wr <reg> <val> | an <0|1>\n");
	return 0;
}
