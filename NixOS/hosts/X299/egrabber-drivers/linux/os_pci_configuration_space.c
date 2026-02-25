#include "mc_linux.h"
#include "../os_pci_configuration_space.h"

INT32 EDDI_API OsPciReadConfigByte(PDEVICE pciDevice, UINT32 offset, PUCHAR value)
{
    return pci_read_config_byte((struct pci_dev *)pciDevice, (int)offset, (u8 *)value);
}

INT32 EDDI_API OsPciWriteConfigByte(PDEVICE pciDevice, UINT32 offset, UCHAR value)
{
    return pci_write_config_byte((struct pci_dev *)pciDevice, (int)offset, (u8)value);
}

INT32 EDDI_API OsPciReadConfigWord(PDEVICE pciDevice, UINT32 offset, PUSHORT value)
{
    return pci_read_config_word((struct pci_dev *)pciDevice, (int)offset, (u16 *)value);
}

INT32 EDDI_API OsPciWriteConfigWord(PDEVICE pciDevice, UINT32 offset, USHORT value)
{
    return pci_write_config_word((struct pci_dev *)pciDevice, (int)offset, (u16)value);
}

INT32 EDDI_API OsPciReadConfigDword(PDEVICE pciDevice, UINT32 offset, PUINT32 value)
{
    return pci_read_config_dword((struct pci_dev *)pciDevice, (int)offset, (u32 *)value);
}

INT32 EDDI_API OsPciWriteConfigDword(PDEVICE pciDevice, UINT32 offset, UINT32 value)
{
    return pci_write_config_dword((struct pci_dev *)pciDevice, (int)offset, (u32)value);
}
