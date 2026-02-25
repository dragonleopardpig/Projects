#include "mc_linux.h"
#include "../os_thread.h"

#if (LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 20))
static void work_entry(void *work)
#else
static void work_entry(struct work_struct *work)
#endif
{
    WORK_CTX *ctx = container_of((OS_TASK *)work, WORK_CTX, task);
    OS_THREAD_ROUTINE routine = ctx->work;
    routine(ctx->context);
}

BOOLEAN EDDI_API OsCreateSystemThread(OS_RESOURCE osResource, WORK_CTX *kernelThread)
{
    struct work_struct *work = (struct work_struct *)&kernelThread->task;
#if (LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 20))
    INIT_WORK(work, work_entry, work);
#else
    INIT_WORK(work, work_entry);
#endif
    return schedule_work(work) != 0 ? TRUE : FALSE;
}

void EDDI_API OsTerminateSystemThread(void)
{
}

void EDDI_API OsGetThreadId(UINT32 *pid, UINT32 *tid)
{
#if (LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 24))
    *pid = (UINT32)current->tgid;
    *tid = (UINT32)current->pid;
#else
    *pid = (UINT32)task_tgid_nr(current);
    *tid = (UINT32)task_pid_nr(current);
#endif
}
