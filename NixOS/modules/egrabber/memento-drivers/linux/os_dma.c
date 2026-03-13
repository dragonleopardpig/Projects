#include "mc_linux.h"
#include "../os_dma.h"
#include "../os_memory.h"
#include "../os_debug.h"
#ifdef NVIDIA_RDMA
#include <nvidia/nv-p2p.h>
// CUDA 12.2: see https://docs.nvidia.com/cuda/gpudirect-rdma/index.html#changes-in-cuda-12-2
#ifdef NVIDIA_P2P_CAP_GET_PAGES_PERSISTENT_API
#define api_nvidia_get_pages(virt_start, pin_size, page_table) nvidia_p2p_get_pages_persistent((virt_start), (pin_size), (page_table), 0)
#define api_nvidia_put_pages(device_address, page_table)       nvidia_p2p_put_pages_persistent((device_address), (page_table), 0)
#else
#define api_nvidia_get_pages(virt_start, pin_size, page_table) nvidia_p2p_get_pages(0, 0, (virt_start), (pin_size), (page_table), NULL, NULL)
#define api_nvidia_put_pages(device_address, page_table)       nvidia_p2p_put_pages(0, 0, (device_address), (page_table))
#endif
#endif

#ifndef EURESYS_OSAL_UNITTEST
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,7,0)
#ifdef CONFIG_DMA_SHARED_BUFFER
#define ENABLE_DMA_BUF_SUPPORT
#endif
#endif
#endif

#ifdef ENABLE_DMA_BUF_SUPPORT
#include <linux/module.h>
#include <linux/dma-buf.h>
#include <linux/dma-resv.h>
#endif
extern char *driver_name;

#define PAGE_OFFSET_MASK (PAGE_SIZE - 1)

// Workaround for specific kernels having Secure Encrypted Virtualization support
// without the patch 9d5f38ba6c82359b7cec31fb27fb78ecc02f3946
// https://git.kernel.org/pub/scm/linux/kernel/git/tip/tip.git/commit/?id=9d5f38ba6c82359b7cec31fb27fb78ecc02f3946

#if (defined(OSAL_ENABLE_NO_SME_ACTIVE_WORKAROUND)  &&  \
     !defined(CONFIG_ARCH_HAS_DMA_SET_COHERENT_MASK))
#define OSAL_WITHOUT_SME_ACTIVE
#endif

#ifdef OSAL_WITHOUT_SME_ACTIVE
static inline int os_dma_set_coherent_mask(struct device *dev, u64 mask)
{
    if (!dma_supported(dev, mask)) {
        return -EIO;
    }
    dev->coherent_dma_mask = mask;
    return 0;
}
static inline int os_pci_set_consistent_dma_mask(struct pci_dev *dev, u64 mask)
{
    return os_dma_set_coherent_mask(&dev->dev, mask);
}
#else
#define os_pci_set_consistent_dma_mask pci_set_consistent_dma_mask
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,18,0)
#define pci_set_dma_mask(HWDEV, MASK)                       dma_set_mask(&(HWDEV)->dev, MASK)
#define pci_set_consistent_dma_mask(HWDEV, MASK)            dma_set_coherent_mask(&(HWDEV)->dev, MASK)
#define pci_alloc_consistent(HWDEV, SIZE, HANDLE)           dma_alloc_coherent(&(HWDEV)->dev, SIZE, HANDLE, GFP_ATOMIC)
#define pci_free_consistent(HWDEV, SIZE, VADDR, HANDLE)     dma_free_coherent(&(HWDEV)->dev, SIZE, VADDR, HANDLE)
#define pci_map_sg(HWDEV, SG, NENTS, DIRECTION)             dma_map_sg(&(HWDEV)->dev, SG, NENTS, DIRECTION)
#define pci_unmap_sg(HWDEV, SG, NENTS, DIRECTION)           dma_unmap_sg(&(HWDEV)->dev, SG, NENTS, DIRECTION)
#endif

#ifndef EURESYS_OSAL_UNITTEST
PDMA_OBJECT EDDI_API OsCreateDmaObject(PDEVICE physicalDeviceObject,
                                        BOOLEAN dma64bit, UINT32 maxLength,
                                        unsigned int *numberOfMapRegisters)
{
    struct pci_dev *pciDevice = (struct pci_dev *)physicalDeviceObject;

    // DMA addresses are 32-bit by default
    if (dma64bit) {
        if (!pci_set_dma_mask(pciDevice, DMA_BIT_MASK(64))) {
            int err = os_pci_set_consistent_dma_mask(pciDevice, DMA_BIT_MASK(32));
            if (err) {
                OsPrintk("pci_set_consistent_dma_mask(pciDevice, DMA_BIT_MASK(32)) failed (error %i)\n", err);
                if (!pci_set_dma_mask(pciDevice, DMA_BIT_MASK(32))) {
                    OsPrintk("64-bit DMA disabled!\n");
                } else {
                    OsPrintk("no suitable 32-bit DMA available\n");
                    return NULL;
                }
            }
        } else if (!pci_set_dma_mask(pciDevice, DMA_BIT_MASK(32))) {
            OsPrintk("64-bit DMA not available\n");
        } else {
            OsPrintk("no suitable DMA available\n");
            return NULL;
        }
    }
    return (PDMA_OBJECT)pciDevice;
}

void EDDI_API OsDeleteDmaObject(PDMA_OBJECT dmaAdapter)
{
}

BOOLEAN EDDI_API OsAllocateCommonBuffer(OS_COMMON_BUFFER *cbuf,
                                        UINT32 size, PDMA_OBJECT dmaAdapter)
{
    struct pci_dev *pciDevice = (struct pci_dev *)dmaAdapter;
    dma_addr_t dmaAddress;

#ifdef PCI_ALLOC_CONSISTENT_TEGRA_WORKAROUND
    cbuf->va = dma_alloc_coherent(&pciDevice->dev, size, &dmaAddress, GFP_ATOMIC | __GFP_DIRECT_RECLAIM);
#else
    cbuf->va = pci_alloc_consistent(pciDevice, size, &dmaAddress);
#endif
    cbuf->pa.QuadPart = dmaAddress;
    cbuf->size = size;
    cbuf->dmaAdapter = dmaAdapter;

    return cbuf->va ? TRUE : FALSE;
}

void EDDI_API OsFreeCommonBuffer(OS_COMMON_BUFFER *cbuf)
{
    struct pci_dev *pciDevice = (struct pci_dev *)cbuf->dmaAdapter;
    if (cbuf->va) {
        pci_free_consistent(pciDevice, cbuf->size, cbuf->va,
            (dma_addr_t)(cbuf->pa.QuadPart));
    }
}
#endif

static UINT32 GetPageCount(void *address, UINT32 buffer_size)
{
    unsigned long page_offset = ((uintptr_t)address) & PAGE_OFFSET_MASK;
    UINT32 page_count = buffer_size / PAGE_SIZE;
    UINT32 remainder = buffer_size % PAGE_SIZE;
    if (page_offset == 0) { // The buffer is aligned on a page boundary
        return remainder ? page_count + 1 : page_count;
    } else {
        return ((page_offset + remainder) > PAGE_SIZE) ? page_count + 2 : page_count + 1;
    }
}

MEMORY_DESCRIPTION * EDDI_API OsCreateMemoryDescription(void *buffer, unsigned int length, unsigned int offset, int type)
{
    MEMORY_DESCRIPTION *memory;
    size_t size;
#ifdef NVIDIA_RDMA
    if (type == MEMORY_DESCRIPTION_TYPE_NVIDIA_RDMA) {
        if (offset) {
            OsPrintk("OsCreateMemoryDescription failed (invalid offset)\n");
            return 0;
        }
        memory = (MEMORY_DESCRIPTION *)kzalloc(sizeof(MEMORY_DESCRIPTION), GFP_KERNEL);
        if (memory == NULL) {
            return NULL;
        }
        memory->type = type;
        memory->deviceAddress = buffer;
        memory->length = length;
        memory->offset = 0;
        memory->page_table = 0;
        memory->sglist.type = type;
        memory->sglist.numberOfElements = 0;
        memory->sglist.elements_1 = 0;
        memory->sglist.page_table = 0;
        memory->sglist.dma_mapping = 0;
        return memory;
    }
#endif

#ifdef ENABLE_DMA_BUF_SUPPORT
    if (type == MEMORY_DESCRIPTION_TYPE_DMA_BUF) {
        memory = (MEMORY_DESCRIPTION *)kmalloc(sizeof(MEMORY_DESCRIPTION), GFP_KERNEL);
        if (memory == NULL) {
            return NULL;
        }
        memory->type = type;
        memory->dmabuf_fd = (long long int)buffer;
        memory->length = length;
        memory->offset = offset;
        memory->sgl.type = type;
        memory->sgl.numberOfElements = 0;
        memory->sgl.elements_2 = 0;
        memory->sgl.dmabuf = 0;
        memory->sgl.dmabuf_attachment = 0;
        memory->sgl.dmabuf_sg_table = 0;
        memory->sgl.skip_ents = 0;
        memory->sgl.patch_offset = 0;
        return memory;
    }
#endif

    if (offset) {
        OsPrintk("OsCreateMemoryDescription failed (invalid offset)\n");
        return 0;
    }
    if (type) {
        OsPrintk("OsCreateMemoryDescription failed (invalid type)\n");
        return 0;
    }

    size = GetPageCount(buffer, length) * sizeof(void *);
    memory = (MEMORY_DESCRIPTION *)kzalloc(sizeof(MEMORY_DESCRIPTION), GFP_KERNEL);
    if (memory == NULL) {
        return NULL;
    }
    memory->type = type;
    memory->virtualAddress = buffer;
    memory->length = length;
    memory->offset = (unsigned long)buffer & PAGE_OFFSET_MASK;
    memory->pageCount = 0;
    memory->pages = (struct page **)OsMalloc(size, OS_NOT_PAGEABLE);
    if (memory->pages == NULL) {
        kfree(memory);
        return NULL;
    }
    memory->next = NULL;
    return memory;
}

void EDDI_API OsFreeMemoryDescription(MEMORY_DESCRIPTION *memory)
{
    if (memory->type == 0) {
        OsFree(memory->pages);
    }
    kfree(memory);
}

#if   (LINUX_VERSION_CODE >= KERNEL_VERSION(6,5,0)) || defined(OSAL_GET_USER_PAGES_REMOTE_NO_VMAS)
#define GetUserPages(TSK, MM, START, NR_PAGES, PAGES)   get_user_pages_remote(     MM, START, NR_PAGES, FOLL_WRITE, PAGES,       NULL)
#elif (LINUX_VERSION_CODE >= KERNEL_VERSION(5,9,0))
#define GetUserPages(TSK, MM, START, NR_PAGES, PAGES)   get_user_pages_remote(     MM, START, NR_PAGES, FOLL_WRITE, PAGES, NULL, NULL)
#elif (LINUX_VERSION_CODE >= KERNEL_VERSION(4,10,0))
#define GetUserPages(TSK, MM, START, NR_PAGES, PAGES)   get_user_pages_remote(TSK, MM, START, NR_PAGES, FOLL_WRITE, PAGES, NULL, NULL)
#elif (LINUX_VERSION_CODE >= KERNEL_VERSION(4,9,0))
#define GetUserPages(TSK, MM, START, NR_PAGES, PAGES)   get_user_pages_remote(TSK, MM, START, NR_PAGES, FOLL_WRITE, PAGES, NULL)
#elif (LINUX_VERSION_CODE >= KERNEL_VERSION(4,6,0))
#define GetUserPages(TSK, MM, START, NR_PAGES, PAGES)   get_user_pages_remote(TSK, MM, START, NR_PAGES, 1, 0, PAGES, NULL)
#else
#if ((LINUX_VERSION_CODE >= KERNEL_VERSION(4,4,168) && LINUX_VERSION_CODE < KERNEL_VERSION(4,5,0)))
#define GetUserPages(TSK, MM, START, NR_PAGES, PAGES)   get_user_pages(TSK, MM, START, NR_PAGES, FOLL_WRITE, PAGES, NULL)
#else
#define GetUserPages(TSK, MM, START, NR_PAGES, PAGES)   get_user_pages(TSK, MM, START, NR_PAGES, 1, 0, PAGES, NULL)
#endif
#endif

#if (LINUX_VERSION_CODE >= KERNEL_VERSION(4,6,0))
#define PutPage(page)   put_page(page)
#else
#define PutPage(page)   page_cache_release(page)
#endif

#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5,8,0))
#define mmap_sem mmap_lock
#endif

#define GPU_BOUND_SHIFT   16
#define GPU_BOUND_SIZE    ((u64)1 << GPU_BOUND_SHIFT)
#define GPU_BOUND_OFFSET  (GPU_BOUND_SIZE-1)
#define GPU_BOUND_MASK    (~GPU_BOUND_OFFSET)

BOOLEAN EDDI_API OsGetUserPages(MEMORY_DESCRIPTION *memory)
{
    int pageCount;
    int requestedPageCount;

#ifdef NVIDIA_RDMA
    if (memory->type == MEMORY_DESCRIPTION_TYPE_NVIDIA_RDMA) {
        // do proper alignment, as required by NVIDIA kernel driver
        u64 virt_start = ((uint64_t)memory->deviceAddress) & GPU_BOUND_MASK;
        size_t pin_size = (((uint64_t)memory->deviceAddress) + memory->length - virt_start + GPU_BOUND_SIZE - 1) & GPU_BOUND_MASK;
        int ret = api_nvidia_get_pages(virt_start, pin_size, &memory->page_table);
        if (ret == 0) {
            memory->offset = (uint64_t)memory->deviceAddress & GPU_BOUND_OFFSET;
            //printk(KERN_INFO "%s: OsGetUserPages() : offset (%u)\n", driver_name, memory->offset);
            return TRUE;
        } else {
            printk(KERN_ERR "%s: OsGetUserPages() : api_nvidia_get_pages failed (error %d)\n", driver_name, ret);
            return FALSE;
        }
    }
#endif

    if (memory->type == MEMORY_DESCRIPTION_TYPE_DMA_BUF) {
        return TRUE;
    }

    requestedPageCount = GetPageCount(memory->virtualAddress, memory->length);
    down_read(&current->mm->mmap_sem);
    pageCount = GetUserPages(current, current->mm,
                             (unsigned long)memory->virtualAddress,
                             requestedPageCount, memory->pages);
    up_read(&current->mm->mmap_sem);
    if (pageCount < requestedPageCount) {
        int i;
        for (i = 0; i < pageCount; i++) {
            PutPage(memory->pages[i]);
        }
        return FALSE;
    }
    memory->pageCount = pageCount;
    return TRUE;
}

void EDDI_API OsPutUserPages(MEMORY_DESCRIPTION *memory)
{
    unsigned int i;
#ifdef NVIDIA_RDMA
    if (memory->type == MEMORY_DESCRIPTION_TYPE_NVIDIA_RDMA) {
        api_nvidia_put_pages((uint64_t)(memory->deviceAddress), memory->page_table);
        return;
    }
#endif

    if (memory->type == MEMORY_DESCRIPTION_TYPE_DMA_BUF) {
        return;
    }

    for (i = 0; i < memory->pageCount; i++) {
        SetPageDirty(memory->pages[i]);
        PutPage(memory->pages[i]);
    }
}

void EDDI_API OsChainMemoryDescription(MEMORY_DESCRIPTION **memoryList, unsigned int size)
{
    unsigned int i;

    for (i = 0; i < size - 1; i++) {
        MEMORY_DESCRIPTION *memory = memoryList[i];
        while (memory->type == 0 && memory->next) {
            memory = memory->next;
        }
        if (memory->type == 0) {
            memory->next = memoryList[i + 1];
        }
    }
}

unsigned int GetTotalPageCount(MEMORY_DESCRIPTION *memory);
unsigned int GetTotalPageCount(MEMORY_DESCRIPTION *memory)
{
    unsigned int totalPageCount = 0;
#ifdef NVIDIA_RDMA
    if (memory->type == MEMORY_DESCRIPTION_TYPE_NVIDIA_RDMA) {
        return (memory->page_table) ? memory->page_table->entries : 0;
    }
#endif

#ifdef ENABLE_DMA_BUF_SUPPORT
    if (memory->type == MEMORY_DESCRIPTION_TYPE_DMA_BUF) {
        printk(KERN_ERR "%s: GetTotalPageCount() : invalid for memory type %d\n", driver_name, MEMORY_DESCRIPTION_TYPE_DMA_BUF);
        return 0;
    }
#endif

    while (memory != NULL) {
        totalPageCount += memory->pageCount;
        memory = memory->next;
    }
    return totalPageCount;
}

#if (LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 24))
static void sg_set_page(struct scatterlist *sg, struct page *page, unsigned int length, unsigned int offset)
{
    sg->page = page;
    sg->offset = offset;
    sg->length = length;
}

static void sg_init_table(struct scatterlist *sg, unsigned int nents)
{
    memset(sg, 0, sizeof(*sg) * nents);
}

static struct scatterlist *sg_next(struct scatterlist *sg)
{
    return ++sg;
}
#endif

static void PopulateSglist(MEMORY_DESCRIPTION *memory, struct scatterlist *sglist)
{
    int i;
    int remainingLength;
    struct scatterlist *sgElement = sglist;

    while (memory != NULL) {
        remainingLength = memory->length;
        if (memory->pageCount > 1) {
            sg_set_page(sgElement, memory->pages[0], PAGE_SIZE - memory->offset, memory->offset);
            remainingLength -= sgElement->length;
            sgElement = sg_next(sgElement);
            for (i = 1; i < memory->pageCount; i++) {
                unsigned int length = PAGE_SIZE < remainingLength ? PAGE_SIZE : remainingLength;
                sg_set_page(sgElement, memory->pages[i], length, 0);
                remainingLength -= length;
                sgElement = sg_next(sgElement);
            }
        } else {
            sg_set_page(sgElement, memory->pages[0], memory->length, memory->offset);
            sgElement = sg_next(sgElement);
        }
        memory = memory->next;
    }
}

#ifdef ENABLE_DMA_BUF_SUPPORT
static void cleanup_dma_buf_sgl(SG_LIST *sgl) {
    if (sgl->dmabuf_sg_table) {
        if (sgl->patch_offset && sgl->skip_ents < sgl->dmabuf_sg_table->nents) {
            struct scatterlist *patchsgl = sgl->dmabuf_sg_table->sgl;
            unsigned int skip_ents = 0;
            while (patchsgl && skip_ents < sgl->skip_ents) {
                patchsgl = sg_next(patchsgl);
                ++skip_ents;
            }
            if (patchsgl) {
                patchsgl->offset -= sgl->patch_offset;
                patchsgl->length += sgl->patch_offset;
                patchsgl->dma_address -= sgl->patch_offset;
#ifdef CONFIG_NEED_SG_DMA_LENGTH
                patchsgl->dma_length += sgl->patch_offset;
#endif
            }
        }
        sgl->dmabuf_attachment->dmabuf->ops->unmap_dma_buf(sgl->dmabuf_attachment, sgl->dmabuf_sg_table, DMA_FROM_DEVICE);
        sgl->dmabuf_sg_table = 0;
    }
    if (sgl->dmabuf_attachment) {
        dma_resv_lock(sgl->dmabuf->resv, NULL);
        list_del(&sgl->dmabuf_attachment->node);
        dma_resv_unlock(sgl->dmabuf->resv);
        if (sgl->dmabuf->ops->detach) {
            sgl->dmabuf->ops->detach(sgl->dmabuf, sgl->dmabuf_attachment);
        }
        kfree(sgl->dmabuf_attachment);
        sgl->dmabuf_attachment = 0;
    }
    if (sgl->dmabuf) {
        fput(sgl->dmabuf->file);
        sgl->dmabuf = 0;
    }
    sgl->numberOfElements = 0;
    sgl->elements_2 = 0;
    return;
}

static int setup_dma_buf_sgl(int fd, SG_LIST *sgl, PDMA_OBJECT adapter, size_t min_size) {
    struct dma_buf *dmabuf;
    struct dma_buf_attachment *attachment;
    struct sg_table *sg_table;
    struct file *file = fget(fd);
    int valid_dmabuf = 0;
    dmabuf = (struct dma_buf *)((file) ? file->private_data : 0);
    do {
        if (!dmabuf) {
            printk(KERN_ERR "%s: OsGetUserPages() : invalid file descriptor for memory type %d\n", driver_name, MEMORY_DESCRIPTION_TYPE_DMA_BUF);
            break;
        } else if (dmabuf->size < min_size) {
            printk(KERN_ERR "%s: OsGetUserPages() : invalid dmabuf size %zd (expected at least %zd)\n", driver_name, dmabuf->size, min_size);
            break;
        } else if (dmabuf->file != file) {
            printk(KERN_ERR "%s: OsGetUserPages() : invalid dmabuf file %p (expected %p)\n", driver_name, dmabuf->file, file);
            break;
        } else if (!dmabuf->ops) {
            printk(KERN_ERR "%s: OsGetUserPages() : invalid dmabuf ops\n", driver_name);
            break;
        } else if (dmabuf->ops->pin) {
            printk(KERN_ERR "%s: OsGetUserPages() : unexpected pin operation\n", driver_name);
            break;
        }
        valid_dmabuf = 1;
    } while (0);
    if (!valid_dmabuf) {
        fput(file);
        return -1;
    }
    sgl->dmabuf = dmabuf;
    attachment = kzalloc(sizeof(*attachment), GFP_KERNEL);
    if (!attachment) {
        printk(KERN_ERR "%s: OsGetUserPages() : could not allocate attachment\n", driver_name);
        return -1;
    }
    attachment->dmabuf = sgl->dmabuf;
    attachment->dev = &adapter->dev;
    if (sgl->dmabuf->ops->attach) {
        if (sgl->dmabuf->ops->attach(sgl->dmabuf, attachment)) {
            printk(KERN_ERR "%s: OsGetUserPages() : could not attach buffer\n", driver_name);
            kfree(attachment);
            return -1;
        }
    }
    dma_resv_lock(sgl->dmabuf->resv, NULL);
    list_add(&attachment->node, &sgl->dmabuf->attachments);
    dma_resv_unlock(sgl->dmabuf->resv);
    sgl->dmabuf_attachment = attachment;
    sgl->type = MEMORY_DESCRIPTION_TYPE_DMA_BUF;
    sg_table = attachment->dmabuf->ops->map_dma_buf(attachment, DMA_FROM_DEVICE);
    if (IS_ERR_OR_NULL(sg_table)) {
        printk(KERN_ERR "%s: OsGetUserPages() : could not map buffer\n", driver_name);
        return -1;
    }
    sgl->dmabuf_sg_table = sg_table;
    return 0;
}
#endif

int EDDI_API OsGetScatterGatherList(MEMORY_DESCRIPTION *memory,
                                  PDEVICE device, PDMA_OBJECT adapter,
                                  struct ScatterGatherCallbackContext *context)
{
    int result;
    SG_LIST *scatterGatherList;
    struct scatterlist *sglist;
    unsigned int totalPageCount;

#ifdef NVIDIA_RDMA
    if (memory->type == MEMORY_DESCRIPTION_TYPE_NVIDIA_RDMA) {
        struct nvidia_p2p_dma_mapping *dma_mapping;
        result = nvidia_p2p_dma_map_pages((struct pci_dev *)adapter, memory->page_table, &dma_mapping);
        if (result < 0) {
            printk(KERN_ERR "%s: OsGetScatterGatherList() : nvidia_p2p_dma_map_pages failed (error %d)\n", driver_name, result);
            return GET_SG_FAILURE;
        }
        memory->sglist.type = memory->type;
        memory->sglist.elements_1 = (SG_ELEMENT_1*)OsMalloc(sizeof(SG_ELEMENT_1) * dma_mapping->entries, OS_PAGEABLE);
        //printk(KERN_INFO "%s: OsGetScatterGatherList() : %d entries\n", driver_name, dma_mapping->entries);
        if (memory->sglist.elements_1 == NULL) {
            printk(KERN_ERR "%s: memory allocation for %d entries failed\n", driver_name, dma_mapping->entries);
            nvidia_p2p_dma_unmap_pages((struct pci_dev *)adapter, memory->page_table, dma_mapping);
            return GET_SG_FAILURE;
        }
        {
            unsigned int nvidia_page_size = 0;
            switch (dma_mapping->page_size_type) {
                case NVIDIA_P2P_PAGE_SIZE_4KB: nvidia_page_size = 4*1024; break;
                case NVIDIA_P2P_PAGE_SIZE_64KB : nvidia_page_size = 64*1024; break;
                case NVIDIA_P2P_PAGE_SIZE_128KB : nvidia_page_size = 128*1024; break;
                default: break;
            }
            if (memory->offset > nvidia_page_size || nvidia_page_size == 0) {
                if (nvidia_page_size == 0) {
                    printk(KERN_ERR "%s: OsGetScatterGatherList() : nvidia_page_size is 0\n", driver_name);
                } else {
                    printk(KERN_ERR "%s: OsGetScatterGatherList() : offset (%u) > nvidia_page_size (%u)\n", driver_name, memory->offset, nvidia_page_size);
                }
                nvidia_p2p_dma_unmap_pages((struct pci_dev *)adapter, memory->page_table, dma_mapping);
                OsFree(memory->sglist.elements_1);
                memory->sglist.elements_1 = NULL;
                return GET_SG_FAILURE;
            } else {
                size_t i;
                unsigned int length = memory->length;
                for (i = 0; i < dma_mapping->entries; ++i) {
                    unsigned int offset = (i == 0) ? memory->offset : 0;
                    unsigned int size = nvidia_page_size - offset;
                    memory->sglist.elements_1[i].pa.QuadPart = dma_mapping->dma_addresses[i] + offset;
                    memory->sglist.elements_1[i].length = (length >= size) ? size : length;
                    //printk(KERN_INFO "%s: OsGetScatterGatherList() : element[%zd] addr: %llx len: %llu\n", driver_name, i, memory->sglist.elements_1[i].pa.QuadPart, memory->sglist.elements_1[i].length);
                    length -= size;
                }
            }
        }
        memory->sglist.page_table = memory->page_table;
        memory->sglist.dma_mapping = dma_mapping;
        memory->sglist.numberOfElements = dma_mapping->entries;
        context->callback(&memory->sglist, context->context);
        return GET_SG_SUCCESS;
    }
#endif

#ifdef ENABLE_DMA_BUF_SUPPORT
    if (memory->type == MEMORY_DESCRIPTION_TYPE_DMA_BUF) {
        size_t min_size = (memory->length + memory->offset + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
        size_t offset = 0;
        unsigned int skip_ents = 0;
        struct scatterlist *sl = 0;
        if (setup_dma_buf_sgl(memory->dmabuf_fd, &memory->sgl, adapter, min_size)) {
            cleanup_dma_buf_sgl(&memory->sgl);
            return GET_SG_FAILURE;
        }
        for (sl = memory->sgl.dmabuf_sg_table->sgl; skip_ents < memory->sgl.dmabuf_sg_table->nents && sl; ++skip_ents, sl = sg_next(sl)) {
            if (offset + sl->length > memory->offset) {
                memory->offset -= offset;
                break;
            }
            offset += sl->length;
        }
        memory->sgl.skip_ents = skip_ents;
        memory->sgl.elements_2 = sl;
        if (memory->offset && memory->sgl.elements_2 && memory->offset < memory->sgl.elements_2->length) {
            //printk(KERN_INFO "%s: OsGetUserPages() : patching %p (skip=%d)\n", driver_name, memory->sgl.elements_2, skip_ents);
            memory->sgl.patch_offset = memory->offset;
            memory->sgl.elements_2->offset += memory->offset;
            memory->sgl.elements_2->length -= memory->offset;
            memory->sgl.elements_2->dma_address += memory->offset;
#ifdef CONFIG_NEED_SG_DMA_LENGTH
            memory->sgl.elements_2->dma_length -= memory->offset;
#endif
        } else if (memory->offset) {
            printk(KERN_ERR "%s: OsGetUserPages() : could not adjust offset %d for first sg(offset=%u, length=%u)\n", driver_name, memory->offset, memory->sgl.elements_2->offset, memory->sgl.elements_2->length);
            cleanup_dma_buf_sgl(&memory->sgl);
            return GET_SG_FAILURE;
        }
        context->callback(&memory->sgl, context->context);
        return GET_SG_SUCCESS;
    }
#endif

    totalPageCount = GetTotalPageCount(memory);
    scatterGatherList = (SG_LIST *)OsMalloc(sizeof(SG_LIST), OS_PAGEABLE);
    sglist = (struct scatterlist *)OsMalloc(sizeof(struct scatterlist) * totalPageCount, OS_PAGEABLE);
    if (scatterGatherList == NULL || sglist == NULL) {
        OsFree(sglist);
        OsFree(scatterGatherList);
        return GET_SG_INSUFFICIENT_RESOURCES;
    }
    sg_init_table(sglist, totalPageCount);
    scatterGatherList->type = memory->type;
    scatterGatherList->totalPageCount = totalPageCount;

    PopulateSglist(memory, sglist);
    result = pci_map_sg((struct pci_dev *)adapter, sglist, totalPageCount,
                        DMA_FROM_DEVICE);
    if (result <= 0) {
        OsFree(sglist);
        OsFree(scatterGatherList);
        return GET_SG_FAILURE;
    }
    scatterGatherList->numberOfElements = result;
    scatterGatherList->elements = sglist;
    context->callback(scatterGatherList, context->context);
    return GET_SG_SUCCESS;
}

void EDDI_API OsPutScatterGatherList(SG_LIST **scatterGatherList, PDMA_OBJECT adapter)
{
#ifdef NVIDIA_RDMA
    if ((*scatterGatherList)->type == MEMORY_DESCRIPTION_TYPE_NVIDIA_RDMA) {
        nvidia_p2p_dma_unmap_pages((struct pci_dev *)adapter, (*scatterGatherList)->page_table, (*scatterGatherList)->dma_mapping);
        OsFree((*scatterGatherList)->elements_1);
        (*scatterGatherList)->elements_1 = NULL;
        (*scatterGatherList)->numberOfElements = 0;
        return;
    }
#endif

#ifdef ENABLE_DMA_BUF_SUPPORT
    if ((*scatterGatherList)->type == MEMORY_DESCRIPTION_TYPE_DMA_BUF) {
        SG_LIST *sgl = *scatterGatherList;
        cleanup_dma_buf_sgl(sgl);
        return;
    }
#endif

    pci_unmap_sg((struct pci_dev *)adapter, (*scatterGatherList)->elements,
                 (*scatterGatherList)->totalPageCount, DMA_FROM_DEVICE);
    OsFree((*scatterGatherList)->elements);
    OsFree(*scatterGatherList);
    *scatterGatherList = NULL;
}

unsigned int EDDI_API OsGetSgLength(SG_ELEMENT *sgElement, int type)
{
    if (sgElement == NULL) {
        return 0;
    }
#ifdef NVIDIA_RDMA
    if (type == MEMORY_DESCRIPTION_TYPE_NVIDIA_RDMA) {
        return (unsigned int)(((SG_ELEMENT_1 *)sgElement)->length);
    }
#endif
    return sg_dma_len(sgElement);
}

void EDDI_API OsGetSgPhysicalAddress(SG_ELEMENT *sgElement, PHYSICAL_ADDR *address, int type)
{
    if (sgElement == NULL) {
        address->QuadPart = 0;
    } else {
#ifdef NVIDIA_RDMA
        if (type == MEMORY_DESCRIPTION_TYPE_NVIDIA_RDMA) {
            *address = ((SG_ELEMENT_1 *)sgElement)->pa;
            return;
        }
#endif
        address->QuadPart = sg_dma_address(sgElement);
    }
}

SG_ELEMENT *EDDI_API OsGetFirstSgElement(SG_LIST *sgList)
{
    if (sgList->type == MEMORY_DESCRIPTION_TYPE_NVIDIA_RDMA) {
        return (SG_ELEMENT *)sgList->elements_1;
    }
    return sgList->elements;
}

SG_ELEMENT *EDDI_API OsGetNextSgElement(SG_ELEMENT *sgElement, int type)
{
#ifdef NVIDIA_RDMA
    if (type == MEMORY_DESCRIPTION_TYPE_NVIDIA_RDMA) {
        return (SG_ELEMENT *)((SG_ELEMENT_1 *)sgElement + 1);
    }
#endif
    return sg_next(sgElement);
}

size_t EDDI_API OsGetSgElementCount(SG_LIST *sgList) {
    size_t count;
    SG_ELEMENT *sgElement;
#ifdef NVIDIA_RDMA
    if (sgList->type == MEMORY_DESCRIPTION_TYPE_NVIDIA_RDMA) {
        return sgList->numberOfElements;
    }
#endif
    // the documentation for pci_map_sg only states that "dma_maps_sg_attrs
    // returns 0 on error and > 0 on success"
    for (count = 0, sgElement = OsGetFirstSgElement(sgList);
         sgElement;
         ++count, sgElement = OsGetNextSgElement(sgElement, 0)) {
    }
    return count;
}

int EDDI_API OsIsMemoryTypeSupported(int type) {
    switch (type) {
        case MEMORY_DESCRIPTION_TYPE_DEFAULT:
            return 1;
#ifdef NVIDIA_RDMA
        case MEMORY_DESCRIPTION_TYPE_NVIDIA_RDMA:
            return 1;
#endif
#ifdef ENABLE_DMA_BUF_SUPPORT
        case MEMORY_DESCRIPTION_TYPE_DMA_BUF:
            return 1;
#endif
        default:
            return 0;
    }
}
