import XCTest
import Foundation

/// A `Sendable` holder so the concurrent stderr drain can publish its bytes without a
/// mutable capture — which warns under the Swift 5 language mode and is an error under
/// Swift 6. The `DispatchGroup` establishes the happens-before, so the unchecked
/// conformance is sound here.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Drives the built `pict` binary against a temp store — the LP-14 acceptance test.
/// Everything the CLI does end to end (parse → store → filesystem) is exercised here.
final class PictCLIIntegrationTests: XCTestCase {

    private var storeDirectory: URL!

    override func setUpWithError() throws {
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pict-cli-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let storeDirectory { try? FileManager.default.removeItem(at: storeDirectory) }
    }

    // MARK: The round trip

    func testSetListGetRemoveRoundTrip() throws {
        let fixture = try fixturePNG()
        let appKey = "app:/Applications/Test.app"

        // path — prints the directory we asked for.
        let path = try run("path", "--store", storeDirectory.path)
        XCTAssertEqual(path.status, 0, path.stderr)
        XCTAssertEqual(path.stdout.trimmingCharacters(in: .whitespacesAndNewlines), storeDirectory.path)

        // list — empty to start (assert the clean exit too, not just empty stdout, so a
        // failing list with empty output can't pass vacuously).
        let emptyList = try run("list", "--store", storeDirectory.path)
        XCTAssertEqual(emptyList.status, 0, emptyList.stderr)
        XCTAssertEqual(emptyList.stdout, "")

        // set — writes an entry + a re-encoded PNG.
        let set = try run("set", "--store", storeDirectory.path, appKey, fixture.path)
        XCTAssertEqual(set.status, 0, set.stderr)
        XCTAssertTrue(set.stdout.contains(appKey), set.stdout)

        let entries = storeDirectory.appendingPathComponent("entries")
        let names = try FileManager.default.contentsOfDirectory(atPath: entries.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".json") }.count, 1)
        XCTAssertEqual(names.filter { $0.hasSuffix(".png") }.count, 1)

        // set again for the same key — overwriting must replace, not orphan, the stored
        // PNG (the file stem is derived from the key, so the second write lands on it).
        XCTAssertEqual(try run("set", "--store", storeDirectory.path, appKey, fixture.path).status, 0)
        let afterOverwrite = try FileManager.default.contentsOfDirectory(atPath: entries.path)
        XCTAssertEqual(afterOverwrite.filter { $0.hasSuffix(".json") }.count, 1)
        XCTAssertEqual(afterOverwrite.filter { $0.hasSuffix(".png") }.count, 1)

        // list — now shows the entry: <key> TAB <origin> TAB <image>.
        let list = try run("list", "--store", storeDirectory.path)
        XCTAssertEqual(list.status, 0, list.stderr)
        let columns = list.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        // Guard before subscripting: a malformed line should fail cleanly, not crash the
        // whole test runner out of bounds and swallow every later result.
        guard columns.count == 3 else {
            return XCTFail("expected 3 tab-separated columns, got \(columns) in \(list.stdout)")
        }
        XCTAssertEqual(columns[0], appKey)
        XCTAssertEqual(columns[1], "file")             // origin
        XCTAssertTrue(columns[2].hasSuffix(".png"))    // stored image name

        // get — reports the entry and the resolved image path.
        let get = try run("get", "--store", storeDirectory.path, appKey)
        XCTAssertEqual(get.status, 0, get.stderr)
        // Whitespace-tolerant so a cosmetic change to the aligned output isn't a failure.
        XCTAssertNotNil(get.stdout.range(of: #"origin:\s+file"#, options: .regularExpression), get.stdout)
        XCTAssertNotNil(get.stdout.range(of: "path:\\s+\(NSRegularExpression.escapedPattern(for: entries.path))",
                                         options: .regularExpression), get.stdout)

        // remove — clears it.
        let remove = try run("remove", "--store", storeDirectory.path, appKey)
        XCTAssertEqual(remove.status, 0, remove.stderr)
        XCTAssertTrue(remove.stdout.contains("Removed"), remove.stdout)

        // list — empty again.
        let finalList = try run("list", "--store", storeDirectory.path)
        XCTAssertEqual(finalList.status, 0, finalList.stderr)
        XCTAssertEqual(finalList.stdout, "")
    }

    // MARK: Error paths (non-zero exit)

    func testGetMissingKeyFails() throws {
        let result = try run("get", "--store", storeDirectory.path, "app:/nope.app")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("No entry"), result.stderr)
    }

    func testUnrecognizedKeyFails() throws {
        let result = try run("remove", "--store", storeDirectory.path, "not-a-key")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Unrecognized key"), result.stderr)
    }

    func testSetMissingImageFails() throws {
        let result = try run("set", "--store", storeDirectory.path,
                             "app:/Applications/Test.app", "/no/such/file.png")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("No such image file"), result.stderr)
    }

    // MARK: A hostile key can't escape the store

    func testHostileKeysStaySandboxedInTheStore() throws {
        // `set` routes every key through IconStore, whose IconEntryKey.fileStem sanitizes
        // to a safe bare name and resolvedURL bounds it inside entries/. A traversal-shaped
        // key is therefore stored *safely* under its sanitized stem, not rejected — so this
        // pins the invariant that nothing a key can spell writes outside the store, rather
        // than asserting a rejection the CLI deliberately doesn't do.
        let png = try fixturePNG()
        for key in ["app:../../pwned", "app:/tmp/pwned", "app:foo/../../bar",
                    "file:/a/b/../../../c"] {
            _ = try run("set", "--store", storeDirectory.path, key, png.path)
        }
        // The store root holds only entries/ and its README — nothing traversed out.
        let root = try FileManager.default.contentsOfDirectory(atPath: storeDirectory.path).sorted()
        XCTAssertEqual(root, ["README.txt", "entries"])
        // And every file inside entries/ is a safe bare name; no separator survived.
        let inside = try FileManager.default.contentsOfDirectory(
            atPath: storeDirectory.appendingPathComponent("entries").path)
        XCTAssertFalse(inside.contains { $0.contains("/") || $0.contains("..") }, "\(inside)")
    }

    // MARK: The shared location honors XDG_DATA_HOME on Linux

    #if os(Linux)
    func testDefaultStoreFollowsXDGDataHome() throws {
        let xdg = storeDirectory!   // reuse the temp dir as a fake XDG_DATA_HOME
        let result = try run("path", environment: ["XDG_DATA_HOME": xdg.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       xdg.appendingPathComponent("Pict").path)
    }
    #endif

    // MARK: Running the binary

    private struct Output {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    @discardableResult
    private func run(_ arguments: String..., environment: [String: String]? = nil) throws -> Output {
        let process = Process()
        process.executableURL = productsDirectory.appendingPathComponent("pict")
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        // Drain both pipes concurrently, then wait. Reading stdout to EOF blocks until the
        // child closes it, so a child blocked writing a full stderr pipe (>1 buffer) would
        // deadlock a *sequential* read — draining stderr on another queue closes that
        // window. The bounded wait turns a wedged child into a clean failure, not a hang.
        let stderrBox = DataBox()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            stderrBox.data = err.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        if drained.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            drained.wait()
            XCTFail("pict \(arguments) did not exit within 30 s")
        }
        process.waitUntilExit()
        return Output(stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                      stderr: String(data: stderrBox.data, encoding: .utf8) ?? "",
                      status: process.terminationStatus)
    }

    /// The checked-in fixture PNG, bundled as a `Bundle.module` test resource (returned
    /// directly — not a per-test copy, so tests must not mutate it).
    private func fixturePNG() throws -> URL {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample-icon", withExtension: "png"),
                               "sample-icon.png resource is missing")
        return url
    }

    /// The directory the built products (including `pict`) live in.
    private var productsDirectory: URL {
        #if os(macOS)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("couldn't locate the products directory")
        #else
        return Bundle.main.bundleURL
        #endif
    }
}
