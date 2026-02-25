#include "mc_linux.h"
#include "../os_debug.h"
#ifndef __KERNEL__
#include <stdio.h>
#endif
#if defined(EURESYS_UNITTEST) || (LINUX_VERSION_CODE < KERNEL_VERSION(5, 16, 0) && !defined(OSAL_EARLY_STDARG_MOVE))
#include <stdarg.h>
#else
#include <linux/stdarg.h>
#endif

extern char *driver_name;

int EDDI_API OsPrintk(const char *fmt, ...)
{
    int ret, size;
    static char pTexte[1024];
    static DEFINE_SPINLOCK(mc_printk_lock);
    unsigned long flags;
    va_list args;

    va_start(args, fmt);
    spin_lock_irqsave(&mc_printk_lock, flags);
    size = snprintf(pTexte, 1024, KERN_ERR "%s: ", driver_name);
    if (size < 0) {
        spin_unlock_irqrestore(&mc_printk_lock, flags);
        return size;
    }
    ret = vsnprintf(&pTexte[size], 1024 - size, fmt, args);
    if (ret < 0) {
        spin_unlock_irqrestore(&mc_printk_lock, flags);
        return ret;
    }
    pTexte[1023] = '\0';
    va_end(args);

    ret = printk(pTexte);
    spin_unlock_irqrestore(&mc_printk_lock, flags);

    return ret ;
}
