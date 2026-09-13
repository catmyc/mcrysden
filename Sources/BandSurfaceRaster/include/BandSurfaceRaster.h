#ifndef BANDSURFACERASTER_H
#define BANDSURFACERASTER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Rasterize flat-shaded, opaque triangles with a greater-than depth test into
/// an RGBA8 premultiplied-last pixel buffer.
///
/// `xyzd` contains 9 floats per triangle: x, y and viewer depth for the three
/// vertices, in buffer-local pixel coordinates (0,0 is the buffer's first
/// row/column). `rgb` contains 3 bytes per triangle. A pixel is covered when
/// its barycentric coordinates are all >= 0; the depth convention matches the
/// band-surface renderer (larger depth = nearer to the viewer).
void band_surface_raster_triangles_opaque(uint8_t *pixels,
                                          float *depth_buffer,
                                          int width,
                                          int height,
                                          const float *xyzd,
                                          const uint8_t *rgb,
                                          int triangle_count);

/// Rasterize one convex parallelogram quad with bilinearly interpolated depth
/// and source-over premultiplied alpha blending. Corners are ordered (0,0),
/// (1,0), (1,1), (0,1) so p1 = p0 + U and p3 = p0 + V. `depth_write` mirrors
/// the Swift z-buffer rule: translucent planes test depth but do not write it.
void band_surface_raster_quad_blended(uint8_t *pixels,
                                      float *depth_buffer,
                                      int width,
                                      int height,
                                      const float *xyzd,
                                      float sr,
                                      float sg,
                                      float sb,
                                      float sa,
                                      int depth_write);

#ifdef __cplusplus
}
#endif

#endif /* BANDSURFACERASTER_H */
