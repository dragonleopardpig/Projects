#include "mc_linux.h"
#include "../os_memory.h"
#include "../os_debug.h"

#if !defined(in_irq) && defined(in_hardirq)
#define in_irq in_hardirq
#endif

typedef UINT_PTR OsMallocTag;
static const OsMallocTag ALLOCATED_BY_KMALLOC = 0x6C616D6B;
static const OsMallocTag ALLOCATED_BY_VMALLOC = 0x6C616D76;

static void *MarkMemoryAs(void *memory, OsMallocTag tag)
{
    *(OsMallocTag *)memory = tag;
    return (OsMallocTag *)memory + 1;
}

void *EDDI_API OsMalloc(size_t size, enum OsPageability pageability)
{
    void *memory = NULL;

    if (in_irq()) {
        OsPrintk("OsMalloc cannot be used at hardirq level\n");
        BUG();
    }

    size += sizeof(OsMallocTag);
    if (size <= 0x20000) {
        memory = kzalloc(size,
                         in_interrupt() ? GFP_ATOMIC : GFP_KERNEL);
        if (memory != NULL) {
            return MarkMemoryAs(memory, ALLOCATED_BY_KMALLOC);
        }
    }
    if (!in_interrupt()) {
        memory = vzalloc(size);
        if (memory != NULL) {
            return MarkMemoryAs(memory, ALLOCATED_BY_VMALLOC);
        }
    }
    return NULL;
}

void EDDI_API OsFree(void *memory)
{
    OsMallocTag *tag;

    if (in_irq()) {
        OsPrintk("OsFree cannot be used at hardirq level\n");
        BUG();
    }
    if (memory != NULL) {
        tag = (OsMallocTag *)memory - 1;
        if (*tag == ALLOCATED_BY_KMALLOC) {
            kfree(tag);
        } else if (*tag == ALLOCATED_BY_VMALLOC) {
            vfree(tag);
        } else {
            OsPrintk("trying to OsFree memory not OsMalloc'd (or memory corruption occurred)\n");
            BUG();
        }
    }
}

int EDDI_API OsMallocAtomicInit(void)
{
    return 0;
}

void EDDI_API OsMallocAtomicDelete(void)
{
}

void *EDDI_API OsMallocAtomic(size_t size)
{
    if (in_irq()) {
        OsPrintk("OsMallocAtomic cannot be used at hardirq level\n");
        BUG();
    }
    return kzalloc(size, GFP_ATOMIC);
}

void EDDI_API OsFreeAtomic(void *memory)
{
    kfree(memory);
}


void *EDDI_API OsMemSet(void *memory, INT32 character, UINT32 size)
{
    return memset(memory, character, size);
}

void *EDDI_API OsMemCopy(void *destination, const void *source, UINT32 n)
{
    return memcpy(destination, source, n);
}

void *EDDI_API OsMemMove(void *destination, const void *source, UINT32 n)
{
    return memmove(destination, source, n);
}

int EDDI_API OsMemCmp(const void *p1, const void *p2, size_t size)
{
    return memcmp(p1, p2, size);
}
