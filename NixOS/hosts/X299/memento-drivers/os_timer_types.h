#if defined(EURESYS_UNITTEST)
    #include "linux/os_timer_types.h"
#elif defined(EURESYS_OS_WINDOWS)
    #include "windows/os_timer_types.h"
#elif defined(EURESYS_OS_LINUX)
    #include "linux/os_timer_types.h"
#elif defined(EURESYS_OS_DARWIN)
    #include "darwin/os_timer_types.h"
#endif
