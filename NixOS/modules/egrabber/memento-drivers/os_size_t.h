#ifndef OS_SIZE_T
#define OS_SIZE_T

#if defined(EURESYS_UNITTEST)
    #include <stdlib.h>
    #if defined(EURESYS_OS_WINDOWS)
        #include <BaseTsd.h>
        typedef SSIZE_T ssize_t;
    #else
        #include <sys/types.h>
    #endif
#elif defined(EURESYS_OS_WINDOWS)
    #include <crtdefs.h>
    #ifdef EURESYS_PTRSIZE_64_BITS
        typedef long long ssize_t;
    #else
        typedef int ssize_t;
    #endif
#elif defined(EURESYS_OS_LINUX) || defined(EURESYS_OS_DARWIN)
    #ifndef _SIZE_T
    #define _SIZE_T
    #ifdef EURESYS_PTRSIZE_64_BITS
        typedef unsigned long size_t;
    #else
        typedef unsigned int size_t;
    #endif
    #endif
    #ifndef _SSIZE_T
    #define _SSIZE_T
    #ifdef EURESYS_PTRSIZE_64_BITS
        typedef long ssize_t;
    #else
        typedef int ssize_t;
    #endif
    #endif
#endif

#endif
