import XCTest

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

        // list — empty to start.
        XCTAssertEqual(try run("list", "--store", storeDirectory.path).stdout, "")

        // set — writes an entry + a re-encoded PNG.
        let set = try run("set", "--store", storeDirectory.path, appKey, fixture.path)
        XCTAssertEqual(set.status, 0, set.stderr)
        XCTAssertTrue(set.stdout.contains(appKey), set.stdout)

        let entries = storeDirectory.appendingPathComponent("entries")
        let names = try FileManager.default.contentsOfDirectory(atPath: entries.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".json") }.count, 1)
        XCTAssertEqual(names.filter { $0.hasSuffix(".png") }.count, 1)

        // list — now shows the entry: <key> TAB <origin> TAB <image>.
        let list = try run("list", "--store", storeDirectory.path)
        let columns = list.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(columns.first, appKey)
        XCTAssertEqual(columns.count, 3)
        XCTAssertEqual(columns[1], "file")             // origin
        XCTAssertTrue(columns[2].hasSuffix(".png"))    // stored image name

        // get — reports the entry and the resolved image path.
        let get = try run("get", "--store", storeDirectory.path, appKey)
        XCTAssertEqual(get.status, 0, get.stderr)
        XCTAssertTrue(get.stdout.contains("origin:   file"), get.stdout)
        XCTAssertTrue(get.stdout.contains("path:     \(entries.path)"), get.stdout)

        // remove — clears it.
        let remove = try run("remove", "--store", storeDirectory.path, appKey)
        XCTAssertEqual(remove.status, 0, remove.stderr)
        XCTAssertTrue(remove.stdout.contains("Removed"), remove.stdout)

        // list — empty again.
        XCTAssertEqual(try run("list", "--store", storeDirectory.path).stdout, "")
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
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Output(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }

    /// The temp copy of the checked-in fixture PNG (`Bundle.module` resource).
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
