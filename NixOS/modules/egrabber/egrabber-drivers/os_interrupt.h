#ifndef OS_INTERRUPT_HEADER_FILE
#define OS_INTERRUPT_HEADER_FILE

#include "os_types.h"
#include "os_interrupt_types.h"

#ifdef __cplusplus
extern "C"
{
#endif

typedef struct {
    OS_INTERRUPT *osInterrupt;
    OS_IRQ_RESOURCE *osResources;
    PCCHAR deviceName;
    PDEVICE physicalDeviceObject;
    OS_IRQ_EXT osExt;
} OS_INTERRUPT_REQUEST;

typedef struct {
    OS_ISR_ROUTINE Handler;
    void *Context;
} ISR_CTX;


/** Registers an interrupt handler for a given IRQ.
    The IRQ is specified through the irq argument.
    The handler and its context are passed by context argument. The raw
    value of the "context" pointer must be unique for each registered
    interrupt.
    The name of the device must be provided through deviceName.
 **/
INT32 EDDI_API OsRequestIrq(OS_INTERRUPT_REQUEST *irq, ISR_CTX *context);

/** Unregisters the interrupt handler associated with irq and context.
    context pointer must be the same as the one passed to OsRequestIrq.
 **/
void EDDI_API OsFreeIrq(OS_INTERRUPT_REQUEST *irq, ISR_CTX *context);

#ifdef __cplusplus
}
#endif

#endif
