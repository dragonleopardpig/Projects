#ifndef OS_ENTRY_POINTS_HEADER_FILE
#define OS_ENTRY_POINTS_HEADER_FILE

#include "os_types.h"
#include "os_synchro.h"
#include "os_interrupt.h"

#ifdef __cplusplus
extern "C"
{
#endif

typedef struct t_MemResources
{
    PHYSICAL_ADDR Start;
    UINT32 Size;
    PDEVICE Device;
    UINT32 Index;
    BOOLEAN HardenedAccess;
} OS_MEM_RESOURCE;

#define OS_MAX_RESOURCES 12

typedef struct t_DeviceInfo
{
    PDEVICE ppcidev;
    UINT32 bus;
    UINT32 slot;
    USHORT DeviceID;
    USHORT VendorID;
    USHORT SubDeviceID;
    USHORT SubVendorID;
    OS_MEM_RESOURCE memResources[OS_MAX_RESOURCES];
    UINT32 memResourcesCount;
    OS_IRQ_RESOURCE irqResource;
    BOOLEAN irqAvailable;
    UINT32 slotID;
    OS_RESOURCE osResource;
} OS_DEVICE_INFO;


#if defined(EURESYS_OS_LINUX)

INT32 EDDI_API mc_init_module(void);
INT32 EDDI_API mc_add_device(OS_DEVICE_INFO *dev);
void EDDI_API mc_remove_device(PDEVICE pciDevice);
void EDDI_API mc_cleanup_module(void);

INT32 EDDI_API mc_device_open(INT32 Major, INT32 Minor, void **private_data);
INT32 EDDI_API mc_device_release(INT32 Major, INT32 Minor, void **private_data);
INT32 EDDI_API mc_device_read(INT32 Major, INT32 Minor, char *buffer, UINT32 size,
                            void **private_data);
INT32 EDDI_API mc_device_write(INT32 Major, INT32 Minor, PCCHAR buffer, UINT32 size,
                             void **private_data);
INT32 EDDI_API mc_device_ioctl(INT32 Major, INT32 Minor, INT32 cmd, void *arg,
                             void **private_data);
OS_NOTIFICATION_EVENT *EDDI_API mc_device_poll(void **private_data);

INT32 EDDI_API mc_suspend(PDEVICE pciDevice);
INT32 EDDI_API mc_resume(PDEVICE pciDevice);

void EDDI_API mc_shutdown(PDEVICE pciDevice);

#elif defined(EURESYS_OS_DARWIN)

void  EDDI_API DriverInit();
void  EDDI_API DriverInitMemento(void *buffer, unsigned int length);
#ifdef MEMENTO_EMBEDDED
void  EDDI_API DriverInitMementoClient(void *buffer, unsigned int length);
#endif
void  EDDI_API DriverCleanup();
void *EDDI_API DriverAddDevice(OS_DEVICE_INFO *info, int *index);
void  EDDI_API DriverRemoveDevice(void *dispatcher);
#ifdef EURESYS_DARWIN_DRIVERKIT
void  EDDI_API DriverDisableDevice(void *dispatcher);
#endif
int   EDDI_API DriverOpenDispatch(void *dispatcher, void **private_data);
int   EDDI_API DriverCloseDispatch(void *dispatcher, void **private_data);
int   EDDI_API DriverIoctl(void *dispatcher, void **private_data,
                           unsigned int code,
                           const void *inBuffer, unsigned int inBufferLength,
                           void *outBuffer, unsigned int outBufferLength);
void  EDDI_API DriverSetNotificationPort(void *dispatcher, void **private_data, void *port);
int   EDDI_API DriverGetComPortCount(void *dispatcher);
unsigned int EDDI_API DriverGetSupportedBaudRates(void *dispatcher);

typedef void (*DriverSerialOnDataReady)(void *context, void *cookie, int data);
int   EDDI_API DriverSerialOpen(void *dispatcher, int com, DriverSerialOnDataReady onDataReady, void *context, void *data);
int   EDDI_API DriverSerialClose(void *dispatcher, int com);
int   EDDI_API DriverSerialIoctl(void *dispatcher, int com, unsigned int code,
                                 void *inBuffer, unsigned int inBufferLength,
                                 void *outBuffer, unsigned int outBufferLength);
int   EDDI_API DriverSerialRead(void *dispatcher, int com, unsigned char *buffer, unsigned int size);
int   EDDI_API DriverSerialWrite(void *dispatcher, int com, unsigned char *buffer, unsigned int size);

#endif

#ifdef __cplusplus
}
#endif

#endif

