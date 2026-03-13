#include "mc_linux.h"
#include "../os_request_firmware.h"

int EDDI_API OsRequestFirmware(const char *firmwareName, OsFirmware *firmwareImage,
                           PDEVICE device)
{
    int status;
    struct pci_dev *pciDevice = device;
    const struct firmware *fw;

    status = request_firmware(&fw, firmwareName, &pciDevice->dev);
    if (status == 0) {
        firmwareImage->image = fw->data;
        firmwareImage->size = fw->size;
        firmwareImage->osSpecificValue = fw;
    }
    return status;
}

void EDDI_API OsReleaseFirmware(OsFirmware *firmwareImage)
{
    release_firmware((const struct firmware *)firmwareImage->osSpecificValue);
    firmwareImage->image = NULL;
    firmwareImage->size = 0;
    firmwareImage->osSpecificValue = NULL;
}
