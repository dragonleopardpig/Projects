#include "os_types.h"

#define memento_backing memento_backing_1
#define memento_mmap_size memento_mmap_size_1

#ifdef EURESYS_NO_MEMENTO
#ifdef EURESYS_WARN_IF_NO_MEMENTO
#pragma message "compiling without memento support"
#endif
void *memento_backing = 0;
UINT64 memento_mmap_size = 0;
#endif
