#ifndef OS_THREAD_TYPES_HEADER_FILE
#define OS_THREAD_TYPES_HEADER_FILE

#include "os_types.h"

/*
 This has at least the same size as the biggest of the structures
 tq_struct and work_struct from Linux kernel 2.4 and 2.6.

    struct tq_struct {
        struct tq_struct *next;
        int sync;
        void (*routine)(void *);
        void *data;
    };

    struct work_struct {
        unsigned long pending;
        struct list_head entry;
        void (*func)(void *);
        void *data;
        void *wq_data;
        struct timer_list timer

    struct timer_list {
        struct list_head entry;
        unsigned long expires;
        unsigned long magic;
        void (*function)(unsigned long);
        unsigned long data;
        struct timer_base_s *base;
    };

    struct list_head {
        struct list_head *next, *prev;
    };

  13 longs for work_struct (6 + 7 for timer_list), 16 should do it.
*/
typedef struct {
    unsigned long linux_task_data[16];
} OS_TASK;

typedef void EDDI_API (*OS_THREAD_ROUTINE)(void *ctx);

#endif
