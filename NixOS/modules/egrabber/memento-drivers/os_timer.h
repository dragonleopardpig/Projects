#ifndef OS_TIMER_HEADER_FILE
#define OS_TIMER_HEADER_FILE

#include "os_types.h"

#ifdef __cplusplus
extern "C" 
{
#endif

typedef void EDDI_API (*OS_TIMER_HANDLER)(void *);

#if defined(EURESYS_OS_DARWIN) && defined(__cplusplus)
}
#endif

#include "os_timer_types.h"
#include "os_entry_points.h"

#if defined(EURESYS_OS_DARWIN) && defined(__cplusplus)
extern "C"
{
#endif

/** Initializes a timer. The routine argument is the routine that is run when 
    the timer expires. It runs at DISPATCH_LEVEL. The context argument is 
    passed to the routine. 
    Must be called before any other timer function.
    Can be called at IRQL <= DISPATCH_LEVEL.
**/
void EDDI_API OsTimerInit(OS_RESOURCE osResource, OS_TIMER *timer, OS_TIMER_HANDLER routine, void *context);

/** Deletes a timer.
    The timer may not be scheduled or running when calling this function.
    Can be called at IRQL <= DISPATCH_LEVEL.
**/
void EDDI_API OsTimerDelete(OS_TIMER *timer);

/** Stops a timer. If the timer was not started, nothing is done.
    The timer must have been initialized with OsTimerInit.
    Can be called at IRQL <= DISPATCH_LEVEL.
**/
void EDDI_API OsTimerCancel(OS_TIMER *timer);

/** OsTimerCancelSync Stops a timer and guarantees that when it returns,
    the timer function is not running. If the timer was not started, nothing is done.
    The timer must have been initialized with OsTimerInit.
    Must be called at PASSIVE_LEVEL.
    Note: calling OsTimerCancelSync while holding the same lock as the timer
    function attempts to obtain can lead to system deadlock.
**/
void EDDI_API OsTimerCancelSync(OS_TIMER *timer);

/** Starts a timer that will expire after dueTimeMs.
    The timer must have been initialized with OsTimerInit.
    Can be called at IRQL <= DISPATCH_LEVEL.
**/
BOOLEAN EDDI_API OsTimerSetOnce(OS_TIMER *timer, UINT32 dueTimeMs);

#ifdef __cplusplus
}
#endif

#endif
