/* s2i_io.h -- IO header
 *
 * (C) 2023 by Sensor to Image GmbH
 *
 * Version: 2.7.2 Date: 01.02.2023
 *
 * History:
 * Version: 1.0.0 Date: 28.10.2021
 * - initial realease
 * Version: 2.7.1 Date: 20.07.2022
 * - changed packet resend count from BYTE to DWORD
 * - use abstract gev_pkcount_t type where appropriate
 * Version: 2.7.2 Date: 01.02.2023
 * - delegating struct image_header to Common/image_header.h
 */
#ifndef __S2I_IO_H
#define __S2I_IO_H
// use 'k' as magic number
#define S2I_IOC_MAGIC   'k'

#include "s2i_types.h"
#include "image_header.h"

typedef u_int8_t gev_filterno_t; //!< identifies a filter slot from user's perspective

struct grab_param_io {
  u_int32_t width;
  u_int32_t height;
  u_int32_t cam_ip;                 //ip address
  u_int16_t cam_port;              //port data
  u_int16_t cam_port_ctrl;         //port control
  u_int32_t pixel_format;
  u_int32_t adapter_ip;             //ip address
  u_int32_t grab_size;  
  u_int16_t packet_size;
  u_int16_t extra_packets;
  u_int8_t packet_resend;
  gev_pkcount_t packet_resend_count;
  gev_filterno_t filterno;
  u_int32_t timeout;   // FIXME? bring up to avoid alignment issues ?
  u_int8_t gendc_support;
};

struct image_header_io {
  gev_filterno_t filterno;
  struct image_header img_h;
};

struct packet_resend_io {
  gev_filterno_t filterno;
  u_int8_t packet_resend_flag;
};

struct trace_context_io {
  gev_filterno_t filterno;
  u_int32_t trace_context;
};

struct image_fps_io {
  gev_filterno_t filterno;
  u_int32_t image_fps;
};

struct version_io {
  u_int8_t major;
  u_int8_t minor;
};

struct status_io {
  gev_filterno_t filterno;
  u_int32_t img_cnt;
  u_int32_t img_error;
  u_int32_t missing_packets;
  u_int32_t time_img_cnt;
  u_int64_t img_time;
  u_int32_t data_blocks_discarded_on_device;
};

struct buffer_count_io {
  gev_filterno_t filterno;
  gev_bufno_t count;
};

struct packets_out_of_order_io {
  gev_filterno_t filterno;
  u_int8_t packets_out_of_order;
};

struct test_packet_resend_io {
  gev_filterno_t filterno;
  u_int16_t packet;
  u_int16_t count;
};

// Windows only
struct ring_buffer_io {
  gev_filterno_t filterno;
  void * buffer;
  gev_bufno_t index;
  u_int32_t length;
};

// Darwin only
struct get_image_io {
  gev_filterno_t filterno;
  u_int32_t count;
};

//Darwin only
struct enable_disable_adapter_io {
  gev_filterno_t filterno;
  char adapter_name[20];
};

struct allocate_filter_slot_io {
  gev_filterno_t filterno;
};

#endif
