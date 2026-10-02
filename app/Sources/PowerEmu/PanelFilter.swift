import CoreImage
import Foundation

/*
 * Period Mac display emulation, over the guest's screen.
 *
 * The maths is PocketShaver's -- compositor_shaders.metal, apply_panel_filter
 * -- unchanged except for the plumbing.  A Core Image kernel is the cheapest
 * way to reach it from here, because the guest's screen is already a CALayer
 * backed by an IOSurface and CALayer.filters composites on the GPU without a
 * copy or a second render path.
 *
 * It is written in the Core Image Kernel Language rather than Metal.  The
 * Metal form is the supported one and app/Resources/PanelFilters.ci.metal
 * holds the same kernel ready for it, but building that needs Xcode's Metal
 * toolchain (xcodebuild -downloadComponent MetalToolchain), which is a
 * multi-gigabyte download this build does not require.  CIKL has been
 * deprecated since 10.14 and still compiles and renders; when the toolchain
 * is present, loading the metallib is the only change needed here.
 *
 * The 4x4 Bayer matrix is computed rather than looked up, because CIKL has no
 * arrays.  Writing the table as 4*A + B:
 *
 *      0  8  2 10        A: 0 2 0 2     B: 0 0 2 2
 *     12  4 14  6           3 1 3 1        0 0 2 2
 *      3 11  1  9           0 2 0 2        3 3 1 1
 *     15  7 13  5           3 1 3 1        3 3 1 1
 *
 * A depends on whether x and y are odd, B on whether they are past the
 * halfway point -- so both fall out of two comparisons each.
 */
enum PanelFilters {

    /// 0 is off; the rest match PocketShaver's numbering.
    static let choices: [(Int, String)] = [
        (0, "None"),
        (1, "Grayscale LCD"),
        (2, "Passive Color (DSTN)"),
        (3, "Active Color (TFT)"),
        (4, "Color CRT"),
        (5, "Grayscale CRT"),
        (6, "4-bit Passive"),
        (7, "1-bit CRT"),
    ]

    static func name(_ mode: Int) -> String {
        choices.first { $0.0 == mode }?.1 ?? "None"
    }

    static let source = """
    float panelLum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

    vec3 toneGray(vec3 rgb) {
        float l = panelLum(rgb);
        l = mix(0.05, 0.95, l);
        l = floor(l * 15.0 + 0.5) / 15.0;
        return clamp(l * vec3(0.92, 1.0, 0.94), 0.0, 1.0);
    }

    vec3 tonePassive(vec3 rgb) {
        float l = panelLum(rgb);
        vec3 c = mix(vec3(l), rgb, 0.55);
        c = mix(vec3(0.10, 0.10, 0.14), vec3(0.86, 0.86, 0.92), c);
        return clamp(c, 0.0, 1.0);
    }

    vec3 toneActive(vec3 rgb) {
        float l = panelLum(rgb);
        vec3 c = mix(vec3(l), rgb, 1.18);
        return clamp(c * vec3(0.99, 1.0, 1.02), 0.0, 1.0);
    }

    float bayer(vec2 p) {
        float ix = mod(floor(p.x), 4.0);
        float iy = mod(floor(p.y), 4.0);
        float cx = mod(ix, 2.0), cy = mod(iy, 2.0);
        float hx = step(2.0, ix),  hy = step(2.0, iy);
        float a = mix(mix(0.0, 2.0, cx), mix(3.0, 1.0, cx), cy);
        float b = mix(mix(0.0, 2.0, hx), mix(3.0, 1.0, hx), hy);
        return (a * 4.0 + b + 0.5) / 16.0;
    }

    vec3 crt(vec3 rgb, vec2 pos, vec2 uv, float colorMask) {
        float scan = 0.78 + 0.22 * (0.5 + 0.5 * cos(pos.y * 3.14159265));
        float col = mod(floor(pos.x), 3.0);
        vec3 mask = mix(mix(vec3(1.0, 0.72, 0.72), vec3(0.72, 1.0, 0.72), step(0.5, col)),
                        vec3(0.72, 0.72, 1.0), step(1.5, col));
        mask = mix(vec3(1.0), mask, colorMask);
        vec2 d = uv - vec2(0.5);
        float vig = clamp(1.0 - dot(d, d) * 0.7, 0.0, 1.0);
        vec3 c = rgb * scan * mix(vec3(1.0), mask, 0.22) * vig;
        return clamp(c * 1.18, 0.0, 1.0);
    }

    kernel vec4 panel(__sample s, float mode, float w, float h) {
        vec2 pos = destCoord();
        vec2 uv = vec2(pos.x / max(w, 1.0), pos.y / max(h, 1.0));
        vec3 rgb = s.rgb;
        vec3 o = rgb;
        if (mode < 0.5)       { o = rgb; }
        else if (mode < 1.5)  { o = toneGray(rgb); }
        else if (mode < 2.5)  { o = tonePassive(rgb); }
        else if (mode < 3.5)  { o = toneActive(rgb); }
        else if (mode < 4.5)  { o = crt(rgb, pos, uv, 1.0); }
        else if (mode < 5.5)  { o = crt(vec3(panelLum(rgb)), pos, uv, 0.0); }
        else if (mode < 6.5)  { o = floor(tonePassive(rgb) * 3.0 + 0.5) / 3.0; }
        else                  { o = crt(vec3(step(bayer(pos), panelLum(rgb))), pos, uv, 0.0); }
        return vec4(o, s.a);
    }
    """

    /// Built once; nil if the kernel will not compile, in which case the
    /// screen is simply left alone.
    static let kernel: CIKernel? = {
        let k = CIKernel(source: source)
        if k == nil { NSLog("PowerEmu: the panel filter kernel did not compile; filters are off") }
        return k
    }()
}

/// A CIFilter wrapper, because CALayer.filters takes filters, not kernels.
final class PanelFilter: CIFilter {
    @objc dynamic var inputImage: CIImage?
    @objc dynamic var inputMode: NSNumber = 0
    @objc dynamic var inputWidth: NSNumber = 0
    @objc dynamic var inputHeight: NSNumber = 0

    override var outputImage: CIImage? {
        guard let inputImage, let kernel = PanelFilters.kernel,
              inputMode.intValue > 0 else { return inputImage }
        let extent = inputImage.extent
        // The guest's size, not the layer's: scanlines and the phosphor mask
        // are meant to sit on the guest's pixels.
        let w = inputWidth.doubleValue > 0 ? inputWidth.doubleValue : Double(extent.width)
        let h = inputHeight.doubleValue > 0 ? inputHeight.doubleValue : Double(extent.height)
        return kernel.apply(extent: extent, roiCallback: { _, r in r },
                            arguments: [inputImage, Double(inputMode.intValue), w, h])
    }
}
