#include "mc_linux.h"
#include "../os_entry_points.h"
#include "../os_debug.h"
#include "../os_user_memory.h"

#include <linux/mm.h>

#define memento_backing memento_backing_1
#define memento_mmap_size memento_mmap_size_1

void *memento_backing=0;
UINT64 memento_mmap_size;

EXPORT_SYMBOL(memento_backing_1);
EXPORT_SYMBOL(memento_mmap_size_1);
static int ringsize=-1;
module_param(ringsize, int, S_IRUSR|S_IRGRP|S_IROTH);
MODULE_PARM_DESC(ringsize,"Ring size in KiB. 0 to skip ring allocation.");
MODULE_AUTHOR("Euresys");
MODULE_DESCRIPTION("Memento driver");
MODULE_LICENSE("Proprietary");

#ifdef CONFIG_MMU
static int device_mmap(struct file *filp, struct vm_area_struct *vma);
void* EDDI_API mc_device_memory(UINT64 vm_pgoff, UINT64 size, void **private_data);
int EDDI_API mc_initmodule(int alloc);
#endif

extern struct file_operations fops;

// linux module interface functions (called by linux kernel)
static int euresys_memento_init(void)
{
    int status;
#ifdef CONFIG_MMU
    fops.mmap = device_mmap;
#endif

    if (ringsize < 0) {
        int EDDI_API mc_getMementoConfigDefaultRingSizeKB(void);
        ringsize = mc_getMementoConfigDefaultRingSizeKB();
    }
    memento_mmap_size = ringsize * 1024;
    if (memento_mmap_size & (PAGE_SIZE-1)) {
        memento_mmap_size+=PAGE_SIZE;
    }
    memento_mmap_size &= PAGE_MASK;
    ringsize = memento_mmap_size / 1024;

    memento_backing = vzalloc(memento_mmap_size);
    if (memento_backing == NULL) 
        return -ENOMEM;

    status = mc_init_module();
    if (status < 0) {
        vfree(memento_backing);
    }
    return status;
}

static void memento_exit(void)
{
    void* freeme = memento_backing;
    memento_backing = 0;
    mc_cleanup_module();
    vfree(freeme);
}

#ifdef CONFIG_MMU
/** Make user-space segment [vma->vm_start .. vma->vm_end[ map to device's
 *    [vm_pgoff*PAGESIZE .. vm_pgoff*PAGESIZE + size[ if that fits within
 *    device's memory range.
 */
int device_mmap(struct file *filp, struct vm_area_struct *vma)
{
    size_t size = vma->vm_end - vma->vm_start;
    void * vaddr;
    unsigned long uaddr = vma->vm_start;
    if (!OsUserCanWrite((void *)uaddr, size))
        return -EINVAL;
    
    if ((vaddr = mc_device_memory(vma->vm_pgoff << PAGE_SHIFT, size, &filp->private_data))) {
        unsigned int i, retcode = -EINVAL;
        void* kaddr = vaddr;
        for (i=0;i<(size>>PAGE_SHIFT);i++) {
            struct page *pg = vmalloc_to_page(kaddr);
            if (( retcode = vm_insert_page(vma, uaddr, pg) )) {
                printk(KERN_ERR "memento: unable to remap %lx <- [%i] %lx (%p) (error %i)\n",
                       uaddr, i, (unsigned long)(page_to_pfn(pg)), kaddr, retcode);
                return retcode;
            }
            uaddr+=PAGE_SIZE;
            kaddr+=PAGE_SIZE;
        }
        return retcode;
    } else {
        printk(KERN_ERR "memento: denied to remap %lx..%lx from %lx\n",vma->vm_start, vma->vm_end, vma->vm_pgoff);
        return -ENODEV;
    }
}
#endif

#ifndef EURESYS_OSAL_NO_MEMENTO_MODULE_INIT

module_init(euresys_memento_init);
module_exit(memento_exit);

#endif
