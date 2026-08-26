import XCTest
@testable import PictKit

final class DesktopEntryRewriterTests: XCTestCase {

    func testReplacesIconAndPreservesEverythingElse() {
        let input = """
            [Desktop Entry]
            Name=Firefox
            Exec=firefox %u
            Icon=firefox
            Categories=Network;WebBrowser;

            """
        let out = DesktopEntryRewriter.rewrite(input, iconPath: "/store/firefox.png")

        XCTAssertTrue(out.contains("Icon=/store/firefox.png"), out)
        XCTAssertFalse(out.contains("Icon=firefox\n"), out)              // old value gone
        XCTAssertTrue(out.contains("Name=Firefox"), out)                // untouched
        XCTAssertTrue(out.contains("Exec=firefox %u"), out)             // untouched
        XCTAssertTrue(out.contains("Categories=Network;WebBrowser;"), out)
        XCTAssertTrue(out.contains("X-Pict-Managed=true"), out)
        XCTAssertTrue(out.hasSuffix("\n"), "trailing newline preserved")
    }

    func testAppendsIconAndMarkerWhenAbsent() {
        let input = "[Desktop Entry]\nName=Thing\nExec=thing\n"
        let out = DesktopEntryRewriter.rewrite(input, iconPath: "/store/thing.png")
        XCTAssertTrue(out.contains("Icon=/store/thing.png"), out)
        XCTAssertTrue(out.contains("X-Pict-Managed=true"), out)
        XCTAssertTrue(out.contains("Name=Thing"), out)
    }

    func testIsIdempotent() {
        let input = "[Desktop Entry]\nName=Thing\nIcon=old\n"
        let once = DesktopEntryRewriter.rewrite(input, iconPath: "/p.png")
        let twice = DesktopEntryRewriter.rewrite(once, iconPath: "/p.png")
        XCTAssertEqual(once, twice, "rewriting a managed override again is a no-op")
        // Exactly one Icon= and one marker.
        XCTAssertEqual(twice.components(separatedBy: "Icon=").count - 1, 1, twice)
        XCTAssertEqual(twice.components(separatedBy: "X-Pict-Managed=").count - 1, 1, twice)
    }

    func testOnlyTheDesktopEntryGroupIsTouched() {
        let input = """
            [Desktop Entry]
            Name=App
            Icon=app
            Actions=New;

            [Desktop Action New]
            Name=New Window
            Icon=app-new
            Exec=app --new
            """
        let out = DesktopEntryRewriter.rewrite(input, iconPath: "/store/app.png")
        XCTAssertTrue(out.contains("Icon=/store/app.png"), out)   // [Desktop Entry] replaced
        XCTAssertTrue(out.contains("Icon=app-new"), out)          // the action's icon left alone
        // The marker must land in the main group, before the action header — not just be
        // present somewhere (a parser ignores X-Pict-Managed inside [Desktop Action]).
        let mainGroup = out[..<(out.range(of: "[Desktop Action")?.lowerBound ?? out.endIndex)]
        XCTAssertTrue(mainGroup.contains("X-Pict-Managed=true"), out)
    }

    func testLocalizedIconIsNotTouched() {
        let input = "[Desktop Entry]\nIcon=app\nIcon[de]=app-de\n"
        let out = DesktopEntryRewriter.rewrite(input, iconPath: "/store/app.png")
        XCTAssertTrue(out.contains("Icon=/store/app.png"), out)   // plain Icon replaced
        XCTAssertTrue(out.contains("Icon[de]=app-de"), out)       // localized left as-is
    }

    func testWithoutDesktopEntryGroupReturnsInputUnchanged() {
        let input = "[Some Other Group]\nIcon=x\n"
        XCTAssertEqual(DesktopEntryRewriter.rewrite(input, iconPath: "/p.png"), input)
    }

    func testCarriageReturnLineEndingsAreHandledAndPreserved() {
        // A CRLF file: the `[Desktop Entry]\r` header must still be recognized, the icon
        // replaced, and the file left with CRLF endings (not a mix).
        let input = "[Desktop Entry]\r\nName=Win\r\nIcon=win\r\n"
        let out = DesktopEntryRewriter.rewrite(input, iconPath: "/store/win.png")
        XCTAssertTrue(out.contains("Icon=/store/win.png"), out)   // header was found despite \r
        XCTAssertFalse(out.contains("Icon=win\r"), out)           // old value gone
        XCTAssertTrue(out.contains("X-Pict-Managed=true\r\n"), out) // marker uses CRLF too
        // Every terminator is CRLF — strip the \r\n pairs and no lone \n may remain.
        XCTAssertFalse(out.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
                       "no stray LF-only lines introduced")
        XCTAssertTrue(out.hasSuffix("\r\n"), "trailing CRLF preserved")
    }

    func testMixedLineEndingsDoNotDropLines() {
        // A pathological file mixing CRLF and lone LF: the old separator-split would have
        // glued "Icon=win\nName=Win" into one element and the Icon replacement would drop
        // Name=Win. Splitting on \n (stripping \r) keeps every logical line.
        let input = "[Desktop Entry]\r\nIcon=win\nName=Win\r\nExec=win %u\r\n"
        let out = DesktopEntryRewriter.rewrite(input, iconPath: "/store/win.png")
        XCTAssertTrue(out.contains("Icon=/store/win.png"), out)
        XCTAssertTrue(out.contains("Name=Win"), out)              // not swallowed by the Icon line
        XCTAssertTrue(out.contains("Exec=win %u"), out)
        XCTAssertTrue(out.contains("X-Pict-Managed=true"), out)
    }

    func testALeadingBOMDoesNotHideTheGroup() {
        // A UTF-8 BOM before the header: GLib reads it fine, so we must too — the entry is
        // rewritten (not silently skipped) and reads back as managed.
        let input = "\u{FEFF}[Desktop Entry]\nName=B\nIcon=b\n"
        let out = DesktopEntryRewriter.rewrite(input, iconPath: "/store/b.png")
        XCTAssertTrue(out.contains("Icon=/store/b.png"), out)
        XCTAssertTrue(out.contains("Name=B"), out)
        XCTAssertTrue(DesktopEntryRewriter.isManaged(out), out)
    }

    func testIsManaged() {
        XCTAssertTrue(DesktopEntryRewriter.isManaged("[Desktop Entry]\nName=A\nX-Pict-Managed=true\n"))
        // rewrite() emits CRLF markers for CRLF sources, so isManaged must recognize its own
        // CRLF-marked overrides — otherwise sync treats them as hand-authored (never updated,
        // never reaped).
        XCTAssertTrue(DesktopEntryRewriter.isManaged("[Desktop Entry]\r\nName=A\r\nX-Pict-Managed=true\r\n"),
                      "our own CRLF-marked override must round-trip as managed")
        XCTAssertFalse(DesktopEntryRewriter.isManaged("[Desktop Entry]\nName=A\nIcon=x\n"))
        // The marker only counts inside [Desktop Entry], not another group.
        XCTAssertFalse(DesktopEntryRewriter.isManaged("[Other]\nX-Pict-Managed=true\n"))
    }
}
