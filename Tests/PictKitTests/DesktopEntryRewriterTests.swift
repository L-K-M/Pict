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
        // The marker is in the main group, not the action group.
        XCTAssertTrue(out.contains("X-Pict-Managed=true"), out)
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

    func testIsManaged() {
        XCTAssertTrue(DesktopEntryRewriter.isManaged("[Desktop Entry]\nName=A\nX-Pict-Managed=true\n"))
        XCTAssertFalse(DesktopEntryRewriter.isManaged("[Desktop Entry]\nName=A\nIcon=x\n"))
        // The marker only counts inside [Desktop Entry], not another group.
        XCTAssertFalse(DesktopEntryRewriter.isManaged("[Other]\nX-Pict-Managed=true\n"))
    }
}
