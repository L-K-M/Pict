import Foundation

/// Where the shared store lives, and the one piece of etiquette that comes with
/// putting a directory in someone's Library that outlives any one app.
public enum IconStoreLocation {

    /// The shared directory's name.
    ///
    /// Not inside any one app's folder, which is the whole point — a store under
    /// `Application Support/Zap/` is Zap's, and three apps writing into another app's
    /// directory is a worse arrangement than a neutral one. The three existing bundle
    /// identifiers (`com.zapapp.Zap`, `com.jettyapp.Jetty`, `com.macdring.MacDring`)
    /// share no reverse-DNS root, so there was no prefix to inherit and a name had to
    /// be invented.
    public static let directoryName = "Pict"

    /// `~/Library/Application Support/Pict`, falling back to a temporary directory if
    /// Application Support is somehow unavailable.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The name recorded in an entry's `writtenBy`, taken from the running app.
    public static var callingAppName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    // MARK: The README

    /// Writes a short `README.txt` beside the entries, once.
    ///
    /// A shared directory outlives every app that writes it: delete Zap, Jetty, Top
    /// Drawer and Pict and this stays. Someone will eventually open it wondering what
    /// put PNGs in their Library, and the entire mitigation for that is a file that
    /// answers them. Cheap, and the alternative is mystery data nobody dares delete.
    ///
    /// Never overwrites — a user who edited or deleted it meant to.
    public static func seedReadMe(in directory: URL, fileManager: FileManager = .default) {
        let url = directory.appendingPathComponent("README.txt")
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? readMe.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private static let readMe = """
        Pict — shared app icons
        =======================

        This folder holds custom icons you have chosen for apps, files, folders and
        links. It is shared: Pict, Zap, Jetty and Top Drawer all read it, so setting
        an icon in one of them sets it in all of them.

        entries/
            One pair of files per icon you have set — a small .json describing where
            the icon came from, and the .png itself. The .png files are re-encoded
            copies, so moving or deleting the image you originally picked does not
            affect them.

        Deleting this folder is safe. Every app falls back to the icons macOS
        provides, exactly as it did before you set any.

        This folder is not created by an installer and is not removed when you
        uninstall the apps, because no one app owns it.

        https://github.com/L-K-M/Pict

        """
}
