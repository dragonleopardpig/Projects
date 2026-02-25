/*****************************************************************************/
/*
 * s2i_utils.c -- Utils functions
 *
 *  (c) Copyright 2023 Sensor to Image GmbH
 *
 * Version: 2.7.2 Date: 01.02.2023
 *
 * History:
 * Version: 1.0.0 Date: 28.10.2021
 * - initial realease 
 * Version: 2.7.1 Date: 20.07.2022
 * - refactory: new Os*Signal helpers to report arrival of new buffers
 * Version: 2.7.2 Date: 01.02.2023
 * - new deque_flush function
 * - let InitImageBuffer know whether it should push buffers
 * - introduce InitImageQueue and CloseImageQueue abstractions
 * - new functions to support deferred buffers queue
*/
/*****************************************************************************/
#define M_KIND M_KIND_GEV
#include "s2i_gev.h"
#include "s2i_utils.h"                   
#include <s2i/os.h>                  


/** Get the first image buffer from the queue
 *  returns NULL if no buffer is available right now
 */
IMAGE_BUFFER* deque_pop_front(struct QueueBuffer *q)
{
  IMAGE_BUFFER* image_buffer = NULL;

  if (q == NULL)
    return NULL;

  OsLockSpin(&q->lock);
  if (q->front)
  {
    image_buffer = q->front;
    q->size--;
    q->front = q->front->NextBuffer;
    image_buffer->NextBuffer = NULL;

    if (q->front == NULL) 
      q->last = NULL;
  }
  OsUnlockSpin(&q->lock);

  return image_buffer;
}

void deque_push_back(struct QueueBuffer *q, IMAGE_BUFFER *buffer)
{
  if (q == NULL || buffer == NULL)
    return;
  buffer->NextBuffer = NULL;

  OsLockSpin(&q->lock);
  if (q->last != NULL) {
    q->last->NextBuffer = buffer;
    q->last = buffer;
  }
  else {
    q->front = buffer;
    q->last = buffer;
  }
  ++(q->size);
  OsUnlockSpin(&q->lock);
  OsNotifySignal(&q->newBuffer);
}

void deque_cancel(struct QueueBuffer *q)
{
  if (q == NULL)
    return;
  OsNotifySignal(&q->newBuffer);
}


size_t deque_size(struct QueueBuffer *q)
{
  size_t s;
	
  if (q == NULL)
    return 0;

  OsLockSpin(&q->lock);
  s = q->size;
  OsUnlockSpin(&q->lock);
  return s;
}

size_t deque_flush(struct QueueBuffer *q, gev_bufno_t *flushed, size_t flushsize)
{
  size_t i = 0;
  IMAGE_BUFFER *buf;
  if (q == NULL)
    return 0;
  OsLockSpin(&q->lock);
  if (flushed)
  {
    for (i = 0, buf = q->front; buf; i++)
    {
      if (i < flushsize)
        flushed[i] = buf->Index;
      buf = buf->NextBuffer;
    }
  }
  q->size = 0;
  q->front = NULL;
  q->last = NULL;
  OsUnlockSpin(&q->lock);
  return i;
}


void deque_init(struct QueueBuffer *q)
{
  if (q == NULL)
    return;

  OsInitSpin(&q->lock);
  OsInitSignal(&q->newBuffer);
  q->front = NULL;
  q->last = NULL;
  q->size = 0;
}


void deque_close(struct QueueBuffer *q)
{
  if (q == NULL)
    return;

  while (q->size && q->front)
  {
    deque_pop_front(q);
  }
  q->size = 0;
  q->front = NULL;
  q->last = NULL;
  OsCloseSpin(&q->lock);
  OsCloseSignal(&q->newBuffer);
}

static u_int32_t account_lost_frames(struct grab_param *grab, IMAGE_BUFFER *pImage);

void set_fps(struct grab_param *grab)
{
  struct time_stats *ts = grab->time_param;
  u_int32_t trace_context = grab->trace_context;
  if (OsTimeDefined(ts->start))
  {
    ts->stop = OsGetTickCount();
  }
  else
  {
    ts->start = OsGetTickCount();
    return;
  }
  OsLockSpin(&ts->lock);
  ts->ongoing.duration = OsTickDelta(ts->stop, ts->start);
  ts->ongoing.img_cnt++;

  if (ts->ongoing.duration >= ts->frequency)
  {
    TRACE_3x(M_VERBOSE, M_KIND_SPHINX_GEV, "set_fps update: %d frames in %"PRId64" time ticks (%"PRId64" ticks/sec)",
            ts->ongoing.img_cnt, ts->ongoing.duration, ts->frequency);
    ts->last.img_cnt = ts->ongoing.img_cnt;
    ts->last.duration = ts->ongoing.duration;
    ts->ongoing.img_cnt = 0;
    ts->start = ts->stop;
  }
  OsUnlockSpin(&ts->lock);
}

void EDDI_API set_image(struct grab_param *grab, IMAGE_BUFFER *pImage)
{
  u_int32_t trace_context = grab->trace_context;
  if (pImage == NULL)
    return;

  if (pImage->ImageHeader.ResendSendCount || pImage->ImageHeader.ResendReceiveCount)
    TRACE_3x(M_INFO, M_KIND_SPHINX_GEV, "Packet resend [BlockID %"PRId64"] -> requested: %d, received: %d packets", pImage->ImageHeader.FrameCounter, pImage->ImageHeader.ResendSendCount, pImage->ImageHeader.ResendReceiveCount);
  
  if (pImage->ImageHeader.MissingPacket == 0)
    pImage->Error = IMAGE_SUCCESS;
  else
  {
    pImage->Error = IMAGE_GRAB_ERROR;
    grab->missing_packets += pImage->ImageHeader.MissingPacket;
  }
  grab->img_cnt++;
  
  TRACE_3x(M_DEBUG, M_KIND_SPHINX_GEV, "Enqueueing image #%d (%d underrun, %d discarded so far)...", 
           pImage->ImageHeader.FrameCounter, pImage->ImageHeader.BufferUnderruns, pImage->ImageHeader.DiscardedFrames);
  pImage->ImageHeader.LostFrames = account_lost_frames(grab, pImage);

  deque_push_back(&grab->queue->m_nDeliverList, pImage);
  TRACE_1x(M_DEBUG, M_KIND_SPHINX_GEV, "Image #%d enqueued. Updating fps.", pImage->ImageHeader.FrameCounter);

  set_fps(grab);
  gev_complete_block(grab, pImage->ImageHeader.FrameCounter);
}

u_int32_t account_lost_frames(struct grab_param *grab, IMAGE_BUFFER *pImage)
{
  u_int32_t trace_context = grab->trace_context;
  if (grab->BlockIDCheck != 0)
  {
    if (pImage->ImageHeader.FrameCounter != grab->BlockIDCheck)
    {
      int64_t lost;

      lost = pImage->ImageHeader.FrameCounter - grab->BlockIDCheck;
      if (lost < 0)
        lost = -lost;
      
      grab->img_cnt += (u_int32_t)lost;
      grab->img_error += (u_int32_t) lost;
      grab->missing_packets += grab->nNumberOfPacket * (u_int32_t)lost;
      if (lost > 1)
      {
        TRACE_2x(M_ERROR, M_KIND, "Missing frames: %"PRId64" -> %"PRId64"", grab->BlockIDCheck, pImage->ImageHeader.FrameCounter - 1);
      }
      else
      {
        TRACE_1x(M_ERROR, M_KIND, "Missing frame: %"PRId64"", grab->BlockIDCheck);
      }
      return (u_int32_t) lost;
    }
    else
    {
      TRACE_1x(M_DEBUG, M_KIND_SPHINX_GEV, "BlockIDCheck ok: %"PRId64"", 
               pImage->ImageHeader.FrameCounter);
    }
  }
  else
  {
    TRACE_1x(M_DEBUG, M_KIND_SPHINX_GEV, "Setting up BlockIDCheck: %"PRId64"",
             pImage->ImageHeader.FrameCounter);
  }
  return 0;
}

os_error_t InitImageBuffer(gev_streamno_t device, u_int32_t image_size, u_int32_t packet_size,
                           BOOL pushBuffers)
{
  gev_bufno_t i;
  size_t allocSize = sizeof(IMAGE_BUFFER) * grab_parameter[device]->buffer_count;
  if (allocSize)
  {
    grab_parameter[device]->Image = (IMAGE_BUFFER *)OsMalloc(allocSize);
    if (grab_parameter[device]->Image == NULL)
      return OS_ALLOC_FAILURE;
    OsMemSet(grab_parameter[device]->Image, 0, allocSize);
  }
  for (i = 0; i < grab_parameter[device]->buffer_count; i++)
  {
    grab_parameter[device]->Image[i].Index = i;
    grab_parameter[device]->Image[i].SizePacket = packet_size;
    grab_parameter[device]->Image[i].SizeLastPacket = (image_size % packet_size);
    if (grab_parameter[device]->Image[i].SizeLastPacket == 0)
      grab_parameter[device]->Image[i].SizeLastPacket = packet_size;
    if (grab_parameter[device]->ring_buffer_count)
    {
      grab_parameter[device]->Image[i].pData = grab_parameter[device]->ring_buffer[i].pBuffer;
    }
    else
      grab_parameter[device]->Image[i].pData = (unsigned char*)OsMalloc(grab_parameter[device]->isize);

    if (grab_parameter[device]->Image[i].pData == NULL)
      return OS_ALLOC_FAILURE;

    grab_parameter[device]->Image[i].pPacket = (unsigned char*)OsMalloc(grab_parameter[device]->nNumberOfPacket);
    if (grab_parameter[device]->Image[i].pPacket == NULL)
      return OS_ALLOC_FAILURE;
    /** gev_setup_parameters() should have been called before we run this */
    grab_parameter[device]->Image[i].ImageHeader.PixelType = grab_parameter[device]->pixel_format;
    grab_parameter[device]->Image[i].ImageHeader.SizeX = grab_parameter[device]->width;
    grab_parameter[device]->Image[i].ImageHeader.SizeY = grab_parameter[device]->height;
  } 

  grab_parameter[device]->current_buffer_count = 0;
  if (pushBuffers)
  {
    for (i = 0; i < grab_parameter[device]->buffer_count; i++)
    {
      deque_push_back(&queue_parameter[device]->m_nQueuedList, &grab_parameter[device]->Image[i]);
    }
  }
  grab_parameter[device]->init_buffer = 1;
  return OS_OK;
}

void InitImageQueue(struct queue_param *q)
{
  deque_init(&q->m_nQueuedList);
  deque_init(&q->m_nDeliverList);
#ifdef S2I_DEFERRED_QUEUE
  q->deferred_head = GEV_BUFNO_NONE;
  q->deferred_tail = GEV_BUFNO_NONE;
#endif
}

void CloseImageQueue(struct queue_param *q)
{
  // NOTE: invalid unless InitImageQueue() has been called first.
  deque_close(&q->m_nQueuedList);
  deque_close(&q->m_nDeliverList);
#ifdef S2I_DEFERRED_QUEUE
  q->deferred_head = GEV_BUFNO_NONE;
  q->deferred_tail = GEV_BUFNO_NONE;
#endif
}

void CloseImageBuffer(gev_streamno_t device)
{
  int i;
  int delegated = 0;
  u_int32_t trace_context = grab_parameter[device]->trace_context;
  if (grab_parameter[device] == 0 || grab_parameter[device]->Image == NULL)
    return;

  // free image ring buffer 
  for (i = 0; i < grab_parameter[device]->buffer_count; i++)
  {
    if (grab_parameter[device]->ring_buffer_count == 0)
    {
      OsFree((void *)grab_parameter[device]->Image[i].pData, grab_parameter[device]->isize);
    } else {
      delegated++;
    }
    OsFree((void *)grab_parameter[device]->Image[i].pPacket, grab_parameter[device]->nNumberOfPacket);
    grab_parameter[device]->Image[i].pData = NULL;
    grab_parameter[device]->Image[i].pPacket = NULL;
  }
  if (delegated)
  {
    TRACE_2x(M_VERBOSE, M_KIND, "Delegating %d/%d ring buffers to the 'release' step", 
             delegated, grab_parameter[device]->ring_buffer_count);
  }
  OsFree((void *)grab_parameter[device]->Image, sizeof(IMAGE_BUFFER) * grab_parameter[device]->buffer_count);

  grab_parameter[device]->Image = NULL;
  TRACE_3x(M_VERBOSE, M_KIND_SPHINX_GEV, 
           "Queues state for %p at close_buffer: %d pending, %d to deliver", &queue_parameter[device],
           deque_size(&queue_parameter[device]->m_nQueuedList), 
           deque_size(&queue_parameter[device]->m_nDeliverList));
  deque_flush(&queue_parameter[device]->m_nQueuedList, 0, 0);
  deque_flush(&queue_parameter[device]->m_nDeliverList, 0, 0);
  grab_parameter[device]->init_buffer = 0;
}

PIMAGE_BUFFER EDDI_API get_clean_buffer(struct grab_param *grab, u_int64_t nBlockID)
{
  PIMAGE_BUFFER img_buffer = NULL;
  BOOL quiet = grab->last_underrun == nBlockID;
  u_int32_t trace_context = grab->trace_context;

  img_buffer = deque_pop_front(&grab->queue->m_nQueuedList);

  if (NULL == img_buffer && !quiet)
    TRACE_2x(M_WARNING, M_KIND, "There is no buffer available in the queue to store the data. (QueuedList: %d, DeliverList: %d)", grab->queue->m_nQueuedList.size, grab->queue->m_nDeliverList.size);

  return(img_buffer);
}

void InitTimeStats(gev_streamno_t streamno)
{
  struct time_stats *ts = time_param(streamno);
  OsInitSpin(&ts->lock);
}

void ResetTimeStats(gev_streamno_t streamno, os_time_t start, os_frequency_t freq)
{
  struct time_stats *ts = time_param(streamno);
  (void) start;
  ts->start = OS_TIME_UNDEF;
  ts->frequency = freq;
  ts->ongoing.img_cnt = 0;
  ts->ongoing.duration = 0;
  ts->last.img_cnt = 0;
  ts->last.duration = 0;
}

void CloseTimeStats(gev_streamno_t streamno)
{
  struct time_stats *ts = time_param(streamno);
  OsCloseSpin(&ts->lock);
}

void GetTimeStats(gev_streamno_t streamno, u_int32_t *img_cnt, u_int64_t *img_time)
{
  struct time_stats *ts = time_param(streamno);
  u_int64_t freq = ts->frequency ? ts->frequency : 1;
  u_int32_t trace_context = grab_parameter[streamno]->trace_context;
  TRACE_3x(M_DEBUG, M_KIND_SPHINX_GEV, "Time stats: last = (%d / %"PRId64"), ongoing = (%d)",
          ts->last.img_cnt, ts->last.duration, ts->ongoing.img_cnt);
  OsLockSpin(&ts->lock);
  if(ts->last.img_cnt == 0 || ts->last.duration == 0)
  {
    *img_cnt = ts->ongoing.img_cnt;
    *img_time = (1000ULL * ts->ongoing.duration) / freq;
  }
  else
  {
    *img_cnt = ts->last.img_cnt;
    *img_time = (1000ULL * ts->last.duration) / freq;
  }
  OsUnlockSpin(&ts->lock);
}

#if !defined(_KERNEL_MODE) && !defined(__KERNEL__)
double GetFpsFromTimeStats(gev_streamno_t streamno)
{
  struct time_stats *ts = time_param(streamno);
  double freq = ts->frequency ? (double) ts->frequency : 1.0;
  u_int32_t img_cnt;
  double img_time;
  u_int32_t trace_context = grab_parameter[streamno]->trace_context;
  OsLockSpin(&ts->lock);
  if(ts->last.img_cnt == 0)
  {
    TRACE_0x(M_NOTICE, M_KIND_SPHINX_GEV, "Fps computation hasn't stabilized yet. Using running average");
    img_cnt = ts->ongoing.img_cnt;
    img_time = (double) ts->ongoing.duration / freq;
  }
  else
  {
    img_cnt = ts->last.img_cnt;
    img_time = (double) ts->last.duration / freq;
  }
  OsUnlockSpin(&ts->lock);
  if (img_cnt && img_time != 0.0)
  {
    double averageDuration = img_time / (double) img_cnt;
    return 1.0 / averageDuration;
  }
  else
  {
    return 0.0;
  }
}
#endif

#ifdef S2I_DEFERRED_QUEUE
void QueueDeferredBuffers(gev_streamno_t device, struct queue_param* q)
{
  u_int32_t trace_context = grab_parameter[device]->trace_context;
  if (q->deferred_tail != GEV_BUFNO_NONE)
  {
    gev_bufno_t no, next;
    struct OsRingBuffer *buffers = grab_parameter[device]->ring_buffer;

    for (no = q->deferred_head; no != GEV_BUFNO_NONE; no = next)
    {
      next = buffers[no].next_deferred;
      TRACE_1x(M_VERBOSE, M_KIND_SPHINX_GEV, "Queueing deferred buffer %d", no);
      deque_push_back(&q->m_nQueuedList, &grab_parameter[device]->Image[no]);
      buffers[no].next_deferred = GEV_BUFNO_NONE;
    }
    q->deferred_tail = GEV_BUFNO_NONE;
    q->deferred_head = GEV_BUFNO_NONE;
  }
}

BOOL DeferBuffer(struct queue_param *q, struct OsRingBuffer *buffers, gev_bufno_t no)
{
  if (buffers[no].next_deferred != GEV_BUFNO_NONE || q->deferred_tail == no)
  {
    return FALSE;
  }

  if (q->deferred_tail != GEV_BUFNO_NONE)
  {
    buffers[q->deferred_tail].next_deferred = no;
  }
  q->deferred_tail = no;
  if (q->deferred_head == GEV_BUFNO_NONE)
  {
    q->deferred_head = no;
  }
  buffers[no].next_deferred = GEV_BUFNO_NONE;
  return TRUE;
}

void DeferQueuedBuffers(gev_streamno_t stream, struct queue_param* q)
{
  IMAGE_BUFFER *img = NULL;
  struct OsRingBuffer *buffers = grab_parameter[stream]->ring_buffer;
  struct grab_param *grab = grab_parameter[stream];
  u_int32_t trace_context = grab->trace_context;

  if (!buffers)
  {
    TRACE_0x(M_VERBOSE, M_KIND_SPHINX_GEV, "Grabber has no ring buffer. Skipping DeferQueuedBuffers");
    return;
  }
  while ( (img = deque_pop_front(&q->m_nQueuedList)) != NULL)
  {
    gev_bufno_t no = img->Index;
    TRACE_3x(M_VERBOSE, M_KIND_SPHINX_GEV, "Defer queueing of buffer %d (queue=%d..%d)",
           no, q->deferred_head, q->deferred_tail);
    DeferBuffer(q, buffers, no);
  }
  while ( (img = deque_pop_front(&q->m_nDeliverList)) != NULL)
  {
    gev_bufno_t no = img->Index;
    TRACE_3x(M_VERBOSE, M_KIND_SPHINX_GEV, "Cancel delivery of buffer %d (queue=%d..%d)",
           no, q->deferred_head, q->deferred_tail);
    DeferBuffer(q, buffers, no);
  }
  TRACE_3x(M_DEBUG, M_KIND_SPHINX_GEV, "Cancelling ongoing buffers: prev=%d, curr=%d, next=%d",
           grab->pImageBufferBefore ? (grab->pImageBufferBefore->ImageHeader.FrameCounter & 0xffff) : 0,
           grab->pImageBuffer ? (grab->pImageBuffer->ImageHeader.FrameCounter & 0xffff) : 0,
           grab->pImageBufferNext ? (grab->pImageBufferNext->ImageHeader.FrameCounter & 0xffff) : 0);
  if (grab->pImageBufferBefore)
    DeferBuffer(q, buffers, grab->pImageBufferBefore->Index);
  if (grab->pImageBuffer)
    DeferBuffer(q, buffers, grab->pImageBuffer->Index);
  if (grab->pImageBufferNext)
    DeferBuffer(q, buffers, grab->pImageBufferNext->Index);
}

size_t FlushDeferredBuffers(gev_streamno_t stream, struct queue_param* q, gev_bufno_t *flushed, size_t flushed_size)
{
  struct OsRingBuffer *buffers = grab_parameter[stream]->ring_buffer;
  gev_bufno_t no;
  size_t i;
  u_int32_t trace_context = grab_parameter[stream]->trace_context;
  for (i = 0, no = q->deferred_head; no != GEV_BUFNO_NONE; i++)
  {
    gev_bufno_t next = buffers[no].next_deferred;
    if (flushed  && i < flushed_size)
      flushed[i] = no;
    buffers[no].next_deferred = GEV_BUFNO_NONE;
    no = next;
  }
  TRACE_1x(M_VERBOSE, M_KIND_SPHINX_GEV, "Flushed %d deferred buffers", i);
  q->deferred_head = GEV_BUFNO_NONE;
  q->deferred_tail = GEV_BUFNO_NONE;
  return i;
}
#endif
