import XCTest

final class WorkoutFlowUITests: XCTestCase {
    private var storeDirectory: URL!
    private var testRoot: URL!
    private var storeMarker: String?
    private var createdStoreDirectory = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteUITest-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        testRoot = root
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard manager.createFile(atPath: root.appendingPathComponent(".melete-ui-test-root").path, contents: Data("Melete UI test root v1".utf8), attributes: [.posixPermissions: 0o600]) else {
            throw IsolationError.invalidRoot
        }
        guard Self.validRoot(root) else { throw IsolationError.invalidRoot }
        storeDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: storeDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        createdStoreDirectory = true
        storeMarker = UUID().uuidString
        guard manager.createFile(atPath: storeDirectory.appendingPathComponent(".melete-ui-test-store").path, contents: Data(storeMarker!.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw IsolationError.invalidStore
        }
    }

    override func tearDownWithError() throws {
        if createdStoreDirectory, let storeDirectory, let storeMarker,
           (try? String(contentsOf: storeDirectory.appendingPathComponent(".melete-ui-test-store"), encoding: .utf8)) == storeMarker,
           let testRoot, Self.validRoot(testRoot) {
            try FileManager.default.removeItem(at: testRoot)
        }
    }

    func testCreateExerciseSaveDifferentSetsAndRestoreAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--melete-ui-test-root", testRoot.path, "--melete-ui-test-store", storeDirectory.path]
        app.launch()
        guard app.staticTexts["melete-isolated-store-active"].waitForExistence(timeout: 5) else {
            XCTFail("隔離ストア使用中の識別子がありません。安全のためUI操作を中断します。")
            return
        }
        guard isolationMarkerIsValid else {
            XCTFail("隔離ストアの識別子が一致しません。安全のためUI操作を中断します。")
            return
        }

        app.staticTexts["種目"].click()
        app.buttons["createExerciseButton"].click()
        app.textFields["exerciseNameField"].tapAndReplace("UIテストベンチプレス")
        app.textFields["metricNameField0"].tapAndReplace("重量")
        app.textFields["metricUnitField0"].tapAndReplace("kg")
        app.popUpButtons["metricFormatPicker0"].click()
        app.menuItems["小数（第3位まで）"].click()
        app.buttons["項目を追加"].click()
        app.textFields["metricNameField1"].tapAndReplace("回数")
        app.textFields["metricUnitField1"].tapAndReplace("回")
        app.buttons["saveExerciseButton"].click()

        XCTAssertTrue(app.staticTexts["UIテストベンチプレス"].waitForExistence(timeout: 5))
        app.staticTexts["記録"].click()
        app.buttons["addWorkoutButton"].click()
        app.buttons["addExerciseToWorkoutButton"].click()
        app.textFields["set1_metric_重量"].tapAndReplace("62.5")
        app.textFields["set1_metric_回数"].tapAndReplace("8")
        app.buttons["addSetButton"].click()
        app.textFields["set2_metric_重量"].tapAndReplace("60.25")
        app.textFields["set2_metric_回数"].tapAndReplace("10")
        app.buttons["saveWorkoutButton"].click()
        XCTAssertTrue(app.buttons["addWorkoutButton"].waitForExistence(timeout: 5))

        XCTAssertTrue(historyText(containing: "62.5", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(historyText(containing: "回数: 8回", in: app).exists)
        XCTAssertTrue(historyText(containing: "重量: 60.25kg", in: app).exists)
        XCTAssertTrue(historyText(containing: "回数: 10回", in: app).exists)

        app.terminate()
        app.launch()
        guard app.staticTexts["melete-isolated-store-active"].waitForExistence(timeout: 5) else {
            XCTFail("再起動後に隔離ストアを確認できません。安全のため以降の照合を中断します。")
            return
        }
        guard isolationMarkerIsValid else {
            XCTFail("再起動後に隔離ストアの識別子が一致しません。安全のため以降の照合を中断します。")
            return
        }
        XCTAssertTrue(app.staticTexts["UIテストベンチプレス"].waitForExistence(timeout: 5))
        XCTAssertTrue(historyText(containing: "重量: 62.5kg", in: app).exists)
        XCTAssertTrue(historyText(containing: "回数: 8回", in: app).exists)
        XCTAssertTrue(historyText(containing: "重量: 60.25kg", in: app).exists)
        XCTAssertTrue(historyText(containing: "回数: 10回", in: app).exists)

        let storeURL = storeDirectory.appendingPathComponent("Melete.store")
        let storeData = try Data(contentsOf: storeURL)
        XCTAssertFalse(storeData.isEmpty, "UI操作で専用SwiftDataストアが実際に作成される")
    }

    func testCancelAndConfirmWorkoutDeletionAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--melete-ui-test-root", testRoot.path, "--melete-ui-test-store", storeDirectory.path]
        app.launch()
        guard app.staticTexts["melete-isolated-store-active"].waitForExistence(timeout: 5) else {
            XCTFail("隔離ストア使用中の識別子がありません。安全のためUI操作を中断します。")
            return
        }
        guard isolationMarkerIsValid else {
            XCTFail("隔離ストアの識別子が一致しません。安全のためUI操作を中断します。")
            return
        }

        app.staticTexts["種目"].click()
        app.buttons["createExerciseButton"].click()
        app.textFields["exerciseNameField"].tapAndReplace("削除検証用スクワット")
        app.textFields["metricNameField0"].tapAndReplace("重量")
        app.textFields["metricUnitField0"].tapAndReplace("kg")
        app.buttons["saveExerciseButton"].click()
        XCTAssertTrue(app.staticTexts["削除検証用スクワット"].waitForExistence(timeout: 5))

        app.staticTexts["記録"].click()
        app.buttons["addWorkoutButton"].click()
        app.buttons["addExerciseToWorkoutButton"].click()
        app.textFields["set1_metric_重量"].tapAndReplace("80")
        app.buttons["saveWorkoutButton"].click()
        XCTAssertTrue(historyText(containing: "重量: 80kg", in: app).waitForExistence(timeout: 5))

        let deleteButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "の運動記録を削除")).firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.click()
        app.buttons["キャンセル"].click()
        XCTAssertTrue(historyText(containing: "重量: 80kg", in: app).waitForExistence(timeout: 5))

        deleteButton.click()
        app.buttons["この運動を削除"].click()
        XCTAssertFalse(historyText(containing: "重量: 80kg", in: app).exists)

        app.terminate()
        app.launch()
        guard app.staticTexts["melete-isolated-store-active"].waitForExistence(timeout: 5) else {
            XCTFail("再起動後に隔離ストアを確認できません。安全のため以降の照合を中断します。")
            return
        }
        guard isolationMarkerIsValid else {
            XCTFail("再起動後に隔離ストアの識別子が一致しません。安全のため以降の照合を中断します。")
            return
        }
        XCTAssertFalse(historyText(containing: "重量: 80kg", in: app).exists)
        app.staticTexts["種目"].click()
        XCTAssertTrue(app.staticTexts["削除検証用スクワット"].waitForExistence(timeout: 5))
    }
}

private enum IsolationError: Error {
    case invalidRoot
    case invalidStore
}

private extension WorkoutFlowUITests {
    var isolationMarkerIsValid: Bool {
        guard let storeMarker,
              Self.validRoot(testRoot),
              let attributes = try? FileManager.default.attributesOfItem(atPath: storeDirectory.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700 else { return false }
        let markerURL = storeDirectory.appendingPathComponent(".melete-ui-test-store")
        guard let markerAttributes = try? FileManager.default.attributesOfItem(atPath: markerURL.path),
              markerAttributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return (try? String(contentsOf: markerURL, encoding: .utf8)) == storeMarker
    }

    static func validRoot(_ root: URL) -> Bool {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: root.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700 else { return false }
        let marker = root.appendingPathComponent(".melete-ui-test-root")
        guard let markerAttributes = try? manager.attributesOfItem(atPath: marker.path),
              markerAttributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return (try? String(contentsOf: marker, encoding: .utf8)) == "Melete UI test root v1"
    }
}

private func historyText(containing text: String, in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
}

private extension XCUIElement {
    func tapAndReplace(_ value: String) {
        click()
        let currentValue = (self.value as? String) ?? ""
        if !currentValue.isEmpty {
            typeKey("a", modifierFlags: .command)
            typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        }
        typeText(value)
    }
}
