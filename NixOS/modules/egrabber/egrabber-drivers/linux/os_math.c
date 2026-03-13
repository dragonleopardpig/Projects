#include "mc_linux.h"
#include "../os_math.h"

/* Note that the following functions are defined only for
 * 32-bit Linux kernels versions >= 2.6.26
 */
#ifndef EURESYS_PTRSIZE_64_BITS
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 26))
#include <linux/math64.h>

#if (LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 37))
#define abs64(x)               \
({                             \
    INT64 r = (x);             \
    (r < 0) ? -r :r;           \
})
#endif

UINT64 EDDI_API OsDivU64WithRem(UINT64 dividend, UINT32 divisor, UINT32 *remainder)
{
    return div_u64_rem(dividend, divisor, remainder);
}

UINT64 EDDI_API OsDivU64ByU64(UINT64 dividend, UINT64 divisor)
{
    return div64_u64(dividend, divisor);
}

INT64 EDDI_API OsDivS64ByS64(INT64 dividend, INT64 divisor)
{
#if (LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 37))
    INT64 quotient, t;
    quotient = div64_u64(abs64(dividend), abs64(divisor));
    t = (dividend ^ divisor) >> 63;
    return (quotient ^ t) - t;
#else
    return div64_s64(dividend, divisor);
#endif
}
#endif
#endif
