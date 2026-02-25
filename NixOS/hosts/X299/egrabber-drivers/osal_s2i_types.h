#ifndef __OSAL_S2I_TYPES_H
#define __OSAL_S2I_TYPES_H
#include <linux/types.h>
#ifndef __BIT_TYPES_DEFINED__
#define __OSAL_BIT_TYPES_DEFINED__
typedef __u8 u_int8_t;
typedef __u8 uint8_t;
typedef __s8 int8_t;
typedef __u16 u_int16_t;
typedef __u16 uint16_t;
typedef __s16 int16_t;
typedef __u32 u_int32_t;
typedef __u32 uint32_t;
typedef __s32 int32_t;
typedef __u64 u_int64_t;
typedef __u64 uint64_t;
typedef __s64 int64_t;
#endif

#define true 1
#define false 0
#ifndef NULL
#define NULL (void*)0
#endif

// from include/linux/kern_levels.h
#define KERN_SOH "\001"
#define KERN_EMERG      KERN_SOH "0"    /* system is unusable */
#define KERN_ALERT      KERN_SOH "1"    /* action must be taken immediately */
#define KERN_CRIT       KERN_SOH "2"    /* critical conditions */
#define KERN_ERR        KERN_SOH "3"    /* error conditions */
#define KERN_WARNING    KERN_SOH "4"    /* warning conditions */
#define KERN_NOTICE     KERN_SOH "5"    /* normal but significant condition */
#define KERN_INFO       KERN_SOH "6"    /* informational */
#define KERN_DEBUG      KERN_SOH "7"    /* debug-level messages */

#define KERN_DEFAULT    KERN_SOH "d"    /* the default kernel loglevel */


#endif
