#ifndef OS_TIME_HEADER_FILE
#define OS_TIME_HEADER_FILE

#include "os_types.h"

#ifndef OS_OK
#define OS_OK 0
#endif

#ifdef __cplusplus
extern "C" 
{
#endif

/** Put the process to sleep for a given period

    This function can only be called in the context of a process 
    or big trouble will happen.

    \param ms_delay The time in ms to sleep.
**/
int EDDI_API OsSleep(unsigned int ms_delay);

/** Returns the number of processor ticks. **/
LONGLONG EDDI_API OsGetCpuTicks(void);

/** Returns the number of processor ticks. **/
LONGLONG EDDI_API OsGetCpuTicksFrequency(void);

/** Returns the number of microseconds since Epoch on
    the OSes that support it, otherwise returns 0.
    When supported, this value has near microsecond resolution.

    The Epoch is at 00:00:00 UTC, January 1, 1970.
**/
LONGLONG EDDI_API OsGetTimeSinceEpoch_us(void);

/** Returns the "System Time" expressed in microseconds.
    Under Windows, system time reference is January 1, 1601.
    Under Linux, system time reference is the Epoch (January 1, 1970).
    This value is updated approximately every 10 milliseconds on Windows.
**/
LONGLONG EDDI_API OsGetSystemTime_us(void);

/** Returns time-since-boot in microseconds/nanoseconds.
**/
extern LONGLONG EDDI_API (*OsGetMementoTimestamp_us)(void);
extern LONGLONG EDDI_API (*OsGetMementoTimestamp_ns)(void);

/** Returns the "current timestamp" expressed in microseconds.
    Under Windows, timestamp reference is boot.
    Under Linux, timestamp reference is the Epoch (January 1, 1970). TODO: use
    monotonic clock.
**/
LONGLONG EDDI_API OsGetTimestamp(void);

typedef struct
{
    unsigned int Year;
    unsigned int Month;
    unsigned int Day;
    unsigned int Hour;
    unsigned int Minute;
    unsigned int Second;
    unsigned int Microsecond;
} OS_DATE_TIME;

void OsGetSystemDateTime(OS_DATE_TIME *datetime);

#ifdef __cplusplus
}
#endif


#endif
