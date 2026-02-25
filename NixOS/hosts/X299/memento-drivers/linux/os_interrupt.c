#include "mc_linux.h"
#include "../os_interrupt.h"

#if (LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 19))
static irqreturn_t mc_isr(INT32 irq, void *context, struct pt_regs * regs)
#else
static irqreturn_t mc_isr(INT32 irq, void *context)
#endif
{
    BOOLEAN handled = FALSE;
    ISR_CTX *ctx = (ISR_CTX *)context;

    OS_ISR_ROUTINE routine = ctx->Handler;

    handled = routine(irq, ctx->Context);

    return IRQ_RETVAL(handled);
}

#ifndef IRQF_SHARED
#define IRQF_SHARED SA_SHIRQ
#endif

INT32 EDDI_API OsRequestIrq(OS_INTERRUPT_REQUEST *irqRequest, ISR_CTX *context)
{
    *irqRequest->osInterrupt = irqRequest->osResources->interrupt;
    return request_irq(*irqRequest->osInterrupt, mc_isr, IRQF_SHARED, irqRequest->deviceName, context);
}

void EDDI_API OsFreeIrq(OS_INTERRUPT_REQUEST *irqRequest, ISR_CTX *context)
{
    free_irq(*irqRequest->osInterrupt, context);
}
