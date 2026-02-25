#ifndef OS_TIMER_TYPES_HEADER_FILE
#define OS_TIMER_TYPES_HEADER_FILE

/*
 This has at least the same size as the structure timer_list 
 from Linux.

 It will work as long as in futere the versions of Linux the 
 structure remains smaller than this. 

 For higher portability, we could set a pointer in this structure to
 lookup the normal Linux structure. But then "dynamic" creation of 
 the timer's would be needed. Bit slower and more complex.

 In linux 2.6.29 from "include\linux\timer.h" and "include\linux\list.h":


 struct timer_list {
     struct list_head entry;
     unsigned long expires;

     void (*function)(unsigned long);
     unsigned long data;

     struct timer_base_s *base;
#ifdef CONFIG_TIMER_STATS
     void *start_size;
     char start_comm[16];
     int start_pid;
#endif
 };

 struct list_head {
     struct list_head *next, *prev;
 };

 Thus for Linux 2.6.29, 
 6 longs is a minimum, 12 with timer statistics; 14 should do it. 
*/
typedef struct {
    unsigned long linux_timer_data[14];
    OS_TIMER_HANDLER routine;
    void *context;
    unsigned long shutdown_flag;
} OS_TIMER;

#endif
