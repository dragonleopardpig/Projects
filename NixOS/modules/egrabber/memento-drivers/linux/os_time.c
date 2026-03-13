#include "mc_linux.h"
#include "../os_time.h"
#include "../os_math.h"

#ifdef S2I_FILTER_NAME
char *driver_name = S2I_FILTER_NAME;
#else
extern char *driver_name;
#endif

struct osal_timestamp {
    LONGLONG monotonic_ns;
    LONGLONG cycles;
    LONGLONG cycles_per_ms;
};

int EDDI_API OsSleep(unsigned int ms_delay) 
{
    unsigned long timeout;
    LONGLONG before;

    if (ms_delay == 0) {
        timeout = 0;
    } else {
        timeout = ((ms_delay * HZ + 999) / 1000) + 1;
    }

    /* On some systems, when NOHZ is enabled, the jiffies sometimes jump forward
     * and the timer expires too early. We work around this by checking the
     * required time has elapsed and if not go back to sleep. This was seen on
     * kernels < 2.6.27.
     */
    before = OsGetTimeSinceEpoch_us();
    do {
        set_current_state(TASK_UNINTERRUPTIBLE);
        schedule_timeout(timeout);
    } while (OsGetTimeSinceEpoch_us() - before < ms_delay * 1000);

    return OS_OK;
}

#ifndef EURESYS_UNITTEST

#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 28))
#define HAS_GETRAWMONOTONIC
#endif

#if !defined(__aarch64__) && !defined(__ARM_ARCH_7A__)
#define CAN_USE_GET_CYCLES
#endif

#if defined(HAS_GETRAWMONOTONIC) && defined(CAN_USE_GET_CYCLES)
#define CAN_INTERPOLATE_TIME
static DEFINE_PER_CPU(struct osal_timestamp, time0);
#endif

#else // EURESYS_UNITTEST is defined

struct osal_timestamp time0;
#define HAS_GETRAWMONOTONIC
#define CAN_USE_GET_CYCLES
#define CAN_INTERPOLATE_TIME

#endif

#define MS_IN_NS (1000 * 1000LL)
#define SEC_IN_NS (1000LL * MS_IN_NS)

static char *mementoclocksource = "unknown";
module_param(mementoclocksource, charp, S_IRUSR | S_IRGRP | S_IROTH);
MODULE_PARM_DESC(mementoclocksource, "current clock source at load time");

#ifdef CAN_INTERPOLATE_TIME

static LONGLONG EDDI_API OsGetMonotonic_ns(void);

LONGLONG EDDI_API OsGetInterpolatedTimestamp_ns(void);
LONGLONG EDDI_API OsGetInterpolatedTimestamp_ns(void)
{
    struct osal_timestamp *ref = &get_cpu_var(time0);  
    /* kernel preemption disabled by get_cpu_var. Interruptions are still allowed. */
    
    LONGLONG nowc, oldc, deltac, stamp, cpms;
    do {
        oldc = ref->cycles;
        stamp = ref->monotonic_ns;
        cpms = ref->cycles_per_ms;
    } while (! __sync_bool_compare_and_swap(&ref->cycles, oldc, oldc));
    /* we had no alteration of per-cpu state between reading of cycles and monotonic stamp */
    nowc = get_cycles();

    deltac = nowc - oldc;
    put_cpu_var(time0);  /* kernel preemption re-enabled */
    
    if (cpms > 0 && deltac < cpms && deltac >= 0) {
        /* accepted precision up to 1ms */
        stamp += OsDivS64ByS64(deltac * MS_IN_NS, cpms);
    } else {
        LONGLONG now_ns, old_ns;
        now_ns = OsGetMonotonic_ns();
        
        ref = &get_cpu_var(time0); /* kernel preemption disabled */

        oldc = ref->cycles;
        nowc = get_cycles();
        old_ns = ref->monotonic_ns;
        
        if (__sync_bool_compare_and_swap(&ref->cycles, oldc, nowc) &&
            __sync_bool_compare_and_swap(&ref->monotonic_ns, old_ns, now_ns)) {
            /* succesfully updated state uninterrupted */
            deltac = nowc - oldc;

            if (old_ns && old_ns < now_ns) {
                LONGLONG old_cpms, now_cpms;
                if (deltac > LLONG_MAX / MS_IN_NS) {
                    now_cpms = OsDivS64ByS64(deltac,  OsDivS64ByS64(now_ns - old_ns, MS_IN_NS));
                } else {
                    now_cpms = OsDivS64ByS64(MS_IN_NS * deltac, now_ns - old_ns);
                }
                do {
                    old_cpms = ref->cycles_per_ms;
                } while (! __sync_bool_compare_and_swap(&ref->cycles_per_ms, old_cpms, now_cpms));
            }
        } 
        put_cpu_var(time0);   /* kernel preemption re-enabled */

        stamp = now_ns;
    }
    return stamp;
}

LONGLONG EDDI_API OsGetInterpolatedTimestamp_us(void);
LONGLONG EDDI_API OsGetInterpolatedTimestamp_us(void)
{
    return OsDivS64ByS64(OsGetInterpolatedTimestamp_ns(), 1000);
}

#endif

static LONGLONG EDDI_API OsGetMonotonic_us(void);
static LONGLONG EDDI_API OsGetMonotonic_ns(void);
/**
Return the number of processor ticks.
 **/
LONGLONG EDDI_API OsGetCpuTicks(void)
{
#if defined(CAN_USE_GET_CYCLES)
    return get_cycles();
#elif defined(HAS_GETRAWMONOTONIC)
#if defined(__ARM_ARCH_7A__)
    return OsGetMonotonic_ns();
#else
    return OsGetMonotonic_us();
#endif
#else
    // might be OK depending on kernel version and kernel config
    return get_cycles();
#endif
}

/**
  Returns the number of processor ticks in KHz.

  Call it only in the context of a process.
**/
LONGLONG EDDI_API OsGetCpuTicksFrequency(void) 
{
    LONGLONG ticks;
    static LONGLONG frequency = 0;
    LONGLONG t0, t1;
    unsigned long time_delta, ih, il;
    unsigned int tik;

    if (frequency != 0) {
        return frequency;
    }

    ticks = OsGetCpuTicks();
    t0 = OsGetTimeSinceEpoch_us();

    OsSleep(1020);

    t1 = OsGetTimeSinceEpoch_us();
    ticks = OsGetCpuTicks() - ticks;

    if (ticks == 0) {
        return 1; // error
    }

    time_delta = t1 - t0;

    tik = (unsigned int)ticks;
    ih = ((tik & 0xFFFF0000) >> 10) * 1000 / time_delta;
    il = ((tik & 0xFFFF) << 6) * 1000 / time_delta + (1 << 5);

    frequency = (ih << 10) | (il) >> 6;

    return frequency;
}

/**
  Returns the number of microseconds since Epoch (00:00:00 UTC, January 1, 1970).
**/
LONGLONG EDDI_API OsGetTimeSinceEpoch_us(void)
{
    LONGLONG time_us;
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0))
    struct timespec64 ts;
    ktime_get_real_ts64(&ts);
    time_us = ((LONGLONG)ts.tv_sec * 1000000) + ts.tv_nsec / 1000;
#else
    struct timeval tv;
    do_gettimeofday(&tv);
    time_us = ((LONGLONG)tv.tv_sec * 1000000) + tv.tv_usec;
#endif
    return time_us;
}

/**
  Returns the number of microseconds since Epoch (00:00:00 UTC, January 1, 1970).
**/
LONGLONG EDDI_API OsGetSystemTime_us(void)
{
    return OsGetTimeSinceEpoch_us();
}

LONGLONG EDDI_API OsGetTimestamp(void)
{
    return OsGetSystemTime_us();
}

#ifdef HAS_GETRAWMONOTONIC
static LONGLONG EDDI_API OsGetMonotonic_ns(void)
{
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0))
    struct timespec64 ts;
    ktime_get_raw_ts64(&ts);
#else
    struct timespec ts;
    getrawmonotonic(&ts);
#endif
    return ((LONGLONG)ts.tv_sec * 1000000000) + ts.tv_nsec;
}

static LONGLONG EDDI_API OsGetMonotonic_us(void)
{
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0))
    struct timespec64 ts;
    ktime_get_raw_ts64(&ts);
#else
    struct timespec ts;
    getrawmonotonic(&ts);
#endif
    return ((LONGLONG)ts.tv_sec * 1000000) + ts.tv_nsec / 1000;
}

#ifdef CAN_INTERPOLATE_TIME
#define DEFINE_SELECT_TIMESTAMP_FN(UNIT)                                                                        \
static LONGLONG EDDI_API OsSelectTimestampFn_##UNIT(void)                                                       \
{                                                                                                               \
    if (strncmp(mementoclocksource, "acpi_pm", 7) == 0) {                                                       \
        OsGetMementoTimestamp_us = OsGetInterpolatedTimestamp_us;                                               \
        OsGetMementoTimestamp_ns = OsGetInterpolatedTimestamp_ns;                                               \
        printk(KERN_WARNING "%s: using clock source 'acpi_pm' with experimental interpolation\n", driver_name); \
    } else {                                                                                                    \
        OsGetMementoTimestamp_us = OsGetMonotonic_us;                                                           \
        OsGetMementoTimestamp_ns = OsGetMonotonic_ns;                                                           \
        printk(KERN_DEBUG "%s: using clock source '%s'\n", driver_name, mementoclocksource);                    \
    }                                                                                                           \
    return OsGetMementoTimestamp_##UNIT();                                                                      \
}
#else
#define DEFINE_SELECT_TIMESTAMP_FN(UNIT)                                                                        \
static LONGLONG EDDI_API OsSelectTimestampFn_##UNIT(void)                                                       \
{                                                                                                               \
    OsGetMementoTimestamp_us = OsGetMonotonic_us;                                                               \
    OsGetMementoTimestamp_ns = OsGetMonotonic_ns;                                                               \
    return OsGetMementoTimestamp_##UNIT();                                                                      \
}
#endif

DEFINE_SELECT_TIMESTAMP_FN(us);
DEFINE_SELECT_TIMESTAMP_FN(ns);

LONGLONG EDDI_API (*OsGetMementoTimestamp_us)(void) = OsSelectTimestampFn_us;
LONGLONG EDDI_API (*OsGetMementoTimestamp_ns)(void) = OsSelectTimestampFn_ns;

#else
/**
  The following implementation of OsGetMementoTimestamp is not recommended.
  The aim is to define it to be able to install Memento-dependent modules on
  older kernels.
**/
static LONGLONG EDDI_API OsGetWallTime_ns(void)
{
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0))
    struct timespec64 now;
#else
    struct timespec ts;
#endif
    ts = current_kernel_time();
    return ((LONGLONG)ts.tv_sec * 1000000000) + ts.tv_nsec;
}

static LONGLONG EDDI_API OsGetWallTime_us(void)
{
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0))
    struct timespec64 now;
#else
    struct timespec ts;
#endif
    ts = current_kernel_time();
    return ((LONGLONG)ts.tv_sec * 1000000) + ts.tv_nsec / 1000;
}

LONGLONG EDDI_API (*OsGetMementoTimestamp_us)(void) = OsGetWallTime_us;
LONGLONG EDDI_API (*OsGetMementoTimestamp_ns)(void) = OsGetWallTime_ns;
#endif

#ifndef EURESYS_UNITTEST
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 32))
void OsGetSystemDateTime(OS_DATE_TIME *datetime)
{
    struct tm tm_val;
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0))
    struct timespec64 now;
    ktime_get_real_ts64(&now);
    time64_to_tm(now.tv_sec, 0, &tm_val);
#else
    struct timeval now;
    do_gettimeofday(&now);
    time_to_tm(now.tv_sec, 0, &tm_val);
#endif
    datetime->Year = 1900 + tm_val.tm_year;
    datetime->Month = tm_val.tm_mon + 1;
    datetime->Day = tm_val.tm_mday;
    datetime->Hour = tm_val.tm_hour;
    datetime->Minute = tm_val.tm_min;
    datetime->Second = tm_val.tm_sec;
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0))
    datetime->Microsecond = now.tv_nsec / 1000;
#else
    datetime->Microsecond = now.tv_usec;
#endif
}
#endif
#endif
