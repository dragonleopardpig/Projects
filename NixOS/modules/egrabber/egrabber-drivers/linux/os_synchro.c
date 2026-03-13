#include "mc_linux.h"
#include "../os_synchro.h"
#include "../os_math.h"

#ifndef EURESYS_UNITTEST
int EDDI_API OsSemaInit(OS_SEMA *lock, int initCount, int maxCount)
{
    sema_init((struct semaphore *) lock, initCount);

    return OS_OK;
}

int EDDI_API OsSemaWait(OS_SEMA *lock)
{
    int result;
    result=down_interruptible((struct semaphore*)lock);

    if (result<0)
        return OS_WAIT_ALERTED;

    return OS_OK;
}

static int EDDI_API OsSemaWaitUninterruptible(OS_SEMA *lock)
{
    down((struct semaphore*)lock);

    return OS_OK;
}

int EDDI_API OsSemaTimedWait(OS_SEMA *lock, int timeout)
{
    return OsSemaWait(lock);
}

int EDDI_API OsSemaRelease(OS_SEMA *lock)
{
    up((struct semaphore*)lock);

    return OS_OK;
}

int EDDI_API OsSemaDelete(OS_SEMA *lock)
{
    /* nothing to do*/
    return OS_OK;
}


int EDDI_API OsMutexInit(OS_MUTEX *lock)
{
    return OsSemaInit((OS_SEMA*)lock,1,1);
}

int EDDI_API OsMutexWait(OS_MUTEX *lock)
{
    return OsSemaWait((OS_SEMA*)lock);
}

int EDDI_API OsMutexWaitUninterruptible(OS_MUTEX *lock)
{
    return OsSemaWaitUninterruptible((OS_SEMA*)lock);
}

int EDDI_API OsMutexRelease(OS_MUTEX *lock)
{
    return OsSemaRelease((OS_SEMA*)lock);
}

int EDDI_API OsMutexDelete(OS_MUTEX *lock)
{
    return OsSemaDelete((OS_SEMA*)lock);
}


int EDDI_API OsSpinLockInit(OS_SPINLOCK *spinlock)
{
    spin_lock_init((spinlock_t *)spinlock);

    return OS_OK;
}

int EDDI_API OsSpinLockWait(OS_SPINLOCK *spinlock, OS_SPINLOCAL *context)
{
    spin_lock_bh((spinlock_t *)spinlock);

    return OS_OK;
}

int EDDI_API OsSpinLockRelease(OS_SPINLOCK *spinlock, OS_SPINLOCAL *context)
{
    spin_unlock_bh((spinlock_t *)spinlock);

    return OS_OK;
}

int EDDI_API OsSpinLockWaitDpc(OS_SPINLOCK *spinlock, OS_SPINLOCAL *context)
{
    spin_lock((spinlock_t *)spinlock);

    return OS_OK;
}

int EDDI_API OsSpinLockReleaseDpc(OS_SPINLOCK *spinlock, OS_SPINLOCAL *context)
{
    spin_unlock((spinlock_t *)spinlock);

    return OS_OK;
}

int EDDI_API OsSpinLockWaitIrqSafe(OS_SPINLOCK *spinlock, OS_SPINLOCAL *context)
{
    unsigned long flags;

    spin_lock_irqsave((spinlock_t *)spinlock, flags);
    *context = flags;

    return OS_OK;
}

int EDDI_API OsSpinLockReleaseIrqSafe(OS_SPINLOCK *spinlock, OS_SPINLOCAL *context)
{
    unsigned long flags;

    flags = *context;
    spin_unlock_irqrestore((spinlock_t *)spinlock, flags);

    return OS_OK;
}

int EDDI_API OsSpinLockDelete(OS_SPINLOCK *spinlock)
{
    /*nothing to do*/
    return OS_OK;
}

int EDDI_API OsNotificationEventInit(OS_RESOURCE osResource, OS_NOTIFICATION_EVENT *event)
{
    init_waitqueue_head((wait_queue_head_t*) &(event->event));
    event->bNotified=FALSE;
    return OS_OK;
}

int EDDI_API OsNotificationEventWait(OS_NOTIFICATION_EVENT *event)
{
    int result=OS_OK;
    wait_queue_head_t *pQueue;
#if (LINUX_VERSION_CODE < KERNEL_VERSION(4, 13, 0))
    wait_queue_t wait;
#else
    wait_queue_entry_t wait;
#endif

    pQueue=(wait_queue_head_t*)&(event->event);
    init_waitqueue_entry(&wait,current);

    add_wait_queue(pQueue,&wait);
    while (1) {
        set_current_state(TASK_INTERRUPTIBLE);
        if (event->bNotified == TRUE) {
            result=OS_OK;
            break;
        }
        if (signal_pending(current)) {
            result=OS_WAIT_ALERTED;
            break;
        }
        schedule();
    }
    set_current_state(TASK_RUNNING);
    remove_wait_queue(pQueue,&wait);

    return result;
}

int EDDI_API OsNotificationEventWaitUninterruptible(OS_NOTIFICATION_EVENT *event)
{
    int result = OS_OK;
    wait_queue_head_t *pQueue;
#if (LINUX_VERSION_CODE < KERNEL_VERSION(4, 13, 0))
    wait_queue_t wait;
#else
    wait_queue_entry_t wait;
#endif

    pQueue = (wait_queue_head_t *)&(event->event);
    init_waitqueue_entry(&wait, current);

    add_wait_queue(pQueue, &wait);
    while (1) {
        set_current_state(TASK_UNINTERRUPTIBLE);
        if (event->bNotified == TRUE) {
            result = OS_OK;
            break;
        }
        schedule();
    }
    set_current_state(TASK_RUNNING);
    remove_wait_queue(pQueue, &wait);

    return result;
}

int EDDI_API OsNotificationEventTimedWait(OS_NOTIFICATION_EVENT *event, int timeout)
{
    return OsNotificationEventWait(event);
}

int EDDI_API OsNotificationEventRelease(OS_NOTIFICATION_EVENT *event)
{
    event->bNotified=TRUE;
    wake_up((wait_queue_head_t*) &(event->event));

    return OS_OK;
}

int EDDI_API OsNotificationEventDelete(OS_NOTIFICATION_EVENT *event)
{
    return OS_OK;
}

int EDDI_API OsNotificationEventClear(OS_NOTIFICATION_EVENT *event)
{
    event->bNotified=FALSE;

    return OS_OK;
}

void EDDI_API OsReleaseNotificationPort(void *port)
{
}

void EDDI_API OsMemoryBarrier(void)
{
    smp_mb();
}

int EDDI_API OsSynchronizeIrqExecution(OS_SYNC_ROUTINE syncRoutine,
                                       void *syncRoutineContext,
                                       OS_INTERRUPT itr)
{
    disable_irq(itr);
    syncRoutine(syncRoutineContext);
    enable_irq(itr);

    return OS_OK;
}
#endif

int EDDI_API OsStallProcessor(unsigned int usecs)
{
    if (usecs > 1500) {
        mdelay(usecs / 1000);
        udelay(usecs % 1000);
    } else {
        udelay(usecs);
    }

    return OS_OK;
}

