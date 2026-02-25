#include "mc_linux.h"
#include "os_registration.h"
#include "os_thread_types.h"
#include "../os_timer.h"
#include "os_synchro_types.h"
#include "os_debug.h"
#include "../os_time.h"

extern struct file_operations fops;

// Register/unregister driver function: 
// the driver must be registered once to obtain a major number
// it must also be unregistered when unloaded!
INT32 EDDI_API mc_register_device(const char *name)
{
    INT32 major;

    major = register_chrdev(0, name, &fops);
    return major;
}

void EDDI_API mc_unregister_device(UINT32 major, const char *name)
{
    unregister_chrdev(major, name);
}

#define EDDI_CHECK_STRUCT_SIZE(OS,LX)                               \
    do {                                                            \
        if (sizeof(OS) < sizeof(LX)) {                              \
            OsPrintk("sizeof(" #OS ") < sizeof(" #LX ") == %zu\n",  \
                     sizeof(LX));                                   \
            EDDI_STRUCT_SIZE_STATUS = -1;                           \
        }                                                           \
    } while (0)

static int EDDI_API check_struct_sizes(void)
{
    int EDDI_STRUCT_SIZE_STATUS = 0;
    EDDI_CHECK_STRUCT_SIZE(OS_TASK, struct work_struct);
    EDDI_CHECK_STRUCT_SIZE(OS_SPINLOCK, spinlock_t);
#if (LINUX_VERSION_CODE < KERNEL_VERSION(4, 13, 0))
    EDDI_CHECK_STRUCT_SIZE(OS_EVENT, wait_queue_t);
#else
    EDDI_CHECK_STRUCT_SIZE(OS_EVENT, wait_queue_entry_t);
#endif
    EDDI_CHECK_STRUCT_SIZE(OS_SEMA, struct semaphore);
    EDDI_CHECK_STRUCT_SIZE(OS_TIMER, struct timer_list);
    return EDDI_STRUCT_SIZE_STATUS;
}

extern struct pci_driver multicam_driver;
extern char *driver_name;
extern int dev_number;

INT32 EDDI_API mc_register_driver(void) {
    int ret;

    ret = check_struct_sizes();
    if (ret < 0) {
        OsPrintk("check_struct_sizes failed\n");
        return -ENODEV;
    }
#ifdef PCI_BRIDGE_INIT_TEGRA_WORKAROUND
    OsSleep(500);
#endif

    multicam_driver.name = driver_name;
    ret = pci_register_driver(&multicam_driver);
    if (ret < 0) {
        OsPrintk("pci_register_driver failed (error %i)\n", ret);
        return ret;
    }

    OsPrintk("%i device%s detected\n", dev_number, dev_number == 1 ? "" : "s");
    if (dev_number == 0) {
        pci_unregister_driver(&multicam_driver);
        return -ENODEV;
    }
    return 0;
}

INT32 EDDI_API mc_unregister_driver(void) {
    pci_unregister_driver(&multicam_driver);

    return 0;
}
