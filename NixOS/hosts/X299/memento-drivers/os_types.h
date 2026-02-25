#if defined(EURESYS_UNITTEST) && !defined(EURESYS_OSAL_UNITTEST)
    #include "UnitTests/os_types.h"
#elif defined(EURESYS_OS_LINUX)
    #include "linux/os_types.h"
#elif defined(EURESYS_OS_WINDOWS)
    #include "windows/os_types.h"
#elif defined(EURESYS_OS_DARWIN)
    #include "darwin/os_types.h"
#else
#error Please define a valid EURESYS_OS_XXX macro
#endif

