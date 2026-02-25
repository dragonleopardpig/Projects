/* s2i_gev.h -- GigE vision modul header
 *
 * (C) 2022 by Sensor to Image GmbH
 *
 * Version: 2.7.1 Date: 20.07.2022
 *
 * History:
 * Version: 1.0 Date: 13.01.2021
 * - initial realease
 * Version: 2.6.0 Date: 26.05.2021
 * - fixed kernel panic due to binary blob interface using kernel structures
 * Version: 2.7.0 Date: 28.10.2021
 * - refactoring 
 * Version: 2.7.1 Date: 20.07.2022
 * - changed packet resend count from BYTE to DWORD
 */
#ifndef __S2I_GEV_H
#define __S2I_GEV_H
#include "s2i_config.h"
#include <s2i/types.h>
#include "s2i_io.h"

#ifdef NDIS_WDM
#define RESEND_PACKET_NEEDS_ETHER_FIELDS
#define ETHER_ADDR_LEN    6 /* length of an Ethernet address */
#endif

// === public/private API

typedef enum {
  S2I_CAPTURED_PACKET=0,
  S2I_IGNORED_PACKET=1
} gev_filter_decision_t;

u_int32_t EDDI_API gev_decodeBytesPerPixel(u_int32_t pixel_format);
struct GigEPacketResend;

#define IMAGE_SIZE_UNDEFINED ((u_int32_t) -1)

#include "image_buffer.h"

struct resend_packet_param
{
#ifdef RESEND_PACKET_NEEDS_ETHER_FIELDS
  u_int8_t ether_dhost[ETHER_ADDR_LEN];
  u_int8_t ether_shost[ETHER_ADDR_LEN];
#endif
  u_int8_t ip_saddr[4];
  u_int8_t ip_daddr[4];
  u_int16_t sport;                             // Source port
  u_int16_t dport;                             // Destination port
  u_int16_t stream_channel;
  u_int64_t block_id;
  u_int32_t first_packet_id;
  u_int32_t last_packet_id;
  u_int16_t req_id;
  u_int16_t ip_id;
  u_int8_t init_param;
  u_int8_t GVSPVersion;
  u_int32_t trace_context;
};


struct grab_param {
  u_int32_t isize;
  u_int32_t width;
  u_int32_t height;
  u_int32_t pixel_format;
  u_int8_t init_flag;
  u_int32_t *index_buffer;
  u_int32_t *size_buffer;
  u_int64_t BlockID;
  u_int64_t lastSeen;
  u_int32_t nNumberOfPacket;
  u_int32_t m_nMissingPacket;
  u_int8_t PacketResendFlag;
  u_int32_t PacketResendCountMax;
  u_int16_t PacketSize;

  IMAGE_BUFFER *Image;
  PIMAGE_BUFFER pImageBuffer;
  PIMAGE_BUFFER pImageBufferBefore;
  PIMAGE_BUFFER pImageBufferNext;

  u_int32_t img_error;
  u_int32_t missing_packets;
  u_int32_t img_cnt;
  u_int8_t GVSPVersion;
  int start_header;
  u_int64_t BlockIDMask;
  u_int64_t BlockIDCheck;
  
  u_int8_t check_payload;
  u_int8_t init_buffer;
  gev_bufno_t buffer_count;
  u_int8_t packets_out_of_order;
  u_int8_t PacketNotEqual;
  u_int16_t test_packet_resend;
  u_int8_t PacketLarger;
  u_int8_t RawData;
  gev_bufno_t current_buffer_count;
  
  u_int64_t timestamp_sav;
  u_int16_t test_packet_resend_count;

  u_int32_t data_blocks_discarded_on_device;
  u_int64_t start_of_last_hole;
  u_int8_t gendc_support;

  gev_bufno_t ring_buffer_count;
  RING_BUFFER *ring_buffer;
  u_int32_t trace_context;
  struct queue_param *queue;
  struct resend_packet_param *resend_param;
  struct time_stats *time_param;
  u_int64_t last_underrun;
  u_int32_t buffer_underrun;
};


void EDDI_API set_image(struct grab_param *grab, IMAGE_BUFFER *pImage);
PIMAGE_BUFFER EDDI_API get_clean_buffer(struct grab_param *grab, u_int64_t nBlockID);
os_error_t EDDI_API resend_packet(gev_kernel_context_t *pskb, struct resend_packet_param *grab, u_int64_t block_id,
                                  u_int32_t first_packet_id, u_int32_t last_packet_id, u_int8_t GVSPVersion);
void EDDI_API gev_set_resend_packet_header(struct GigEPacketResend *udp_data, struct resend_packet_param *grab, u_int64_t block_id, u_int32_t first_packet_id, u_int32_t last_packet_id, u_int8_t extended_id);
void EDDI_API gev_complete_block(struct grab_param *grab, u_int64_t completedId);
gev_filter_decision_t EDDI_API gev_process(struct grab_param *grab, gev_kernel_context_t *skb,
                                           const u_int8_t *data, size_t skb_head_len);

void EDDI_API gev_init_grab_parameters(struct grab_param *grab);
void EDDI_API gev_init_grab_counters(struct grab_param *grab);
void EDDI_API gev_setup_parameters(struct grab_param *grab, struct grab_param_io *ib_param, int ignore_gendc);
os_error_t EDDI_API gev_init_extra_buffers(struct grab_param *grab);
void EDDI_API gev_close_extra_buffers(struct grab_param *grab);
void EDDI_API gev_close_ring_buffer(struct grab_param *grab);

extern struct grab_param *grab_parameter[STREAM_COUNT];
extern struct resend_packet_param *resend_packet_parameter[STREAM_COUNT];
extern struct queue_param *queue_parameter[STREAM_COUNT];

#endif
