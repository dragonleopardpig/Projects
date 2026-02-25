/*****************************************************************************/
/*
 *  image_buffer.h -- image buffer functions for GigE device
 *
 *  (c) Copyright 2007 - 2022 Sensor to Image GmbH
 *
 * Version: 2.7.1 Date: 20.07.2022
 *
 * History:
 * Version: 1.0.0 Date: 30.06.2010
 * - initial realease
 * Version: 2.0.4 Date: 15.05.2012
 * - changed buffer handling
 * Version: 2.2.0 Date: 09.07.2019
 * - use the same data type for the image ring buffer index
 * - buffer handling has been changed
 * Version: 2.3.0 Date: 08.01.2020
 * - added SizePacket, SizeLastPacket and NumberOfPacket to the IMAGE_BUFFER struct
 * - added GenDC support
 * - added PacketIndexSav to the IMAGE_BUFFER struct 
 * Version: 2.6.0 Date: 26.05.2021
 * - migrate the next pointer into IMAGE_BUFFER and stop allocating/freeing NodeBuffer structures.
 * - removed unused function deque_front
 * - added remove_buffer_from_deque function
 * Version: 2.7.0 Date: 28.10.2021
 * - refactoring 
 * Version: 2.7.1 Date: 20.07.2022
 * - changed packet resend count from BYTE to DWORD
 */
/*****************************************************************************/
#ifndef __IMAGE_BUFFER_H
#define __IMAGE_BUFFER_H

#include "s2i_types.h"
#include "s2i_io.h"

#define IMAGE_SIZE_UNDEFINED ((u_int32_t) -1)

typedef unsigned char packet_rx_status_t;

#define BUFFER_COUNT        4

#define IMAGE_SUCCESS 0
#define IMAGE_GRAB_ERROR 2
#define IMAGE_DIFFERENT_HEADER 3

typedef IMAGE_BUFFER *PIMAGE_BUFFER;
struct _IMAGE_BUFFER {

  PIMAGE_BUFFER NextBuffer;
  u_int8_t *pData;
  struct image_header ImageHeader;
  u_int16_t Error;
  gev_bufno_t Index;
  packet_rx_status_t *pPacket;
  gev_pkcount_t PacketResendCount;
  u_int8_t OutOfOrder;
  u_int32_t TrailerSizeY;
  int NumberOfPacket;
  u_int32_t SizePacket;
  u_int32_t SizeLastPacket;
  int LeaderSize;
  u_int32_t LeaderOffset;
  u_int64_t PayloadDataSize;
  u_int8_t GenDCFlag;
  u_int8_t MultiPartCount;
  u_int32_t PacketIndexSav;
};

typedef void * IMAGE_BUFFER_HANDLE;

typedef struct OsRingBuffer RING_BUFFER;
typedef RING_BUFFER *PRING_BUFFER;

typedef struct sphinx_stream sphinx_stream;

void InitImageIndex(gev_camno_t device, int image_size, int packet_size );
void CloseImageIndex(gev_camno_t device);
u_int16_t SetBufferCountDriver(sphinx_stream *stream);

#endif

