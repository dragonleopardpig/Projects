/* types.h -- Types header
 *
 * (C) 2021 by Sensor to Image GmbH
 *
 * Version: 2.7.1 Date: 20.07.2022
 * History:
 * Version: 1.0.0 Date: 15.12.2021
 * - initial realease
 * - microseconds precision timestamps
 * Version: 2.7.1 Date: 20.07.2022
 * - delegate common abstract types to Common/s2i_types.h
 */
#ifndef __S2I_TYPES_H
#define __S2I_TYPES_H
#include <linux/types.h>

typedef __kernel_size_t size_t;
typedef __kernel_ssize_t ssize_t;
typedef _Bool BOOL;

#ifdef __aarch64__
#define EDDI_API
#else
#define EDDI_API __attribute__((regparm(0)))
#endif
#define WINAPI
typedef enum {
    OS_OK = 0,
    OS_ALLOC_FAILURE = 1,
    OS_SEND_FAILURE = 2,
    OS_TIMEOUT = 3,
} os_error_t;
struct sk_buff;
typedef struct sk_buff gev_kernel_context_t;
typedef u_int64_t os_time_t;
typedef u_int64_t os_delay_t;
#define OS_TIME_UNDEF 0
#define OsTimeDefined(t) (t)
typedef u_int32_t os_frequency_t;

typedef struct _IMAGE_BUFFER IMAGE_BUFFER;

#endif
