import AppKit
import Metal
import MetalKit
import simd

/// Printing support for the current viewport layer.
///
/// `PrintSupport` renders the layer currently visible in the viewer — the live
/// Metal canvas scene, or the displayed band/DOS/color-plane graph — to an
/// `NSImage` at print resolution (2 px/pt) that the controller hands to
/// `NSPrintOperation`. The Metal path mirrors `PngExporter`/`RasterExporter`:
/// a throwaway `Renderer` encodes into an offscreen texture via the shared
/// `Renderer.encode(to:target:viewport:camera:)` path, export labels are
/// composited on top, and the result is wrapped in an `NSImage`. The graph path
/// draws the view into a bitmap at the page size.
///
/// Validation is total: absurd page sizes throw instead of trapping on an
/// `Int` cast or allocating a pathological buffer, and the 16 000 000
/// total-pixel cap is enforced with overflow-checked arithmetic.
enum PrintSupport {
    enum PrintError: Error, LocalizedError {
        case invalidPageSize(String)
        case pixelCapExceeded
        case noGPU
        case noRenderTarget
        case labelViewportMismatch(viewport: SIMD2<Float>, pixels: (width: Int, height: Int))
        case noImage
        case noCommandQueue
        case noCommandBuffer
        case encodeFailed
        case commandBufferError(Error?)

        var errorDescription: String? {
            switch self {
            case .invalidPageSize(let message):
                return message
            case .pixelCapExceeded:
                return "Print dimensions exceed the 16 million pixel cap"
            case .noGPU:
                return "No Metal GPU available for printing"
            case .noRenderTarget:
                return "Could not allocate a print-resolution render target"
            case .labelViewportMismatch(let viewport, let pixels):
                return "Print label viewport (\(viewport.x), \(viewport.y)) does not match "
                    + "the print pixel dimensions (\(pixels.width), \(pixels.height))"
            case .noImage:
                return "Could not create an image from the printed output"
            case .noCommandQueue:
                return "Could not create a Metal command queue"
            case .noCommandBuffer:
                return "Could not create a Metal command buffer"
            case .encodeFailed:
                return "Metal render encoding failed"
            case .commandBufferError(let error):
                return "GPU error during printing: \(error?.localizedDescription ?? "unknown")"
            }
        }
    }

    /// Render scale: 2 pixels per point. At 72 points/inch this yields 144 DPI,
    /// a good balance between sharpness and the total-pixel cap.
    static let scale: CGFloat = 2.0

    /// Total-pixel cap shared with the PNG/vector exporters.
    static let maxTotalPixels = 16_000_000

    /// Per-axis texture dimension cap matching the Metal maximum 2D texture size.
    static let maxAxisDimension: Int = 16_384

    /// The printable page rect for a print info: paper size minus margins.
    static func pageRect(for printInfo: NSPrintInfo) -> NSRect {
        let paper = printInfo.paperSize
        let vertical = printInfo.topMargin + printInfo.bottomMargin
        let horizontal = printInfo.leftMargin + printInfo.rightMargin
        return NSRect(x: 0, y: 0,
                      width: max(0, paper.width - horizontal),
                      height: max(0, paper.height - vertical))
    }

    /// Validate a page rect and return the pixel dimensions at the render scale.
    /// Throws on non-finite/non-positive sizes, Int overflow, or exceeding the
    /// per-axis / total-pixel caps — never traps.
    static func pixelDimensions(for pageRect: NSRect,
                                scale: CGFloat = scale) throws -> (width: Int, height: Int) {
        guard pageRect.width.isFinite, pageRect.height.isFinite,
              pageRect.width > 0, pageRect.height > 0 else {
            throw PrintError.invalidPageSize("page size must be finite and positive")
        }
        let pixelWidth = pageRect.width * scale
        let pixelHeight = pageRect.height * scale
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= CGFloat(Int.max), pixelHeight <= CGFloat(Int.max) else {
            throw PrintError.invalidPageSize("page size is not representable in pixels")
        }
        let width = Int(pixelWidth.rounded())
        let height = Int(pixelHeight.rounded())
        guard width >= 1, height >= 1 else {
            throw PrintError.invalidPageSize("page rounds to zero pixels")
        }
        guard width <= maxAxisDimension, height <= maxAxisDimension else {
            throw PrintError.invalidPageSize("page exceeds the maximum texture dimension")
        }
        let total = width.multipliedReportingOverflow(by: height)
        guard !total.overflow, total.partialValue <= maxTotalPixels else {
            throw PrintError.pixelCapExceeded
        }
        return (width, height)
    }

    // MARK: - Metal scene

    /// Render the Metal scene to a printable image at the page rect.
    ///
    /// The scene is passed by value and never mutated: the renderer works on a
    /// copy. Labels in `labels` are drawn by `PngExporter.composite` at their
    /// `x`/`y` positions directly in the output image's pixel coordinate space,
    /// so they MUST be projected for `pixelViewport` — the pixel dimensions of
    /// the page (`pixelDimensions(for: pageRect)`), not the point dimensions.
    /// Passing a point-space viewport here would land every label at half its
    /// intended position relative to the rendered structure.
    static func renderMetalScene(scene: Scene,
                                 camera: Camera,
                                 labels: [LabelOverlayView.Label],
                                 pixelViewport: SIMD2<Float>,
                                 pageRect: NSRect,
                                 scale: CGFloat = scale) throws -> NSImage {
        let (width, height) = try pixelDimensions(for: pageRect, scale: scale)
        // The label projection viewport must match the render target in pixels;
        // a mismatch is the scale bug this parameter name exists to prevent.
        // This is a THROWN check, not an assert: asserts are compiled out in
        // Release, which would let a shipping build silently print every label
        // at the wrong position instead of reporting a recoverable failure.
        guard pixelViewport.x == Float(width), pixelViewport.y == Float(height) else {
            throw PrintError.labelViewportMismatch(viewport: pixelViewport,
                                                   pixels: (width, height))
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw PrintError.noGPU }
        let renderer: Renderer
        do {
            renderer = try Renderer(device: device)
        } catch {
            throw PrintError.noGPU
        }
        renderer.scene = scene
        renderer.msaaSampleCount = scene.msaaSampleCount
        renderer.showBZLandmarks = false
        renderer.coordinationNumbers = []
        renderer.showCoordinationColors = false
        renderer.selectedKPathNode = nil
        renderer.displacementArrows = []
        renderer.showDisplacementArrows = false

        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PrintError.noRenderTarget
        }
        guard let queue = device.makeCommandQueue() else { throw PrintError.noCommandQueue }
        guard let commandBuffer = queue.makeCommandBuffer() else { throw PrintError.noCommandBuffer }

        // A zero quaternion is not a valid rotation; normalize to identity.
        var camera = camera
        if camera.rotation == simd_quatf(ix: 0, iy: 0, iz: 0, r: 0) {
            camera.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let metalViewport = MTLViewport(originX: 0, originY: 0,
                                        width: Double(width), height: Double(height),
                                        znear: 0, zfar: 1)
        guard renderer.encode(to: commandBuffer, target: texture,
                              viewport: metalViewport, camera: camera) else {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            throw PrintError.encodeFailed
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw PrintError.commandBufferError(error) }

        // Read back the rendered pixels.
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw PrintError.noImage
        }
        guard let rendered = context.makeImage() else { throw PrintError.noImage }

        // Composite export labels (atom symbols, bond distances, scale bar, route
        // nodes) using the same path as PNG export. Labels are drawn at their
        // x/y in the image's pixel space, which is why they must have been
        // projected for the pixel viewport.
        let composited = try PngExporter.composite(labels: labels, onto: rendered)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(NSBitmapImageRep(cgImage: composited))
        return image
    }

    // MARK: - Graph view

    /// Render a graph view (band/DOS/color-plane) to a printable image at the
    /// page rect. The view draws itself into a bitmap at print resolution; a
    /// white background is filled first so the graph reads on paper.
    ///
    /// The view is temporarily resized to the pixel dimensions so its
    /// `draw(_:)` fills the bitmap at print resolution. The original frame is
    /// restored in `defer`. This is safe because: (1) the resize and draw are
    /// synchronous on the main thread, with no run-loop turn in between; (2)
    /// `draw(_:)` is called directly — not `display()` — so AppKit does not
    /// schedule an automatic redraw that could observe the temporary frame;
    /// (3) the frame is restored before any layout pass can run. The caller
    /// must be on the main thread.
    static func renderGraph<View: NSView>(_ view: View,
                                          pageRect: NSRect,
                                          scale: CGFloat = scale) throws -> NSImage {
        let (width, height) = try pixelDimensions(for: pageRect, scale: scale)
        let pixelSize = NSSize(width: width, height: height)

        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else {
            throw PrintError.noImage
        }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw PrintError.noImage
        }

        let originalFrame = view.frame
        view.setFrameSize(pixelSize)
        defer { view.setFrameSize(originalFrame.size) }

        NSGraphicsContext.saveGraphicsState()
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)

        // Opaque white paper background.
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        view.draw(view.bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = bitmap.cgImage else { throw PrintError.noImage }
        let image = NSImage(size: pixelSize)
        image.addRepresentation(NSBitmapImageRep(cgImage: cgImage))
        return image
    }
}
