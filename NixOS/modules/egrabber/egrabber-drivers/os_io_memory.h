#ifndef IO_MEMORY_HEADER_FILE
#define IO_MEMORY_HEADER_FILE

#include "os_types.h"
#include "os_entry_points.h"

#ifdef __cplusplus
extern "C"
{
#endif

/** Maps bus memory into CPU space. **/
void *EDDI_API OsMapUncachedIoSpace(PHYSICAL_ADDR physicalAddress, size_t size);

/** Unmaps bus memory from CPU space. **/
void EDDI_API OsUnmapUncachedIoSpace(void *baseAddress, size_t size);

void EDDI_API OsMemCopyFromIo8(void *dest, const volatile void *source, unsigned int n);
void EDDI_API OsMemCopyFromIo16(void *dest, const volatile void *source, unsigned int n);
void EDDI_API OsMemCopyFromIo32(void *dest, const volatile void *source, unsigned int n);
void EDDI_API OsMemCopyToIo8(volatile void *dest, const void *source, unsigned int n);
void EDDI_API OsMemCopyToIo16(volatile void *dest, const void *source, unsigned int n);
void EDDI_API OsMemCopyToIo32(volatile void *dest, const void *source, unsigned int n);
UINT8  EDDI_API OsReadRegister8(const OS_MEM_RESOURCE *memory, volatile UINT8 *p);
UINT16 EDDI_API OsReadRegister16(const OS_MEM_RESOURCE *memory, volatile UINT16 *p);
UINT32 EDDI_API OsReadRegister32(const OS_MEM_RESOURCE *memory, volatile UINT32 *p);
void EDDI_API OsWriteRegister8(const OS_MEM_RESOURCE *memory, volatile UINT8 *p, UINT8 v);
void EDDI_API OsWriteRegister16(const OS_MEM_RESOURCE *memory, volatile UINT16 *p, UINT16 v);
void EDDI_API OsWriteRegister32(const OS_MEM_RESOURCE *memory, volatile UINT32 *p, UINT32 v);
#ifdef EURESYS_PTRSIZE_64_BITS
UINT64 EDDI_API OsReadRegister64(const OS_MEM_RESOURCE *memory, volatile UINT64 *p);
void EDDI_API OsWriteRegister64(const OS_MEM_RESOURCE *memory, volatile UINT64 *p, UINT64 v);
#endif

#ifdef __cplusplus
}
#endif

#endif
