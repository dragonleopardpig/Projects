#if defined(EURESYS_UNITTEST) && !defined(EURESYS_OSAL_UNITTEST)
    #include "UnitTests/os_interrupt_types.h"
#elif defined(EURESYS_OS_LINUX)
    #include "linux/os_interrupt_types.h"
#elif defined(EURESYS_OS_WINDOWS)
    #include "windows/os_interrupt_types.h"
#elif defined(EURESYS_OS_DARWIN)
    #include "darwin/os_interrupt_types.h"
#endif
