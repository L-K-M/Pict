import Foundation

/// Rewrites a freedesktop `.desktop` file's text so its `[Desktop Entry]` group points at
/// a chosen icon and is marked as Pict-generated — the one text transform behind the
/// Linux "apply icons system-wide" override (LP-15, `DesktopOverrideSync`).
///
/// It is deliberately a **line-level** edit, not a parse-and-reserialize: the plan's rule
/// is "the current system entry with only `Icon=` replaced", so every other line — order,
/// comments, blank lines, other groups, localized `Name`/`Comment` keys — is preserved
/// byte for byte. The `[Desktop Entry]` group's plain `Icon=` is set to the store icon, an
/// `X-Pict-Managed=true` marker is ensured so the sync can tell its own overrides from
/// files it must never delete, and — because `Icon` is a spec *localestring* — any
/// localized `Icon[xx]=` is dropped: leaving one would let it shadow our managed icon in
/// its locale (GLib resolves a matching localized key ahead of the plain one), silently
/// defeating the override. The originals stay in the untouched system entry, so dropping
/// them from our fresh copy is safe.
///
/// Pure and platform-neutral so it can be unit-tested on both CIs; `DesktopOverrideSync`,
/// which drives it against the filesystem, is Linux-only.
public enum DesktopEntryRewriter {

    /// The marker key/value stamped into every generated override, so the sync only ever
    /// removes files it wrote and never a hand-authored `.desktop`.
    public static let managedKey = "X-Pict-Managed"
    public static let managedValue = "true"

    /// Whether `content` carries the `X-Pict-Managed=true` marker in its `[Desktop Entry]`
    /// group — i.e. whether it is one of Pict's own generated overrides.
    public static func isManaged(_ content: String) -> Bool {
        forEachDesktopEntryKey(content) { key, value in
            key == managedKey && value.trimmingCharacters(in: .whitespaces) == managedValue
        }
    }

    /// Returns `content` with the `[Desktop Entry]` group's plain `Icon=` set to
    /// `iconPath` and `X-Pict-Managed=true` ensured, preserving every other line. If the
    /// keys are absent they are appended at the end of the group. Returns the input
    /// unchanged if it has no `[Desktop Entry]` group.
    public static func rewrite(_ content: String, iconPath: String) -> String {
        guard content.range(of: "[Desktop Entry]") != nil else { return content }
        // A line break inside the icon path would inject extra key lines into the generated
        // override (e.g. a second `Hidden=true` line), so refuse to build one — leave the
        // input unchanged, which `DesktopOverrideSync` then skips as unmarkable.
        guard !iconPath.contains("\n"), !iconPath.contains("\r") else { return content }

        // Preserve the file's line terminator (LF or CRLF) on the way out.
        let separator = content.contains("\r\n") ? "\r\n" : "\n"
        // Normalize CRLF → LF *before* splitting. Swift treats `\r\n` as a single Character,
        // so `components(separatedBy: "\n")` would not split CRLF content at all; and
        // splitting on the detected `\r\n` separator would instead glue a lone-LF line onto
        // its neighbor in a mixed-ending file, letting the `Icon=` replacement silently drop
        // a logical line. Replacing `\r\n` (which does match the grapheme) sidesteps both;
        // rejoining on `separator` restores the file's ending byte-for-byte.
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        // Normalize a single trailing newline out so the split doesn't yield a spurious empty
        // final element that group-end insertions would straddle; re-add it at the end.
        let hadTrailingNewline = normalized.hasSuffix("\n")
        var body = hadTrailingNewline ? String(normalized.dropLast()) : normalized
        // A leading UTF-8 BOM would glue onto the `[Desktop Entry]` header and hide it —
        // GLib tolerates a BOM, so such a file is valid and must still be rewritten, not
        // silently skipped. Drop it (the generated override needn't carry one).
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let lines = body.components(separatedBy: "\n")

        var out: [String] = []
        out.reserveCapacity(lines.count + 2)
        var inTarget = false
        var iconDone = false
        var managedDone = false

        // Emit whichever managed keys the group didn't already carry, at its end.
        func closeGroup() {
            guard inTarget else { return }
            if !iconDone { out.append("Icon=\(iconPath)"); iconDone = true }
            if !managedDone { out.append("\(managedKey)=\(managedValue)"); managedDone = true }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                closeGroup()                       // finish the previous [Desktop Entry]
                inTarget = (trimmed == "[Desktop Entry]")
                out.append(line)
                continue
            }
            if inTarget, let key = exactKey(of: trimmed) {
                if key == "Icon" { out.append("Icon=\(iconPath)"); iconDone = true; continue }
                // `Icon` is a localestring, so a localized `Icon[xx]=` would take precedence
                // over our managed plain `Icon=` in matching locales and keep showing the old
                // icon there. This override is a fresh Pict-owned copy (the system entry is
                // untouched), so drop the localized duplicates and let the store icon win in
                // every locale.
                if key.hasPrefix("Icon[") { continue }
                if key == managedKey {
                    out.append("\(managedKey)=\(managedValue)"); managedDone = true; continue
                }
            }
            out.append(line)
        }
        closeGroup()   // the [Desktop Entry] group may run to end-of-file

        return out.joined(separator: separator) + (hadTrailingNewline ? separator : "")
    }

    // MARK: - Parsing helpers

    /// The exact key of a `Key=Value` line — locale suffix included, so a localized
    /// `Icon[de]=` is *not* mistaken for the plain `Icon=` we replace — or `nil` for a
    /// blank line, a `# comment`, or a `[group]` header.
    private static func exactKey(of trimmedLine: String) -> String? {
        guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#"), !trimmedLine.hasPrefix("["),
              let equals = trimmedLine.firstIndex(of: "=") else { return nil }
        return String(trimmedLine[trimmedLine.startIndex..<equals])
    }

    /// Runs `predicate(key, value)` over the plain-keyed lines of the `[Desktop Entry]`
    /// group, returning `true` at the first match. Shared by `isManaged`.
    private static func forEachDesktopEntryKey(_ content: String,
                                               _ predicate: (String, String) -> Bool) -> Bool {
        var inTarget = false
        // Normalize CRLF → LF (Swift won't split the `\r\n` grapheme on `\n`) and strip a
        // leading BOM, mirroring `rewrite`, so our own CRLF-/BOM-authored overrides still
        // read as managed instead of being mistaken for hand-authored files.
        var scan = content.replacingOccurrences(of: "\r\n", with: "\n")
        if scan.hasPrefix("\u{FEFF}") { scan.removeFirst() }
        for line in scan.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                inTarget = (trimmed == "[Desktop Entry]")
                continue
            }
            guard inTarget, let equals = trimmed.firstIndex(of: "="),
                  let key = exactKey(of: trimmed) else { continue }
            let value = String(trimmed[trimmed.index(after: equals)...])
            if predicate(key, value) { return true }
        }
        return false
    }
}
