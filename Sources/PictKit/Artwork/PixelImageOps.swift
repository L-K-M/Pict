import Foundation

/// Pure-Swift pixel operations on `PixelImage`, the Linux counterparts of the Core
/// Graphics steps in `IconBitmap`/`IconNormalizer`. Platform-neutral: on macOS they
/// exist only to be exercised by tests (the shipping path is still Core Graphics);
/// on Linux they are the whole raster backend behind the LP-03 seam.
///
/// `PixelImage` is **premultiplied** RGBA, which is exactly the space these ops want
/// — averaging, scaling, corner-masking and shadow compositing are all correct on
/// premultiplied samples (the same reason Core Graphics uses premultiplied bitmap
/// contexts).
extension PixelImage {

    // MARK: Resampling

    /// Resamples so the longest edge is `longestEdge`, never upscaling — the same
    /// contract as `IconBitmap.downsample`. Area-averages each destination cell's
    /// source footprint.
    public func downsample(longestEdge: Int) -> PixelImage {
        let sourceLongest = Swift.max(width, height)
        guard longestEdge > 0, sourceLongest > longestEdge else { return self }
        let scale = Double(longestEdge) / Double(sourceLongest)
        let newWidth = Swift.max(1, Int((Double(width) * scale).rounded()))
        let newHeight = Swift.max(1, Int((Double(height) * scale).rounded()))
        return areaAveraged(toWidth: newWidth, height: newHeight)
    }

    /// Area-averaging resize, used for any shrink (downsample, and the render path
    /// when the layout scales the artwork down).
    func areaAveraged(toWidth newWidth: Int, height newHeight: Int) -> PixelImage {
        guard newWidth > 0, newHeight > 0 else { return self }
        var out = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        samples.withUnsafeBufferPointer { src in
            for outRow in 0..<newHeight {
                let y0 = outRow * height / newHeight
                let y1 = Swift.max(y0 + 1, (outRow + 1) * height / newHeight)
                for outColumn in 0..<newWidth {
                    let x0 = outColumn * width / newWidth
                    let x1 = Swift.max(x0 + 1, (outColumn + 1) * width / newWidth)
                    var sum = (0, 0, 0, 0)
                    var count = 0
                    for sy in y0..<y1 {
                        let rowBase = sy * width
                        for sx in x0..<x1 {
                            let i = (rowBase + sx) * 4
                            sum.0 += Int(src[i]); sum.1 += Int(src[i + 1])
                            sum.2 += Int(src[i + 2]); sum.3 += Int(src[i + 3])
                            count += 1
                        }
                    }
                    let n = Swift.max(count, 1)
                    let o = (outRow * newWidth + outColumn) * 4
                    out[o] = UInt8(sum.0 / n); out[o + 1] = UInt8(sum.1 / n)
                    out[o + 2] = UInt8(sum.2 / n); out[o + 3] = UInt8(sum.3 / n)
                }
            }
        }
        return PixelImage(width: newWidth, height: newHeight, samples: out)!
    }

    /// General bilinear resize (up or down). The render path uses it to scale the
    /// artwork to its equal-ink size; downscales go through `areaAveraged` for
    /// quality, upscales and near-unity scales through here.
    func resampled(toWidth newWidth: Int, height newHeight: Int) -> PixelImage {
        guard newWidth > 0, newHeight > 0 else { return self }
        if newWidth == width, newHeight == height { return self }
        if newWidth < width, newHeight < height { return areaAveraged(toWidth: newWidth, height: newHeight) }

        var out = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        let scaleX = Double(width) / Double(newWidth)
        let scaleY = Double(height) / Double(newHeight)
        samples.withUnsafeBufferPointer { src in
            func at(_ x: Int, _ y: Int, _ c: Int) -> Double {
                let cx = Swift.min(Swift.max(x, 0), width - 1)
                let cy = Swift.min(Swift.max(y, 0), height - 1)
                return Double(src[(cy * width + cx) * 4 + c])
            }
            for outRow in 0..<newHeight {
                let fy = (Double(outRow) + 0.5) * scaleY - 0.5
                let y0 = Int(fy.rounded(.down))
                let ty = fy - Double(y0)
                for outColumn in 0..<newWidth {
                    let fx = (Double(outColumn) + 0.5) * scaleX - 0.5
                    let x0 = Int(fx.rounded(.down))
                    let tx = fx - Double(x0)
                    let o = (outRow * newWidth + outColumn) * 4
                    for c in 0..<4 {
                        let top = at(x0, y0, c) * (1 - tx) + at(x0 + 1, y0, c) * tx
                        let bottom = at(x0, y0 + 1, c) * (1 - tx) + at(x0 + 1, y0 + 1, c) * tx
                        let value = top * (1 - ty) + bottom * ty
                        out[o + c] = UInt8(Swift.min(255, Swift.max(0, value.rounded())))
                    }
                }
            }
        }
        return PixelImage(width: newWidth, height: newHeight, samples: out)!
    }

    // MARK: Cropping / placement

    /// The sub-rectangle `[x, x+w) × [y, y+h)`, clamped to bounds. Used to trim an
    /// icon's transparent margin before scaling.
    func cropped(x: Int, y: Int, width cropWidth: Int, height cropHeight: Int) -> PixelImage {
        let x0 = Swift.min(Swift.max(x, 0), width)
        let y0 = Swift.min(Swift.max(y, 0), height)
        let x1 = Swift.min(Swift.max(x + cropWidth, 0), width)
        let y1 = Swift.min(Swift.max(y + cropHeight, 0), height)
        let w = x1 - x0
        let h = y1 - y0
        // An empty intersection (the rect lies fully outside the image) would
        // otherwise force `Swift.max(1, …)` into a 1-pixel read whose source index
        // starts past the sample buffer. Not reachable from `normalize` — the
        // ink-bounds crop is always non-empty — but `cropped` is a general helper.
        guard w > 0, h > 0 else { return PixelImage(width: 1, height: 1, samples: [0, 0, 0, 0])! }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        samples.withUnsafeBufferPointer { src in
            for row in 0..<h {
                let srcBase = ((y0 + row) * width + x0) * 4
                let dstBase = (row * w) * 4
                for i in 0..<(w * 4) { out[dstBase + i] = src[srcBase + i] }
            }
        }
        return PixelImage(width: w, height: h, samples: out)!
    }

    /// A transparent `side × side` canvas with `self` centred on it (clipped if it
    /// overflows). Row 0 is the top, matching the whole seam's convention.
    func centred(onCanvasSide side: Int) -> PixelImage {
        guard side > 0 else { return self }
        var out = [UInt8](repeating: 0, count: side * side * 4)
        let originX = (side - width) / 2
        let originY = (side - height) / 2
        samples.withUnsafeBufferPointer { src in
            for row in 0..<height {
                let destRow = originY + row
                guard destRow >= 0, destRow < side else { continue }
                for column in 0..<width {
                    let destColumn = originX + column
                    guard destColumn >= 0, destColumn < side else { continue }
                    let s = (row * width + column) * 4
                    let d = (destRow * side + destColumn) * 4
                    out[d] = src[s]; out[d + 1] = src[s + 1]
                    out[d + 2] = src[s + 2]; out[d + 3] = src[s + 3]
                }
            }
        }
        return PixelImage(width: side, height: side, samples: out)!
    }

    // MARK: Corner masking

    /// Clips to a rounded rectangle by multiplying every pixel by its coverage — the
    /// pure counterpart of `IconBitmap.maskingCorners`. Because the samples are
    /// premultiplied, scaling the whole RGBA tuple by the coverage scales the alpha
    /// correctly. Corner edges are antialiased by 4×4-supersampling the coverage.
    public func maskingCorners(radiusFraction: Double) -> PixelImage {
        // Clamp to half the short side: beyond that the four corner arcs overlap and
        // `roundedRectCoverage` erodes the middle of each edge instead of producing a
        // capsule. The shipping caller (`fullBleedCornerRadiusFraction`) is well under
        // 0.5; this only hardens the public entry point against larger fractions.
        let radius = Swift.min(radiusFraction, 0.5) * Double(Swift.min(width, height))
        guard radius > 0 else { return self }
        let r = radius
        var out = samples
        // Corner centres; a pixel fully outside all four corner squares has coverage 1.
        for row in 0..<height {
            for column in 0..<width {
                // Cheap reject: only pixels inside a corner square can be < full.
                let inCornerColumn = Double(column) < r || Double(column + 1) > Double(width) - r
                let inCornerRow = Double(row) < r || Double(row + 1) > Double(height) - r
                guard inCornerColumn && inCornerRow else { continue }
                let coverage = Self.roundedRectCoverage(column: column, row: row,
                                                         width: width, height: height, radius: r)
                if coverage < 1 {
                    let i = (row * width + column) * 4
                    for c in 0..<4 { out[i + c] = UInt8((Double(out[i + c]) * coverage).rounded()) }
                }
            }
        }
        return PixelImage(width: width, height: height, samples: out)!
    }

    /// Fraction of the pixel `[column, column+1) × [row, row+1)` inside the rounded
    /// rectangle, by 4×4 supersampling.
    private static func roundedRectCoverage(column: Int, row: Int, width: Int, height: Int,
                                            radius r: Double) -> Double {
        let w = Double(width), h = Double(height)
        let sub = 4
        var inside = 0
        for sy in 0..<sub {
            let py = Double(row) + (Double(sy) + 0.5) / Double(sub)
            for sx in 0..<sub {
                let px = Double(column) + (Double(sx) + 0.5) / Double(sub)
                let dx = Swift.max(r - px, px - (w - r), 0)
                let dy = Swift.max(r - py, py - (h - r), 0)
                if dx * dx + dy * dy <= r * r { inside += 1 }
            }
        }
        return Double(inside) / Double(sub * sub)
    }

    // MARK: Drop shadow

    /// Composites `self` over its own soft drop shadow: a blurred, downward-offset,
    /// black silhouette of the alpha channel at `alpha` opacity. The pure counterpart
    /// of Core Graphics' `setShadow` in `IconNormalizer.render`.
    ///
    /// **Down is +row here.** `PixelImage` is top-down, so a positive `offsetFraction`
    /// moves the shadow toward larger row indices — the bottom of the image. That
    /// matches the Core Graphics path, whose bottom-up context offsets by negative y
    /// (also down); the shadow-asymmetry test pins the sign.
    ///
    /// The fractions are taken against this image's `side`, which the render path has
    /// already sized to the bleed-inclusive canvas (`.centred(onCanvasSide:)`). That
    /// is the same base the Core Graphics path multiplies these fractions by —
    /// `IconNormalizer.render`'s `canvas = Double(canvasSide)` — so the two platforms
    /// place the shadow at the same geometry, not off by `(1 + 2·bleed)`.
    func withDropShadow(offsetFraction: Double, blurFraction: Double, alpha: Double) -> PixelImage {
        let side = width
        guard side > 0, side == height else { return self }

        // The silhouette: this image's alpha, offset down, blurred, at `alpha`.
        let offset = Int((Double(side) * offsetFraction).rounded())
        let blurRadius = Swift.max(1, Int((Double(side) * blurFraction).rounded()))

        var silhouette = [Double](repeating: 0, count: side * side)
        samples.withUnsafeBufferPointer { src in
            for row in 0..<side {
                let destRow = row + offset
                guard destRow >= 0, destRow < side else { continue }
                for column in 0..<side {
                    silhouette[destRow * side + column] = Double(src[(row * side + column) * 4 + 3])
                }
            }
        }
        // Gaussian ≈ three box blurs.
        for _ in 0..<3 { silhouette = Self.boxBlur(silhouette, side: side, radius: blurRadius) }

        var out = samples
        out.withUnsafeMutableBufferPointer { dst in
            for index in 0..<(side * side) {
                // Shadow is premultiplied black: rgb = 0, a = silhouette * alpha.
                let shadowAlpha = silhouette[index] * alpha            // 0...255
                let i = index * 4
                let topAlpha = Double(dst[i + 3])
                let cover = (255 - topAlpha) / 255                     // shadow shows where art doesn't
                // over-composite (premultiplied): out = top + bottom * (1 - topAlpha)
                dst[i + 3] = UInt8(Swift.min(255, (topAlpha + shadowAlpha * cover).rounded()))
                // rgb of the shadow is 0, so top's rgb is unchanged.
            }
        }
        return PixelImage(width: side, height: side, samples: out)!
    }

    /// Separable box blur of a scalar plane (used for the alpha silhouette).
    private static func boxBlur(_ plane: [Double], side: Int, radius: Int) -> [Double] {
        guard radius > 0 else { return plane }
        let window = Double(2 * radius + 1)
        var horizontal = [Double](repeating: 0, count: side * side)
        for row in 0..<side {
            let base = row * side
            for column in 0..<side {
                var sum = 0.0
                for k in -radius...radius {
                    let c = Swift.min(Swift.max(column + k, 0), side - 1)
                    sum += plane[base + c]
                }
                horizontal[base + column] = sum / window
            }
        }
        var blurred = [Double](repeating: 0, count: side * side)
        for column in 0..<side {
            for row in 0..<side {
                var sum = 0.0
                for k in -radius...radius {
                    let rr = Swift.min(Swift.max(row + k, 0), side - 1)
                    sum += horizontal[rr * side + column]
                }
                blurred[row * side + column] = sum / window
            }
        }
        return blurred
    }
}
