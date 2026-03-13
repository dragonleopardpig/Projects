#ifndef PCI_CONFIGURATION_SPACE_HEADER_FILE
#define PCI_CONFIGURATION_SPACE_HEADER_FILE

#include "os_types.h" 

#ifdef __cplusplus
extern "C"
{
#endif

/** Reads a byte located at offset bytes from the beginning of the PCI
    configuration space of pciDevice. The byte is stored into value. **/
INT32 EDDI_API OsPciReadConfigByte(PDEVICE pciDevice, UINT32 offset, PUCHAR value);

/** Writes value into the byte located at offset bytes from the beginning
    of the PCI configuration space of pciDevice. **/
INT32 EDDI_API OsPciWriteConfigByte(PDEVICE pciDevice, UINT32 offset, UCHAR value);

/** Reads a word located at offset bytes from the beginning of the PCI
    configuration space of pciDevice. The word is stored into value. **/
INT32 EDDI_API OsPciReadConfigWord(PDEVICE pciDevice, UINT32 offset, PUSHORT value);

/** Writes value into the word located at offset bytes from the beginning
    of the PCI configuration space of pciDevice. **/
INT32 EDDI_API OsPciWriteConfigWord(PDEVICE pciDevice, UINT32 offset, USHORT value);

/** Reads a dword located at offset bytes from the beginning of the PCI
    configuration space of pciDevice. The dword is stored into value. **/
INT32 EDDI_API OsPciReadConfigDword(PDEVICE pciDevice, UINT32 offset, PUINT32 value);

/** Writes value into the dword located at offset bytes from the beginning
    of the PCI configuration space of pciDevice. **/
INT32 EDDI_API OsPciWriteConfigDword(PDEVICE pciDevice, UINT32 offset, UINT32 value);

#ifdef __cplusplus
}
#endif

#endif
