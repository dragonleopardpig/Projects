#ifndef OS_SYNCHRO_TYPES_HEADER_FILE
#define OS_SYNCHRO_TYPES_HEADER_FILE

#include "../os_interrupt_types.h"

typedef struct {
    unsigned int lock;
    unsigned int reserved[12];
} OS_SPINLOCK;

typedef unsigned int OS_SPINLOCAL;

/*
 This has at least the same size as the structure wait_queue_t 
 from Linux.

 It will work as long as in futere the versions of Linux the 
 structure remains smaller than this. 

 For higher portability, we could set a pointer in this structure to
 lookup the normal Linux structure. But then "dynamic" creation of 
 the wait_queut_t's would be needed. Bit slower and more complex.

 In linux 2.4.18 from "include\linux\wait.h" and "include\linux\list.h":

   struct __wait_queue_head {
        wq_lock_t lock;
        struct list_head task_list;
       #if WAITQUEUE_DEBUG
        long __magic;
        long __creator;
       #endif
   };
   typedef struct __wait_queue_head wait_queue_head_t;


   struct list_head {
        struct list_head *next, *prev;
   };

 Thus for Linux 2.4.18 and probably many others, 
 3 longs is a minimum, 6 with the debug info; 8 should do it.
*/
typedef struct {
    unsigned long linux_wait_data[8];
} OS_EVENT;



typedef struct {
    OS_EVENT event;
    volatile int bNotified;
} OS_NOTIFICATION_EVENT;


/*
 This has at least the same size as the structure semaphore 
 from Linux.

 It will work as long as in futere the versions of Linux the 
 structure remains smaller than this. 

 For higher portability, we could set a pointer in this structure to
 lookup the normal Linux structure. But then "dynamic" creation of 
 the wait_queut_t's would be needed. Bit slower and more complex.

 In linux 2.4.18 from "include\asm\i386\semaphore.h"
   struct semaphore {
        atomic_t count;
        int sleepers;
        wait_queue_head_t wait;
       #if WAITQUEUE_DEBUG
        long __magic;
       #endif
   };

 Thus for Linux 2.4.18 and probably many others,
 8 longs for the wait_queue and 4 other for the rest.
*/
typedef struct {
    unsigned long linux_wait_data[12];
} OS_SEMA;


#define OS_MUTEX OS_SEMA

#endif
