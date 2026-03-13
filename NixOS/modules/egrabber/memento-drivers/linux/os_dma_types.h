#ifndef OS_DMA_TYPES_HEADER_FILE
#define OS_DMA_TYPES_HEADER_FILE

#include "os_types.h"

#ifdef NVIDIA_RDMA
#include <nvidia/nv-p2p.h>
#endif

typedef struct pci_dev *PDMA_OBJECT;

typedef struct {
    PHYSICAL_ADDR pa;
    void *va;
    UINT32 size;
    PDMA_OBJECT dmaAdapter;
} OS_COMMON_BUFFER;

typedef struct scatterlist SG_ELEMENT;

typedef struct {
    PHYSICAL_ADDR pa;
    UINT64 length;
} SG_ELEMENT_1;

typedef struct {
    int type;
    int numberOfElements;
    union {
        struct {
            SG_ELEMENT *elements;
            int totalPageCount;
        } /*host*/ ;
        struct {
            SG_ELEMENT_1 *elements_1;
#ifdef NVIDIA_RDMA
            nvidia_p2p_page_table_t *page_table;
            nvidia_p2p_dma_mapping_t *dma_mapping;
#endif
        } /*device*/;
        struct {
            SG_ELEMENT *elements_2;
            struct dma_buf *dmabuf;
            struct dma_buf_attachment *dmabuf_attachment;
            struct sg_table *dmabuf_sg_table;
            unsigned int skip_ents;
            unsigned int patch_offset;
        } /*dmabuf*/;
    };
} SG_LIST;

typedef struct _MEMORY_DESCRIPTION {
    int type;
    union {
        void *virtualAddress;
        void *deviceAddress;
        int dmabuf_fd;
    };
    unsigned int length;
    unsigned int offset;
    union {
        struct {
            unsigned int pageCount;
            struct page **pages;
            struct _MEMORY_DESCRIPTION *next;
        } /*host*/;
        struct {
#ifdef NVIDIA_RDMA
            nvidia_p2p_page_table_t *page_table;
            SG_LIST sglist;
#endif
        } /*device*/;
        struct {
            SG_LIST sgl;
        } /*dmabuf*/;
    };
} MEMORY_DESCRIPTION;



#endif
