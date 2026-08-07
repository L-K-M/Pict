import CoreGraphics

/// Everything the resolver needs to know about *how* to draw, as plain data.
///
/// This type is the seam between the package and the four apps that use it. Zap's
/// resolver used to take a `Preferences` and subscribe to it with Combine, which
/// bound the resolution ladder to one app's settings screen — Jetty has no
/// `iconBleed` slider and Pict has no switcher row to bleed into. Passing a value
/// instead means each app owns the code that maps *its* settings onto these fields
/// and calls `update(_:)`; the package owns none of it.
///
/// Being a value with `Equatable` is what makes `update(_:)` cheap to call: an app
/// can hand over the current options on every settings change and the resolver
/// invalidates only when something that affects a bitmap actually moved.
public struct IconRenderOptions: Equatable, Sendable {

    /// Which rungs of the ladder are in play.
    public var mode: IconSourceMode

    /// The size icons are cached at, in **pixels** — the display size times the
    /// backing scale of the sharpest attached screen.
    ///
    /// Masters are not kept in memory: 40 apps at 1024² RGBA would be 160 MB, so each
    /// icon is resampled to its display size before being cached, and re-resolved
    /// when this changes. Computing it needs `NSScreen`, which is main-thread-only,
    /// so it is computed by the app and passed in rather than read here.
    public var pixelSize: Int

    /// The backing scale the pixel size was computed against, used to size the
    /// resulting `NSImage` in points.
    public var scale: CGFloat

    /// How far artwork may bleed past its nominal frame, as a fraction. Free-form
    /// icons poking out of their cell is the classic Mac look and the reason to
    /// un-jail at all; an app with no room for it passes 0.
    public var bleed: Double

    /// Whether to trim transparent margin before scaling. Source art often carries
    /// it, and without trimming the icon floats small inside its frame.
    public var trimsTransparentEdges: Bool

    /// Whether to bake a soft drop shadow in. Free-form art on a translucent panel
    /// loses its edges; the system's own icons get this for free from the grey plate.
    public var drawsShadow: Bool

    public init(mode: IconSourceMode,
                pixelSize: Int,
                scale: CGFloat = 2,
                bleed: Double = 0.08,
                trimsTransparentEdges: Bool = true,
                drawsShadow: Bool = true) {
        self.mode = mode
        self.pixelSize = pixelSize
        self.scale = scale
        self.bleed = bleed
        self.trimsTransparentEdges = trimsTransparentEdges
        self.drawsShadow = drawsShadow
    }

    /// Options for an app that draws icons at `pointSize` and wants no layout
    /// flourishes — a dock tile or a drawer slot, where the icon sits in a grid and
    /// bleeding into its neighbours is not the look.
    ///
    /// **`.originalPlusCustom`, not `.systemDefault`.** The mode is Zap's *preference*
    /// — a switcher row the user can set back to plain system icons — and Jetty and
    /// Top Drawer have no such preference to read. Inheriting the default here would
    /// leave `usesCustomIcons` false for both, so an icon the user set in Pict would
    /// never be read by either and the store would be shared in name only. Worse,
    /// before macOS 26 `systemDefault` is `.system`, which switches the ladder off
    /// entirely and makes the resolver answer `nil` for every target.
    ///
    /// An icon the user picked by hand is not a display flourish, and no OS version
    /// makes it stop being their choice.
    public static func plain(pointSize: Double, scale: CGFloat) -> IconRenderOptions {
        IconRenderOptions(mode: .originalPlusCustom,
                          pixelSize: IconBitmap.pixelSize(forIconSize: pointSize, scale: scale),
                          scale: scale,
                          bleed: 0,
                          trimsTransparentEdges: true,
                          drawsShadow: false)
    }
}
