#include "mc_linux.h"

const struct pci_device_id multicam_ids[] = {
	{PCI_DEVICE(0x1805, 0x08F0)},
	{0, 0}
};

char *driver_name = "grablink";

MODULE_DEVICE_TABLE(pci, multicam_ids);
MODULE_DESCRIPTION("Grablink driver");
