#if canImport(AppKit)
import AppKit
#endif
// Foundation is imported unconditionally: this file uses it on every platform (NSLock,
// DispatchQueue, NSSize/CGFloat). CoreGraphics sits under its own `canImport` gate
// because CGImage is only referenced on the AppKit path. Foundation is deliberately NOT
// tucked into an `#else` of that gate — that would tie whether Foundation is in scope to
// CoreGraphics's availability, so the Linux build would lean on the toolchain
// re-exporting Foundation instead of importing it outright. Matches IconResolverTests.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

#if canImport(AppKit)
/// The resolved artwork type — an `NSImage` on macOS, ready to draw.
public typealias ResolvedIconImage = NSImage
#else
/// The resolved artwork type on Linux: the premultiplied pixels plus the point size
/// they should draw at (pixels ÷ scale). The frontend turns this into whatever its
/// toolkit draws; the resolver stays toolkit-agnostic.
public struct ResolvedIconImage: Sendable, Equatable {
    public let pixels: PixelImage
    public let pointSize: Double
    public init(pixels: PixelImage, pointSize: Double) {
        self.pixels = pixels
        self.pointSize = pointSize
    }
}
#endif

/// The image type the resolution pipeline works in: Core Graphics on macOS (the
/// shipping path, untouched), the pure raster `PixelImage` on Linux. Every pipeline
/// step — `store.image(for:)`, the bundle read, classify/mask/normalize — has an
/// overload for each, so `resolve()` is written once against this alias.
///
/// Gated on `canImport(AppKit)` to match `ResolvedIconImage` and `resolve()`'s final
/// construction — this package assumes CoreGraphics and AppKit travel together (true
/// on its macOS and Linux targets); a CoreGraphics-without-AppKit target would need
/// these three gates reconciled first.
#if canImport(AppKit)
private typealias PipelineImage = CGImage
#else
private typealias PipelineImage = PixelImage
#endif

/// Resolves a target to the artwork to draw for it.
///
/// This is the only part of the package a hot path touches — Zap's ⌘-Tab handler
/// calls it once per app, per keystroke — so the rule is that `icon(for:)` costs a
/// dictionary lookup and nothing else. Everything expensive (reading a bundle,
/// decoding, resampling) happens on a background queue, either warmed ahead of time
/// or kicked off by the first miss. A miss returns `nil`, which the caller reads as
/// "use the system icon", so no caller ever blocks and no caller ever waits on I/O.
///
/// Keyed by `IconTarget` rather than a bundle identifier, because an identifier does
/// not identify an app: site-specific-browser wrappers all report the browser's, and
/// one override would then paint every one of them.
public final class IconResolver {

    public let store: IconStore

    /// Called on the main queue once artwork has actually landed in the cache.
    ///
    /// The reason this exists: `invalidate()` empties the cache and re-warms in the
    /// background, so a consumer that redraws *at* the moment of invalidation reads a
    /// miss and draws the system icon. One that then caches what it drew — Jetty's
    /// dock does, with a five-minute TTL — would pin the squircle-masked fallback on
    /// screen for five minutes, starting from the instant the user picked a new icon
    /// in Pict. Redrawing on this instead is what makes a change visible rather than
    /// merely eventual.
    ///
    /// Only fires when a resolve produced real artwork. A target that resolves to
    /// "use the system icon" is already what the consumer is drawing, so there is
    /// nothing to redraw for.
    ///
    /// Coalesced: re-warming two hundred targets calls this once per runloop hop,
    /// not two hundred times.
    public var onIconsResolved: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onIconsResolved }
        set { lock.lock(); _onIconsResolved = newValue; lock.unlock() }
    }
    private var _onIconsResolved: (() -> Void)?
    private var notifyScheduled = false

    private let queue = DispatchQueue(label: "com.pict.icon-resolver", qos: .utility)
    private let lock = NSLock()

    /// A resolved icon, or a resolved *absence* of one — distinguishing "we looked
    /// and there's nothing" from "we haven't looked yet".
    private enum Resolution {
        case useSystemIcon
        case image(ResolvedIconImage)
    }

    private var cache: [IconTarget: Resolution] = [:]
    private var inFlight: Set<IconTarget> = []
    /// Every target seen, so an invalidation can re-warm them all rather than waiting
    /// for each to be missed again.
    private var known: Set<IconTarget> = []
    /// Bumped on every invalidation. Work enqueued under an older generation is
    /// discarded when it lands, so a resolve started before an icon-size change can't
    /// overwrite the cache with an icon at the old size.
    private var generation = 0
    private var options: IconRenderOptions

    // MARK: Lifecycle

    public init(options: IconRenderOptions, store: IconStore = IconStore()) {
        self.options = options
        self.store = store
    }

    // MARK: Hot path

    /// The artwork to draw for `target`, or `nil` to fall back to the system icon.
    /// A dictionary lookup; a miss schedules the work and returns `nil`.
    public func icon(for target: IconTarget) -> ResolvedIconImage? {
        lock.lock()
        known.insert(target)
        let cached = cache[target]
        var pendingGeneration: Int?
        if cached == nil, !inFlight.contains(target) {
            inFlight.insert(target)
            pendingGeneration = generation
        }
        lock.unlock()

        if let pendingGeneration { enqueueResolve(target, generation: pendingGeneration) }

        if case .image(let image)? = cached { return image }
        return nil
    }

    /// Resolves `targets` ahead of time, so the first draw after launch already has
    /// them. Warming policy belongs to the app — a switcher warms the running apps, a
    /// dock warms its tiles — so the package only offers the verb.
    public func warm(_ targets: [IconTarget]) {
        var pending: [IconTarget] = []
        lock.lock()
        let generation = self.generation
        for target in targets {
            known.insert(target)
            guard cache[target] == nil, !inFlight.contains(target) else { continue }
            inFlight.insert(target)
            pending.append(target)
        }
        lock.unlock()

        for target in pending { enqueueResolve(target, generation: generation) }
    }

    /// Drops cached artwork. Pass a target to invalidate one (after its icon
    /// changes), or `nil` for all of them.
    public func invalidate(_ target: IconTarget? = nil) {
        var toWarm: [IconTarget] = []
        lock.lock()
        // Retire everything already in flight along with the cached values: those
        // results were computed for the settings we just left.
        generation &+= 1
        inFlight.removeAll()
        if let target {
            cache[target] = nil
            toWarm = [target]
        } else {
            cache.removeAll()
            toWarm = Array(known)
        }
        lock.unlock()

        warm(toWarm)
    }

    // MARK: Settings

    /// Adopts new render options, re-rendering everything if they changed anything.
    ///
    /// Safe and cheap to call on every settings change: identical options are a
    /// comparison and a return, not a cache flush.
    ///
    /// **It invalidates for you when they differ.** Everything cached was rendered
    /// against the old options — a icon cached at 1× is the wrong picture once a 2×
    /// display arrives — so keeping it would be the bug. Callers must not add their
    /// own `invalidate()` after this; that drops the cache and re-warms it twice.
    ///
    /// A caller that caches the resolved image downstream should drop that cache from
    /// `onIconsResolved`, not from here: at this point the re-render has only been
    /// scheduled, so redrawing now caches the system icon it falls back to.
    public func update(_ options: IconRenderOptions) {
        lock.lock()
        let unchanged = options == self.options
        self.options = options
        lock.unlock()

        guard !unchanged else { return }
        invalidate()
    }

    public var currentOptions: IconRenderOptions {
        lock.lock()
        defer { lock.unlock() }
        return options
    }

    // MARK: Resolution

    private func enqueueResolve(_ target: IconTarget, generation: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            let resolution = self.resolve(target)
            self.lock.lock()
            // Dropped wholesale if an invalidation happened while this was in flight —
            // including the in-flight marker, which by then belongs to whatever
            // re-warm replaced it.
            if generation == self.generation {
                self.cache[target] = resolution
                self.inFlight.remove(target)
                if case .image = resolution { self.scheduleNotifyLocked() }
            }
            self.lock.unlock()
        }
    }

    /// Schedules the one main-queue hop that tells consumers new artwork is readable.
    /// Call with the lock held.
    private func scheduleNotifyLocked() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // Cleared before the callback runs, so artwork landing *during* it
            // schedules the next hop rather than being swallowed by this one.
            self.notifyScheduled = false
            let notify = self._onIconsResolved
            self.lock.unlock()
            notify?()
        }
    }

    /// The resolution ladder, first hit wins:
    ///
    /// ```
    ///   3. the shared store ────── an icon the user chose, in any of the four apps
    ///   2. original artwork ────── read out of the bundle, unmasked
    ///   1. system icon ─────────── whatever macOS hands us (returned as nil)
    /// ```
    private func resolve(_ target: IconTarget) -> Resolution {
        lock.lock()
        let options = self.options
        lock.unlock()

        guard options.mode.usesBundleArtwork else { return .useSystemIcon }
        // A pin opts this target out entirely.
        guard !store.isPinnedToSystemIcon(target) else { return .useSystemIcon }

        var artwork: PipelineImage?
        var isCustom = false

        if options.mode.usesCustomIcons, let custom = store.image(for: target) {
            artwork = custom
            isCustom = true
        }
        if artwork == nil {
            artwork = bundleArtwork(for: target)
        }
        guard var image = artwork else { return .useSystemIcon }

        // A user-chosen file is taken at face value; a bundle's own artwork is
        // classified first, so a modern full-bleed square doesn't come back
        // hard-cornered — sharper corners than anything else on screen.
        if !isCustom {
            let shape = IconShapeClassifier.classify(image)
            guard shape.isWorthSubstituting else { return .useSystemIcon }
            if shape.needsCornerMask {
                image = IconBitmap.maskingCorners(
                    image, radiusFraction: IconBitmap.fullBleedCornerRadiusFraction)
            }
        }

        // Normalising resamples straight into the target canvas, so there is no
        // separate downsample step. Unlike `downsample` it may scale *up* — equal-ink
        // normalisation of a sparse shape requires it — which is why the validator's
        // 64px floor and the bleed clamp both matter.
        let sized = IconNormalizer.normalize(image, targetExtent: options.pixelSize,
                                             bleed: options.bleed,
                                             trim: options.trimsTransparentEdges,
                                             shadow: options.drawsShadow)
        #if canImport(AppKit)
        let points = NSSize(width: CGFloat(sized.width) / options.scale,
                            height: CGFloat(sized.height) / options.scale)
        return .image(NSImage(cgImage: sized, size: points))
        #else
        // Square by construction: `normalize` renders into a `canvasSide × canvasSide`
        // canvas, so one point size suffices. Assert it, so a future change that breaks
        // the invariant is caught in debug rather than drawing a distorted aspect ratio.
        assert(sized.width == sized.height, "ResolvedIconImage.pointSize assumes a square canvas")
        // Derive from the shorter side so a future non-square regression degrades
        // gracefully in release (never an inflated dimension) rather than distorting.
        let side = Double(min(sized.width, sized.height))
        return .image(ResolvedIconImage(pixels: sized, pointSize: side / Double(options.scale)))
        #endif
    }

    /// The app's own bundle artwork for `target`, or `nil`. macOS reads the bundle as a
    /// `CGImage`, so the hot-path pipeline stays Core Graphics; a wrapper that borrowed
    /// an identifier borrowed the artwork behind it, so this stays keyed by identifier.
    /// Linux has no bundle equivalent — icon-theme lookup lands in LP-24 — so it misses.
    ///
    /// Mirrors `BundleArtworkProvider` (Resolve/ArtworkProviding.swift), which feeds the
    /// status path; keep the two identifier-keyed reads in sync (LP-24 must update both).
    private func bundleArtwork(for target: IconTarget) -> PipelineImage? {
        #if canImport(AppKit)
        guard case .application(_, let bundleIdentifier) = target, let bundleIdentifier else { return nil }
        return BundleArtwork.image(forBundleID: bundleIdentifier)
        #else
        return nil
        #endif
    }
}
