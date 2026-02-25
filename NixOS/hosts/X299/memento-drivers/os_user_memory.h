#ifndef OS_USER_MEMORY_HEADER_FILE
#define OS_USER_MEMORY_HEADER_FILE

#include "os_types.h"

#ifdef __cplusplus
extern "C"
{
#endif

/** Copies to kernel buffer n bytes located at offset fromOffset from fromBase user buffer.
    Returns zero on success.
 **/
UINT32 EDDI_API OsCopyFromUser(OS_RESOURCE osResource, void *to, const void *fromBase, UINT32 n, UINT32 fromOffset);

/** Copies from kernel buffer n bytes to a location starting at offset toOffset from toBase user buffer.
    Returns zero on success.
 **/
unsigned int EDDI_API OsCopyToUser(OS_RESOURCE osResource, void *toBase, const void *from, unsigned int n, UINT32 toOffset);

/** Checks whether reading [at ... at+n[ is allowed for user process.
 **/
BOOLEAN EDDI_API OsUserCanRead(const void *at, size_t n);

/** Checks whether writing [to ... to+n[ is allowed for user process.
 **/
BOOLEAN EDDI_API OsUserCanWrite(void *to, size_t n);

#ifdef __cplusplus
}
#endif

#endif
