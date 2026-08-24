#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A small grid of alpha samples taken off a `CGImage`, used to reason about an
/// icon's shape without keeping the full-resolution bitmap around.
///
/// The grid keeps the source's aspect ratio (a 2:1 image samples into a 2:1 grid),
/// so a shape's proportions survive the downsample. Row 0 is whichever edge Core
/// Graphics drew first; every measurement here is symmetric under flipping, so it
/// makes no difference which.
public struct AlphaMask: Equatable {

    /// A rectangle of grid cells, inclusive on all four edges.
    public struct InkBounds: Equatable {
        public let minRow: Int
        public let maxRow: Int
        public let minColumn: Int
        public let maxColumn: Int

        public init(minRow: Int, maxRow: Int, minColumn: Int, maxColumn: Int) {
            self.minRow = minRow
            self.maxRow = maxRow
            self.minColumn = minColumn
            self.maxColumn = maxColumn
        }

        public var rowCount: Int { maxRow - minRow + 1 }
        public var columnCount: Int { maxColumn - minColumn + 1 }
    }

    public let width: Int
    public let height: Int

    /// Row-major alpha samples, `width * height` of them.
    public let samples: [UInt8]

    /// How finely the diagonal is walked when measuring corner reach. Finer than
    /// the grid so the measurement isn't quantised to whole cells.
    private static let diagonalSteps = 256

    /// Builds a mask from raw samples, or `nil` when the dimensions don't match.
    /// Exposed so tests can measure synthetic shapes without Core Graphics.
    public init?(width: Int, height: Int, samples: [UInt8]) {
        guard width > 0, height > 0, samples.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.samples = samples
    }

    /// The valid `longestEdge` range for the samplers. The floor keeps a corner
    /// radius resolving to several cells; the ceiling bounds the ~`longestEdge`²
    /// grid allocation. A request outside `minLongestEdge...maxLongestEdge` makes the
    /// initializers return `nil` rather than trap or over-allocate.
    public static let minLongestEdge = 8
    public static let maxLongestEdge = 4096

    /// Grid dimensions for a `sourceWidth × sourceHeight` source whose longest edge
    /// maps to `longestEdge` — or `nil` for a degenerate or out-of-range request.
    /// Both sampling paths route through this, so they cannot drift; and, like the
    /// other failable initializers here, an extreme `longestEdge` returns `nil`
    /// rather than trapping the `Int(_:)` conversion or overflowing the sample
    /// allocation.
    static func gridSize(sourceWidth: Int, sourceHeight: Int, longestEdge: Int) -> (width: Int, height: Int)? {
        guard sourceWidth > 0, sourceHeight > 0,
              longestEdge >= minLongestEdge, longestEdge <= maxLongestEdge else { return nil }
        let longest = Swift.max(sourceWidth, sourceHeight)
        let gridWidth = Swift.max(1, Int((Double(sourceWidth) / Double(longest) * Double(longestEdge)).rounded()))
        let gridHeight = Swift.max(1, Int((Double(sourceHeight) / Double(longest) * Double(longestEdge)).rounded()))
        return (gridWidth, gridHeight)
    }

    /// Samples a `PixelImage`'s alpha channel onto a grid whose longest edge is
    /// `longestEdge` (valid range `minLongestEdge...maxLongestEdge`; out of range
    /// returns `nil`), area-averaging each cell's source footprint. A box filter, so
    /// cell values can differ slightly from the CG path's resampling — grid
    /// dimensions and classification agree, exact samples don't. The pure-Swift
    /// counterpart of `init(image:longestEdge:)`, routed through the same `gridSize`
    /// and the raw-samples initializer.
    public init?(pixelImage: PixelImage, longestEdge: Int) {
        guard let grid = AlphaMask.gridSize(sourceWidth: pixelImage.width,
                                            sourceHeight: pixelImage.height,
                                            longestEdge: longestEdge) else { return nil }
        let sourceWidth = pixelImage.width
        let sourceHeight = pixelImage.height
        let gridWidth = grid.width
        let gridHeight = grid.height

        var alpha = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        pixelImage.samples.withUnsafeBufferPointer { source in
            for gridRow in 0..<gridHeight {
                let y0 = gridRow * sourceHeight / gridHeight
                let y1 = Swift.max(y0 + 1, (gridRow + 1) * sourceHeight / gridHeight)
                for gridColumn in 0..<gridWidth {
                    let x0 = gridColumn * sourceWidth / gridWidth
                    let x1 = Swift.max(x0 + 1, (gridColumn + 1) * sourceWidth / gridWidth)
                    var sum = 0
                    var count = 0
                    for sourceRow in y0..<y1 {
                        let rowBase = sourceRow * sourceWidth
                        for sourceColumn in x0..<x1 {
                            sum += Int(source[(rowBase + sourceColumn) * 4 + 3])
                            count += 1
                        }
                    }
                    alpha[gridRow * gridWidth + gridColumn] = UInt8(sum / Swift.max(count, 1))
                }
            }
        }

        self.init(width: gridWidth, height: gridHeight, samples: alpha)
    }

    #if canImport(CoreGraphics)
    /// Samples `image`'s alpha channel onto a grid whose longest edge is
    /// `longestEdge` (valid range `minLongestEdge...maxLongestEdge`), or `nil` when
    /// the request is out of range or it can't be rasterised.
    public init?(image: CGImage, longestEdge: Int) {
        guard let grid = AlphaMask.gridSize(sourceWidth: image.width,
                                            sourceHeight: image.height,
                                            longestEdge: longestEdge) else { return nil }
        let gridWidth = grid.width
        let gridHeight = grid.height

        // Core Graphics has no Swift-expressible alpha-only bitmap context (the
        // colour space parameter is non-optional, and alpha-only requires none),
        // so sample into RGBA and keep the alpha byte.
        var rgba = [UInt8](repeating: 0, count: gridWidth * gridHeight * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base,
                                          width: gridWidth,
                                          height: gridHeight,
                                          bitsPerComponent: 8,
                                          bytesPerRow: gridWidth * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            let rect = CGRect(x: 0, y: 0, width: CGFloat(gridWidth), height: CGFloat(gridHeight))
            context.interpolationQuality = .high
            context.clear(rect)
            context.draw(image, in: rect)
            return true
        }
        guard drawn else { return nil }

        var alpha = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for index in 0..<(gridWidth * gridHeight) {
            alpha[index] = rgba[index * 4 + 3]
        }

        self.width = gridWidth
        self.height = gridHeight
        self.samples = alpha
    }
    #endif

    // MARK: Measurements

    /// Whether the sample at `row`/`column` reaches `threshold`. Out-of-range
    /// coordinates read as empty.
    public func isInk(row: Int, column: Int, threshold: UInt8) -> Bool {
        guard row >= 0, row < height, column >= 0, column < width else { return false }
        return samples[row * width + column] >= threshold
    }

    /// How many samples reach `threshold`, over the whole grid.
    public func inkCount(threshold: UInt8) -> Int {
        samples.reduce(into: 0) { total, sample in
            if sample >= threshold { total += 1 }
        }
    }

    /// The tightest cell rectangle containing every inked sample, or `nil` when
    /// nothing reaches `threshold`.
    public func inkBounds(threshold: UInt8) -> InkBounds? {
        var minRow = Int.max
        var maxRow = Int.min
        var minColumn = Int.max
        var maxColumn = Int.min

        for row in 0..<height {
            for column in 0..<width where samples[row * width + column] >= threshold {
                minRow = Swift.min(minRow, row)
                maxRow = Swift.max(maxRow, row)
                minColumn = Swift.min(minColumn, column)
                maxColumn = Swift.max(maxColumn, column)
            }
        }

        guard minRow <= maxRow, minColumn <= maxColumn else { return nil }
        return InkBounds(minRow: minRow, maxRow: maxRow, minColumn: minColumn, maxColumn: maxColumn)
    }

    /// Mean distance from each corner of `box` to the first inked sample along the
    /// diagonal toward its centre, as a fraction of the half-diagonal.
    ///
    /// 0 means the corners are hard; a rounded square measures about 0.11 and a
    /// circle about 0.27. A corner that never reaches ink contributes 1.
    public func cornerReach(in box: InkBounds, threshold: UInt8) -> Double {
        let centreRow = Double(box.minRow + box.maxRow) / 2
        let centreColumn = Double(box.minColumn + box.maxColumn) / 2
        let corners = [(box.minRow, box.minColumn), (box.minRow, box.maxColumn),
                       (box.maxRow, box.minColumn), (box.maxRow, box.maxColumn)]

        var total = 0.0
        for (cornerRow, cornerColumn) in corners {
            var reach = 1.0
            for step in 0...Self.diagonalSteps {
                let t = Double(step) / Double(Self.diagonalSteps)
                let row = Int((Double(cornerRow) + (centreRow - Double(cornerRow)) * t).rounded())
                let column = Int((Double(cornerColumn) + (centreColumn - Double(cornerColumn)) * t).rounded())
                if isInk(row: row, column: column, threshold: threshold) {
                    reach = t
                    break
                }
            }
            total += reach
        }
        return total / Double(corners.count)
    }
}
