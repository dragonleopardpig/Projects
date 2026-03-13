#include "mc_linux.h"

const struct pci_device_id multicam_ids[] = {
	{0, 0}
};

char *driver_name = "memento";

MODULE_DEVICE_TABLE(pci, multicam_ids);
