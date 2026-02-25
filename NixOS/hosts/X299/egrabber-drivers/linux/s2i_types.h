/* s2i_types.h -- common abstract types
 *
 * (C) 2022 by Sensor to Image GmbH
 *
 * Version: 2.7.1 Date: 07.04.2022
 */

#ifndef __COMMON_S2I_TYPES_H
#define __COMMON_S2I_TYPES_H

#include <s2i/types.h>

/** camera identifier, as identified in the API calls.
 *  valid values range from 1 to CAMERA_COUNT (included)
 */
typedef u_int8_t SPHINX_CAMNR;

/** camera or stream identifier, as identified in the API calls.
 *  valid camera values range from 1 to CAMERA_COUNT (included)
 */
typedef u_int8_t SPHINX_IDENTIFIER;

/** internal camera identifier.
 *  valid values range from 0 to CAMERA_COUNT-1
 */
typedef u_int8_t gev_camno_t;

/** internal stream identifier
 *  valid values range from 0 to STREAM_COUNT-1
 */
typedef u_int8_t gev_streamno_t;

/** buffer identifier
 */
typedef u_int16_t gev_bufno_t;
#define GEV_BUFNO_NONE 0xffffU
/** amount of network packets
 */
typedef u_int32_t gev_pkcount_t;

#endif
