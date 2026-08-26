import Foundation

/// Rewrites a freedesktop `.desktop` file's text so its `[Desktop Entry]` group points at
/// a chosen icon and is marked as Pict-generated — the one text transform behind the
/// Linux "apply icons system-wide" override (LP-15, `DesktopOverrideSync`).
///
/// It is deliberately a **line-level** edit, not a parse-and-reserialize: the plan's rule
/// is "the current system entry with only `Icon=` replaced", so every other line — order,
/// comments, blank lines, other groups, localized keys — is preserved byte for byte.
/// Only the plain `Icon=` (no `[locale]` suffix) in the `[Desktop Entry]` group is
/// touched, and an `X-Pict-Managed=true` marker is ensured so the sync can tell its own
/// overrides from files it must never delete.
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

        // Preserve the file's line terminator (LF or CRLF): splitting and rejoining on the
        // detected separator means a CRLF `[Desktop Entry]\r` header is still recognized
        // and the rewritten file isn't left with mixed endings.
        let separator = content.contains("\r\n") ? "\r\n" : "\n"
        // Normalize the trailing newline out so `components(separatedBy:)` doesn't yield a
        // spurious empty final element that group-end insertions would straddle; re-add it
        // at the end so the file keeps its original terminator.
        let hadTrailingNewline = content.hasSuffix(separator)
        let body = hadTrailingNewline ? String(content.dropLast(separator.count)) : content
        let lines = body.components(separatedBy: separator)

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
        for line in content.components(separatedBy: "\n") {
            // whitespacesAndNewlines so a CRLF file's trailing `\r` doesn't hide the header.
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
