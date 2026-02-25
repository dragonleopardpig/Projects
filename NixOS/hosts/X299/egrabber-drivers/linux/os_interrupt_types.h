#ifndef OS_INTERRUPT_TYPES_HEADER_FILE
#define OS_INTERRUPT_TYPES_HEADER_FILE

typedef int OS_INTERRUPT;
typedef BOOLEAN EDDI_API (*OS_ISR_ROUTINE)(OS_INTERRUPT irq, void *ctx);

typedef struct t_IrqResources {
    int interrupt;
} OS_IRQ_RESOURCE;

typedef struct t_OS_IRQ_EXT {
    void *unused;
} OS_IRQ_EXT;

#endif
