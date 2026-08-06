import Combine
import Foundation

/// Pict's own settings. Deliberately almost empty.
///
/// Zap's `IconsView` also owned an `IconSourceMode` picker — system icons /
/// original artwork / originals plus custom. That control does **not** move here,
/// and the distinction is the point of the whole split: Pict decides what icon a
/// thing *has*, and each app decides how it *draws* it. A switcher that bleeds
/// free-form art past its cell and a dock that lays tiles on a grid want different
/// answers, and neither is Pict's to give.
///
/// So the only thing persisted is the provider disclosures the user has already
/// read, which is Pict's own state because Pict is where the searching happens.
final class PictPreferences: ObservableObject {

    private enum Key {
        static let acknowledgedSearchProviders = "acknowledgedSearchProviders"
    }

    private let defaults: UserDefaults

    /// Providers whose "here is what gets sent, and to whom" notice has been shown.
    ///
    /// Persisted rather than per-session: a notice shown every time is one that
    /// stops being read. Kept per provider because the disclosure is each
    /// provider's own statement of what it sends.
    @Published var acknowledgedSearchProviders: Set<String> {
        didSet {
            defaults.set(Array(acknowledgedSearchProviders),
                         forKey: Key.acknowledgedSearchProviders)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.array(forKey: Key.acknowledgedSearchProviders) as? [String] ?? []
        self.acknowledgedSearchProviders = Set(stored)
    }
}
