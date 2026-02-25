#include "mc_linux.h"
#include "../os_user_memory.h"

#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)) \
    || defined(OSAL_ACCESS_OK_MACRO_2_ARGS)
#define check_access_ok(t, a, s) access_ok((a),(s))
#else
#define check_access_ok access_ok
#endif

BOOLEAN EDDI_API OsUserCanRead(const void *at, size_t n)
{
    return (0 != check_access_ok(VERIFY_READ, at, n)) ? TRUE : FALSE;
}

BOOLEAN EDDI_API OsUserCanWrite(void *at, size_t n)
{
    return (0 != check_access_ok(VERIFY_WRITE, at, n)) ? TRUE : FALSE;
}

UINT32 EDDI_API OsCopyFromUser(OS_RESOURCE osResource, void *to, const void *from, UINT32 n, UINT32 fromOffset)
{
    return copy_from_user(to, (const char *)from + fromOffset, n);
}

unsigned int EDDI_API OsCopyToUser(OS_RESOURCE osResource, void *to, const void *from, unsigned int n, UINT32 toOffset)
{
    return copy_to_user((char *)to + toOffset, from, n);
}
