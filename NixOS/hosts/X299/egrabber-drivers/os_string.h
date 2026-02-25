#ifndef STRING_HEADER_FILE
#define STRING_HEADER_FILE

#include "os_size_t.h"
#include "os_types.h"

#ifdef __cplusplus
extern "C"
{
#endif

/** Returns the length of string which must be null-terminated.
    The length does not include the terminating null character. **/
size_t EDDI_API OsStrLen(const char *string);

#ifdef __cplusplus
}
#endif

#endif
