#ifndef __IMAGE_HEADER
#define __IMAGE_HEADER

#include <s2i_types.h>

struct image_header {
  u_int64_t FrameCounter;
  u_int64_t TimeStamp;
  u_int32_t PixelType;
  u_int32_t SizeX;
  u_int32_t SizeY;
  u_int32_t OffsetX;
  u_int32_t OffsetY;
  u_int16_t  PaddingX;
  u_int16_t  PaddingY;
  int32_t  MissingPacket;
  u_int32_t LostFrames;
  u_int16_t PayloadType;
  u_int32_t ChunkDataPayloadLength;
  u_int32_t ChunkLayoutId;
  gev_pkcount_t ResendSendCount;
  gev_pkcount_t ResendReceiveCount;
  u_int32_t SizeFilled;
  gev_pkcount_t PacketsOutOfOrder;
  u_int64_t DiscardedFrames;
  u_int64_t BufferUnderruns;
};

#endif
