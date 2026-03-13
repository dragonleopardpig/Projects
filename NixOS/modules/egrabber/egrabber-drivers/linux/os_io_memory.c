#include "mc_linux.h"
#include "../os_io_memory.h"

#ifdef CONFIG_PSTORE_RTRACE
extern void pstore_rtrace_call(enum rtrace_event_type log_type, void *data, long val)
{
}
#endif

void *EDDI_API OsMapUncachedIoSpace(PHYSICAL_ADDR physicalAddress, size_t size)
{
#if (LINUX_VERSION_CODE < KERNEL_VERSION(5,6,0))
    return ioremap_nocache((UINT_PTR)physicalAddress.QuadPart, size);
#else
    return ioremap((UINT_PTR)physicalAddress.QuadPart, size);
#endif
}

void EDDI_API OsUnmapUncachedIoSpace(void *baseAddress, size_t size)
{
    iounmap(baseAddress);
}

void EDDI_API OsMemCopyFromIo8(void *dest, const volatile void *source, unsigned int n)
{
    u8 *d = (u8 *)dest;
    u8 __iomem *s = (u8 __iomem *)source;
    unsigned int i;
    for (i = 0; i < n; ++i) {
        d[i] = ioread8(&s[i]);
    }
}

void EDDI_API OsMemCopyToIo8(volatile void *dest, const void *source, unsigned int n)
{
    u8 *s = (u8 *)source;
    u8 __iomem *d = (u8 __iomem *)dest;
    unsigned int i;
    for (i = 0; i < n; ++i) {
        iowrite8(s[i], &d[i]);
    }
}

void EDDI_API OsMemCopyFromIo16(void *dest, const volatile void *source, unsigned int n)
{
    u16 *d = (u16 *)dest;
    u16 __iomem *s = (u16 __iomem *)source;
    unsigned int i;
    for (i = 0; i < n; ++i) {
        d[i] = ioread16(&s[i]);
    }
}

void EDDI_API OsMemCopyToIo16(volatile void *dest, const void *source, unsigned int n)
{
    u16 *s = (u16 *)source;
    u16 __iomem *d = (u16 __iomem *)dest;
    unsigned int i;
    for (i = 0; i < n; ++i) {
        iowrite16(s[i], &d[i]);
    }
}

void EDDI_API OsMemCopyFromIo32(void *dest, const volatile void *source, unsigned int n)
{
    u32 *d = (u32 *)dest;
    u32 __iomem *s = (u32 __iomem *)source;
    unsigned int i;
    for (i = 0; i < n; ++i) {
        d[i] = ioread32(&s[i]);
    }
}

void EDDI_API OsMemCopyToIo32(volatile void *dest, const void *source, unsigned int n)
{
    u32 *s = (u32 *)source;
    u32 __iomem *d = (u32 __iomem *)dest;
    unsigned int i;
    for (i = 0; i < n; ++i) {
        iowrite32(s[i], &d[i]);
    }
}

UINT8 EDDI_API OsReadRegister8(const OS_MEM_RESOURCE * memory, volatile UINT8 *p)
{
    return (UINT8)ioread8((void __iomem *)p);
}

UINT16 EDDI_API OsReadRegister16(const OS_MEM_RESOURCE * memory, volatile UINT16 *p)
{
    return (UINT16)ioread16((void __iomem *)p);
}

UINT32 EDDI_API OsReadRegister32(const OS_MEM_RESOURCE * memory, volatile UINT32 *p)
{
    return (UINT32)ioread32((void __iomem *)p);
}

void EDDI_API OsWriteRegister8(const OS_MEM_RESOURCE * memory, volatile UINT8 *p, UINT8 v)
{
    iowrite8(v, (void __iomem *)p);
}

void EDDI_API OsWriteRegister16(const OS_MEM_RESOURCE * memory, volatile UINT16 *p, UINT16 v)
{
    iowrite16(v, (void __iomem *)p);
}

void EDDI_API OsWriteRegister32(const OS_MEM_RESOURCE * memory, volatile UINT32 *p, UINT32 v)
{
    iowrite32(v, (void __iomem *)p);
}

#ifdef EURESYS_PTRSIZE_64_BITS
UINT64 EDDI_API OsReadRegister64(const OS_MEM_RESOURCE * memory, volatile UINT64 *p)
{
    return (UINT64)readq(p); /* ioread64 not available */
}

void EDDI_API OsWriteRegister64(const OS_MEM_RESOURCE * memory, volatile UINT64 *p, UINT64 v)
{
    writeq(v, p); /* iowrite64 not avaiable */
}
#endif

