#if defined(EURESYS_UNITTEST)
    #include "UnitTests/os_thread_types.h"
#elif defined(EURESYS_OS_LINUX)
    #include "./linux/os_thread_types.h"
#elif defined(EURESYS_OS_WINDOWS)
    #include "./windows/os_thread_types.h"
#elif defined(EURESYS_OS_DARWIN)
    #include "./darwin/os_thread_types.h"
#endif
