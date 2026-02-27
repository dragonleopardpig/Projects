use image::{GrayImage, ImageBuffer};
use wgpu::util::DeviceExt;

#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct Params {
    width: u32,
    height: u32,
}

pub struct GpuSobel {
    device: wgpu::Device,
    queue: wgpu::Queue,
    pipeline: wgpu::ComputePipeline,
    bind_group_layout: wgpu::BindGroupLayout,
}

impl GpuSobel {
    /// Attempt to initialize GPU compute. Returns None if GPU is unavailable.
    pub fn new() -> Option<Self> {
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::VULKAN | wgpu::Backends::GL,
            ..Default::default()
        });

        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: None,
            force_fallback_adapter: false,
        }))?;

        eprintln!("GPU Sobel: using adapter {:?}", adapter.get_info().name);

        let (device, queue) = pollster::block_on(adapter.request_device(
            &wgpu::DeviceDescriptor {
                label: Some("sobel-device"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::default(),
                ..Default::default()
            },
            None,
        ))
        .ok()?;

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("sobel-shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("sobel.wgsl").into()),
        });

        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("sobel-bgl"),
            entries: &[
                // Params uniform
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::COMPUTE,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                // Input storage (read-only)
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::COMPUTE,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Storage { read_only: true },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                // Output storage (read-write)
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::COMPUTE,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Storage { read_only: false },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
            ],
        });

        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("sobel-pl"),
            bind_group_layouts: &[&bind_group_layout],
            push_constant_ranges: &[],
        });

        let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some("sobel-pipeline"),
            layout: Some(&pipeline_layout),
            module: &shader,
            entry_point: Some("main"),
            compilation_options: Default::default(),
            cache: None,
        });

        Some(Self {
            device,
            queue,
            pipeline,
            bind_group_layout,
        })
    }

    /// Run Sobel edge detection on grayscale pixels using the GPU.
    pub fn detect_edges(&self, gray: &[u8], width: u32, height: u32) -> GrayImage {
        let pixel_count = (width * height) as usize;

        // Expand u8 → u32 for GPU buffer (one u32 per pixel)
        let input_u32: Vec<u32> = gray.iter().map(|&b| b as u32).collect();

        let params = Params { width, height };

        let param_buf = self
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("params"),
                contents: bytemuck::bytes_of(&params),
                usage: wgpu::BufferUsages::UNIFORM,
            });

        let input_buf = self
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("input"),
                contents: bytemuck::cast_slice(&input_u32),
                usage: wgpu::BufferUsages::STORAGE,
            });

        let output_buf = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("output"),
            size: (pixel_count * 4) as u64,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });

        let readback_buf = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("readback"),
            size: (pixel_count * 4) as u64,
            usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("sobel-bg"),
            layout: &self.bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: param_buf.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: input_buf.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: output_buf.as_entire_binding(),
                },
            ],
        });

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("sobel-encoder"),
            });

        {
            let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("sobel-pass"),
                timestamp_writes: None,
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, &bind_group, &[]);
            // Dispatch enough workgroups to cover all pixels (16x16 workgroup size)
            let wg_x = (width + 15) / 16;
            let wg_y = (height + 15) / 16;
            pass.dispatch_workgroups(wg_x, wg_y, 1);
        }

        encoder.copy_buffer_to_buffer(&output_buf, 0, &readback_buf, 0, (pixel_count * 4) as u64);
        self.queue.submit(std::iter::once(encoder.finish()));

        // Map readback buffer and wait
        let slice = readback_buf.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |result| {
            let _ = tx.send(result);
        });
        self.device.poll(wgpu::Maintain::Wait);
        rx.recv().unwrap().unwrap();

        let data = slice.get_mapped_range();
        let output_u32: &[u32] = bytemuck::cast_slice(&data);

        // Pack u32 → u8
        let pixels: Vec<u8> = output_u32.iter().map(|&v| v.min(255) as u8).collect();
        drop(data);
        readback_buf.unmap();

        ImageBuffer::from_raw(width, height, pixels).unwrap()
    }
}
