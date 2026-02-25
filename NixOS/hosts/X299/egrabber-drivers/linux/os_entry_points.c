#include "mc_linux.h"
#include "../os_entry_points.h"

#if (LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 29))
#if (OS_MAX_RESOURCES < DEVICE_COUNT_RESOURCE)
     #error "Not enough resources"
#endif
#endif

MODULE_AUTHOR("Euresys");
MODULE_LICENSE("Proprietary");

int dev_number = 0;

extern const struct pci_device_id multicam_ids[];
extern char *driver_name;

static int device_open (struct inode *, struct file *);
static int device_release (struct inode *, struct file *);
static ssize_t device_read (struct file *, char *, size_t , loff_t *);
static ssize_t device_write (struct file *, const char *, size_t , loff_t *);
static long device_compat_ioctl(struct file *, unsigned int, unsigned long);
static int add_device(struct pci_dev *dev);
static unsigned int device_poll(struct file *, struct poll_table_struct *);

// Driver entry points 
struct file_operations fops = {
    read: device_read,
    write: device_write,
    unlocked_ioctl: device_compat_ioctl,
    compat_ioctl: device_compat_ioctl,
    open: device_open,
    release: device_release,
    poll: device_poll
};

static void ReleasePciRegions(struct pci_dev *dev, int max)
{
    int j;

    for (j = 0; j < max; j++) {
        if (dev->resource[j].flags & IORESOURCE_MEM) {
            pci_release_region(dev, j);
        }
    }
}

static int probe(struct pci_dev *dev, const struct pci_device_id *id) 
{
    return add_device(dev);
}

static void remove(struct pci_dev *dev) 
{
    mc_remove_device(dev);
    pci_disable_msi(dev);
    pci_disable_device(dev);
    ReleasePciRegions(dev, DEVICE_COUNT_RESOURCE);
}

#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 32))
#ifdef CONFIG_PM_SLEEP
static int suspend(struct device *dev)
{
    return mc_suspend(to_pci_dev(dev));
}

static int resume(struct device *dev)
{
    return mc_resume(to_pci_dev(dev));
}

static SIMPLE_DEV_PM_OPS(multicam_pm, suspend, resume);
#endif
#endif

#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 12))
static void shutdown(struct pci_dev *dev)
{
    mc_shutdown(dev);
}
#endif

struct pci_driver multicam_driver = {
    .id_table = multicam_ids,
    .probe = probe,
    .remove = remove,
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 12))
    .shutdown = shutdown,
#endif
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 32))
#ifdef CONFIG_PM_SLEEP
    .driver = {
        .pm = &multicam_pm,
    },
#endif
#endif
};

// linux module interface functions (called by linux kernel)
#ifndef EURESYS_OSAL_NO_MC_MODULE_INIT
static int euresys_driver_init(void)
{
    int result;
    printk(KERN_DEBUG "%s: initializing driver...\n", driver_name);
    result = mc_init_module();
    switch (result) {
        case 0:
            break;
        case -ENODEV:
            printk(KERN_ERR "%s: module_init failed (no such device)\n", driver_name);
            break;
        default:
            printk(KERN_ERR "%s: module_init failed (error %i)\n", driver_name, result);
            break;
    }
    return result;
}

static void driver_exit(void)
{
    printk(KERN_DEBUG "%s: unloading driver...\n", driver_name);
    mc_cleanup_module();
}
#endif

int device_open(struct inode *pnode, struct file *pfile)
{
    int result; 
    if (!try_module_get(THIS_MODULE)) {
        return -ENODEV;
    }
    result = mc_device_open(MAJOR(pnode->i_rdev), MINOR(pnode->i_rdev), 
                            &(pfile->private_data));
    if (result < 0) {
        module_put(THIS_MODULE);
        return result;
    }
    return result;
}

// invoked when one process removes a file descriptor to the device from its table
int device_release(struct inode *pnode, struct file *pfile)
{
    int result = mc_device_release(MAJOR(pnode->i_rdev), MINOR(pnode->i_rdev),
                                   &(pfile->private_data));
    if (result < 0) {
        return result;
    }
    module_put(THIS_MODULE);
    return result;
}

static struct inode *GetInode(struct file *pfile)
{
#if (LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 20))
    return pfile->f_dentry->d_inode;
#else
    return pfile->f_path.dentry->d_inode;
#endif
}

ssize_t device_read(struct file *pfile, char *buffer, size_t size, loff_t *f_pos)
{
    struct inode *pnode;
    pnode = GetInode(pfile);
    if (!pnode)
        return -1;

    return mc_device_read(MAJOR(pnode->i_rdev), MINOR(pnode->i_rdev), buffer,
                          size, &(pfile->private_data));
}

ssize_t device_write(struct file *pfile, const char *buffer, size_t size, loff_t *f_pos)
{
    struct inode *pnode;
    pnode = GetInode(pfile);
    if (!pnode)
        return -1;

    return mc_device_write(MAJOR(pnode->i_rdev), MINOR(pnode->i_rdev), buffer,
                           size, &(pfile->private_data));
}

long device_compat_ioctl(struct file *pfile, unsigned int cmd, unsigned long arg)
{
    struct inode *pnode;
    pnode = GetInode(pfile);
    if (!pnode)
        return -1;

    return mc_device_ioctl(MAJOR(pnode->i_rdev), MINOR(pnode->i_rdev), cmd,
                           (void *)arg,  &(pfile->private_data));
}

unsigned int device_poll(struct file *pfile, struct poll_table_struct *poll_table)
{
    unsigned int mask = 0;
    OS_NOTIFICATION_EVENT *event = mc_device_poll(&(pfile->private_data));
    if (event == NULL) {
        return (POLLIN|POLLRDNORM|POLLOUT|POLLWRNORM);
    }
    poll_wait(pfile, (wait_queue_head_t *)&event->event, poll_table);
    if (event->bNotified == TRUE)
        mask = POLLIN | POLLRDNORM;
    return mask;
}

static int add_device(struct pci_dev *dev)
{
    OS_DEVICE_INFO McDev;
    int j;
    int ret;
    int memResourceCount = 0;

    ret = pci_enable_device(dev);
    if (ret != 0) {
        printk(KERN_ERR "%s: couldn't enable device (error %i)\n", driver_name, ret);
        return ret;
    }
    pci_set_master(dev);
    pci_enable_msi(dev);

    McDev.irqAvailable = FALSE;
    McDev.ppcidev = dev;
    McDev.bus = dev->bus->number;
    McDev.slot = dev->devfn;
    McDev.DeviceID = dev->device;
    McDev.VendorID = dev->vendor;
    McDev.SubDeviceID = dev->subsystem_device;
    McDev.SubVendorID = dev->subsystem_vendor;
    McDev.irqResource.interrupt = dev->irq;
    McDev.slotID = (UINT32)-1;

    for (j = 0; j < DEVICE_COUNT_RESOURCE && j < OS_MAX_RESOURCES; j++)
    {
        if (dev->resource[j].flags & IORESOURCE_MEM) {
            ret = pci_request_region(dev, j, driver_name);
            if (ret != 0) {
                pci_disable_msi(dev);
                pci_disable_device(dev);
                ReleasePciRegions(dev, j);
                return ret;
            }
            McDev.memResources[memResourceCount].Start.QuadPart = dev->resource[j].start;
            McDev.memResources[memResourceCount].Size = dev->resource[j].end - dev->resource[j].start + 1;
            ++memResourceCount;
        }
    }
    McDev.memResourcesCount = memResourceCount;
    if (dev->irq != 0)
    {
        McDev.irqAvailable = TRUE;
    }

    ret = mc_add_device(&McDev);
    if (ret != 0) {
        printk(KERN_ERR "%s: couldn't add device (error %i)\n", driver_name, ret);
        pci_disable_msi(dev);
        pci_disable_device(dev);
        ReleasePciRegions(dev, DEVICE_COUNT_RESOURCE);
        return ret;
    }

    dev_number++;
    return ret;
}

#ifndef EURESYS_OSAL_NO_MC_MODULE_INIT
module_init(euresys_driver_init);
module_exit(driver_exit);
#endif
