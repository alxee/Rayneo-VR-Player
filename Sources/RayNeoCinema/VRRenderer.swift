// VRRenderer.swift — Metal renderer with per-eye VR reprojection.
//
// Port of the IINA plugin's lib/vr-shader.js GLSL (itself validated against
// ffmpeg 9 v360 at 65 dB PSNR) to Metal. Geometry is identical:
//   dir = Ry(yaw) * Rx(-pitch) * Rz(-roll) * normalize(nx*tan(h/2),
//                                                       ny*tan(v/2), 1)
//   equirect:  u = (lon + pi) / 2pi
//   hequirect: u = (lon + pi/2) / pi   (black outside, behind the camera)
//   v = 0.5 - lat/pi ; packed-SBS sample x = u*0.5 + eye*0.5
// Each output half is a ray viewport matching one eye's half of the output
// drawable (16:9 on the glasses' 3840×1080 panel — each eye occupies exactly
// 1920×1080).
//
// The key advantage over the mpv path: head tracking is a plain uniform
// write per frame (setFragmentBytes) — no recompilation, no filter rebuild,
// so the view tracks the IMU at the display's full refresh rate.

import Metal
import MetalKit
import CoreVideo

/// Must match VRParams in the MSL source (all 4-byte fields, 48 bytes).
struct VRParams {
    var yaw: Float = 0        // degrees
    var pitch: Float = 0      // degrees
    var roll: Float = 0       // degrees
    var vfov: Float = 60      // degrees, vertical FOV of each eye view
    var projection: UInt32 = 0 // 0 = equirect (360), 1 = hequirect (180)
    /// 0 passthroughSBS · 1 ouToSbs · 2 collapseToOneEye (windowed) ·
    /// 3 sphericalStereo · 4 sphericalMono · 5 ouToSbsPanel · 6 monoPerEyePanel
    var outputMode: UInt32 = 0
    /// 0 = windowed view, 1 = the drawable is the glasses' 3840×1080 panel.
    /// On the panel, passthrough must FILL (the stretch unsqueezes half-SBS);
    /// in a window, flat modes letterbox to the source's own aspect.
    var panelMode: UInt32 = 0
    /// Full drawable aspect (width / height) — used by the flat full-frame
    /// modes, unlike `aspect` which is the per-eye half used by spherical.
    var viewAspect: Float = 16.0 / 9.0
    /// 0 = source sbs, 1 = source ou, 2 = source mono (spherical sampling)
    var inputFormat: UInt32 = 2
    var mirror: UInt32 = 0    // swap left/right eyes
    /// 0 = single BGRA texture (texture 0), 1 = YUV 4:2:0 planes (textures 1+2)
    var inputLayout: UInt32 = 0
    /// Per-eye ray-viewport aspect (width / height of one eye's half of the
    /// drawable). 16:9 on the glasses panel; recomputed per draw so windowed
    /// spherical views stay unstretched at any window shape.
    var aspect: Float = 16.0 / 9.0
}

final class VRRenderer: NSObject {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    /// Current video textures: texture 0 = BGRA (if the buffer is BGRA),
    /// textures 1+2 = YUV 4:2:0 luma/chroma planes (otherwise). The format is
    /// auto-detected per frame.
    private var cvTexture: CVMetalTexture?
    private var cvLuma: CVMetalTexture?
    private var cvChroma: CVMetalTexture?

    var params = VRParams()

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw NSError(domain: "VRRenderer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot create Metal command queue"])
        }
        self.queue = queue

        // Preserve the compiler's diagnostics — a struct mismatch between the
        // Swift VRParams and the MSL VRParams surfaces here at first launch.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.msl, options: nil)
        } catch {
            throw NSError(domain: "VRRenderer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "shader compile failed: \(error)"])
        }
        guard let vertex = library.makeFunction(name: "vsMain"),
              let fragment = library.makeFunction(name: "fsMain") else {
            throw NSError(domain: "VRRenderer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "cannot compile Metal shader"])
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else {
            throw NSError(domain: "VRRenderer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "cannot create render pipeline"])
        }
        self.pipeline = pipeline

        // 12 × 4-byte fields — keep in lockstep with the MSL VRParams.
        assert(MemoryLayout<VRParams>.stride == 48, "VRParams layout drifted from the MSL struct")

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        super.init()
    }

    /// Hand the latest decoded frame to the renderer. Pixel format is
    /// auto-detected: BGRA buffers bind as texture 0; 4:2:0 buffers bind as
    /// luma (texture 1, r8Unorm) + chroma (texture 2, rg8Unorm) with BT.709
    /// conversion in-shader — the zero-copy path, no host-side conversion.
    func setPixelBuffer(_ pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer, let textureCache else {
            cvTexture = nil; cvLuma = nil; cvChroma = nil
            return
        }
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if fmt == kCVPixelFormatType_32BGRA {
            cvTexture = makeTexture(pixelBuffer, plane: 0, format: .bgra8Unorm,
                                    width: CVPixelBufferGetWidth(pixelBuffer),
                                    height: CVPixelBufferGetHeight(pixelBuffer))
            cvLuma = nil
            cvChroma = nil
        } else {
            // Assume 4:2:0 biplanar video.
            cvTexture = nil
            cvLuma = makeTexture(pixelBuffer, plane: 0, format: .r8Unorm,
                                 width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                                 height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0))
            cvChroma = makeTexture(pixelBuffer, plane: 1, format: .rg8Unorm,
                                   width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                                   height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1))
        }
    }

    private func makeTexture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, width: Int, height: Int) -> CVMetalTexture? {
        guard let textureCache else { return nil }
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, format,
            width, height, plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    /// The texture sampled as "the video": BGRA texture when present, else luma.
    func currentTexture() -> MTLTexture? {
        if let t = cvTexture.flatMap(CVMetalTextureGetTexture) { return t }
        return cvLuma.flatMap(CVMetalTextureGetTexture)
    }

    /// Render one frame. `clearOnly` presents the black-cleared drawable when
    /// no video frame is available yet — an unpresented CAMetalLayer shows
    /// white, which is why a "waiting for first frame" state must still
    /// present. Never returns with an open encoder (Metal aborts on that —
    /// the SIGABRT in -[_MTLCommandEncoder dealloc]).
    func draw(in view: MTKView, clearOnly: Bool = false) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commandBuffer = queue.makeCommandBuffer(),
              let rpe = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }
        if !clearOnly, let texture = currentTexture() {
            // Keep the ray geometry matched to the actual per-eye viewport.
            let ds = view.drawableSize
            if ds.height > 0 {
                params.aspect = Float(ds.width / 2 / ds.height)
                params.viewAspect = Float(ds.width / ds.height)
            }
            rpe.setRenderPipelineState(pipeline)
            rpe.setFragmentTexture(texture, index: 0)
            if let luma = cvLuma.flatMap(CVMetalTextureGetTexture) {
                rpe.setFragmentTexture(luma, index: 1)
            }
            if let chroma = cvChroma.flatMap(CVMetalTextureGetTexture) {
                rpe.setFragmentTexture(chroma, index: 2)
            }
            rpe.setFragmentBytes(&params, length: MemoryLayout<VRParams>.stride, index: 0)
            // Fullscreen triangle strip.
            rpe.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        rpe.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Shader source

    /// Conventions carried over from the validated GLSL: fragment coords uv
    /// have y=0 at the TOP of the output; texture v=0 is the top scanline.
    static let msl = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct VRParams {
        float yaw;
        float pitch;
        float roll;
        float vfov;
        uint projection;
        uint outputMode;
        uint panelMode;   // 0 = window, 1 = glasses panel (flat modes fill, window letterboxes)
        float viewAspect; // full drawable aspect; `aspect` is the per-eye half
        uint inputFormat;
        uint mirror;
        uint inputLayout; // 0 = BGRA (texture 0), 1 = YUV 4:2:0 planes (textures 1+2)
        float aspect;     // per-eye ray viewport aspect (width/height of one eye's half)
    };

    struct VOut {
        float4 pos [[position]];
        float2 uv;   // y = 0 at the TOP of the drawable (video convention)
    };

    vertex VOut vsMain(uint vid [[vertex_id]]) {
        float2 pos[4] = { {-1.0, -1.0}, {1.0, -1.0}, {-1.0, 1.0}, {1.0, 1.0} };
        VOut o;
        o.pos = float4(pos[vid], 0.0, 1.0);
        o.uv = float2((pos[vid].x + 1.0) * 0.5, 1.0 - (pos[vid].y + 1.0) * 0.5);
        return o;
    }

    /// Aspect-FIT (letterbox) mapping: viewport coords e ∈ [0,1]² → source
    /// coords for a frame of aspect `srcA` shown complete inside a viewport
    /// of aspect `viewA`. Sampling expands past the frame edge exactly where
    /// the black bars are — the caller bounds-checks and paints black.
    float2 fitUV(float2 e, float srcA, float viewA) {
        float2 k = float2(max(1.0, viewA / srcA), max(1.0, srcA / viewA));
        return (e - 0.5) * k + 0.5;
    }

    /// Out-of-frame test for fitUV results.
    bool outside(float2 uv) {
        return uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0;
    }

    fragment float4 fsMain(VOut in [[stage_in]],
                           texture2d<float> tex [[texture(0)]],
                           texture2d<float> yTex [[texture(1)]],
                           texture2d<float> cTex [[texture(2)]],
                           constant VRParams& p [[buffer(0)]]) {
        constexpr sampler s(mag_filter::linear, min_filter::linear,
                            address::clamp_to_edge);
        float2 uv = in.uv;
        float2 suv;

        // ---- flat output modes -------------------------------------------------
        uint sw, sh;
        if (p.inputLayout == 1u) { sw = yTex.get_width(); sh = yTex.get_height(); }
        else                     { sw = tex.get_width();  sh = tex.get_height(); }
        float srcA = float(sw) / max(1.0, float(sh));

        if (p.outputMode == 0) {
            // passthroughSBS: the untouched stereo pair shown as-is. On the
            // glasses panel it FILLS — the horizontal stretch is exactly what
            // unsqueezes half-SBS to per-eye 16:9 (the IINA plugin's 32:9
            // aspect override). In a window it letterboxes to the pair's own
            // aspect instead of squashing a 2:1 pair or stretching a 32:9 one.
            if (p.panelMode == 1u) {
                suv = uv;
            } else {
                suv = fitUV(uv, srcA, p.viewAspect);
                if (outside(suv)) return float4(0.0, 0.0, 0.0, 1.0);
            }
        } else if (p.outputMode == 1) {
            // ouToSbs: left output half <- top source half, right <- bottom.
            float eye = uv.x < 0.5 ? 0.0 : 1.0;
            suv = float2(uv.x, uv.y * 0.5 + eye * 0.5);
        } else if (p.outputMode == 5u) {
            // ouToSbsPanel: over/under source on the glasses panel — each eye
            // half of the panel samples its stacked half of the source.
            // (Windowed ouToSbs assumes uv spans the full frame; on the panel
            // that would split every eye's view in half.)
            float eye = uv.x < 0.5 ? 0.0 : 1.0;
            suv = float2(fract(uv.x * 2.0), uv.y * 0.5 + eye * 0.5);
        } else if (p.outputMode == 6u) {
            // monoPerEyePanel: a mono frame letterboxed into EACH eye's half,
            // both eyes identical. A full-panel passthrough would put the
            // left half of the picture in the left eye and the right half in
            // the right eye — the "split in the middle" view.
            float2 e = float2(fract(uv.x * 2.0), uv.y);
            suv = fitUV(e, srcA, p.aspect);
            if (outside(suv)) return float4(0.0, 0.0, 0.0, 1.0); // letterbox bars
        } else if (p.outputMode == 2u) {
            // collapseToOneEye: one eye (left, or top for OU) shown complete
            // and aspect-fit — windowed it fills the window with bars; on the
            // panel it letterboxes into each eye's half (both eyes identical).
            float rectW, rectH, eyeA;
            if (p.inputFormat == 0u)      { rectW = 0.5; rectH = 1.0; eyeA = srcA * 0.5; }
            else if (p.inputFormat == 1u) { rectW = 1.0; rectH = 0.5; eyeA = srcA * 2.0; }
            else                          { rectW = 1.0; rectH = 1.0; eyeA = srcA; }
            float2 e = uv;
            if (p.panelMode == 1u) { e = float2(fract(uv.x * 2.0), uv.y); rectW *= 0.5; }
            float viewA = p.panelMode == 1u ? p.aspect : p.viewAspect;
            suv = fitUV(e, eyeA, viewA) * float2(rectW, rectH);
            if (outside(suv)) return float4(0.0, 0.0, 0.0, 1.0);
        } else {
            // ---- spherical output modes ---------------------------------------
            float eye = uv.x < 0.5 ? 0.0 : 1.0;
            if (p.mirror != 0u) eye = 1.0 - eye;
            float nx = fract(uv.x * 2.0) * 2.0 - 1.0;
            float ny = 1.0 - uv.y * 2.0;

            float tv = tan(p.vfov * (M_PI_F / 180.0) * 0.5);
            float3 d = normalize(float3(nx * tv * p.aspect, ny * tv, 1.0));

            float cr = cos(p.roll * (M_PI_F / 180.0)), sr = -sin(p.roll * (M_PI_F / 180.0));
            d = float3(d.x * cr - d.y * sr, d.x * sr + d.y * cr, d.z);
            float cp = cos(p.pitch * (M_PI_F / 180.0)), sp = sin(p.pitch * (M_PI_F / 180.0));
            d = float3(d.x, d.y * cp + d.z * sp, -d.y * sp + d.z * cp);
            float cy = cos(p.yaw * (M_PI_F / 180.0)), sy = sin(p.yaw * (M_PI_F / 180.0));
            d = float3(d.x * cy + d.z * sy, d.y, -d.x * sy + d.z * cy);

            float lon = atan2(d.x, d.z);
            float lat = asin(clamp(d.y, -1.0, 1.0));
            float su;
            if (p.projection == 1u) {
                // hequirect: 180° wide, black outside (behind the camera).
                su = (lon + M_PI_F * 0.5) / M_PI_F;
                if (su < 0.0 || su > 1.0) return float4(0.0, 0.0, 0.0, 1.0);
            } else {
                su = (lon + M_PI_F) / (2.0 * M_PI_F);
            }
            float sv = 0.5 - lat / M_PI_F;

            if (p.outputMode == 3u) {
                // sphericalStereo: per-eye halves of the source pair.
                if (p.inputFormat == 0u)      suv = float2(su * 0.5 + eye * 0.5, sv);
                else if (p.inputFormat == 1u) suv = float2(su, sv * 0.5 + eye * 0.5);
                else                          suv = float2(su, sv);
            } else {
                // sphericalMono: one re-projected view for both eyes.
                suv = float2(su, sv);
            }
        }

        // ---- sample with the active input layout ------------------------------
        float3 rgb;
        if (p.inputLayout == 1u) {
            // YUV 4:2:0 video range → RGB, BT.709 (plane 1 is CbCr).
            float yy = 1.164 * (yTex.sample(s, suv).r - 0.0625);
            float2 cbcr = cTex.sample(s, suv).rg - 0.5;
            rgb = float3(yy + 1.793 * cbcr.y,
                         yy - 0.213 * cbcr.x - 0.533 * cbcr.y,
                         yy + 2.112 * cbcr.x);
        } else {
            rgb = tex.sample(s, suv).rgb;
        }
        return float4(rgb, 1.0);
    }
    """#
}
