#ifndef OS_REQUEST_FIRMWARE_HEADER_FILE
#define OS_REQUEST_FIRMWARE_HEADER_FILE

// Not used by Coaxlink driver

#include "os_size_t.h"
#include "os_types.h"

#ifdef __cplusplus
extern "C" 
{
#endif

/** OsFirmware structure contains the pointer
 *  to the buffer holding the image of the firmware
 *  and the size of this image.
 *  It also contains a pointer to an internal
 *  OS specific data.
 */
typedef struct {
    const unsigned char *image;
    size_t size;
    const void *osSpecificValue;
} OsFirmware;


/** OsRequestFirmware requests a firmware from the Windows kernel, the
 *  Linux hotplug/udev subsystem or a macOS driver bundle.
 *  Upon success, the retrieved firmware is stored at firmwareImage.
 *  \param firmwareName name of the requested firmware
 *  \param firmwareImage store the retrieved firmware
 *  \param device the device for which the firmware is to be loaded
 *  OsRequestFirmware returns 0 on success and a negative value on error.
 *  OsRequestFirmware can only be called at PASSIVE level.
 */
int EDDI_API OsRequestFirmware(const char *firmwareName, OsFirmware *firmwareImage,
                               PDEVICE device);

void EDDI_API OsReleaseFirmware(OsFirmware *firmwareImage);

#ifdef __cplusplus
}
#endif

#endif
