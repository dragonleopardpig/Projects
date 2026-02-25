#ifndef OS_SYNCHRO_HEADER_FILE
#define OS_SYNCHRO_HEADER_FILE

#define OS_OK 0
#define OS_ERROR 1
#define OS_WAIT_ALERTED 88
#define OS_WAIT_TIMEOUT 99
#define OS_WAIT_DEADLOCK 111
#define OS_OVERFLOW 222

#include "os_types.h"

#if defined(EURESYS_OS_LINUX) && (!defined(EURESYS_UNITTEST) || defined(EURESYS_OSAL_UNITTEST))
    #include "linux/os_synchro_types.h"
#elif defined(EURESYS_OS_WINDOWS) && !defined(EURESYS_UNITTEST)
    #ifdef __cplusplus
        extern "C"
        {
    #endif
    #include <ntddk.h>
    #ifdef __cplusplus
        }
    #endif
    #include "windows/os_synchro_types.h"
#elif defined(EURESYS_OS_DARWIN)
    #include "darwin/os_synchro_types.h"
#endif

#ifdef __cplusplus
extern "C" 
{
#endif

/** Initialize a semaphore

    \param lock Semaphore structure (type OS_SEMA)
    \param initCount Initial value of the semaphore
    \param maxCount ignored in Linux

    \sa OsSemaInit, OsSemaWait, OsSemaRelease, OsSemaDelete
**/
int EDDI_API OsSemaInit(OS_SEMA *lock, int initCount, int maxCount);

/** Wait on a semaphore and decrement it

    Call allowed only in the context of a process.
    This is an interruptible wait. If the return value is OS_ALERTED, 
    the system call should abort and return -ESYSRESTART. The caller 
    should try again or completely abort the operation.

    The semaphore must have been initialized by OsSemaInit.

    \sa OsSemaInit, OsSemaWait, OsSemaRelease, OsSemaDelete 
**/
int EDDI_API OsSemaWait(OS_SEMA *lock);

/** Wait during a limited time on a semaphore and decrement it.

    WARNING: On Linux the timeout is ignored !

    Call allowed only in the context of a process.

    The semaphore must have been initialized by OsSemaInit.

    \param timeout Timeout for the wait expressed in milliseconds
    \sa OsSemaInit, OsSemaWait, OsSemaRelease, OsSemaDelete 
**/
int EDDI_API OsSemaTimedWait(OS_SEMA *lock, int timeout);

/** Release a semaphore incrementing it and wake threads waiting on it.

    The semaphore must have been initialized by OsSemaInit.

    \sa OsSemaInit, OsSemaWait, OsSemaRelease, OsSemaDelete
**/
int EDDI_API OsSemaRelease(OS_SEMA *lock);

/** Free a semaphore

    No more threads may be waiting on the semaphore or
    you're gonna have a lot of trouble.

    The semaphore must have been initialized by OsSemaInit.
    Windows limitation: Callers of KeReleaseSemaphore must be running
    at IRQL <= DISPATCH_LEVEL.

    \sa OsSemaInit, OsSemaWait, OsSemaRelease, OsSemaDelete
**/
int EDDI_API OsSemaDelete(OS_SEMA *lock);


/** Initialize a mutex, also called critical section

    A mutex must be initialized before any other operation on it.

    \sa OsMutexWait, OsMutexWaitUninterruptible, OsMutexRelease,
    \sa OsMutexDelete
**/
int EDDI_API OsMutexInit(OS_MUTEX *lock);

/** Enter into a mutex, also called critical section

    The mutex must have been initialized with OsMutexInit. Call
    OsMutexWait only once when entering a mutex. Don't call
    OsMutexWait again while already in the mutex.

    Call allowed only in the context of a process.
    This is an interruptible wait.If the return value is OS_ALERTED, 
    the system call should abort and return -ESYSRESTART. The caller 
    should try again or completely abort the operation.

    \sa OsMutexInit, OsMutexWaitUninterruptible, OsMutexRelease,
    \sa OsMutexDelete
**/
int EDDI_API OsMutexWait(OS_MUTEX *lock);

/** Enter into a mutex, also called critical section

    The mutex must have been initialized with OsMutexInit. Call
    OsMutexWaitUninterruptible only once when entering a mutex.
    Don't call OsMutexWaitUninterruptible again while already in
    the mutex.

    Call allowed only in the context of a process.
    This is an uninterruptible wait.

    Warning: Windows tolerates recursive locks on a mutex, Linux doesn't.

    \sa OsMutexInit, OsMutexWait, OsMutexRelease, OsMutexDelete
**/
int EDDI_API OsMutexWaitUninterruptible(OS_MUTEX *lock);

/** Leave a mutex, also called critical section

    The mutex must have been initialized with OsMutexInit 
    and taken with OsMutexWait. Call osMutexRelease only once
    when leaving a mutex. Windows limitation: Callers of 
    KeReleaseSemaphore must be running at IRQL <= DISPATCH_LEVEL.

    \sa OsMutexInit, OsMutexWait, OsMutexWaitUninterruptible,
    \sa OsMutexDelete
**/
int EDDI_API OsMutexRelease(OS_MUTEX *lock);

/** Free an initialized mutex

    The mutex must have been initialized with OsMutexInit and nobody may be waiting
    on it anymore.
    \sa OsMutexInit, OsMutexWait, OsMutexWaitUninterruptible,
    \sa OsMutexRelease
**/
int EDDI_API OsMutexDelete(OS_MUTEX *lock);


/** Initialize a spinlock

    For mutual exclusion with high priority routines like interrupt handlers,
    DPC's, or tasklets.
    The spinlock must have been initialized with OsSpinLockInit

    This function should only be called in the context of a process.
    \sa OsSpinLockInit, OsSpinLockWait, OsSpinLockRelease, OsSpinLockDelete
**/
int EDDI_API OsSpinLockInit(OS_SPINLOCK *spinlock);

/** Spin on a lock and acquire it

    For mutual exclusion with high priority routines like interrupt handlers
    or DPC's, or tasklets.

    This function can be called in the context of a process or at DPC level.
    The spinlock must have been initialized with OsSpinLockInit
    \sa OsSpinLockInit, OsSpinLockWait, OsSpinLockRelease, OsSpinLockDelete
**/
int EDDI_API OsSpinLockWait(OS_SPINLOCK *spinlock, OS_SPINLOCAL *context);


/** Release a spinlock

    For mutual exclusion with high priority routines like interrupt handlers
    or DPC's, or tasklets.

    This function can be called in the context of a process or at DPC level.
    The spinlock must have been initialized with OsSpinLockInit
    \sa OsSpinLockInit, OsSpinLockWait, OsSpinLockRelease, OsSpinLockDelete
**/
int EDDI_API OsSpinLockRelease(OS_SPINLOCK *spinlock, OS_SPINLOCAL *context);

/** Spin on a lock and acquire it

    For mutual exclusion with high priority routines like interrupt handlers
    or DPC's, or tasklets.

    This function should only be called in high priority routines 
    like interrupt handlers, DPC's, or tasklets. .
    The spinlock must have been initialized with OsSpinLockInit
    \sa OsSpinLockInit, OsSpinLockWait, OsSpinLockRelease, OsSpinLockDelete
    \sa OsSpinLockWaitDpc, OsSpinLockReleaseDpc
**/
int EDDI_API OsSpinLockWaitDpc(OS_SPINLOCK *spinlock, OS_SPINLOCAL *context);

/** Release a spinlock

    For mutual exclusion with high priority routines like interrupt handlers,
    DPC's, or tasklets.

    This function should only be called in high priority routines 
    like interrupt handlers or DPC's, or tasklets.
    The spinlock must have been initialized with OsSpinLockInit
    \sa OsSpinLockInit, OsSpinLockWait, OsSpinLockRelease, OsSpinLockDelete
    \sa OsSpinLockWaitDpc, OsSpinLockReleaseDpc
**/
int EDDI_API OsSpinLockReleaseDpc(OS_SPINLOCK *spinlock, OS_SPINLOCAL *context);

/** Acquire a spinlock

    For mutual exclusion with interrupt handlers.

    The spinlock must have been initialized with OsSpinLockInit
    \sa OsSpinLockInit, OsSpinLockWait, OsSpinLockRelease, OsSpinLockDelete
    \sa OsSpinLockWaitDpc, OsSpinLockReleaseDpc
**/
int EDDI_API OsSpinLockWaitIrqSafe(OS_SPINLOCK *spinlock, OS_SPINLOCAL *context);

/** Release a spinlock

    For mutual exclusion with interrupt handlers.

    The spinlock must have been initialized with OsSpinLockInit
    \sa OsSpinLockInit, OsSpinLockWait, OsSpinLockRelease, OsSpinLockDelete
    \sa OsSpinLockWaitDpc, OsSpinLockReleaseDpc
**/
int EDDI_API OsSpinLockReleaseIrqSafe(OS_SPINLOCK *spinlock, OS_SPINLOCAL *context);

/** Free a spinlock

    This function should only be called in context of a process.
    The spinlock must have been initialized with OsSpinLockInit and nobody
    may be waiting on it anymore.
    \sa OsSpinLockInit, OsSpinLockWait, OsSpinLockRelease, OsSpinLockDelete
    \sa OsSpinLockWaitDpc, OsSpinLockReleaseDpc
**/
int EDDI_API OsSpinLockDelete(OS_SPINLOCK *spinlock);


/** Initialize a notification event

    An notification event is a special synchronisation event 
    which signals something to all its waiting threads. On a OsNotificationEventRelease,
    all waiting threads are woken up untill the event is cleared with 
    OsNotificationEventClear.

    Must be called before any other OsNotificationEvent* function.
    \sa OsNotificationEventWait, OsNotificationEventRelease, OsNotificationEventDelete
    \sa OsNotificationEventClear
**/
int EDDI_API OsNotificationEventInit(OS_RESOURCE osResource, OS_NOTIFICATION_EVENT *event);

/** Wait on a notification event.

    Allowed only in the context of a process.
    Warning, other waiting threads will also wake up! 

    Alertable WITHOUT notice ! Caller should check its own status data
    to be sure the wait didn't abort.

    The event must have been initialized with OsNotificationEventInit before using it.

    \sa OsNotificationEventWait, OsNotificationEventRelease, OsNotificationEventDelete
    \sa OsNotificationEventInit, OsNotificationEventClear
**/
int EDDI_API OsNotificationEventWait(OS_NOTIFICATION_EVENT *event);

/** Wait on a notification event in a uninterruptible way.

    Allowed only in the context of a process.
    Warning, other waiting threads will also wake up!

    No signal can interrupt the wait so make sure the condition will be
    satisfied and that it won't wait too long.

    The event must have been initialized with OsNotificationEventInit before using it.

    \sa OsNotificationEventWait, OsNotificationEventRelease, OsNotificationEventDelete
    \sa OsNotificationEventInit, OsNotificationEventClear
**/
int EDDI_API OsNotificationEventWaitUninterruptible(OS_NOTIFICATION_EVENT *event);

/** Wait on a notification event during a limited time.

    Allowed only in the context of a process.
    Warning, other waiting threads will also wake up! 

    WARNING: On Linux the timeout is ignored !

    The event must have been initialized with OsNotificationEventInit before using it.

    \param timeout Timeout for the wait expressed in milliseconds
    \sa OsNotificationEventWait, OsNotificationEventRelease, OsNotificationEventDelete
    \sa OsNotificationEventInit, OsNotificationEventClear
**/
int EDDI_API OsNotificationEventTimedWait(OS_NOTIFICATION_EVENT *event, int timeout);

/** Release an event waking all threads sleeping on it.

    The event must have been initialized with OsNotificationEventInit before using it.

    \sa OsNotificationEventWait, OsNotificationEventRelease, OsNotificationEventDelete
    \sa OsNotificationEventInit, OsNotificationEventClear
**/
int EDDI_API OsNotificationEventRelease(OS_NOTIFICATION_EVENT *event);

/** Resets the notification event.

    When a notification event is cleared, any OsNotificationWait will
    wait till a new OsNotificationEventRelease.

    \sa OsNotificationEventWait, OsNotificationEventRelease, OsNotificationEventDelete
    \sa OsNotificationEventInit
**/
int EDDI_API OsNotificationEventClear(OS_NOTIFICATION_EVENT *event);

/** Free an initialized event

    No more threads may be waiting on the event when deleting it.

    \sa OsNotificationEventWait, OsNotificationEventRelease, OsNotificationEventDelete
    \sa OsNotificationEventInit
**/
int EDDI_API OsNotificationEventDelete(OS_NOTIFICATION_EVENT *event);

/** Release the mach_port_t passed to registerNotificationPort()

    This function is darwin specific
**/
void EDDI_API OsReleaseNotificationPort(void *port);

/** Create a barrier at this position in the code.
**/
void EDDI_API OsMemoryBarrier(void);


typedef BOOLEAN EDDI_API (*OS_SYNC_ROUTINE)(void *);

/** Synchronize the execution of the function with the given interrupt.

    \param syncRoutine The callback function called when synchronized. 
    Should be fast. 
    The callback has the prototype: 
    BOOLEAN syncRoutine(void *syncRoutineContext).
    \param syncRoutineContext Argument passed to the callback function
    \param itr Interrupt to synchronize with
**/
int EDDI_API OsSynchronizeIrqExecution(OS_SYNC_ROUTINE syncRoutine, 
                                       void *syncRoutineContext,
                                       OS_INTERRUPT itr);

/** Sleep with a busy loop

    For small (<<1ms) and precise sleeps call OsStallProcessor. 
    This is a busy wait, stalling the CPU and the whole system. 
    Use with care and avoid it when possible.
**/
int EDDI_API OsStallProcessor(unsigned int usecs);
#ifdef __cplusplus
}
#endif

#endif
