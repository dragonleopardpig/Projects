#ifndef OS_LINUX_HEADER_FILE
#define OS_LINUX_HEADER_FILE

#ifdef EURESYS_OSAL_UNITTEST
#define EURESYS_OSAL_NO_MC_MODULE_INIT
#define EURESYS_OSAL_NO_MEMENTO_MODULE_INIT
#include "UnitTests/linuxFakes.h"
#include <sys/time.h>
#else

#include <linux/version.h>
#if (LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 15))
#include <linux/config.h>
#elif (LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 33))
#include <linux/autoconf.h>
#else
#include <generated/autoconf.h>
#endif

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/fs.h>
#include <linux/pci.h>
#include <linux/firmware.h>
#include <linux/delay.h>
#include <linux/types.h>
#include <linux/sched.h>
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0))
#include <linux/sched/signal.h>
#endif
#include <linux/interrupt.h>
#include <linux/spinlock.h>
#include <linux/timex.h>
#include <linux/timer.h>
#include <linux/poll.h>
#include <linux/vmalloc.h>

#include <linux/pagemap.h>
#include <linux/swap.h>

#include <linux/errno.h>

#include <asm/current.h>
#if (LINUX_VERSION_CODE < KERNEL_VERSION(4, 12, 0))
#include <asm/uaccess.h>
#else
#include <linux/uaccess.h>
#endif
#if (LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 26))
#include <asm/semaphore.h>
#else
#include <linux/semaphore.h>
#endif
#endif

#endif
