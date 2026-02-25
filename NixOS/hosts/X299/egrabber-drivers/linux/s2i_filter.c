/* s2i_filter.c -- Netfilter module
 *
 * (C) 2023 by Sensor to Image GmbH
 *
 * Version: 24.04.0 Date: 11.04.2024
 * History:
 * Version: 1.0 Date: 11.03.2009
 * - initial realease
 * Version: 1.1 Date: 25.06.2009
 * - remove wait_event_interruptible and insert interruptible_sleep_on_timeout in read function to get an timeout when
 *   no image data is incomming   
 * - change in strucht image_fps_io the variable image_fps form unsigned long to u_int32_t. On 64 bit linux we got always 0
 * - check in main_hook function CAMERA_COUNT instead cam_cnt
 *
 * Version: 1.2 Date: 14.08.2009
 * - check pointer in main_hook function
 * - check cam_nr in cancamgige_read function
 *
 * Version: 1.3 Date: 25.09.2009
 * - resend packet with dev_queue_xmit function
 * - blocks in-buffer when user read from same as out-buffer
 *
 * Version: 1.4 Date: 06.10.2009
 * - get packetsize in IOCTL_CMD_START_GRAB command
 * - if jumbo frames comming in, the data are not linearly
 *
 * Version: 1.5 Date: 23.10.2009
 * - insert grab end event
 * - insert get driver version in cancamgige_ioctl function
 * - remove bug to set buffer event every time
 * - increment measure image count only when image is ok
 *
 * Version: 1.0.6 Date: 20.01.2010
 * - change filter driver parameter
 * - check image with width, height and pixelformat parameter
 *
 * Version: 1.0.7 Date: 04.02.2010
 * - get image parameter from stream
 *- insert get_image_header in FltDevIoControl function

 * Version: 1.0.8 Date: 07.04.2010
 * - grab event for every buffer
 * - change measure time

 * Version: 2.0.0 Date: 17.03.2011
 * - change buffer management
 * - change filter driver parameter 
 * - remove measure frames per seconds
 * - remove bug measure number of packets
 * - change buffer and error handling 
 * - change driver name to s2igevfilter

 * Version: 2.0.3 Date: 02.08.2011
 * - change packet resend implementation

 * Version: 2.0.4 Date: 15.05.2012
 * - check resend packets in next frame
 * - change minor version to minor and sub minor X.X.X
 * - added PaddingX in s2iGEVFilter_read function
 * - set padding parameter to 0, when the image header is corrupt
 * - changed buffer handling
 * - insert extended ID (GigEVision Specifikation 2.0)

 * Version: 2.0.5 Date: 12.12.2012
 * - changed buffer handling
 * - wait of end event (drop packets) when stop grabbing

 * Version: 2.0.6 Date: 13.12.2013
 * - remove bug in check next block id 
  
 * Version: 2.0.8 Date: 09.09.2014
 * - get absolute value of packet id 
 * - increment device/camera count to 20
  
 * Version: 2.0.9 Date: 19.01.2015
 * - added BlockIDMask
 * - change check missing frames
  
 * Version: 2.1.0 Date: 11.11.2015
 * - check grab_flag before set end event
 * - check payload when width, height and pixel format == 0 in start grab
 * - when lost packets at trailer, wait next frame of packets 
 * - added set buffer count
 * - added set packets out of order
 * - added test packet resend
 * - remove bug in resend_packet. (mac header)
 
 * Version: 2.1.1 Date: 26.01.2017
 * - added pImageBufferBeforeBefore and pImageBufferNext;
 
 * Version: 2.1.2 Date: 08.03.2017
 * - support extended chunk data payload type
 * - support multi-part data payload type

 * Version: 2.1.3 Date: 29.06.2017
 * - return image time and image time cnt in IOCTL_CMD_GET_STATUS
 * - added calculation of frames per second
 * - change buffer handling
 * - supported more than one packet to test packet resend
 * - no error when leader SizeY != trailer SizeY
 * - fill new IMAGE_HEADER parameter
 * - supported image extended chunk and chunk payload type
 * - make nodes in /dev by driver 
 
 * Version: 2.1.4 Date: 22.08.2018
 * - added payload type defines
 * - check of  GEV_FLAG_PREVIOUS_BLOCK_DROPPED flag
 * - return data blocks discarded on device count in ioctl get status command

 * Version: 2.2.0 Date: 09.07.2019
 * - added packet resend info to image header
 * - buffer handling has been changed
 * - the address offset is now used to sort multipart data packets

 * Version: 2.3.0 Date: 08.01.2020
 * - check if trailer sizeX smaller than leader sizeX
 * - copy image header after change SizeY with TrailerSizeY
 * - added GenDC support
 * - set current number of packets for GenDC
 * - check the write index of pPacket array

 * Version: 2.4.0 Date: 05.05.2020
 * - do_gettimeofday no longer available from kernel 3.18
 * - nf_register_hook/nf_unregister_hook has been replaced by the function nf_register_net_hook/nf_unregister_net_hook from kernel 4.13
 * - increase the size after allocated NodeBuffer in deque functions
 * - decrease the size after free NodeBuffer in deque functions
 * - clear new image event before wait
 * - added PacketIndexSav to IMAGE_BUFFER struct
 * - changed packet resend handling
 * - check missing frames in set_image function
 * - changed buffer handling

 * Version: 2.5.0 Date: 13.01.2021
 * - return the leader parameter if feature and leader parameter not equal
 * - set current missing packets when leader SizeY != trailer SizeY
 * - now supports 50 devices
 * - moved the gige vision specific code in separate files outsourced, to create precompiled file
 * - if it's a multicast packet than set in all open multicast devices
 * - fixed mutex issue

 * Version: 2.6.0 Date: 26.05.2021
 * - fixed queue handling
 * - Access to queues is not thread safe, use spin lock 
 * - migrate the next pointer into IMAGE_BUFFER and stop allocating/freeing NodeBuffer structures.
 * - removed unused function deque_front
 * - check if pPacket are correct allocated 
 * - fixed kernel panic due to binary blob interface using kernel structures
 * - check if we can frees the buffers in CloseImageBuffer
 * - fixed, struct timeval is no longer defined in the kernel kernel 5.8.0
 * - remove the two extra buffer space in InitImageBuffer

 * Version: 2.7.0 Date: 15.12.2021
 * - refactoring 
 * Version: 2.7.1 Date: 20.07.2022
 * - changed packet resend count from BYTE to DWORD
 * - grab_flag: improved resilience against `AcquisitionStop` while packet capture is ongoing
 * - microseconds precision timestamps
 * - fix: allocate resources before registering hook
 * - fix: release resource when handles are closed
 * - refactory: new Os*Signal helpers to report arrival of new buffers

 * Version: 2.7.1 Date: 19.01.2022
 * - changed packet resend count from BYTE to DWORD

 * Version: 2.7.2 Date: 01.02.2023
 * - introduce OsInitQueue and OsCloseQueue abstractions
 * - introduce InitImageQueue and CloseImageQueue abstractions

 * Version: 24.04.0 Date: 11.04.2024
 * - parameter of the main_hook function has changed
 
make clean
make
sudo make install
sudo modprobe s2igevfilter

sudo cp s2igevfilter.ko /lib/modules/3.13.0-101-generic/extra
sudo insmod s2igevfilter.ko
sudo rmmod s2igevfilter

tail -f /var/log/kern.log & 


 */
#include <linux/ip.h>            
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/version.h>
#include <linux/netdevice.h>     
#include <linux/netfilter.h>
#include <linux/netfilter_ipv4.h>
#include <linux/skbuff.h>        
#include <linux/udp.h>                   
#include <linux/vmalloc.h>
#include <linux/delay.h>
#include <linux/wait.h>

#if LINUX_VERSION_CODE >= KERNEL_VERSION(3,18,0)
#include <linux/ktime.h>
#else
#include <linux/time.h>
#endif
  
#include <linux/mutex.h>

//#include <linux/device.h>
//#include <linux/cdev.h>

#include <net/ip.h>
#include <net/udp.h>
#include <linux/netfilter_ipv4.h>

#include <s2i/queue.h>
#include <s2i/os.h>
#include "s2i_filter.h"                   
#include "s2i_utils.h"                   
#include <s2i/filteruser.h>
#include <s2i_gev.h>

MODULE_AUTHOR("Sensor to Image GmbH");
MODULE_DESCRIPTION("s2i GigE-Vision netfilter module");
MODULE_LICENSE("Proprietray");

struct grab_param *grab_parameter[STREAM_COUNT];
struct filter_param *filter_parameter[STREAM_COUNT];
struct resend_packet_param *resend_packet_parameter[STREAM_COUNT];
struct queue_param *queue_parameter[STREAM_COUNT];

static unsigned char cam_cnt = 0;
struct timer_list grab_timer;
static unsigned char opened = 0;
static unsigned char nonblock = 0;

static struct nf_hook_ops netfilter_ops;                       

#if LINUX_VERSION_CODE< KERNEL_VERSION(4,3,0)
#define atomic_read_acquire(p) smp_load_acquire(&(p)->counter)
#define atomic_set_release(p, i) smp_store_release(&(p)->counter, i)
#endif

static
#if LINUX_VERSION_CODE>= KERNEL_VERSION(4,1,0) 
unsigned int main_hook(const struct nf_hook_ops *ops,
                   struct sk_buff *skb,
                   const struct nf_hook_state *state)

#elif LINUX_VERSION_CODE>= KERNEL_VERSION(3,13,0) 
unsigned int main_hook(const struct nf_hook_ops *ops,
                  struct sk_buff *skb,
                  const struct net_device *in,
                  const struct net_device *out,
                  int (*okfn)(struct sk_buff *))

#elif LINUX_VERSION_CODE>= KERNEL_VERSION(2,6,24) 
unsigned int main_hook(unsigned int hooknum,
                  struct sk_buff *skb,
                  const struct net_device *in,
                  const struct net_device *out,
                  int (*okfn)(struct sk_buff*))
#else
unsigned int main_hook(unsigned int hooknum,
                  struct sk_buff **skb,
                  const struct net_device *in,
                  const struct net_device *out,
                  int (*okfn)(struct sk_buff*))
#endif
{
  gev_camno_t i;
  void *p;
  struct sk_buff *sock_buff = NULL;
  struct udphdr *udp_header;                             
  struct iphdr *ip_header;
  unsigned int ret = NF_ACCEPT;
  unsigned long grab_lock_flags;
  size_t payload_offset = sizeof( struct iphdr ) + sizeof( struct udphdr );

  if(cam_cnt == 0)
    return(ret);

#if LINUX_VERSION_CODE>= KERNEL_VERSION(2,6,24) 
  sock_buff = skb;
#else
  sock_buff = *skb;
#endif

  if(!sock_buff)
   return (ret);                  

  // If jumbo frames comming in, the data are not linearly
  // skb_linearize checks if sock_buff is linear, when not than make linearly
  skb_linearize(sock_buff);

  // get ip header (works on all linux versions)
  ip_header = (struct iphdr *)ip_hdr(sock_buff);    

  if(ip_header == NULL)
    return (ret);

  if(ip_header->protocol != 17)
    return (ret); 

  // get udp header
  p = (void *) ip_header + sizeof( struct iphdr );
  udp_header = (struct udphdr *) p;

  if(udp_header == NULL)
    return (ret);

  for(i = 0;i < CAMERA_COUNT;i++)
  {
    //Must lockout stop grab from deallocating resources while this is running
    // only check if acquisition is in progress
    if (atomic_read_acquire(&queue_parameter[i]->grab_flag) == GRAB_FLAG_RUNNING)
    {
      spin_lock_irqsave(&queue_parameter[i]->grab_lock, grab_lock_flags);
      if (atomic_read_acquire(&queue_parameter[i]->grab_flag) == GRAB_FLAG_RUNNING)
      {
        if((ntohs(udp_header->dest) == filter_parameter[i]->CamPort) && (ip_header->saddr == filter_parameter[i]->CamIp) && (ip_header->daddr == filter_parameter[i]->adapter_ip))
        {
          // set packet resend parameter
          if(resend_packet_parameter[i]->init_param == 0) 
          {
            memcpy(resend_packet_parameter[i]->ip_daddr,&ip_header->saddr,4);
            memcpy(resend_packet_parameter[i]->ip_saddr,&ip_header->daddr,4);
            resend_packet_parameter[i]->init_param = 1;
          }          

          ret = gev_process(grab_parameter[i], sock_buff, sock_buff->data + payload_offset, skb_headlen(sock_buff) - payload_offset);

          // if not multicast address than exit
          //  multicast addresses are defined by the most-significant bit pattern of 1110.
          if ((filter_parameter[i]->adapter_ip & 0x000000F0) != 0x000000E0)
          {
            spin_unlock_irqrestore(&queue_parameter[i]->grab_lock, grab_lock_flags);
            break;
          }
        }
      }
      spin_unlock_irqrestore(&queue_parameter[i]->grab_lock, grab_lock_flags);
    }
  }
  return (ret == S2I_CAPTURED_PACKET) ? NF_DROP : NF_ACCEPT;
}

static ssize_t s2iGEVFilter_read(struct file *file, char *buf,
         size_t count, loff_t * ppos)
{
  ssize_t ret = 0;
  unsigned char cam_nr = CAMERA_COUNT;
  PIMAGE_BUFFER pMyBuffer = NULL;
  unsigned char *psrc, *pdest,*psrclast;
  int i, x,bpp,imgWidth, cnt;
  int status, wait_result;
  if (*ppos)
    return -ESPIPE;

  // get camera number from data pointer first byte
  if (copy_from_user(&cam_nr, buf, 1) != 0) {
    return -EINVAL;
  }
  
  if(cam_nr >= CAMERA_COUNT) {
    return -ESPIPE;
  }

  status = atomic_read_acquire(&queue_parameter[cam_nr]->grab_flag);

  if(status == GRAB_FLAG_STOPPING) {
    ret = -EPIPE;
    goto CompleteRead;
  }
  else if (status == GRAB_FLAG_STOPPED) {
    //Allow waiting on image before grab starts, but do so before acquiring mutex otherwise
    //at least 1 timeout will be triggers before the grab start ioctl can be performed
    wait_result = wait_event_interruptible_timeout(queue_parameter[cam_nr]->grab_wait, 
      atomic_read_acquire(&queue_parameter[cam_nr]->grab_flag) == GRAB_FLAG_RUNNING, 
      msecs_to_jiffies(1000));

    if(0 == wait_result || wait_result == -ERESTARTSYS) {
      ret = -EPIPE;
      goto CompleteRead;
    } 
  }

  //Since copy_to_user may sleep, mutex should be used
  //This mutex should not be used in interrupt handler
  wait_result = mutex_lock_interruptible(&queue_parameter[cam_nr]->read_mutex);
  if (wait_result == -EINTR)
  {
    ret = -EAGAIN;
    goto CompleteRead;
  }

  // Elements in queue might be freed on acquisition stop, we have to lock out image deallocation
  wait_result = wait_event_interruptible_timeout(queue_parameter[cam_nr]->m_nDeliverList.newBuffer.signal, 
      (pMyBuffer = deque_pop_front(&queue_parameter[cam_nr]->m_nDeliverList)) != NULL, 
      msecs_to_jiffies(filter_parameter[cam_nr]->grab_timeout));

  //Can also be interrupted and return non-zero
  if (0 == wait_result || wait_result == -ERESTARTSYS)
  {
    ret = -EAGAIN;
    goto CompleteReadUnlockMutex;
  } 

  switch(pMyBuffer->Error)
  {
    case IMAGE_SUCCESS: ret = 0;
            break;
      
    case IMAGE_GRAB_ERROR: ret = -EIO;
            break;
  
    case IMAGE_DIFFERENT_HEADER: ret = -EINVAL;
            // copy image header
            memcpy(&filter_parameter[cam_nr]->cur_img_header,&pMyBuffer->ImageHeader, sizeof(struct image_header));

            deque_push_back(&queue_parameter[cam_nr]->m_nQueuedList, pMyBuffer);
            goto CompleteReadUnlockMutex;
  }

  // copy pixel data in image memory
  if(pMyBuffer->ImageHeader.PaddingX)
  {
    psrc = pMyBuffer->pData;
    pdest = buf;

    bpp = gev_decodeBytesPerPixel(pMyBuffer->ImageHeader.PixelType);

    imgWidth = (pMyBuffer->ImageHeader.SizeX * bpp);
    x = imgWidth + pMyBuffer->ImageHeader.PaddingX;
    psrclast = psrc + (x * pMyBuffer->ImageHeader.SizeY);
    
    
    for(i = 0; i < (int)pMyBuffer->ImageHeader.SizeY;i++)
    {
      
      if((psrc + imgWidth) < psrclast)
      {
        if (copy_to_user (pdest, psrc, imgWidth))
        {
          ret = -EFAULT;
          break;
        }
      }
      pdest += imgWidth;
      psrc += x;
    }
  }
  else
  {
    if (pMyBuffer->ImageHeader.SizeX == -1)
    {
      if (pMyBuffer->ImageHeader.SizeY > count)
        cnt = count;
      else
        cnt = pMyBuffer->ImageHeader.SizeY;

      if (copy_to_user(buf, pMyBuffer->pData, cnt))
        ret = -EFAULT;
    }
    else
    {
      // check if trailer sizeX smaller than leader sizeX
      if (pMyBuffer->ImageHeader.SizeY != pMyBuffer->TrailerSizeY)
      {
        int lsize;

        if(pMyBuffer->TrailerSizeY != IMAGE_SIZE_UNDEFINED)
          pMyBuffer->ImageHeader.SizeY = pMyBuffer->TrailerSizeY;
        
        bpp = gev_decodeBytesPerPixel(pMyBuffer->ImageHeader.PixelType);

        lsize = (pMyBuffer->ImageHeader.SizeX * bpp) * pMyBuffer->ImageHeader.SizeY;
        if (lsize >(int)count)
          lsize = (int)count;

        if (copy_to_user(buf, pMyBuffer->pData, lsize))
          ret = -EFAULT;
      }
      else
      {
        if (copy_to_user(buf, pMyBuffer->pData, count))
          ret = -EFAULT;
      }
    }
  }

  // copy image header
  memcpy(&filter_parameter[cam_nr]->cur_img_header, &pMyBuffer->ImageHeader, sizeof(struct image_header));

  deque_push_back(&queue_parameter[cam_nr]->m_nQueuedList, pMyBuffer);

  CompleteReadUnlockMutex:
  mutex_unlock(&queue_parameter[cam_nr]->read_mutex);
  CompleteRead:
  return ret;
}

static int _locked_ioctl_cmd_start_grab(struct grab_param_io *ib_param, int rest_cnt) {
  unsigned char cam_nr = ib_param->filterno;
  if (atomic_read_acquire(&queue_parameter[cam_nr]->grab_flag) == GRAB_FLAG_RUNNING)
  {
    return -EBUSY;
  }
  printk("cam_nr: %d\n",cam_nr);

  gev_setup_parameters(grab_parameter[cam_nr], ib_param, 0);
          
  printk("width: %d\n",ib_param->width);
  printk("height: %d\n",ib_param->height);
  printk("pixel_format: %d\n",ib_param->pixel_format);
  printk("CamIP: %08X\n",ib_param->cam_ip);
  printk("CamPort: %d\n",ib_param->cam_port);
  printk("PacketResendCount: %d\n",ib_param->packet_resend_count);

  if(grab_parameter[cam_nr]->buffer_count == 0)
    grab_parameter[cam_nr]->buffer_count = 4;

  // set current count of packets for gendc
  if (grab_parameter[cam_nr]->gendc_support)
    grab_parameter[cam_nr]->nNumberOfPacket++;
         
  if(InitImageBuffer(cam_nr, grab_parameter[cam_nr]->isize, grab_parameter[cam_nr]->PacketSize, true) == OS_ALLOC_FAILURE)
  {
    CloseImageBuffer(cam_nr);
    return -ENOMEM;
  }
        
  if(gev_init_extra_buffers(grab_parameter[cam_nr]) == OS_ALLOC_FAILURE)
  {
    gev_close_extra_buffers(grab_parameter[cam_nr]);
    CloseImageBuffer(cam_nr);
    return -ENOMEM;
  }

  filter_parameter[cam_nr]->grab_timeout = ib_param->timeout;
  filter_parameter[cam_nr]->CamIp = ib_param->cam_ip;
  filter_parameter[cam_nr]->CamPort = ib_param->cam_port;
  filter_parameter[cam_nr]->CamPortCtrl = ib_param->cam_port_ctrl;
  filter_parameter[cam_nr]->adapter_ip = ib_param->adapter_ip;

  grab_parameter[cam_nr]->init_flag = 1;

  gev_init_grab_counters(grab_parameter[cam_nr]);
  gev_init_grab_parameters(grab_parameter[cam_nr]);
         
  resend_packet_parameter[cam_nr]->sport = filter_parameter[cam_nr]->CamPortCtrl;                // GigE control port
  resend_packet_parameter[cam_nr]->dport = 3956;       

  ResetTimeStats(cam_nr, OsGetTickCount(), OsGetFrequency());
          
  grab_parameter[cam_nr]->data_blocks_discarded_on_device = 0; // FIXME: redundant with init_grab_counters ?
  atomic_set_release(&queue_parameter[cam_nr]->grab_flag, GRAB_FLAG_RUNNING);
  cam_cnt++;
  return 0;
}

static int ioctl_cmd_start_grab(struct grab_param_io *ib_param, int rest_cnt) {
  unsigned long grab_lock_flags;
  int rc = 0, cam_nr;
  cam_nr = ib_param->filterno;
  printk("start_grab (%d)\n", cam_nr);
  if(cam_nr < 0 || cam_nr >= CAMERA_COUNT) {
    return -ENOENT;
  }

  mutex_lock(&queue_parameter[cam_nr]->read_mutex);
  spin_lock_irqsave(&queue_parameter[cam_nr]->grab_lock, grab_lock_flags);
  rc = _locked_ioctl_cmd_start_grab(ib_param, rest_cnt);
  spin_unlock_irqrestore(&queue_parameter[cam_nr]->grab_lock, grab_lock_flags);
  mutex_unlock(&queue_parameter[cam_nr]->read_mutex);

  if(rc == 0) {
    wake_up_interruptible(&queue_parameter[cam_nr]->grab_wait);
  }
  return rc;
}

static int _internal_ioctl_cmd_stop_grab(unsigned char cam_nr) {
  printk("stop_grab (%d)\n",cam_nr);
  filter_parameter[cam_nr]->CamIp = 0;
  filter_parameter[cam_nr]->CamPort = 0;

  CloseImageBuffer(cam_nr);

  gev_close_extra_buffers(grab_parameter[cam_nr]);
  deque_flush(&queue_parameter[cam_nr]->m_nDeliverList, 0, 0);
  deque_flush(&queue_parameter[cam_nr]->m_nQueuedList, 0, 0);
  
  memset(resend_packet_parameter[cam_nr],0,sizeof( struct resend_packet_param  ));
  CloseTimeStats(cam_nr);
                    
  if(cam_cnt)
    cam_cnt--;

  atomic_set_release(&queue_parameter[cam_nr]->grab_flag, GRAB_FLAG_STOPPED);

  return 0;
}

static int ioctl_cmd_stop_grab(unsigned char cam_nr) {
  int rc = 0;
  unsigned long grab_lock_flags;

  atomic_set_release(&queue_parameter[cam_nr]->grab_flag, GRAB_FLAG_STOPPING);
  deque_cancel(&queue_parameter[cam_nr]->m_nDeliverList);

  //Has to be done in two steps, first stop network hook from using resources
  mutex_lock(&queue_parameter[cam_nr]->read_mutex);
  spin_lock_irqsave(&queue_parameter[cam_nr]->grab_lock, grab_lock_flags);
  // synchronize with any pending hook running gev_process(cam_nr) 
  spin_unlock_irqrestore(&queue_parameter[cam_nr]->grab_lock, grab_lock_flags);
  //Then clean up and wake up potential read thread
  rc = _internal_ioctl_cmd_stop_grab(cam_nr);
  mutex_unlock(&queue_parameter[cam_nr]->read_mutex);

  if(rc == 0) {
    wake_up_interruptible(&queue_parameter[cam_nr]->grab_wait);
  }
  return rc;
}

#define COPY_ARG(from, type) \
  rest_cnt = copy_from_user(&from, (int*) arg, sizeof(type)); \
  if (rest_cnt > 0) return -EINVAL; \
  if (from.filterno < 0 || from.filterno >= CAMERA_COUNT) return -ENOENT;

static int s2iGEVFilter_ioctl(struct inode *inode, struct file *filp, unsigned int cmd, unsigned long arg)
{
  int rc = 0;
  struct grab_param_io ib_param;
  unsigned char cam_nr = 0;
  int rest_cnt;

  switch (cmd) 
  {
    case IOCTL_CMD_START_GRAB:
      rest_cnt = copy_from_user(&ib_param,(int *)arg, sizeof(struct grab_param_io));
      if(rest_cnt > 0)
        ib_param.gendc_support = 0;
      rc = ioctl_cmd_start_grab(&ib_param, rest_cnt);
      break;

    case IOCTL_CMD_STOP_GRAB:
      COPY_ARG(ib_param, struct grab_param_io);
      cam_nr = ib_param.filterno;
      rc = ioctl_cmd_stop_grab(cam_nr);
      rest_cnt = copy_to_user((int *)arg, &ib_param, sizeof(struct grab_param_io));
      break;

    case IOCTL_CMD_PACKET_RESEND:
    {
      struct packet_resend_io pr_param;
      COPY_ARG(pr_param, struct packet_resend_io);
      cam_nr = pr_param.filterno;
      grab_parameter[cam_nr]->PacketResendFlag = pr_param.packet_resend_flag;
      break;
    }
    case IOCTL_CMD_GET_VERSION:
    {
      struct version_io version_param;
      version_param.major = DRIVER_MAJOR_VERSION;
      version_param.minor = DRIVER_MINOR_VERSION;
      rest_cnt = copy_to_user((int *)arg, &version_param, sizeof(struct version_io));
      break;
    }
    case IOCTL_CMD_GET_IMAGE_HEADER:
    {
      struct image_header_io img_header_param;
      COPY_ARG(img_header_param, struct image_header_io);
      cam_nr = img_header_param.filterno;
      
      memcpy(&img_header_param.img_h,&filter_parameter[cam_nr]->cur_img_header, sizeof(struct image_header));

      if(rest_cnt == 0)
        rest_cnt = copy_to_user((int *)arg, &img_header_param, sizeof(struct image_header_io));
      else
        rest_cnt = copy_to_user((int *)arg, &img_header_param, sizeof(struct image_header_io) - rest_cnt);
      break;
    }
    case IOCTL_CMD_GET_STATUS:
    {
      struct status_io status_param;
      COPY_ARG(status_param, struct status_io);
      cam_nr = status_param.filterno;

      status_param.img_cnt = grab_parameter[cam_nr]->img_cnt;
      status_param.img_error = grab_parameter[cam_nr]->img_error;
      status_param.missing_packets = grab_parameter[cam_nr]->missing_packets;
      GetTimeStats(cam_nr, &status_param.time_img_cnt, &status_param.img_time);
      status_param.data_blocks_discarded_on_device = grab_parameter[cam_nr]->data_blocks_discarded_on_device;
      rest_cnt = copy_to_user((int *)arg, &status_param, sizeof(struct status_io) - rest_cnt);
      break;
    }
    case IOCTL_CMD_SET_BUFFER_COUNT:
    {
      struct buffer_count_io bc_param;
      COPY_ARG(bc_param, struct buffer_count_io);
      cam_nr = bc_param.filterno;
      grab_parameter[cam_nr]->buffer_count = bc_param.count;
      break;
    }
    case IOCTL_CMD_SET_PACKETS_OUT_OF_ORDER:
    {
      struct packets_out_of_order_io po_param;
      COPY_ARG(po_param, struct packets_out_of_order_io);
      cam_nr = po_param.filterno;
      grab_parameter[cam_nr]->packets_out_of_order = po_param.packets_out_of_order;
      break;
    }
    case IOCTL_CMD_SET_TEST_PACKET_RESEND:
    {
      struct test_packet_resend_io tp_param;
      COPY_ARG(tp_param, struct test_packet_resend_io);
      cam_nr = tp_param.filterno;
      grab_parameter[cam_nr]->test_packet_resend = tp_param.packet;
      grab_parameter[cam_nr]->test_packet_resend_count = tp_param.count;
      break;
    }
    case IOCTL_CMD_SET_TRACE_CONTEXT:
    {
      struct trace_context_io tio;
      COPY_ARG(tio, struct trace_context_io);
      cam_nr = tio.filterno;
      grab_parameter[cam_nr]->trace_context = TRACE_IMPORT(tio.trace_context);
      break;
    }
    default:
      rc = -EINVAL;
      break;
  }
  return(rc);
}

#if LINUX_VERSION_CODE>= KERNEL_VERSION(2,6,24) 
static long s2iGEVFilter_unlocked_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
  return s2iGEVFilter_ioctl(NULL, f, cmd, (unsigned long)arg);
}
#endif

static int s2iGEVFilter_open(struct inode *inode, struct file *filp)
{
//  int minor = MINOR (inode->i_rdev);

//  if(minor != S2IGEVFILTER_MINOR) return -ENXIO;
    
//  if(opened)
//    return -EMFILE;

  if(filp->f_flags & O_NONBLOCK)
    nonblock = 1;

  opened = 1;
  return 0;
}

static int s2iGEVFilter_release (struct inode *inode, struct file *filp)
{
  int cam_nr = MINOR (inode->i_rdev);
  printk(KERN_INFO "release " S2I_FILTER_NAME " %d\n", cam_nr);

  if (atomic_read_acquire(&queue_parameter[cam_nr]->grab_flag) == GRAB_FLAG_RUNNING)
    ioctl_cmd_stop_grab(cam_nr);
  
  opened = 0; 
  nonblock = 0;
  return 0;
}


static struct file_operations s2iGEVFilter_fops =
{
   owner:   THIS_MODULE,
#if LINUX_VERSION_CODE>= KERNEL_VERSION(3,0,13)
    unlocked_ioctl: s2iGEVFilter_unlocked_ioctl,
#else
    ioctl:   s2iGEVFilter_ioctl,
#endif
   open:    s2iGEVFilter_open,
   read:    s2iGEVFilter_read,
   release: s2iGEVFilter_release,
};

#if LINUX_VERSION_CODE <= KERNEL_VERSION(3,3,0)
typedef mode_t devnode_mode_t;
#else
typedef umode_t devnode_mode_t;
#endif

struct net* our_net_namespace;

static int __init s2iGEVFilter_init(void)
{
    int result,i;
    char lstr[20];
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4,13,0)
//    struct net *init_net;
#endif

    result = register_chrdev(S2IGEVFILTER_MAJOR, S2I_FILTER_NAME, &s2iGEVFilter_fops);
    if (result < 0)
    {
        printk(KERN_WARNING S2I_FILTER_NAME ": can't get major %d\n", S2IGEVFILTER_MAJOR);
        return 1;
    }
    
    netfilter_ops.hook              =       (nf_hookfn *)main_hook;
    netfilter_ops.pf                =       PF_INET;  
#if LINUX_VERSION_CODE>= KERNEL_VERSION(2,6,24) 
    netfilter_ops.hooknum           =       0;
#else
    netfilter_ops.hooknum           =       NF_IP_PRE_ROUTING;
#endif
    netfilter_ops.priority          =       NF_IP_PRI_FIRST;

    for(i = 0;i < CAMERA_COUNT;i++)
    {  
       struct grab_param *grab;
       grab = grab_parameter[i] = kmalloc (sizeof( struct grab_param ), GFP_KERNEL);
       memset(grab_parameter[i],0,sizeof( struct grab_param ));
       filter_parameter[i] = kmalloc(sizeof( struct filter_param ), GFP_KERNEL);
       memset(filter_parameter[i],0, sizeof( struct filter_param ));
       grab->time_param = &(filter_parameter[i]->time);
       InitTimeStats(i);
       
       grab->resend_param = resend_packet_parameter[i] = kmalloc (sizeof( struct resend_packet_param  ), GFP_KERNEL);
       memset(resend_packet_parameter[i],0,sizeof( struct resend_packet_param  ));

       grab->queue = queue_parameter[i] = kmalloc (sizeof( struct queue_param ), GFP_KERNEL);
       memset(queue_parameter[i],0,sizeof( struct queue_param ));

       atomic_set_release(&queue_parameter[i]->grab_flag, GRAB_FLAG_STOPPED);
       OsInitQueue(queue_parameter[i]);
    }

#if LINUX_VERSION_CODE >= KERNEL_VERSION(4,13,0)
    nf_register_net_hook((our_net_namespace = current->nsproxy->net_ns), &netfilter_ops);
    if (our_net_namespace != &init_net) {
        printk(KERN_WARNING "registered hook on netns%p. Init had netns%p",
               our_net_namespace, &init_net);
    }
#else
    nf_register_hook(&netfilter_ops);
#endif    
    cam_cnt = 0;

    sprintf(lstr,"V%d.%d.%d",DRIVER_MAJOR_VERSION,DRIVER_MINOR_VERSION >> 4, DRIVER_MINOR_VERSION & 0x0f);
    printk(KERN_INFO "init module " S2I_FILTER_NAME " %s\n",lstr);
    return mc_SetupMemento();
}

static void __exit s2iGEVFilter_fini(void)
{
  int i;
  mc_CleanupMemento();
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4,13,0)
  nf_unregister_net_hook(our_net_namespace, &netfilter_ops);
#else
  nf_unregister_hook(&netfilter_ops); 
#endif    
  
  unregister_chrdev(S2IGEVFILTER_MAJOR, S2I_FILTER_NAME);

  for(i = 0;i < CAMERA_COUNT;i++)
  {  
    kfree (grab_parameter[i]);
    CloseImageQueue(queue_parameter[i]);
    CloseTimeStats(i);
    kfree (filter_parameter[i]);
    kfree (resend_packet_parameter[i]);
    kfree (queue_parameter[i]);
  }
}

module_init(s2iGEVFilter_init);
module_exit(s2iGEVFilter_fini);


