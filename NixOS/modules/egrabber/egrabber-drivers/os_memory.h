#ifndef MEMORY_HEADER_FILE
#define MEMORY_HEADER_FILE

#include "os_types.h"
#include "os_size_t.h"

enum OsPageability {
    OS_NOT_PAGEABLE,
    OS_PAGEABLE,
};

#ifdef __cplusplus
extern "C"
{
#endif

/** Allocates size bytes of memory and returns its address.
    The memory may be allocated from pageable memory pool if pageability
    equals OS_PAGEABLE and if the OS supports such allocations in the kernel.
    Note that there is no garantee on the physical contiguity of the
    allocated memory.
    OsMalloc can be used at IRQL <= DISPATCH_LEVEL.
    OsMalloc returns a non-null pointer when size is 0. **/
void *EDDI_API OsMalloc(size_t size, enum OsPageability pageability);

/** Frees memory allocated by OsMalloc.
    OsFree can be used at IRQL <= DISPATCH_LEVEL. **/
void EDDI_API OsFree(void *memory);

/** Must be called before the first call to OsMallocAtomic on darwin OS.
    Returns 0 on success **/
int EDDI_API OsMallocAtomicInit(void);

/** Must be called after the last call to OsFreeAtomic. **/
void EDDI_API OsMallocAtomicDelete(void);

/** Allocates size bytes of non paged memory and returns its address.
    OsMallocAtomic is specifically designed to be used in context where
    the caller must not sleep, such as when holding a spinlock.
    Note that there is no garantee on the physical contiguity of the
    allocated memory.
    This function cannot allocate more than 128kB.
    OsMallocAtomic can be used at IRQL <= DISPATCH_LEVEL.
    OsMallocAtomic returns a non-null pointer when size is 0. **/
void *EDDI_API OsMallocAtomic(size_t size);

/** Frees memory allocated by OsMallocAtomic.
    OsFreeAtomic can be used at IRQL <= DISPATCH_LEVEL. **/
void EDDI_API OsFreeAtomic(void *memory);


/** Fills the first size bytes of the memory area pointed to by memory
    with the constant byte character.
    Returns memory. **/
void *EDDI_API OsMemSet(void *memory, INT32 character, UINT32 size);

/** Copies n bytes from the memory region pointed to by source
    to the memory region pointed to by destination.
    If the regions overlap, the behavior is undefined. Use OsMemMove instead.
    Returns destination. **/
void *EDDI_API OsMemCopy(void *destination, const void *source, UINT32 n);

/** Copies n bytes from the memory region pointed to by source
    to the memory region pointed to by destination.
    The memory region may overlap.
    Returns destination. **/
void *EDDI_API OsMemMove(void *destination, const void *source, UINT32 n);

/** Compares the first size bytes of the objects pointed to by p1 and p2.
    Returns the result of the comparison, like memcmp. **/
int EDDI_API OsMemCmp(const void *p1, const void *p2, size_t size);

#ifdef __cplusplus
}
#endif

#endif
