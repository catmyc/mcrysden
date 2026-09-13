#include "BandSurfaceRaster.h"

#include <limits.h>
#include <math.h>
#include <stddef.h>

static uint8_t bs_byte(float value) {
    if (!isfinite(value) || value <= 0.0f) return 0;
    if (value >= 1.0f) return 255;
    return (uint8_t)(value * 255.0f + 0.5f);
}

static float bs_min3(float a, float b, float c) { return fminf(a, fminf(b, c)); }
static float bs_max3(float a, float b, float c) { return fmaxf(a, fmaxf(b, c)); }
static int bs_finite3(float a, float b, float c) {
    return isfinite(a) && isfinite(b) && isfinite(c);
}

/// Convert a 1D screen-space span [lo, hi] to the inclusive integer pixel range
/// used by the legacy Swift rasterizer:
///   min = clamp(floor(lo), 0, limit-1)
///   max = clamp(ceil(hi),  0, limit-1)
/// without ever casting a non-finite or out-of-range float to int (UB).
/// Returns 0 when the span misses the buffer or is non-finite.
static int bs_pixel_bounds(float lo, float hi, int limit, int *out_lo, int *out_hi) {
    if (!isfinite(lo) || !isfinite(hi) || limit <= 0) return 0;
    // Entire span right of the buffer, or entirely left of the first pixel
    // centre (ceil(hi) <= -1, matching the old min(width-1, ceil(hi))).
    if (lo >= (float)limit || hi <= -1.0f) return 0;
    int lo_i = (lo <= 0.0f) ? 0 : (int)floorf(lo);
    int hi_i = (hi >= (float)(limit - 1)) ? (limit - 1) : (int)ceilf(hi);
    if (lo_i > hi_i) return 0;
    *out_lo = lo_i;
    *out_hi = hi_i;
    return 1;
}

static int bs_buffer_size_ok(int width, int height) {
    // Pixel indexing below uses int products. AppKit never gets close to this,
    // but keep the C API fail-closed even for adversarial direct callers.
    return width > 0 && height > 0 &&
           (double)width * (double)height <= (double)INT_MAX;
}

void band_surface_raster_triangles_opaque(uint8_t *pixels,
                                          float *depth_buffer,
                                          int width,
                                          int height,
                                          const float *xyzd,
                                          const uint8_t *rgb,
                                          int triangle_count) {
    if (pixels == NULL || depth_buffer == NULL || xyzd == NULL || rgb == NULL ||
        !bs_buffer_size_ok(width, height) || triangle_count <= 0) {
        return;
    }

    for (int tri = 0; tri < triangle_count; ++tri) {
        const float *v = xyzd + tri * 9;
        const uint8_t *c = rgb + tri * 3;
        const float ax = v[0], ay = v[1], da = v[2];
        const float bx = v[3], by = v[4], db = v[5];
        const float cx = v[6], cy = v[7], dc = v[8];
        if (!bs_finite3(ax, ay, da) || !bs_finite3(bx, by, db) ||
            !bs_finite3(cx, cy, dc)) {
            continue;
        }

        int min_x, max_x, min_y, max_y;
        if (!bs_pixel_bounds(bs_min3(ax, bx, cx), bs_max3(ax, bx, cx),
                             width, &min_x, &max_x) ||
            !bs_pixel_bounds(bs_min3(ay, by, cy), bs_max3(ay, by, cy),
                             height, &min_y, &max_y)) {
            continue;
        }

        const float v0x = bx - ax, v0y = by - ay;
        const float v1x = cx - ax, v1y = cy - ay;
        const float d00 = v0x * v0x + v0y * v0y;
        const float d01 = v0x * v1x + v0y * v1y;
        const float d11 = v1x * v1x + v1y * v1y;
        const float denom = d00 * d11 - d01 * d01;
        if (!isfinite(denom) || denom == 0.0f) continue;
        const float inv_denom = 1.0f / denom;

        // Barycentric edge increments. The depth is affine in (v, w):
        // depth = da + v*(db-da) + w*(dc-da).
        const float dvdx = (d11 * v0x - d01 * v1x) * inv_denom;
        const float dwdx = (d00 * v1x - d01 * v0x) * inv_denom;
        const float dzdx = (db - da) * dvdx + (dc - da) * dwdx;

        const uint8_t r = c[0], g = c[1], b = c[2];
        float d20y = ((float)min_x - ax) * v0x + ((float)min_y - ay) * v0y;
        float d21y = ((float)min_x - ax) * v1x + ((float)min_y - ay) * v1y;
        for (int y = min_y; y <= max_y; ++y) {
            float d20 = d20y;
            float d21 = d21y;
            float vv = (d11 * d20 - d01 * d21) * inv_denom;
            float ww = (d00 * d21 - d01 * d20) * inv_denom;
            float depth = da + vv * (db - da) + ww * (dc - da);
            int row = y * width;
            for (int x = min_x; x <= max_x; ++x) {
                if (isfinite(vv) && isfinite(ww) && isfinite(depth) &&
                    vv >= 0.0f && ww >= 0.0f && vv + ww <= 1.0f &&
                    depth > depth_buffer[row + x]) {
                    int o = (row + x) * 4;
                    depth_buffer[row + x] = depth;
                    pixels[o] = r;
                    pixels[o + 1] = g;
                    pixels[o + 2] = b;
                    pixels[o + 3] = 255;
                }
                vv += dvdx;
                ww += dwdx;
                depth += dzdx;
            }
            d20y += v0y;
            d21y += v1y;
        }
    }
}

void band_surface_raster_quad_blended(uint8_t *pixels,
                                      float *depth_buffer,
                                      int width,
                                      int height,
                                      const float *xyzd,
                                      float sr,
                                      float sg,
                                      float sb,
                                      float sa,
                                      int depth_write) {
    if (pixels == NULL || depth_buffer == NULL || xyzd == NULL ||
        !bs_buffer_size_ok(width, height)) {
        return;
    }

    const float x0 = xyzd[0], y0 = xyzd[1], d0 = xyzd[2];
    const float x1 = xyzd[3], y1 = xyzd[4], d1 = xyzd[5];
    const float x2 = xyzd[6], y2 = xyzd[7], d2 = xyzd[8];
    const float x3 = xyzd[9], y3 = xyzd[10], d3 = xyzd[11];
    if (!bs_finite3(x0, y0, d0) || !bs_finite3(x1, y1, d1) ||
        !bs_finite3(x2, y2, d2) || !bs_finite3(x3, y3, d3)) {
        return;
    }

    int min_x, max_x, min_y, max_y;
    if (!bs_pixel_bounds(bs_min3(bs_min3(x0, x1, x2), x3, x3),
                         bs_max3(bs_max3(x0, x1, x2), x3, x3),
                         width, &min_x, &max_x) ||
        !bs_pixel_bounds(bs_min3(bs_min3(y0, y1, y2), y3, y3),
                         bs_max3(bs_max3(y0, y1, y2), y3, y3),
                         height, &min_y, &max_y)) {
        return;
    }

    const float ux = x1 - x0, uy = y1 - y0;
    const float vx = x3 - x0, vy = y3 - y0;
    const float denom = ux * vy - uy * vx;
    if (!isfinite(denom) || fabsf(denom) <= 1.0e-6f) return;

    const float inv_denom = 1.0f / denom;
    const float pr = sr * sa, pg = sg * sa, pb = sb * sa;

    for (int y = min_y; y <= max_y; ++y) {
        int row = y * width;
        for (int x = min_x; x <= max_x; ++x) {
            const float qx = (float)x - x0;
            const float qy = (float)y - y0;
            const float st = (qx * vy - qy * vx) * inv_denom;
            const float tt = (ux * qy - uy * qx) * inv_denom;
            if (!isfinite(st) || !isfinite(tt) ||
                st < 0.0f || tt < 0.0f || st > 1.0f || tt > 1.0f) {
                continue;
            }
            const float w00 = (1.0f - st) * (1.0f - tt);
            const float w10 = st * (1.0f - tt);
            const float w11 = st * tt;
            const float w01 = (1.0f - st) * tt;
            const float depth = w00 * d0 + w10 * d1 + w11 * d2 + w01 * d3;
            if (!isfinite(depth)) continue;
            int i = row + x;
            if (depth <= depth_buffer[i]) continue;

            int o = i * 4;
            const float dr = (float)pixels[o] / 255.0f;
            const float dg = (float)pixels[o + 1] / 255.0f;
            const float db = (float)pixels[o + 2] / 255.0f;
            const float da = (float)pixels[o + 3] / 255.0f;
            const float oa = sa + da * (1.0f - sa);
            const float or = pr + dr * (1.0f - sa);
            const float og = pg + dg * (1.0f - sa);
            const float ob = pb + db * (1.0f - sa);
            pixels[o] = bs_byte(or);
            pixels[o + 1] = bs_byte(og);
            pixels[o + 2] = bs_byte(ob);
            pixels[o + 3] = bs_byte(oa);
            if (depth_write) depth_buffer[i] = depth;
        }
    }
}
