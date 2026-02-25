#ifndef OS_REGISTRATION_HEADER_FILE
#define OS_REGISTRATION_HEADER_FILE

#include "os_types.h"

#ifdef __cplusplus
extern "C"
{
#endif

INT32 EDDI_API mc_register_device(PCCHAR name);
void EDDI_API mc_unregister_device(UINT32 major, PCCHAR name);

INT32 EDDI_API mc_register_driver(void);
INT32 EDDI_API mc_unregister_driver(void);

#ifdef __cplusplus
}
#endif

#endif
