import Foundation
import PictKit

/// What the editor says about one target: where its icon is coming from and, when
/// it is the target's own, what shape that artwork is.
///
/// Answering this needs the store and the bundle — not the resolver's cache — so it
/// lives apart from `IconResolver`, which exists to keep a lookup to a dictionary
/// hit. Describing a target *decodes* its icon, so this is deliberately blocking and
/// deliberately off the main thread.
struct IconArtworkStatus: Equatable {

    /// The shape of the target's own artwork, or `nil` when none was readable.
    var shape: IconShape?
    /// Whether the user has supplied an icon for this target.
    var hasCustomIcon: Bool
    /// Whether this target is pinned to the system icon.
    var isPinnedToSystemIcon: Bool
    /// Who set the icon, when someone did — the one place a user can see that the
    /// icon in front of them arrived from another app.
    var writtenBy: String?
    /// The attribution an adopted icon carries, when it carries one.
    var credit: String?

    var label: String {
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

    /// Where the queue for batch description lives. Utility rather than user
    /// initiated: nothing on screen is waiting on it except a caption.
    private static let queue = DispatchQueue(label: "com.pict.icon-status", qos: .utility)

    /// Describes one target. Decodes its bundle artwork, so it blocks — call it off
    /// the main thread.
    static func describe(_ target: IconTarget, store: IconStore) -> IconArtworkStatus {
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
        // that borrowed an identifier shows what is behind it.
        guard case .application(_, let bundleIdentifier) = target, let bundleIdentifier else {
            return IconArtworkStatus(shape: nil, hasCustomIcon: false,
                                     isPinnedToSystemIcon: false)
        }
        let shape = BundleArtwork.image(forBundleID: bundleIdentifier)
            .map { IconShapeClassifier.classify($0) }
        return IconArtworkStatus(shape: shape, hasCustomIcon: false, isPinnedToSystemIcon: false)
    }

    /// Describes several targets off the main thread, calling `completion` back on
    /// it. Keyed by the serialised storage key, which is what rows are identified by.
    static func load(for targets: [IconTarget], store: IconStore,
                     completion: @escaping ([String: IconArtworkStatus]) -> Void) {
        queue.async {
            var result: [String: IconArtworkStatus] = [:]
            for target in targets {
                guard let key = IconEntryKey.storageKey(for: target) else { continue }
                result[key.serialized] = describe(target, store: store)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
