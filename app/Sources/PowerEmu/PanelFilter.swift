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
 * The kernel itself lives in app/Resources/PanelFilters.ci.metal and is
 * compiled by scripts/build-app.sh into PanelFilters.ci.metallib beside the
 * app's other resources.  That is the one copy of it; there is no second
 * transcription here to drift out of step.
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

    /// Loaded once from the bundle; nil leaves the screen alone.
    static let kernel: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "PanelFilters.ci", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            NSLog("PowerEmu: PanelFilters.ci.metallib is missing; display filters are off")
            return nil
        }
        do {
            return try CIKernel(functionName: "panelFilter", fromMetalLibraryData: data)
        } catch {
            NSLog("PowerEmu: the panel filter kernel did not load: %@", error.localizedDescription)
            return nil
        }
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
        let args: [Any] = [inputImage, Double(inputMode.intValue), w, h]
        /*
         * panelFilter takes a sample_t, which makes it a CIColorKernel, and a
         * colour kernel is applied without a region-of-interest callback --
         * it only ever reads the pixel it is writing.  Calling CIKernel's
         * apply(extent:roiCallback:arguments:) on it returned nothing, so the
         * layer had a filter that produced no image and the guest's screen
         * rendered blank.  That went unnoticed for as long as the setting
         * never reached the live view.
         */
        let out = (kernel as? CIColorKernel)?.apply(extent: extent, arguments: args)
            ?? kernel.apply(extent: extent, roiCallback: { _, r in r }, arguments: args)
        /*
         * And if it still produces nothing, show the guest unfiltered.  A
         * display filter is decoration; it must never be the reason the
         * machine cannot be seen.
         */
        return out ?? inputImage
    }
}
