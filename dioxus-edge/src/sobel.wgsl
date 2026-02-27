struct Params {
    width: u32,
    height: u32,
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read> input: array<u32>;
@group(0) @binding(2) var<storage, read_write> output: array<u32>;

// Each element in input/output holds one pixel value (0-255) stored as u32.
// This avoids byte-packing complexity and atomic operations.

fn read_pixel(x: u32, y: u32) -> i32 {
    return i32(input[y * params.width + x]);
}

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let x = gid.x;
    let y = gid.y;

    if x >= params.width || y >= params.height {
        return;
    }

    // Border pixels get 0
    if x == 0u || y == 0u || x >= params.width - 1u || y >= params.height - 1u {
        output[y * params.width + x] = 0u;
        return;
    }

    // Sobel Gx kernel: [[-1,0,1],[-2,0,2],[-1,0,1]]
    var sum_x: i32 = 0;
    sum_x -= read_pixel(x - 1u, y - 1u);
    sum_x += read_pixel(x + 1u, y - 1u);
    sum_x -= 2 * read_pixel(x - 1u, y);
    sum_x += 2 * read_pixel(x + 1u, y);
    sum_x -= read_pixel(x - 1u, y + 1u);
    sum_x += read_pixel(x + 1u, y + 1u);

    // Sobel Gy kernel: [[-1,-2,-1],[0,0,0],[1,2,1]]
    var sum_y: i32 = 0;
    sum_y -= read_pixel(x - 1u, y - 1u);
    sum_y -= 2 * read_pixel(x, y - 1u);
    sum_y -= read_pixel(x + 1u, y - 1u);
    sum_y += read_pixel(x - 1u, y + 1u);
    sum_y += 2 * read_pixel(x, y + 1u);
    sum_y += read_pixel(x + 1u, y + 1u);

    let mag = sqrt(f32(sum_x * sum_x + sum_y * sum_y));
    let pixel_val = min(u32(mag), 255u);

    output[y * params.width + x] = pixel_val;
}
