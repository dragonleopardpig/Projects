#ifndef OS_TYPES_HEADER_FILE
#define OS_TYPES_HEADER_FILE

#include "../os_size_t.h"

#if defined(__aarch64__) || defined(__ARM_ARCH_7A__)
#define EDDI_API
#else
#define EDDI_API __attribute__((regparm(0)))
#endif

typedef unsigned int ULONG;
typedef unsigned int *PULONG;
typedef unsigned int DWORD;
typedef unsigned char UCHAR;
typedef unsigned char *PUCHAR;
typedef unsigned short USHORT;
typedef unsigned short *PUSHORT;

typedef unsigned int UINT32, UINT;
typedef unsigned int *PUINT32;
typedef unsigned short UINT16;
typedef unsigned short *PUINT16;
typedef unsigned char UINT8;
typedef unsigned char *PUINT8;
typedef signed int INT32;
typedef signed int *PINT32;
typedef const char *PCCHAR;

typedef long long INT64, *PINT64;
typedef long long LONGLONG;
typedef unsigned long long UINT64;
typedef unsigned long long ULONGLONG;
typedef unsigned long long ULONG64;
typedef unsigned short WCHAR;
typedef WCHAR *PWCHAR;
typedef WCHAR *LPWSTR, *PWSTR;

typedef long INT_PTR;
typedef unsigned long UINT_PTR;

typedef UCHAR BOOLEAN;

typedef void *PIRP;

typedef void *OS_RESOURCE;

typedef void DEVICE;
typedef DEVICE *PDEVICE;

#define FALSE   0
#define TRUE    1
#ifndef NULL
#define NULL    0
#endif

#define MC_MAX_DEVICES 16

typedef union
{
    struct
    {
        UINT32 LowPart;
        INT32 HighPart;
    };
    LONGLONG QuadPart;
} PHYSICAL_ADDR;

typedef int DRVSTATUS;

#endif
