#ifndef DMA_INTERFACE_HEADER
#define DMA_INTERFACE_HEADER

#include "os_size_t.h"
#include "os_dma_types.h"
#include "os_types.h"

#ifdef __cplusplus
extern "C" 
{
#endif

#define GET_SG_SUCCESS 0
#define GET_SG_FAILURE -1
#define GET_SG_INSUFFICIENT_RESOURCES -2

typedef void EDDI_API (*ScatterGatherCallback)(SG_LIST *scatterGather, void *context);

struct ScatterGatherCallbackContext{
    ScatterGatherCallback callback;
    void *context;
};


/** Creates and returns a DMA adapter for the given physicalDeviceObject.
    dma64Bit tells whether the physical device supports 64-bit addressing
    and maxLength is the maximum number of bytes the device can handle in
    each DMA operation. The maximum number of map registers the device can
    use for DMA is returned in numberOfMapRegisters. This argument is 
    ignored in Linux. **/
PDMA_OBJECT EDDI_API OsCreateDmaObject(PDEVICE physicalDeviceObject,
                                       BOOLEAN dma64bit, UINT32 maxLength,
                                       unsigned int *numberOfMapRegisters);

/** Destroys a DMA adapter created by OsCreateDmaObject. **/
void EDDI_API OsDeleteDmaObject(PDMA_OBJECT dmaAdapter);

/** Allocates a common buffer of size bytes using dmaAdapter DMA adapter.
**/
BOOLEAN EDDI_API OsAllocateCommonBuffer(OS_COMMON_BUFFER *cbuf,
                                        UINT32 size, PDMA_OBJECT dmaAdapter);

/** Frees a common buffer previously allocated by OsAllocateCommonBuffer.
 **/
void EDDI_API OsFreeCommonBuffer(OS_COMMON_BUFFER *cbuf);

#define MEMORY_DESCRIPTION_TYPE_DEFAULT     0
#define MEMORY_DESCRIPTION_TYPE_NVIDIA_RDMA 1
#define MEMORY_DESCRIPTION_TYPE_DMA_BUF     2

/** Allocates a structure large enough to describe buffer and initializes it.
    OsCreateMemoryDescription can be used at IRQL < DISPATCH_LEVEL.
**/
MEMORY_DESCRIPTION * EDDI_API OsCreateMemoryDescription(void *buffer, unsigned int length, 
                                                        unsigned int offset, int type);

/** Frees the structure memory that was allocated by OsCreateMemoryDescription.
    OsFreeMemoryDescription can be used at IRQL < DISPATCH_LEVEL.
**/
void EDDI_API OsFreeMemoryDescription(MEMORY_DESCRIPTION *memory);

/** Locks the buffer in memory and lists its physical pages.
    Expected to fail if any of the pages doesn't have user/write permission.
**/
BOOLEAN EDDI_API OsGetUserPages(MEMORY_DESCRIPTION *memory);

/** Unlocks the pages described by memory
**/
void EDDI_API OsPutUserPages(MEMORY_DESCRIPTION *memory);

/** Chains the MEMORY_DESCRIPTIONs of the given list together, in the order.
    It modifies the MEMORY_DESCRIPTIONs to chain them.
**/
void EDDI_API OsChainMemoryDescription(MEMORY_DESCRIPTION **memoryList, unsigned int size);

/** Maps the pages described by memory for DMA and lists them in scatterGatherList.
    Allocates the scatterGatherList and passes it to the callback.
    Must be called at PASSIVE_LEVEL.
**/
int EDDI_API OsGetScatterGatherList(MEMORY_DESCRIPTION *memory,
                                    PDEVICE device, PDMA_OBJECT adapter,
                                    struct ScatterGatherCallbackContext *context);

/** Unmap the pages mapped by OsGetScatterGatherList and frees the 
    scatterGatherList structure allocated by OsGetScatterGatherList.
    Must be called at PASSIVE_LEVEL.
**/
void EDDI_API OsPutScatterGatherList(SG_LIST **scatterGatherList,
                                     PDMA_OBJECT adapter);

/** Returns the length of the scatter gather element.
    sgElement must be valid.
**/
unsigned int EDDI_API OsGetSgLength(SG_ELEMENT *sgElement, int type);

/** Returns in address the physical address of the scatter gather element. 
    sgElement must be valid.
**/
void EDDI_API OsGetSgPhysicalAddress(SG_ELEMENT *sgElement, PHYSICAL_ADDR *address, int type);

/** Returns a pointer to the first element of the sgList.
 **/
SG_ELEMENT *EDDI_API OsGetFirstSgElement(SG_LIST *sgList);

/** Returns the next element of the sgList after sgElement.
 **/
SG_ELEMENT *EDDI_API OsGetNextSgElement(SG_ELEMENT *sgElement, int type);

/** Returns the number of elements in the sgList.
 **/
size_t EDDI_API OsGetSgElementCount(SG_LIST *sgList);

/** Returns 1 if the memory type is supported, 0 otherwise.
 **/
int EDDI_API OsIsMemoryTypeSupported(int type);

#ifdef __cplusplus
}
#endif

#endif


