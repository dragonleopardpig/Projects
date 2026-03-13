#ifndef DEFERRED_PROCEDURE_CALLS_HEADER_FILE
#define DEFERRED_PROCEDURE_CALLS_HEADER_FILE

#include "os_types.h"

#ifdef __cplusplus
extern "C"
{
#endif

typedef EDDI_API void (*DpcCallback)(void *context);

#if defined(EURESYS_OS_DARWIN)

#ifdef __cplusplus
}
#endif

#include "darwin/os_dpc_types.h"

#ifdef __cplusplus
extern "C"
{
#endif

#else

// TODO: linux/os_dpc_types.h, windows/os_dpc_types.h

struct OS_DPC {
    DpcCallback callback;
    void *context;
    // Sufficiently large to hold the os nativestructures used for dpc/tasklet objects
    unsigned char native_dpc[16*8]; 
};

#endif


/** Create a DPC.

    This function can be called only at the passive level.
    \param dpc pointer to a preallocated structure that will contain the dpc object
    \param callback callback that will be called when executing the deferred
    \param context context that will be passed to the callback
 **/
void EDDI_API OsCreateDpc(struct OS_DPC *dpc, DpcCallback callback, void *context);

/** Free a DPC.

    This function can be called only at the passive level. 
    No DPC may be running anymore.
    \param dpc pointer to the DPC object that needs to be freeed.
 **/
void EDDI_API OsDeleteDpc(struct OS_DPC *dpc);

/** Queue a call. The DPC will be run as soon as possible by the OS.

    This function can only be called when executing a deferred or an interrupt handler.
    \param dpc pointer to the DPC object.
 **/
BOOLEAN EDDI_API OsQueueDpc(struct OS_DPC *dpc);

/** Queue a call. The DPC will be run as soon as possible by the OS, possibly with higher priority.

    This function can only be called when executing a deferred or an interrupt handler.
    \param dpc pointer to the DPC object.
 **/
BOOLEAN EDDI_API OsQueueFastDpc(struct OS_DPC *dpc);

#ifdef __cplusplus
}
#endif

#endif
