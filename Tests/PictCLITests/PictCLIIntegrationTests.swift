import XCTest
import Foundation

/// A `Sendable` holder so the concurrent stderr drain can publish its bytes without a
/// mutable capture — which warns under the Swift 5 language mode and is an error under
/// Swift 6. The `DispatchGroup` establishes the happens-before, so the unchecked
/// conformance is sound here.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Same justification as `DataBox`: a `@unchecked Sendable` wrapper so a non-Sendable
/// `FileHandle` can be carried into a drain closure without a Swift-6 capture error; the
/// `DispatchGroup` orders the read against the collection that follows.
private final class FileHandleBox: @unchecked Sendable {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
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
        let path = try runPict("path", "--store", storeDirectory.path)
        XCTAssertEqual(path.status, 0, path.stderr)
        XCTAssertEqual(path.stdout.trimmingCharacters(in: .whitespacesAndNewlines), storeDirectory.path)

        // list — empty to start (assert the clean exit too, not just empty stdout, so a
        // failing list with empty output can't pass vacuously).
        let emptyList = try runPict("list", "--store", storeDirectory.path)
        XCTAssertEqual(emptyList.status, 0, emptyList.stderr)
        XCTAssertEqual(emptyList.stdout, "")

        // set — writes an entry + a re-encoded PNG.
        let set = try runPict("set", "--store", storeDirectory.path, appKey, fixture.path)
        XCTAssertEqual(set.status, 0, set.stderr)
        XCTAssertTrue(set.stdout.contains(appKey), set.stdout)

        let entries = storeDirectory.appendingPathComponent("entries")
        let names = try FileManager.default.contentsOfDirectory(atPath: entries.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".json") }.count, 1)
        XCTAssertEqual(names.filter { $0.hasSuffix(".png") }.count, 1)

        // set again for the same key — overwriting must replace, not orphan, the stored
        // PNG (the file stem is derived from the key, so the second write lands on it).
        XCTAssertEqual(try runPict("set", "--store", storeDirectory.path, appKey, fixture.path).status, 0)
        let afterOverwrite = try FileManager.default.contentsOfDirectory(atPath: entries.path)
        XCTAssertEqual(afterOverwrite.filter { $0.hasSuffix(".json") }.count, 1)
        XCTAssertEqual(afterOverwrite.filter { $0.hasSuffix(".png") }.count, 1)

        // list — now shows the entry: <key> TAB <origin> TAB <image>.
        let list = try runPict("list", "--store", storeDirectory.path)
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
        let get = try runPict("get", "--store", storeDirectory.path, appKey)
        XCTAssertEqual(get.status, 0, get.stderr)
        // Whitespace-tolerant so a cosmetic change to the aligned output isn't a failure.
        XCTAssertNotNil(get.stdout.range(of: #"origin:\s+file"#, options: .regularExpression), get.stdout)
        XCTAssertNotNil(get.stdout.range(of: "path:\\s+\(NSRegularExpression.escapedPattern(for: entries.path))",
                                         options: .regularExpression), get.stdout)

        // remove — clears it.
        let remove = try runPict("remove", "--store", storeDirectory.path, appKey)
        XCTAssertEqual(remove.status, 0, remove.stderr)
        XCTAssertTrue(remove.stdout.contains("Removed"), remove.stdout)

        // list — empty again.
        let finalList = try runPict("list", "--store", storeDirectory.path)
        XCTAssertEqual(finalList.status, 0, finalList.stderr)
        XCTAssertEqual(finalList.stdout, "")
    }

    // MARK: Error paths (non-zero exit)

    func testGetMissingKeyFails() throws {
        let result = try runPict("get", "--store", storeDirectory.path, "app:/nope.app")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("No entry"), result.stderr)
    }

    func testUnrecognizedKeyFails() throws {
        let result = try runPict("remove", "--store", storeDirectory.path, "not-a-key")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Unrecognized key"), result.stderr)
    }

    func testSetMissingImageFails() throws {
        let result = try runPict("set", "--store", storeDirectory.path,
                             "app:/Applications/Test.app", "/no/such/file.png")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("No such image file"), result.stderr)
    }

    func testBareInvocationShowsHelpAndUnknownSubcommandFails() throws {
        // A bare `pict` prints help and exits 0 (standard ArgumentParser for a command
        // group) — so this pins that, not a usage error. It also pins the real error path:
        // an unknown subcommand exits non-zero with a message on stderr.
        let bare = try runPict()
        XCTAssertEqual(bare.status, 0, bare.stderr)
        XCTAssertTrue(bare.stdout.contains("USAGE"), bare.stdout)

        let unknown = try runPict("no-such-command")
        XCTAssertNotEqual(unknown.status, 0)
        XCTAssertFalse(unknown.stderr.isEmpty, "an unknown subcommand should explain itself")
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
            let result = try runPict("set", "--store", storeDirectory.path, key, png.path)
            XCTAssertEqual(result.status, 0,
                           "hostile key \(key) should be sanitized and stored, not rejected: \(result.stderr)")
        }
        // The store root holds only entries/ and its README — nothing traversed out.
        let root = try FileManager.default.contentsOfDirectory(atPath: storeDirectory.path).sorted()
        XCTAssertEqual(root, ["README.txt", "entries"])
        // And every file inside entries/ is a safe bare name; no separator survived.
        let inside = try FileManager.default.contentsOfDirectory(
            atPath: storeDirectory.appendingPathComponent("entries").path)
        XCTAssertFalse(inside.contains { $0.contains("/") || $0.contains("..") }, "\(inside)")
    }

    func testStoreTildeIsExpanded() throws {
        // A quoted `--store ~/…` (the shell leaves the `~`) resolves against the home
        // directory. `path` only prints — it writes nothing into home — so this is safe.
        let result = try runPict("path", "--store", "~/pict-cli-tilde-\(UUID().uuidString)")
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                        .hasPrefix(NSHomeDirectory()), result.stdout)
    }

    // MARK: The shared location honors XDG_DATA_HOME on Linux

    #if os(Linux)
    func testDefaultStoreFollowsXDGDataHome() throws {
        let xdg = storeDirectory!   // reuse the temp dir as a fake XDG_DATA_HOME
        let result = try runPict("path", environment: ["XDG_DATA_HOME": xdg.path])
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

    // Named `runPict`, not `run`, so a zero-argument call doesn't resolve to the inherited
    // `XCTestCase.run()` (which returns Void) instead of this variadic helper.
    @discardableResult
    private func runPict(_ arguments: String..., environment: [String: String]? = nil) throws -> Output {
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

        // Drain BOTH pipes on background queues, then wait. Reading a pipe to EOF blocks
        // until the child closes it, so draining either one on the calling thread would let
        // a child that wedges holding that stream open hang forever — and never reach the
        // watchdog. Draining both off-thread means the 30 s bound below governs every hang,
        // whichever stream the child is stuck on.
        let outBox = DataBox(), errBox = DataBox()
        let drained = DispatchGroup()
        drain(out.fileHandleForReading, into: outBox, group: drained)
        drain(err.fileHandleForReading, into: errBox, group: drained)

        if drained.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()                        // SIGTERM; pict installs no handler, so it exits
            if drained.wait(timeout: .now() + 5) == .timedOut {
                // The drains are still running: reading the boxes now would race them (the
                // group never established a happens-before edge). Bail with a sentinel and
                // leave the boxes untouched rather than risk UB.
                XCTFail("pict \(arguments) did not exit within 30 s")
                return Output(stdout: "", stderr: "pict \(arguments) timed out", status: -1)
            }
        }
        // Both pipes reaching EOF doesn't prove the child exited (it can close its fds and
        // linger), so bound the exit wait too instead of trusting waitUntilExit() to return.
        // The boxes are safe to read from here on — the drain group has completed above, so
        // the happens-before edge exists — but `terminationStatus` traps until the process
        // has actually exited, so the timeout path returns a sentinel status instead.
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { process.waitUntilExit(); exited.signal() }
        if exited.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            XCTFail("pict \(arguments) did not exit within 30 s")
            return Output(stdout: String(data: outBox.data, encoding: .utf8) ?? "",
                          stderr: String(data: errBox.data, encoding: .utf8) ?? "",
                          status: -1)
        }
        return Output(stdout: String(data: outBox.data, encoding: .utf8) ?? "",
                      stderr: String(data: errBox.data, encoding: .utf8) ?? "",
                      status: process.terminationStatus)
    }

    /// Reads `handle` to EOF on a background queue, publishing the bytes into `box` once
    /// `group` completes.
    private func drain(_ handle: FileHandle, into box: DataBox, group: DispatchGroup) {
        let reader = FileHandleBox(handle)
        group.enter()
        DispatchQueue.global().async {
            box.data = reader.handle.readDataToEndOfFile()
            group.leave()
        }
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
