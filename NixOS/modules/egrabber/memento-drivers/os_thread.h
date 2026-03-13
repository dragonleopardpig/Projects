#ifndef THREAD_HEADER_FILE
#define THREAD_HEADER_FILE

#include "os_thread_types.h"

#ifdef __cplusplus
extern "C"
{
#endif

typedef struct {
    /// OS dependent representation of a kernel thread
    OS_TASK task;

    /// The routine that is to be run in the kernel thread
    OS_THREAD_ROUTINE work;

    /// The context that will be passed to the routine
    void *context;
} WORK_CTX;


/** Creates a kernel thread that will run a given routine.
    The routine to run and its context are given through the kernelThread
    argument. The memory pointed to by kernelThread must remain valid
    throughout the life of the kernel thread.
 **/
BOOLEAN EDDI_API OsCreateSystemThread(OS_RESOURCE osResource, WORK_CTX *kernelThread);

/** Called by a kernel thread to terminate itself.
    The kernel thread must have been created by OsCreateSystemThread.
 **/
void EDDI_API OsTerminateSystemThread(void);

void EDDI_API OsGetThreadId(UINT32 *pid, UINT32 *tid);

#ifdef __cplusplus
}
#endif

#endif
