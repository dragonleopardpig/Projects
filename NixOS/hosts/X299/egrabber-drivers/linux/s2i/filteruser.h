/* filteruser.h -- Filter header
 *
 * (C) 2023 by Sensor to Image GmbH
 *
 * Version: 2.7.2 Date: 01.02.2023
 * History:
 * Version: 1.0.0 Date: 15.12.2021
 * - initial realease
 * Version: 2.7.2 Date: 01.02.2023
 * - S2I_FILTER_NAME can now be defined from command line
 */
#ifndef __FILTERUSER_H__
#define __FILTERUSER_H__

#include <s2i_io.h> // Common
#define IOCTL_CMD_START_GRAB            _IOWR(S2I_IOC_MAGIC,1,int)
#define IOCTL_CMD_STOP_GRAB             _IOWR(S2I_IOC_MAGIC,2,int)
#define IOCTL_CMD_PACKET_RESEND         _IOWR(S2I_IOC_MAGIC,3,int)
#define IOCTL_CMD_GET_VERSION           _IOWR(S2I_IOC_MAGIC,4,int)
#define IOCTL_CMD_GET_IMAGE_HEADER      _IOWR(S2I_IOC_MAGIC,5,int)
#define IOCTL_CMD_GET_STATUS            _IOWR(S2I_IOC_MAGIC,6,int)
#define IOCTL_CMD_SET_BUFFER_COUNT      _IOWR(S2I_IOC_MAGIC,7,int)
#define IOCTL_CMD_SET_PACKETS_OUT_OF_ORDER  _IOWR(S2I_IOC_MAGIC,8,int)
#define IOCTL_CMD_SET_TEST_PACKET_RESEND    _IOWR(S2I_IOC_MAGIC,9,int)
#define IOCTL_CMD_SET_TRACE_CONTEXT     _IOWR(S2I_IOC_MAGIC,10,int)

#ifndef S2I_FILTER_NAME
#define S2I_FILTER_NAME "s2igevfilter"
#endif

#endif
