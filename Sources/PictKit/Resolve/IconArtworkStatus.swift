import Foundation

/// What an app says about one target in a list: where its icon is coming from and, when
/// it is the target's own, what shape that artwork is.
///
/// Answering this needs the store and the bundle — not the resolver's cache — so it
/// lives apart from `IconResolver`, which exists to keep a lookup to a dictionary
/// hit. Describing a target *decodes* its icon, so this is deliberately blocking and
/// deliberately off the main thread.
///
/// In the package rather than in Pict because it has two consumers: Pict captions
/// its rows with it, and so does Zap's Icons tab, which keeps its read-side list
/// after handing editing over.
public struct IconArtworkStatus: Equatable {

    /// The shape of the target's own artwork, or `nil` when none was readable.
    public var shape: IconShape?
    /// Whether the user has supplied an icon for this target.
    public var hasCustomIcon: Bool
    /// Whether this target is pinned to the system icon.
    public var isPinnedToSystemIcon: Bool
    /// Who set the icon, when someone did — the one place a user can see that the
    /// icon in front of them arrived from another app.
    public var writtenBy: String?
    /// The attribution an adopted icon carries, when it carries one.
    public var credit: String?

    public var label: String {
        if isPinnedToSystemIcon { return "System icon" }
        if hasCustomIcon {
            var parts = ["Custom icon"]
            if let credit, !credit.isEmpty { parts.append(credit) }
            if let writtenBy, !writtenBy.isEmpty { parts.append("set in \(writtenBy)") }
            return parts.joined(separator: " · ")
        }
        guard let shape else { return "No original artwork found" }
        return shape.label
    }

    public init(shape: IconShape? = nil, hasCustomIcon: Bool = false,
                isPinnedToSystemIcon: Bool = false,
                writtenBy: String? = nil, credit: String? = nil) {
        self.shape = shape
        self.hasCustomIcon = hasCustomIcon
        self.isPinnedToSystemIcon = isPinnedToSystemIcon
        self.writtenBy = writtenBy
        self.credit = credit
    }

    /// Where the queue for batch description lives. Utility rather than user
    /// initiated: nothing on screen is waiting on it except a caption.
    private static let queue = DispatchQueue(label: "com.pict.icon-status", qos: .utility)

    /// Describes one target. Decodes its bundle artwork, so it blocks — call it off
    /// the main thread. The artwork source is behind `ArtworkProviding` so the bundle
    /// read stays macOS-only (its Linux placeholder reports no original artwork until
    /// icon-theme lookup arrives in LP-24).
    public static func describe(_ target: IconTarget, store: IconStore,
                                artwork: ArtworkProviding = BundleArtworkProvider()) -> IconArtworkStatus {
        if let entry = store.entry(for: target) {
            if entry.origin == .system {
                return IconArtworkStatus(shape: nil, hasCustomIcon: false,
                                         isPinnedToSystemIcon: true)
            }
            if store.imageURL(for: target) != nil {
                return IconArtworkStatus(shape: nil, hasCustomIcon: true,
                                         isPinnedToSystemIcon: false,
                                         writtenBy: entry.writtenBy, credit: entry.credit)
            }
        }
        // By identifier: this rung is about the bundle's *own* artwork, and a wrapper
        // that borrowed an identifier shows what is behind it. The provider itself
        // applies the identifier check; a non-application target yields nothing.
        let shape = artwork.artwork(for: target).map { IconShapeClassifier.classify($0) }
        return IconArtworkStatus(shape: shape, hasCustomIcon: false, isPinnedToSystemIcon: false)
    }

    /// Describes several targets off the main thread, calling `completion` back on
    /// it. Keyed by the serialised storage key, which is what rows are identified by.
    public static func load(for targets: [IconTarget], store: IconStore,
                     artwork: ArtworkProviding = BundleArtworkProvider(),
                     completion: @escaping ([String: IconArtworkStatus]) -> Void) {
        queue.async {
            var result: [String: IconArtworkStatus] = [:]
            for target in targets {
                guard let key = IconEntryKey.storageKey(for: target) else { continue }
                result[key.serialized] = describe(target, store: store, artwork: artwork)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
