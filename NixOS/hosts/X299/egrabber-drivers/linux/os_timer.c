#include "mc_linux.h"
#include "../os_timer.h"

#define osal_sizeof_linux_timer_data (sizeof(((OS_TIMER*)0)->linux_timer_data))
#define osal_sizeof_timer_list       (sizeof(struct timer_list))
#define osal_sizeof_timer_ok (osal_sizeof_linux_timer_data >= osal_sizeof_timer_list)
typedef char osal_OS_TIMER_size_check_t[osal_sizeof_timer_ok ? 1 : -1];

#if (LINUX_VERSION_CODE < KERNEL_VERSION(4, 15, 0))
static void timer_entry(unsigned long data)
#else
static void timer_entry(struct timer_list *data)
#endif
{
    OS_TIMER *timer = (OS_TIMER *)data;
    OS_TIMER_HANDLER routine = timer->routine;
    routine(timer->context);
}

#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 15, 0))
#define del_timer timer_delete
#define del_timer_sync timer_delete_sync
#endif

void EDDI_API OsTimerInit(OS_RESOURCE osResource, OS_TIMER *timer, OS_TIMER_HANDLER routine, void *context)
{
    struct timer_list *nativeTimer = (struct timer_list *)timer->linux_timer_data;

    timer->routine = routine;
    timer->context = context;
    atomic_set((atomic_t *)&timer->shutdown_flag, 0);
#if (LINUX_VERSION_CODE < KERNEL_VERSION(4, 15, 0))
    init_timer(nativeTimer);
    nativeTimer->data = (UINT_PTR)timer;
    nativeTimer->function = timer_entry;
#else
    timer_setup(nativeTimer, timer_entry, 0);
#endif
}

void EDDI_API OsTimerDelete(OS_TIMER *timer)
{
}

void EDDI_API OsTimerCancel(OS_TIMER *timer)
{
    del_timer((struct timer_list *)timer->linux_timer_data);
}

void EDDI_API OsTimerCancelSync(OS_TIMER *timer)
{
    atomic_set((atomic_t *)&timer->shutdown_flag, 1);
    del_timer_sync((struct timer_list *)timer->linux_timer_data);
    // del_timer_sync guarantees that when it returns, the timer function is not running on any CPU
    // it can sleep if it is called from a nonatomic context but busy waits in other situations
    // see http://www.makelinux.net/ldd3/chp-7-sect-4
    atomic_set((atomic_t *)&timer->shutdown_flag, 0);
}

BOOLEAN EDDI_API OsTimerSetOnce(OS_TIMER *timer, UINT32 dueTimeMs)
{
    struct timer_list *nativeTimer = (struct timer_list *)timer->linux_timer_data;
    unsigned long expires = jiffies + (dueTimeMs*HZ)/1000;
    if (atomic_read((atomic_t *)&timer->shutdown_flag)) {
        return FALSE;
    }
    mod_timer(nativeTimer, expires);
    return TRUE;
}
