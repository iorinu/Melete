import XCTest

final class WindowProbeSmokeUITests: XCTestCase {
    private var testRoot: URL!
    private var storeDirectory: URL!
    private var storeMarker: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let manager = FileManager.default
        testRoot = manager.temporaryDirectory
            .appendingPathComponent("MeleteWindowProbe-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        try manager.createDirectory(at: testRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard manager.createFile(
            atPath: testRoot.appendingPathComponent(".melete-ui-test-root").path,
            contents: Data("Melete UI test root v1".utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw IsolationError.invalidRoot }

        storeDirectory = testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: storeDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        storeMarker = UUID().uuidString
        guard manager.createFile(
            atPath: storeDirectory.appendingPathComponent(".melete-ui-test-store").path,
            contents: Data(storeMarker.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw IsolationError.invalidStore }
    }

    override func tearDownWithError() throws {
        guard validRoot, validStore else { return }
        try FileManager.default.removeItem(at: testRoot)
    }

    func testWindowAndIsolationMarkersAppearWithoutSaving() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--melete-ui-test-root", testRoot.path, "--melete-ui-test-store", storeDirectory.path]
        app.launch()

        guard app.staticTexts["melete-isolated-store-active"].waitForExistence(timeout: 5) else {
            XCTFail("隔離ストア使用中の表示がありません。安全のため操作を中断します。")
            return
        }
        guard validStore else {
            XCTFail("隔離ストアの所有マーカーが一致しません。安全のため操作を中断します。")
            return
        }
        XCTAssertTrue(app.staticTexts["ホーム"].waitForExistence(timeout: 5))
        XCTAssertTrue(validStore)
        app.terminate()

        app.launch()
        guard app.staticTexts["melete-isolated-store-active"].waitForExistence(timeout: 5) else {
            XCTFail("再起動後に隔離ストア使用中の表示がありません。安全のため操作を中断します。")
            return
        }
        XCTAssertTrue(validStore)
        XCTAssertTrue(app.staticTexts["ホーム"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testExerciseNavigationAfterIsolationCheck() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--melete-ui-test-root", testRoot.path, "--melete-ui-test-store", storeDirectory.path]
        app.launch()

        guard app.staticTexts["melete-isolated-store-active"].waitForExistence(timeout: 5) else {
            XCTFail("隔離ストア使用中の表示がありません。安全のため操作を中断します。")
            return
        }
        guard validStore else {
            XCTFail("隔離ストアの所有マーカーが一致しません。安全のため操作を中断します。")
            return
        }

        app.buttons["種目"].click()
        let createButtonAppeared = app.buttons["createExerciseButton"].waitForExistence(timeout: 5)
        XCTAssertTrue(createButtonAppeared)
        XCTAssertEqual(app.state, .runningForeground)
        app.terminate()
    }

    private var validRoot: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: testRoot.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700 else { return false }
        return (try? String(contentsOf: testRoot.appendingPathComponent(".melete-ui-test-root"), encoding: .utf8)) == "Melete UI test root v1"
    }

    private var validStore: Bool {
        guard validRoot,
              let attributes = try? FileManager.default.attributesOfItem(atPath: storeDirectory.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700 else { return false }
        return (try? String(contentsOf: storeDirectory.appendingPathComponent(".melete-ui-test-store"), encoding: .utf8)) == storeMarker
    }
}

private enum IsolationError: Error {
    case invalidRoot
    case invalidStore
}
