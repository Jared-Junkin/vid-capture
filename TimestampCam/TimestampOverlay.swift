import CoreVideo
import CoreText
import UIKit

/// Burns `HH:MM:SS:MMM` into the top-right corner of a frame.
///
/// The camera hands us 4:2:0 YCbCr -- the format the hardware encoder also
/// wants -- so the frame passes through untouched apart from the corner we
/// write. Asking for BGRA instead would force a full-frame colour conversion on
/// every frame purely to make drawing convenient; this touches roughly a
/// 400x150 rectangle out of two million pixels.
///
/// Glyphs are rasterised once at launch into 8-bit masks, so drawing a
/// timestamp is a blend of pre-made bitmaps. No text layout, no allocation and
/// no per-pixel arithmetic beyond one blend happens while recording.
final class TimestampOverlay {

    /// Video-range luma: 16 is black, 235 is white.
    private static let black: UInt8 = 16
    private static let white = 235
    private static let neutralChroma: Int32 = 128

    private struct Mask {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private struct Layout {
        let atlas: [Mask]        // indices 0...9 are digits, 10 is a colon
        let labelLocal: Mask
        let labelUTC: Mask
        let labelUnverified: Mask
        let cell: Int            // uniform advance per digit
        let lineHeight: Int
        let box: (x: Int, y: Int, width: Int, height: Int)
    }

    private static let colon = 10
    private static let timeDigits = 12   // HH:MM:SS:MMM

    private var layout: Layout?
    private var layoutDegraded = false
    private var localDigits = [Int](repeating: 0, count: timeDigits)
    private var utcDigits = [Int](repeating: 0, count: timeDigits)

    /// Draws the timestamp for `unix` into the buffer, in place.
    func draw(into buffer: CVPixelBuffer, unix: Double, gmtOffset: Int, degraded: Bool) {
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        if layout == nil || layoutDegraded != degraded {
            layout = build(forWidth: width, height: height, degraded: degraded)
            layoutDegraded = degraded
        }
        guard let layout else { return }

        let unixMs = Int64((unix * 1000).rounded(.down))
        fill(&localDigits, unixMs: unixMs, gmtOffset: gmtOffset)
        fill(&utcDigits, unixMs: unixMs, gmtOffset: 0)

        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { return }

        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let box = layout.box

        // Dark plate behind the text, and neutral chroma over the same region so
        // the digits read white rather than tinted by whatever was underneath.
        for row in box.y..<min(box.y + box.height, height) {
            memset(luma + row * lumaStride + box.x, Int32(Self.black), box.width)
        }
        for row in (box.y / 2)..<min((box.y + box.height) / 2, height / 2) {
            memset(chromaBase + row * chromaStride + box.x, Self.neutralChroma, box.width)
        }

        var y = box.y + layout.lineHeight / 6
        drawLine(localDigits, label: layout.labelLocal, at: y,
                 layout: layout, luma: luma, stride: lumaStride, width: width, height: height)
        y += layout.lineHeight
        drawLine(utcDigits, label: layout.labelUTC, at: y,
                 layout: layout, luma: luma, stride: lumaStride, width: width, height: height)

        if degraded {
            y += layout.lineHeight
            let mask = layout.labelUnverified
            blend(mask, x: box.x + box.width - mask.width - layout.cell / 2, y: y,
                  luma: luma, stride: lumaStride, width: width, height: height)
        }
    }

    private func drawLine(_ digits: [Int], label: Mask, at y: Int, layout: Layout,
                          luma: UnsafeMutablePointer<UInt8>, stride: Int,
                          width: Int, height: Int) {
        var x = layout.box.x + layout.cell / 2
        for index in digits {
            let mask = layout.atlas[index]
            // Centre each glyph in a fixed cell so the digits never shift as
            // the numbers change.
            blend(mask, x: x + (layout.cell - mask.width) / 2, y: y,
                  luma: luma, stride: stride, width: width, height: height)
            x += layout.cell
        }
        blend(label, x: x + layout.cell / 2, y: y,
              luma: luma, stride: stride, width: width, height: height)
    }

    private func blend(_ mask: Mask, x: Int, y: Int,
                       luma: UnsafeMutablePointer<UInt8>, stride: Int,
                       width: Int, height: Int) {
        for row in 0..<mask.height {
            let destinationY = y + row
            if destinationY < 0 || destinationY >= height { continue }
            let destination = luma + destinationY * stride
            let source = row * mask.width
            for column in 0..<mask.width {
                let destinationX = x + column
                if destinationX < 0 || destinationX >= width { continue }
                let alpha = Int(mask.pixels[source + column])
                if alpha == 0 { continue }
                let under = Int(destination[destinationX])
                destination[destinationX] = UInt8((under * (255 - alpha) + Self.white * alpha) / 255)
            }
        }
    }

    /// Converts Unix milliseconds into twelve glyph indices, with no allocation
    /// and no calendar lookup.
    private func fill(_ output: inout [Int], unixMs: Int64, gmtOffset: Int) {
        let shifted = unixMs + Int64(gmtOffset) * 1000
        var milliseconds = Int(shifted % 1000)
        if milliseconds < 0 { milliseconds += 1000 }
        let seconds = Int((shifted - Int64(milliseconds)) / 1000)
        let secondOfDay = ((seconds % 86_400) + 86_400) % 86_400

        let hours = secondOfDay / 3600
        let minutes = (secondOfDay % 3600) / 60
        let secs = secondOfDay % 60

        output[0] = hours / 10
        output[1] = hours % 10
        output[2] = Self.colon
        output[3] = minutes / 10
        output[4] = minutes % 10
        output[5] = Self.colon
        output[6] = secs / 10
        output[7] = secs % 10
        output[8] = Self.colon
        output[9] = milliseconds / 100
        output[10] = (milliseconds / 10) % 10
        output[11] = milliseconds % 10
    }

    // MARK: - One-time rasterisation

    private func build(forWidth width: Int, height: Int, degraded: Bool) -> Layout {
        let pointSize = max(18.0, Double(width) / 26.0)
        let font = UIFont.monospacedSystemFont(ofSize: pointSize, weight: .bold)
        let labelFont = UIFont.monospacedSystemFont(ofSize: pointSize * 0.55, weight: .semibold)

        let atlas = (0...10).map { index -> Mask in
            rasterise(index == Self.colon ? ":" : String(index), font: font)
        }
        let cell = (atlas.map(\.width).max() ?? 1) + 1
        let labelLocal = rasterise("LOCAL", font: labelFont)
        let labelUTC = rasterise("UTC", font: labelFont)
        let labelUnverified = rasterise("UNVERIFIED", font: labelFont)

        let lineHeight = atlas[0].height + Int(pointSize * 0.25)
        let lines = degraded ? 3 : 2
        var boxWidth = cell * Self.timeDigits + cell + labelLocal.width + cell
        var boxHeight = lineHeight * lines + lineHeight / 3

        boxWidth = min(boxWidth + boxWidth % 2, width)
        boxHeight = min(boxHeight + boxHeight % 2, height)

        let margin = Int(pointSize * 0.4) & ~1
        let boxX = max(0, (width - boxWidth - margin)) & ~1
        let boxY = margin

        return Layout(atlas: atlas,
                      labelLocal: labelLocal,
                      labelUTC: labelUTC,
                      labelUnverified: labelUnverified,
                      cell: cell,
                      lineHeight: lineHeight,
                      box: (boxX, boxY, boxWidth, boxHeight))
    }

    /// Renders text into an 8-bit grey bitmap used as an alpha mask.
    private func rasterise(_ text: String, font: UIFont) -> Mask {
        let attributed = NSAttributedString(string: text,
                                            attributes: [.font: font,
                                                         .foregroundColor: UIColor.white])
        let line = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        let width = max(1, Int(ceil(advance)) + 2)
        let height = max(1, Int(ceil(ascent + descent)) + 2)

        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data
        else {
            return Mask(width: 1, height: 1, pixels: [0])
        }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textPosition = CGPoint(x: 1, y: descent + 1)
        CTLineDraw(line, context)

        let raw = data.assumingMemoryBound(to: UInt8.self)
        return Mask(width: width,
                    height: height,
                    pixels: Array(UnsafeBufferPointer(start: raw, count: width * height)))
    }
}
