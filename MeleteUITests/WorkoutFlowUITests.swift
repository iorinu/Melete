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

        app.buttons["種目"].click()
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
        app.buttons["記録"].click()
        app.buttons["addWorkoutButton"].click()
        app.buttons["addExerciseToWorkoutButton"].click()
        app.textFields["set1_metric_重量"].tapAndReplace("62.5")
        app.textFields["set1_metric_回数"].tapAndReplace("8")
        app.buttons["addSetButton"].click()
        app.textFields["set2_metric_重量"].tapAndReplace("60.25")
        app.textFields["set2_metric_回数"].tapAndReplace("10")
        app.buttons["saveWorkoutButton"].click()
        XCTAssertTrue(historyText(containing: "重量: 62.5kg", in: app).waitForExistence(timeout: 5))
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

        app.buttons["種目"].click()
        app.buttons["createExerciseButton"].click()
        app.textFields["exerciseNameField"].tapAndReplace("削除検証用スクワット")
        app.textFields["metricNameField0"].tapAndReplace("重量")
        app.textFields["metricUnitField0"].tapAndReplace("kg")
        app.buttons["saveExerciseButton"].click()
        XCTAssertTrue(app.staticTexts["削除検証用スクワット"].waitForExistence(timeout: 5))

        app.buttons["記録"].click()
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
        app.buttons["種目"].click()
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

final class IsolatedV2SmokeUITests: XCTestCase {
    private var testRoot: URL!
    private var storeDirectory: URL!
    private var storeMarker: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let manager = FileManager.default
        testRoot = manager.temporaryDirectory
            .appendingPathComponent("MeleteIsolatedV2-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        try manager.createDirectory(at: testRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard manager.createFile(
            atPath: testRoot.appendingPathComponent(".melete-ui-test-root").path,
            contents: Data("Melete UI test root v1".utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw IsolatedV2SetupError.invalidRoot }

        storeDirectory = testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: storeDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        storeMarker = UUID().uuidString
        guard manager.createFile(
            atPath: storeDirectory.appendingPathComponent(".melete-ui-test-store").path,
            contents: Data(storeMarker.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw IsolatedV2SetupError.invalidStore }
    }

    func testIsolatedV2MarkersRemainValidAfterRelaunch() {
        let app = XCUIApplication()
        configureLaunchArguments(for: app)
        app.launch()
        guard verifySafeV2Launch(app, phase: "起動直後") else { return }
        app.terminate()

        configureLaunchArguments(for: app)
        app.launch()
        guard verifySafeV2Launch(app, phase: "再起動後") else { return }
        app.terminate()
    }

    private func configureLaunchArguments(for app: XCUIApplication) {
        app.launchArguments = [
            "--melete-ui-test-root", testRoot.path,
            "--melete-ui-test-store", storeDirectory.path,
            "--melete-v2-experimental"
        ]
    }

    private func verifySafeV2Launch(_ app: XCUIApplication, phase: String) -> Bool {
        let arguments = app.launchArguments
        guard let rootIndex = arguments.firstIndex(of: "--melete-ui-test-root"),
              arguments.indices.contains(rootIndex + 1), arguments[rootIndex + 1] == testRoot.path,
              arguments.filter({ $0 == "--melete-ui-test-root" }).count == 1,
              let storeIndex = arguments.firstIndex(of: "--melete-ui-test-store"),
              arguments.indices.contains(storeIndex + 1), arguments[storeIndex + 1] == storeDirectory.path,
              arguments.filter({ $0 == "--melete-ui-test-store" }).count == 1,
              arguments.filter({ $0 == "--melete-v2-experimental" }).count == 1 else {
            XCTFail("\(phase): 必須の隔離/V2起動引数がありません。以降の操作を中断します。")
            return false
        }
        guard validIsolationMarkers else {
            XCTFail("\(phase): root/storeの所有権またはmarkerが不正です。以降の操作を中断します。")
            return false
        }
        guard app.staticTexts["melete-isolated-store-active"].waitForExistence(timeout: 5),
              app.staticTexts["melete-experimental-v2-active"].waitForExistence(timeout: 5) else {
            XCTFail("\(phase): 隔離ストアまたはV2表示が確認できません。以降の操作を中断します。")
            return false
        }
        guard validIsolationMarkers else {
            XCTFail("\(phase): 画面確認後にroot/storeのmarker整合が失われました。以降の操作を中断します。")
            return false
        }
        return true
    }

    private var validIsolationMarkers: Bool {
        validDirectory(testRoot, permissions: 0o700)
            && validMarker(
                testRoot.appendingPathComponent(".melete-ui-test-root"),
                contents: "Melete UI test root v1"
            )
            && validDirectory(storeDirectory, permissions: 0o700)
            && validMarker(
                storeDirectory.appendingPathComponent(".melete-ui-test-store"),
                contents: storeMarker
            )
    }

    private func validDirectory(_ url: URL, permissions: UInt16) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
            && (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            && (attributes[.posixPermissions] as? NSNumber)?.uint16Value == permissions
    }

    private func validMarker(_ url: URL, contents: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
            && (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            && (attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600
            && (try? String(contentsOf: url, encoding: .utf8)) == contents
    }
}

private enum IsolatedV2SetupError: Error {
    case invalidRoot
    case invalidStore
}

/// V2項目定義の隔離ストアUIフロー。既存の削除処理を持つテストクラスとは独立させ、後片付けでrootを削除しない。
final class IsolatedV2MetricDefinitionFlowUITests: XCTestCase {
    private var testRoot: URL!
    private var storeDirectory: URL!
    private var storeMarker: String!

    override func setUpWithError() throws {
        // env=1はプログラム上のゲートにすぎず、Hermesはユーザーの明示承認なしに設定・実行しない。
        guard ProcessInfo.processInfo.environment["MELETE_APPROVE_ISOLATED_V2_UI"] == "1" else {
            throw XCTSkip("隔離V2画面操作は明示承認まで実行しません。")
        }
        continueAfterFailure = false
        let manager = FileManager.default
        testRoot = manager.temporaryDirectory
            .appendingPathComponent("MeleteV2MetricFlow-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        try manager.createDirectory(at: testRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard manager.createFile(
            atPath: testRoot.appendingPathComponent(".melete-ui-test-root").path,
            contents: Data("Melete UI test root v1".utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw IsolatedV2SetupError.invalidRoot }

        storeDirectory = testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: storeDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        storeMarker = UUID().uuidString
        guard manager.createFile(
            atPath: storeDirectory.appendingPathComponent(".melete-ui-test-store").path,
            contents: Data(storeMarker.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw IsolatedV2SetupError.invalidStore }
    }

    func testV2MetricDefinitionEditPreservesHistoryAndPersistsAfterRelaunch() throws {
        // env=1はプログラム上のゲートにすぎず、Hermesはユーザーの明示承認なしに設定・実行しない。
        guard ProcessInfo.processInfo.environment["MELETE_APPROVE_ISOLATED_V2_UI"] == "1" else {
            throw XCTSkip("隔離V2画面操作は明示承認まで実行しません。")
        }
        let app = XCUIApplication()
        prepareV2Launch(app)
        app.launch()
        guard safeV2State(app, phase: "起動直後") else { return }

        // 「種目」ボタンのクリックは承認前の操作なので、このテストを実行してはならない。
        guard safeV2State(app, phase: "種目画面へ移動する直前") else { return }
        let exerciseTab = app.buttons.matching(NSPredicate(format: "label == %@", "種目"))
        guard exerciseTab.count == 1 else {
            XCTFail("「種目」buttonが唯一ではありません。実画面での要素識別が未確認のため中断します。")
            return
        }
        exerciseTab.firstMatch.click()

        guard safeV2State(app, phase: "種目作成を開く直前") else { return }
        app.buttons["createExerciseButton"].click()
        guard safeV2State(app, phase: "種目名入力直前") else { return }
        app.textFields["exerciseNameField"].tapAndReplace("V2項目履歴テスト種目")
        guard safeV2State(app, phase: "項目名入力直前") else { return }
        app.textFields["metricNameField0"].tapAndReplace("重量")
        guard safeV2State(app, phase: "項目単位入力直前") else { return }
        app.textFields["metricUnitField0"].tapAndReplace("kg")
        guard safeV2State(app, phase: "小数形式選択直前") else { return }
        app.popUpButtons["metricFormatPicker0"].click()
        guard safeV2State(app, phase: "小数形式選択直前（メニュー）") else { return }
        app.menuItems["小数（第3位まで）"].click()
        guard safeV2State(app, phase: "種目保存直前") else { return }
        app.buttons["saveExerciseButton"].click()
        XCTAssertTrue(app.staticTexts["V2項目履歴テスト種目"].waitForExistence(timeout: 5))

        guard safeV2State(app, phase: "記録画面へ移動する直前") else { return }
        let historyTab = app.buttons.matching(NSPredicate(format: "label == %@", "記録"))
        guard historyTab.count == 1 else { XCTFail("「記録」buttonが唯一ではありません。"); return }
        historyTab.firstMatch.click()
        guard safeV2State(app, phase: "運動追加直前") else { return }
        app.buttons["addWorkoutButton"].click()
        guard safeV2State(app, phase: "種目追加直前") else { return }
        app.buttons["addExerciseToWorkoutButton"].click()
        guard safeV2State(app, phase: "初回重量入力直前") else { return }
        app.textFields["set1_metric_重量"].tapAndReplace("62.5")
        guard safeV2State(app, phase: "初回記録保存直前") else { return }
        app.buttons["saveWorkoutButton"].click()
        XCTAssertTrue(historyText(containing: "重量: 62.5kg", in: app).waitForExistence(timeout: 5))

        guard safeV2State(app, phase: "項目画面へ移動する直前") else { return }
        guard exerciseTab.count == 1 else { XCTFail("「種目」buttonが唯一ではありません。"); return }
        exerciseTab.firstMatch.click()
        guard safeV2State(app, phase: "項目管理を開く直前") else { return }
        let manageButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "manageMetricDefinitions_"))
        guard manageButtons.count == 1 else { XCTFail("項目管理buttonが一意に特定できません。"); return }
        manageButtons.firstMatch.click()

        guard safeV2State(app, phase: "項目単位変更直前") else { return }
        let unitFields = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "metricDefinitionUnit_"))
        guard unitFields.count == 1 else { XCTFail("項目単位欄が一意に特定できません。"); return }
        unitFields.firstMatch.tapAndReplace("lb")
        guard safeV2State(app, phase: "項目名変更直前") else { return }
        let nameFields = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "metricDefinitionName_"))
        guard nameFields.count == 1 else { XCTFail("項目名欄が一意に特定できません。"); return }
        nameFields.firstMatch.tapAndReplace("負荷")
        guard safeV2State(app, phase: "項目定義保存直前") else { return }
        app.buttons["saveMetricDefinitionsButton"].click()
        XCTAssertTrue(app.staticTexts["負荷（lb）・小数・必須"].waitForExistence(timeout: 5))

        guard safeV2State(app, phase: "再記録画面へ移動する直前") else { return }
        guard historyTab.count == 1 else { XCTFail("「記録」buttonが唯一ではありません。"); return }
        historyTab.firstMatch.click()
        XCTAssertTrue(historyText(containing: "重量: 62.5kg", in: app).exists, "過去の記録は当時の項目名・単位を保持する")
        guard safeV2State(app, phase: "新規運動追加直前") else { return }
        app.buttons["addWorkoutButton"].click()
        guard safeV2State(app, phase: "更新後種目追加直前") else { return }
        app.buttons["addExerciseToWorkoutButton"].click()
        guard safeV2State(app, phase: "更新後項目入力直前") else { return }
        app.textFields["set1_metric_負荷"].tapAndReplace("70.25")
        guard safeV2State(app, phase: "更新後記録保存直前") else { return }
        app.buttons["saveWorkoutButton"].click()
        XCTAssertTrue(historyText(containing: "負荷: 70.25lb", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(historyText(containing: "重量: 62.5kg", in: app).exists)

        app.terminate()
        prepareV2Launch(app)
        app.launch()
        guard safeV2State(app, phase: "再起動後") else { return }
        XCTAssertTrue(app.staticTexts["V2項目履歴テスト種目"].waitForExistence(timeout: 5))
        XCTAssertTrue(historyText(containing: "負荷: 70.25lb", in: app).exists)
        XCTAssertTrue(historyText(containing: "重量: 62.5kg", in: app).exists)
        app.terminate()
    }

    private func prepareV2Launch(_ app: XCUIApplication) {
        app.launchArguments = [
            "--melete-ui-test-root", testRoot.path,
            "--melete-ui-test-store", storeDirectory.path,
            "--melete-v2-experimental"
        ]
    }

    private func safeV2State(_ app: XCUIApplication, phase: String) -> Bool {
        let arguments = app.launchArguments
        guard let rootIndex = arguments.firstIndex(of: "--melete-ui-test-root"),
              arguments.indices.contains(rootIndex + 1), arguments[rootIndex + 1] == testRoot.path,
              arguments.filter({ $0 == "--melete-ui-test-root" }).count == 1,
              let storeIndex = arguments.firstIndex(of: "--melete-ui-test-store"),
              arguments.indices.contains(storeIndex + 1), arguments[storeIndex + 1] == storeDirectory.path,
              arguments.filter({ $0 == "--melete-ui-test-store" }).count == 1,
              arguments.filter({ $0 == "--melete-v2-experimental" }).count == 1 else {
            XCTFail("\(phase): 隔離/V2起動引数が不正です。操作を中断します。"); return false
        }
        guard validMarkers else {
            XCTFail("\(phase): root/storeのowner・permission・markerが不正です。操作を中断します。"); return false
        }
        guard app.staticTexts["melete-isolated-store-active"].exists,
              app.staticTexts["melete-experimental-v2-active"].exists else {
            XCTFail("\(phase): 隔離表示またはV2表示がありません。操作を中断します。"); return false
        }
        guard validMarkers else {
            XCTFail("\(phase): 画面確認後にmarker整合が失われました。操作を中断します。"); return false
        }
        return true
    }

    private var validMarkers: Bool {
        let rootPath = testRoot.standardizedFileURL.path
        let storePath = storeDirectory.standardizedFileURL.path
        return storePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            && UUID(uuidString: storeMarker) != nil
            && validDirectory(testRoot, permissions: 0o700)
            && validMarker(testRoot.appendingPathComponent(".melete-ui-test-root"), contents: "Melete UI test root v1")
            && validDirectory(storeDirectory, permissions: 0o700)
            && validMarker(storeDirectory.appendingPathComponent(".melete-ui-test-store"), contents: storeMarker)
    }

    private func validDirectory(_ url: URL, permissions: UInt16) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
            && (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            && (attributes[.posixPermissions] as? NSNumber)?.uint16Value == permissions
    }

    private func validMarker(_ url: URL, contents: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
            && (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            && (attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600
            && (try? String(contentsOf: url, encoding: .utf8)) == contents
    }
}
