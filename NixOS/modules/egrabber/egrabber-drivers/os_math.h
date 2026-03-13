#ifndef MATH_HEADER_FILE
#define MATH_HEADER_FILE

#include "os_types.h"

#ifdef __cplusplus
extern "C"
{
#endif

#if !defined(EURESYS_OS_LINUX) || !defined (__KERNEL__) || defined (EURESYS_PTRSIZE_64_BITS) || defined (EURESYS_UNITTEST)
static inline UINT64 EDDI_API OsDivU64WithRem(UINT64 dividend, UINT32 divisor, UINT32 *remainder)
{
    *remainder = (UINT32)(dividend % divisor);
    return dividend / divisor;
}

static inline UINT64 EDDI_API OsDivU64ByU64(UINT64 dividend, UINT64 divisor)
{
    return dividend / divisor;
}

static inline INT64 EDDI_API OsDivS64ByS64(INT64 dividend, INT64 divisor)
{
    return dividend / divisor;
}
#else
UINT64 EDDI_API OsDivU64WithRem(UINT64 dividend, UINT32 divisor, UINT32 *remainder);

UINT64 EDDI_API OsDivU64ByU64(UINT64 dividend, UINT64 divisor);

INT64 EDDI_API OsDivS64ByS64(INT64 dividend, INT64 divisor);
#endif

#ifdef __cplusplus
}
#endif

#endif
