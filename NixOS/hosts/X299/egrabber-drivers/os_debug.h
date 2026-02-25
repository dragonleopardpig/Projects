#include "os_types.h"

#if defined(EURESYS_UNITTEST)
    #include "linux/os_debug.h"
#elif defined(EURESYS_OS_WINDOWS)
    #include "windows/os_debug.h"
#elif defined(EURESYS_OS_LINUX)
    #include "linux/os_debug.h"
#elif defined(EURESYS_OS_DARWIN)
    #include "darwin/os_debug.h"
#endif
