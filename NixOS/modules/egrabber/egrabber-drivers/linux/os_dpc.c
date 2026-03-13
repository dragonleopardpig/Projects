#include "mc_linux.h"
#include "../os_dpc.h"

static void task_entry(unsigned long context)
{
    struct OS_DPC *dpc = (struct OS_DPC *)context;
    dpc->callback(dpc->context);
}

void EDDI_API OsCreateDpc(struct OS_DPC *dpc, DpcCallback callback,
                          void *context)
{
    dpc->callback = callback;
    dpc->context = context;
    tasklet_init((struct tasklet_struct*)dpc->native_dpc, task_entry,
                 (unsigned long)dpc);
}

void EDDI_API OsDeleteDpc(struct OS_DPC *dpc)
{
}

BOOLEAN EDDI_API OsQueueDpc(struct OS_DPC *dpc)
{
    tasklet_schedule((struct tasklet_struct *)dpc->native_dpc);
    return TRUE;
}

BOOLEAN EDDI_API OsQueueFastDpc(struct OS_DPC *dpc)
{
    tasklet_hi_schedule((struct tasklet_struct *)dpc->native_dpc);
    return TRUE;
}
