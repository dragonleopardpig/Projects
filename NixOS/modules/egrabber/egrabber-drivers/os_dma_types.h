#ifndef OS_DMA_TYPES_COMMON_HEADER_FILE
#define OS_DMA_TYPES_COMMON_HEADER_FILE

#if defined(EURESYS_UNITTEST) && !defined(EURESYS_OSAL_UNITTEST)
    #include "UnitTests/os_dma_types.h"
#elif defined(EURESYS_OS_LINUX)
    #include "linux/os_dma_types.h"
#elif defined(EURESYS_OS_WINDOWS)
    #include "windows/os_dma_types.h"
#elif defined(EURESYS_OS_DARWIN)
    #include "darwin/os_dma_types.h"
#endif

#include "os_types.h"

typedef struct
{
    PHYSICAL_ADDR Base;
    UINT32 Length;
    UINT32 Offset;
} OS_DMA_PAGE;

#endif
