import AppKit
import Darwin
import XCTest

/// ScratchProbe用の隔離ストアUIテスト（テスト本体は未実行・未検証）。
///
/// - 安全性レビュー未完了のため、setUpWithErrorで常にskipする。
/// - アプリ自身が隔離V2 storeを開いた後に表示するstore UUIDとPIDを、fixtureとプロセス情報に照合する。
/// - 以下の確認内容は意図するテスト項目であり、実行済みまたは確認済みの動作ではない。
/// - fixtureはscratch（`~/.hermes/cache/scratch`）直下に新規UUID名で作るrootと、その中の新規UUID名のstoreだけ。
///   システム一時ディレクトリには作らない。既存ファイルの削除・移動・上書きは一切せず、作成物はscratchに残す。
/// - 起動前: 起動引数・root/storeの所有者・権限・marker、同じbundle IDのプロセスが無いことを確認する。
/// - 起動後: UI証拠のstore UUID/PID・実行ファイル・所有者、root/store、隔離表示とV2表示、
///   プロセスが実際に開いているstoreファイルのパスを確認する。どれかを確認できなければ直ちに操作を中断する。
/// - GUIフローは自動的に検証済みとは扱わない。
final class ScratchProbeUITests: XCTestCase {
    private static let rootFlag = "--melete-ui-test-root"
    private static let storeFlag = "--melete-ui-test-store"
    private static let v2Flag = "--melete-v2-experimental"
    private static let scratchBundleIdentifier = "jp.iorinu.Melete.UITesting.Scratch"

    private var fixture: ScratchUIFixture!
    private var target: ScratchTargetApp!
    private var launchedApp: XCUIApplication?
    private var verifiedProcess: ProcessProbe.Identity?

    override func setUpWithError() throws {
        throw XCTSkip("安全性レビュー未完了のため、ScratchProbeは常にskipします。")
    }

    override func tearDownWithError() throws {
        // アプリの終了だけ行う。fixtureは削除しない
        if let app = launchedApp, safe(app, "終了直前") {
            app.terminate()
        }
        launchedApp = nil
        verifiedProcess = nil
    }

    // MARK: - 保存なしスモーク

    /// 起動・再起動で隔離条件を確認するだけ。クリックや入力、保存操作はしない。
    func testScratchLaunchIsIsolatedWithoutSaving() throws {
        try prepareFixture()
        guard let app = launchSafely(phase: "初回起動") else { return }
        guard relaunchSafely(app, phase: "再起動") != nil else { return }
    }

    // MARK: - 項目編集・無効化／復帰

    func testMetricEditDeactivateAndReactivatePersistAfterRelaunch() throws {
        try requireFlowApproval()
        try prepareFixture()
        guard var app = launchSafely(phase: "初回起動") else { return }

        // 2項目の種目を作成する
        guard safe(app, "種目画面へ移動する直前"), clickUniqueButton(label: "種目", in: app) else { return }
        guard safe(app, "種目作成を開く直前"), clickUniqueButton(identifier: "createExerciseButton", in: app) else { return }
        guard safe(app, "種目名入力直前"), replaceText(identifier: "exerciseNameField", with: "スクラッチ項目編集種目", in: app) else { return }
        guard safe(app, "項目1入力直前"),
              replaceText(identifier: "metricNameField0", with: "重量", in: app),
              replaceText(identifier: "metricUnitField0", with: "kg", in: app) else { return }
        guard safe(app, "小数形式選択直前"), clickUniqueElement(app.popUpButtons, identifier: "metricFormatPicker0", in: app) else { return }
        guard safe(app, "小数形式メニュー選択直前"), clickUniqueElement(app.menuItems, label: "小数（第3位まで）", in: app) else { return }
        guard safe(app, "小数形式の選択結果確認直前"),
              (app.popUpButtons["metricFormatPicker0"].value as? String) == "小数（第3位まで）" else {
            XCTFail("項目1の形式が小数に切り替わったことを確認できません。操作を中断します。"); return
        }
        guard safe(app, "項目追加直前"), clickUniqueButton(label: "項目を追加", in: app) else { return }
        guard safe(app, "項目2入力直前"),
              replaceText(identifier: "metricNameField1", with: "回数", in: app),
              replaceText(identifier: "metricUnitField1", with: "回", in: app) else { return }
        guard safe(app, "種目保存直前"), clickUniqueButton(identifier: "saveExerciseButton", in: app),
              waitForDisappearance(app.buttons["saveExerciseButton"]) else { return }

        // 変更前の項目で記録を1件保存する
        guard safe(app, "記録画面へ移動する直前"), clickUniqueButton(label: "記録", in: app) else { return }
        guard safe(app, "運動追加直前"), clickUniqueButton(identifier: "addWorkoutButton", in: app) else { return }
        guard safe(app, "種目追加直前"), clickUniqueButton(identifier: "addExerciseToWorkoutButton", in: app) else { return }
        guard safe(app, "初回値入力直前"),
              replaceText(identifier: "set1_metric_重量", with: "60.5", in: app),
              replaceText(identifier: "set1_metric_回数", with: "8", in: app) else { return }
        guard safe(app, "初回記録保存直前"), clickUniqueButton(identifier: "saveWorkoutButton", in: app),
              waitForDisappearance(app.buttons["saveWorkoutButton"]) else { return }
        XCTAssertTrue(historyText(containing: "重量: 60.5kg", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(historyText(containing: "回数: 8回", in: app).exists)

        // 重量を「負荷（lb）」に編集し、回数を入力欄から外す
        guard safe(app, "項目管理を開く直前"), clickUniqueButton(label: "種目", in: app),
              clickUniqueButton(identifierPrefix: "manageMetricDefinitions_", in: app) else { return }
        guard safe(app, "項目定義の特定直前"),
              let weightID = metricDefinitionID(named: "重量", in: app),
              let repsID = metricDefinitionID(named: "回数", in: app) else { return }
        guard safe(app, "項目名・単位変更直前"),
              replaceText(identifier: "metricDefinitionName_\(weightID)", with: "負荷", in: app),
              replaceText(identifier: "metricDefinitionUnit_\(weightID)", with: "lb", in: app) else { return }
        guard safe(app, "項目無効化直前"), toggleMetricActive(repsID, in: app) else { return }
        guard safe(app, "項目定義保存直前（無効化）"), clickUniqueButton(identifier: "saveMetricDefinitionsButton", in: app),
              waitForDisappearance(app.buttons["saveMetricDefinitionsButton"]) else { return }

        // 新規入力欄: 負荷だけがあり、外した回数と旧名の重量は無い。保存せずに閉じる
        guard safe(app, "無効化後の入力欄確認直前"), clickUniqueButton(label: "記録", in: app),
              clickUniqueButton(identifier: "addWorkoutButton", in: app),
              clickUniqueButton(identifier: "addExerciseToWorkoutButton", in: app) else { return }
        XCTAssertTrue(app.textFields["set1_metric_負荷"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["set1_metric_回数"].exists, "外した項目は新規入力欄に出ない")
        XCTAssertFalse(app.textFields["set1_metric_重量"].exists, "変更前の項目名は新規入力欄に出ない")
        guard safe(app, "入力欄確認後に閉じる直前"), clickUniqueButton(label: "キャンセル", in: app),
              waitForDisappearance(app.buttons["saveWorkoutButton"]) else { return }
        // 過去のセットは記録当時の名前・単位・値のまま
        XCTAssertTrue(historyText(containing: "重量: 60.5kg", in: app).exists)
        XCTAssertTrue(historyText(containing: "回数: 8回", in: app).exists)

        // 無効状態を再起動後にも確認してから復帰する
        guard let relaunchedAfterDisable = relaunchSafely(app, phase: "無効化後の再起動") else { return }
        app = relaunchedAfterDisable
        guard safe(app, "再起動後の無効状態確認画面へ移動する直前"),
              clickUniqueButton(label: "種目", in: app),
              clickUniqueButton(identifierPrefix: "manageMetricDefinitions_", in: app) else { return }
        guard safe(app, "再起動後の無効状態確認直前") else { return }
        let inactive = app.descendants(matching: .any).matching(identifier: "metricDefinitionActive_\(repsID)")
        guard inactive.count == 1, String(describing: inactive.firstMatch.value).lowercased().contains("0") else {
            XCTFail("再起動後に回数項目の無効状態を確認できません。操作を中断します。"); return
        }

        // 回数を復帰する
        // 再起動後の無効状態確認で開いた管理シートをそのまま使う
        guard safe(app, "項目復帰直前"), toggleMetricActive(repsID, in: app) else { return }
        guard safe(app, "項目定義保存直前（復帰）"), clickUniqueButton(identifier: "saveMetricDefinitionsButton", in: app),
              waitForDisappearance(app.buttons["saveMetricDefinitionsButton"]) else { return }

        // 復帰後の定義で新しい記録を保存する
        guard safe(app, "復帰後の運動追加直前"), clickUniqueButton(label: "記録", in: app),
              clickUniqueButton(identifier: "addWorkoutButton", in: app),
              clickUniqueButton(identifier: "addExerciseToWorkoutButton", in: app) else { return }
        guard safe(app, "復帰後の値入力直前"),
              replaceText(identifier: "set1_metric_負荷", with: "70.25", in: app),
              replaceText(identifier: "set1_metric_回数", with: "6", in: app) else { return }
        guard safe(app, "復帰後の記録保存直前"), clickUniqueButton(identifier: "saveWorkoutButton", in: app),
              waitForDisappearance(app.buttons["saveWorkoutButton"]) else { return }
        XCTAssertTrue(historyText(containing: "負荷: 70.25lb", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(historyText(containing: "回数: 6回", in: app).exists)
        XCTAssertTrue(historyText(containing: "重量: 60.5kg", in: app).exists)
        XCTAssertTrue(historyText(containing: "回数: 8回", in: app).exists)

        // 再起動後も定義と履歴が保持されている
        guard let relaunched = relaunchSafely(app, phase: "再起動") else { return }
        app = relaunched
        guard safe(app, "再起動後の記録画面へ移動する直前"), clickUniqueButton(label: "記録", in: app) else { return }
        XCTAssertTrue(historyText(containing: "負荷: 70.25lb", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(historyText(containing: "回数: 6回", in: app).exists)
        XCTAssertTrue(historyText(containing: "重量: 60.5kg", in: app).exists)
        XCTAssertTrue(historyText(containing: "回数: 8回", in: app).exists)
        guard safe(app, "再起動後の入力欄確認直前"), clickUniqueButton(identifier: "addWorkoutButton", in: app),
              clickUniqueButton(identifier: "addExerciseToWorkoutButton", in: app) else { return }
        XCTAssertTrue(app.textFields["set1_metric_負荷"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["set1_metric_回数"].exists, "復帰した項目は再起動後も入力欄に出る")
        guard safe(app, "再起動後の入力欄を閉じる直前"), clickUniqueButton(label: "キャンセル", in: app),
              waitForDisappearance(app.buttons["saveWorkoutButton"]) else { return }
        _ = safe(app, "終了直前")
    }

    // MARK: - セット／種目記録の削除

    func testSetAndRecordDeletionCancelConfirmAndRelaunch() throws {
        try requireFlowApproval()
        try prepareFixture()
        guard var app = launchSafely(phase: "初回起動") else { return }

        // 項目名が異なる2種目を作る（入力欄の識別子が種目間で重ならないようにする）
        guard createSingleMetricExercise(name: "スクラッチ削除種目A", metricName: "重量", unit: "kg", decimal: true, in: app),
              createSingleMetricExercise(name: "スクラッチ削除種目B", metricName: "距離", unit: "m", decimal: false, in: app) else { return }

        // 種目A 2セット、種目B 1セットの運動記録を1件保存する
        guard safe(app, "記録画面へ移動する直前"), clickUniqueButton(label: "記録", in: app),
              clickUniqueButton(identifier: "addWorkoutButton", in: app) else { return }
        guard selectExercise(named: "スクラッチ削除種目A", in: app),
              safe(app, "種目A追加直前"), clickUniqueButton(identifier: "addExerciseToWorkoutButton", in: app) else { return }
        guard safe(app, "種目Aセット1入力直前"), replaceText(identifier: "set1_metric_重量", with: "62.5", in: app) else { return }
        // 種目Bを追加する前なのでセット追加ボタンは1つだけ
        guard safe(app, "種目Aセット追加直前"), clickUniqueButton(identifier: "addSetButton", in: app) else { return }
        guard safe(app, "種目Aセット2入力直前"), replaceText(identifier: "set2_metric_重量", with: "57.5", in: app) else { return }
        guard selectExercise(named: "スクラッチ削除種目B", in: app),
              safe(app, "種目B追加直前"), clickUniqueButton(identifier: "addExerciseToWorkoutButton", in: app) else { return }
        guard safe(app, "種目Bセット1入力直前"), replaceText(identifier: "set1_metric_距離", with: "400", in: app) else { return }
        guard safe(app, "記録保存直前"), clickUniqueButton(identifier: "saveWorkoutButton", in: app),
              waitForDisappearance(app.buttons["saveWorkoutButton"]) else { return }
        XCTAssertTrue(historyText(containing: "重量: 62.5kg", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(historyText(containing: "重量: 57.5kg", in: app).exists)
        XCTAssertTrue(historyText(containing: "距離: 400m", in: app).exists)

        // セット削除: キャンセル
        guard safe(app, "セット削除キャンセル用に編集を開く直前"), clickUniqueButton(identifierPrefix: "editWorkout_", in: app) else { return }
        guard safe(app, "削除対象セットの特定直前"), let setButton = setTwoDeleteButton(in: app),
              let setID = suffix(of: setButton.identifier, after: "deleteWorkoutSet_") else { return }
        guard safe(app, "セット削除確認を開く直前（キャンセル）"),
              let setCancel = openConfirmation(by: setButton, confirmIdentifier: "confirmDeleteWorkoutSet_\(setID)", in: app) else { return }
        guard safe(app, "セット削除キャンセル直前"), click(setCancel),
              waitForDisappearance(app.buttons["confirmDeleteWorkoutSet_\(setID)"]) else { return }
        guard safe(app, "編集を閉じる直前（セット削除キャンセル後）"), clickUniqueButton(label: "キャンセル", in: app),
              waitForDisappearance(app.buttons["saveWorkoutEditsButton"]) else { return }
        XCTAssertTrue(historyText(containing: "重量: 57.5kg", in: app).exists, "キャンセルではセットを削除しない")
        XCTAssertTrue(historyText(containing: "重量: 62.5kg", in: app).exists)
        XCTAssertTrue(historyText(containing: "距離: 400m", in: app).exists)

        // セット削除: 確定（同じ種目の他セット・他種目は残る）
        guard safe(app, "セット削除確定用に編集を開く直前"), clickUniqueButton(identifierPrefix: "editWorkout_", in: app) else { return }
        // 要素参照は再解決されるため、保持しておいたIDの文字列で同一セットかを確認する
        guard safe(app, "削除対象セットの再特定直前"), let setButtonAgain = setTwoDeleteButton(in: app),
              setButtonAgain.identifier == "deleteWorkoutSet_\(setID)" else {
            XCTFail("削除対象セットが前回と一致しません。操作を中断します。"); return
        }
        guard safe(app, "セット削除確認を開く直前（確定）"),
              openConfirmation(by: setButtonAgain, confirmIdentifier: "confirmDeleteWorkoutSet_\(setID)", in: app) != nil else { return }
        guard safe(app, "セット削除確定直前"), clickUniqueButton(identifier: "confirmDeleteWorkoutSet_\(setID)", in: app),
              waitForDisappearance(app.buttons["saveWorkoutEditsButton"]) else { return }
        XCTAssertTrue(waitForDisappearance(historyText(containing: "重量: 57.5kg", in: app)), "確定したセットは削除される")
        XCTAssertTrue(historyText(containing: "重量: 62.5kg", in: app).exists, "同じ種目の他セットは残る")
        XCTAssertTrue(historyText(containing: "距離: 400m", in: app).exists, "他の種目記録は残る")

        // 種目記録削除: キャンセル
        guard safe(app, "種目記録削除キャンセル用に編集を開く直前"), clickUniqueButton(identifierPrefix: "editWorkout_", in: app) else { return }
        guard safe(app, "削除対象種目記録の特定直前"), let recordButton = recordBDeleteButton(in: app) else { return }
        guard safe(app, "種目記録削除確認を開く直前（キャンセル）"),
              let recordCancel = openConfirmation(by: recordButton, confirmIdentifierPrefix: "confirmDeleteWorkoutRecord_", in: app) else { return }
        guard safe(app, "種目記録削除キャンセル直前"), click(recordCancel),
              waitForDisappearance(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "confirmDeleteWorkoutRecord_")).firstMatch) else { return }
        guard safe(app, "編集を閉じる直前（種目記録削除キャンセル後）"), clickUniqueButton(label: "キャンセル", in: app),
              waitForDisappearance(app.buttons["saveWorkoutEditsButton"]) else { return }
        XCTAssertTrue(historyText(containing: "距離: 400m", in: app).exists, "キャンセルでは種目記録を削除しない")
        XCTAssertTrue(historyText(containing: "重量: 62.5kg", in: app).exists)

        // 種目記録削除: 確定（同じWorkoutの他種目とWorkoutは残る）
        guard safe(app, "種目記録削除確定用に編集を開く直前"), clickUniqueButton(identifierPrefix: "editWorkout_", in: app) else { return }
        guard safe(app, "削除対象種目記録の再特定直前"), let recordButtonAgain = recordBDeleteButton(in: app) else { return }
        guard safe(app, "種目記録削除確認を開く直前（確定）"),
              openConfirmation(by: recordButtonAgain, confirmIdentifierPrefix: "confirmDeleteWorkoutRecord_", in: app) != nil else { return }
        guard safe(app, "種目記録削除確定直前"), clickUniqueButton(identifierPrefix: "confirmDeleteWorkoutRecord_", in: app),
              waitForDisappearance(app.buttons["saveWorkoutEditsButton"]) else { return }
        XCTAssertTrue(waitForDisappearance(historyText(containing: "距離: 400m", in: app)), "確定した種目記録は削除される")
        XCTAssertTrue(historyText(containing: "重量: 62.5kg", in: app).exists, "同じWorkoutの他種目は残る")
        XCTAssertEqual(editWorkoutButtons(in: app).count, 1, "親のWorkoutは残る")

        // 再起動後も削除結果が保持されている
        guard let relaunched = relaunchSafely(app, phase: "再起動") else { return }
        app = relaunched
        guard safe(app, "再起動後の記録画面へ移動する直前"), clickUniqueButton(label: "記録", in: app) else { return }
        XCTAssertTrue(historyText(containing: "重量: 62.5kg", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(historyText(containing: "重量: 57.5kg", in: app).exists)
        XCTAssertFalse(historyText(containing: "距離: 400m", in: app).exists)
        XCTAssertEqual(editWorkoutButtons(in: app).count, 1)
        guard safe(app, "再起動後の種目画面へ移動する直前"), clickUniqueButton(label: "種目", in: app) else { return }
        XCTAssertTrue(app.staticTexts["スクラッチ削除種目A"].waitForExistence(timeout: 5), "記録削除で種目は削除しない")
        XCTAssertTrue(app.staticTexts["スクラッチ削除種目B"].exists, "記録削除で種目は削除しない")
        _ = safe(app, "終了直前")
    }
}

// MARK: - 起動と安全確認

private extension ScratchProbeUITests {
    var expectedLaunchArguments: [String] {
        [Self.rootFlag, fixture.root.path, Self.storeFlag, fixture.store.path, Self.v2Flag]
    }

    func requireFlowApproval() throws {
        guard ProcessInfo.processInfo.environment["MELETE_APPROVE_SCRATCH_UI_FLOW"] == "1" else {
            throw XCTSkip("scratch隔離ストアへの保存を含むUIフローは明示承認まで実行しません。")
        }
    }

    /// 起動対象アプリの特定とfixture作成。どちらかが失敗したらテストを失敗させて止める
    func prepareFixture() throws {
        do {
            target = try ScratchTargetApp.locate(expectedBundleIdentifier: Self.scratchBundleIdentifier)
        } catch {
            XCTFail("起動対象のScratchProbeアプリを安全に特定できません。起動しません。")
            throw error
        }
        do {
            fixture = try ScratchUIFixture.create()
        } catch {
            XCTFail("scratch直下にfixtureを安全に作成できません。起動しません。")
            throw FixtureSetupError.failed
        }
        // 個人パスを含めないよう、ログにはUUID名だけを残す
        XCTContext.runActivity(named: "scratch fixture root=\(fixture.root.lastPathComponent) store=\(fixture.store.lastPathComponent)") { _ in }
    }

    func launchSafely(phase: String) -> XCUIApplication? {
        // locateで検査済みのMelete.appのファイルURLを指定し、bundle IDだけによる起動対象の曖昧さを狭める。
        // ただしこれで起動が安全になったわけではない（未解決）:
        // - launch()は同じアプリの既存インスタンスを終了させ得る（起動前の同一bundle ID拒否はそのため維持する）
        // - 確認から起動までの間に同じUIDの別プロセスが割り込むレース
        // - 起動したプロセスとUI証拠のPIDの結び付け（PID binding）は起動後の照合に頼っており、証明されていない
        let app = XCUIApplication(url: target.appURL)
        app.launchArguments = expectedLaunchArguments
        guard verifyBeforeLaunch(app, phase: phase) else { return nil }
        guard noRunningScratchApplication(phase: phase) else { return nil }
        launchedApp = app
        app.launch()
        verifiedProcess = nil
        guard safe(app, "\(phase)直後", waitForUI: true) else { return nil }
        return app
    }

    func relaunchSafely(_ app: XCUIApplication, phase: String) -> XCUIApplication? {
        guard safe(app, "\(phase)の終了直前") else { return nil }
        app.terminate()
        launchedApp = nil
        verifiedProcess = nil
        return launchSafely(phase: phase)
    }

    /// 起動前の確認。起動引数・fixture・既存プロセスの有無
    func verifyBeforeLaunch(_ app: XCUIApplication, phase: String) -> Bool {
        guard app.launchArguments == expectedLaunchArguments else {
            XCTFail("\(phase)前: 起動引数が隔離root/store/V2の指定と一致しません。起動しません。"); return false
        }
        if let problem = fixture.validationProblem() {
            XCTFail("\(phase)前: \(problem)。起動しません。"); return false
        }
        // 終了直後に同じbundle IDのプロセスが残っている場合は起動しない（終了させない）
        return noRunningScratchApplication(phase: phase)
    }

    /// bundle IDが同じ既存アプリは実行ファイルの場所に関係なく、起動で終了され得るため拒否する。
    func noRunningScratchApplication(phase: String) -> Bool {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.scratchBundleIdentifier).isEmpty else {
            XCTFail("\(phase)前: 同じbundle IDのアプリが既に動作中です。起動しません。"); return false
        }
        return true
    }

    /// 起動後の確認。失敗理由を記録してfalseを返す。呼び出し側は直ちに操作を中断する
    func safe(_ app: XCUIApplication, _ phase: String, waitForUI: Bool = false) -> Bool {
        guard app.launchArguments == expectedLaunchArguments else {
            XCTFail("\(phase): 起動引数の設定が隔離指定と一致しません。操作を中断します。"); return false
        }
        if let problem = fixture.validationProblem() {
            XCTFail("\(phase): \(problem)。操作を中断します。"); return false
        }
        let pidMarker = app.staticTexts.matching(identifier: "melete-scratch-process-evidence")
        let markerVisible = waitForUI ? pidMarker.firstMatch.waitForExistence(timeout: 10) : pidMarker.firstMatch.exists
        guard markerVisible, pidMarker.count == 1,
              let evidence = ScratchEvidencePolicy.evidence(fromMarker: pidMarker.firstMatch.label) else {
            XCTFail("\(phase): UI上のscratch PID証拠を確認できません。操作を中断します。"); return false
        }
        let pid = evidence.pid
        let identity: ProcessProbe.Identity
        switch checkedProcess(pid, previouslyVerified: verifiedProcess) {
        case .success(let verified):
            identity = verified
        case .failure(.processChanged):
            XCTFail("\(phase): 起動プロセスのPIDまたは開始時刻が変わりました。操作を中断します。"); return false
        case .failure:
            XCTFail("\(phase): 起動プロセスの所有者を確認できません。操作を中断します。"); return false
        }
        guard ScratchEvidencePolicy.storeRejection(evidence: evidence, expectedStoreMarker: fixture.storeMarkerContents) == nil else {
            XCTFail("\(phase): UI上のstore UUID/PID証拠がfixtureと一致しません。操作を中断します。"); return false
        }
        let isolated = app.staticTexts["melete-isolated-store-active"]
        let v2 = app.staticTexts["melete-experimental-v2-active"]
        let uiVisible = waitForUI
            ? isolated.waitForExistence(timeout: 10) && v2.waitForExistence(timeout: 5)
            : isolated.exists && v2.exists
        guard uiVisible else {
            XCTFail("\(phase): 隔離ストア表示またはV2表示がありません。操作を中断します。"); return false
        }
        guard case .success = checkedProcess(pid, previouslyVerified: identity) else {
            XCTFail("\(phase): 待機中に起動プロセスの同一性が確認できなくなりました。操作を中断します。"); return false
        }
        if let problem = openStoreProblem(pid: pid) {
            XCTFail("\(phase): \(problem)。操作を中断します。"); return false
        }
        if let problem = fixture.validationProblem() {
            XCTFail("\(phase): 画面確認後に\(problem)。操作を中断します。"); return false
        }
        guard case .success = checkedProcess(pid, previouslyVerified: identity) else {
            XCTFail("\(phase): 操作直前に起動プロセスの同一性を再確認できません。操作を中断します。"); return false
        }
        verifiedProcess = identity
        return true
    }

    /// この時点のプロセス情報を読み取り（読み取りのみ）、照合はScratchEvidencePolicyに任せる
    func checkedProcess(_ pid: pid_t, previouslyVerified: ProcessProbe.Identity?) -> Result<ProcessProbe.Identity, ScratchEvidenceRejection> {
        let observation = ScratchProcessObservation(
            evidencePID: pid,
            isRunningScratchApplication: Self.scratchApplication(withPID: pid) != nil,
            identity: ProcessProbe.identity(of: pid),
            executablePath: ProcessProbe.executablePathOf(pid)
        )
        return ScratchEvidencePolicy.verifiedProcess(
            observation,
            expectedOwnerUID: getuid(),
            expectedExecutablePath: target.executablePath,
            previouslyVerified: previouslyVerified
        )
    }

    /// UI証拠に示されたPIDだけをbundle IDで照合する。無関係なPIDは列挙・検査しない。
    static func scratchApplication(withPID pid: pid_t) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: scratchBundleIdentifier)
            .first { $0.processIdentifier == pid }
    }

    /// プロセスが開いているストア系ファイルがすべて隔離storeの中にあり、Melete.storeを開いていること
    func openStoreProblem(pid: pid_t) -> String? {
        let allowedPaths = Set(ScratchUIFixture.storeFileNames.map { fixture.store.appendingPathComponent($0).path })
        let rejection = ScratchEvidencePolicy.openStoreRejection(
            openFilePaths: ProcessProbe.openFilePaths(of: pid),
            allowedStoreFilePaths: allowedPaths,
            requiredStoreFilePath: fixture.store.appendingPathComponent("Melete.store").path
        )
        switch rejection {
        case nil:
            return nil
        case .openFilesUnavailable?:
            return "プロセスが開いているファイルを読み取れません"
        case .storeFilesOutsideIsolatedStore(let count)?:
            return "隔離store以外のストアファイル\(count)件を開いています"
        case _?:
            return "隔離storeのMelete.storeを開いていることを確認できません"
        }
    }

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return condition()
    }
}

// MARK: - UI操作の補助（一意に特定できない要素は操作しない）

private extension ScratchProbeUITests {
    func clickUniqueButton(label: String, in app: XCUIApplication) -> Bool {
        clickUniqueElement(app.buttons, label: label, in: app)
    }

    func clickUniqueButton(identifier: String, in app: XCUIApplication) -> Bool {
        clickUniqueElement(app.buttons, identifier: identifier, in: app)
    }

    func clickUniqueButton(identifierPrefix: String, in app: XCUIApplication) -> Bool {
        let query = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix))
        return clickUnique(query, description: "識別子が\(identifierPrefix)で始まるbutton")
    }

    func clickUniqueElement(_ query: XCUIElementQuery, label: String, in app: XCUIApplication) -> Bool {
        clickUnique(query.matching(NSPredicate(format: "label == %@", label)), description: "「\(label)」")
    }

    func clickUniqueElement(_ query: XCUIElementQuery, identifier: String, in app: XCUIApplication) -> Bool {
        clickUnique(query.matching(identifier: identifier), description: identifier)
    }

    func clickUnique(_ query: XCUIElementQuery, description: String) -> Bool {
        guard query.firstMatch.waitForExistence(timeout: 5), query.count == 1 else {
            XCTFail("\(description)を一意に特定できません（\(query.count)件）。操作を中断します。"); return false
        }
        guard let app = launchedApp, safe(app, "\(description)操作直前") else { return false }
        return click(query.firstMatch)
    }

    func click(_ element: XCUIElement) -> Bool {
        guard element.exists, let app = launchedApp, safe(app, "対象要素操作直前") else { XCTFail("操作対象を安全に確認できません。操作を中断します。"); return false }
        element.click()
        return true
    }

    func replaceText(identifier: String, with value: String, in app: XCUIApplication) -> Bool {
        let query = app.textFields.matching(identifier: identifier)
        guard query.firstMatch.waitForExistence(timeout: 5), query.count == 1 else {
            XCTFail("入力欄\(identifier)を一意に特定できません（\(query.count)件）。操作を中断します。"); return false
        }
        guard let app = launchedApp else { return false }
        return query.firstMatch.scratchReplaceText(value) { phase in safe(app, phase) }
    }

    func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        guard XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("画面要素が閉じません。操作を中断します。"); return false
        }
        return true
    }

    func historyText(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
    }

    func editWorkoutButtons(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editWorkout_"))
    }

    func suffix(of identifier: String, after prefix: String) -> String? {
        guard identifier.hasPrefix(prefix) else { XCTFail("識別子の形式が想定と異なります。操作を中断します。"); return nil }
        let value = String(identifier.dropFirst(prefix.count))
        guard UUID(uuidString: value) != nil else { XCTFail("識別子のIDを読み取れません。操作を中断します。"); return nil }
        return value
    }

    /// 項目管理画面で、現在の項目名が一致する名前欄の識別子からdraft ID（=項目ID）を得る
    func metricDefinitionID(named name: String, in app: XCUIApplication) -> String? {
        let fields = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "metricDefinitionName_"))
        guard fields.firstMatch.waitForExistence(timeout: 5) else {
            XCTFail("項目名欄が見つかりません。操作を中断します。"); return nil
        }
        let matches = fields.allElementsBoundByIndex.filter { ($0.value as? String) == name }
        guard matches.count == 1 else {
            XCTFail("項目「\(name)」の名前欄を一意に特定できません（\(matches.count)件）。操作を中断します。"); return nil
        }
        return suffix(of: matches[0].identifier, after: "metricDefinitionName_")
    }

    /// 入力欄での使用状態を切り替え、値が実際に変わったことを確認する（表示文言には依存しない）
    func toggleMetricActive(_ metricID: String, in app: XCUIApplication) -> Bool {
        let query = app.descendants(matching: .any).matching(identifier: "metricDefinitionActive_\(metricID)")
        guard query.firstMatch.waitForExistence(timeout: 5), query.count == 1 else {
            XCTFail("入力欄の使用切替を一意に特定できません（\(query.count)件）。操作を中断します。"); return false
        }
        let toggle = query.firstMatch
        let before = String(describing: toggle.value)
        guard safe(app, "項目使用状態切替の直前") else { return false }
        toggle.click()
        guard waitUntil(timeout: 3, { String(describing: toggle.value) != before }) else {
            XCTFail("入力欄の使用切替の状態が変わりません。保存せずに中断します。"); return false
        }
        return true
    }

    /// 種目Pickerを名前で明示選択し、画面上の選択値を確認する。想定外のアクセシビリティ表現なら中断する。
    func selectExercise(named name: String, in app: XCUIApplication) -> Bool {
        let picker = app.popUpButtons.matching(identifier: "exercisePicker")
        guard picker.firstMatch.waitForExistence(timeout: 5), picker.count == 1 else {
            XCTFail("種目Pickerを一意なポップアップとして確認できません。操作を中断します。"); return false
        }
        let control = picker.firstMatch
        if (control.value as? String) != name {
            guard safe(app, "種目Picker選択直前"), click(control) else { return false }
            let options = app.menuItems.matching(NSPredicate(format: "label == %@", name))
            guard options.firstMatch.waitForExistence(timeout: 5), options.count == 1,
                  safe(app, "種目Picker候補選択直前"), click(options.firstMatch) else {
                XCTFail("種目Pickerの候補「\(name)」を一意に選択できません。操作を中断します。"); return false
            }
        }
        guard (control.value as? String) == name else {
            XCTFail("種目Pickerで「\(name)」が選択されたことを確認できません。操作を中断します。"); return false
        }
        return true
    }

    func createSingleMetricExercise(name: String, metricName: String, unit: String, decimal: Bool, in app: XCUIApplication) -> Bool {
        guard safe(app, "\(name)作成前に種目画面へ移動する直前"), clickUniqueButton(label: "種目", in: app),
              clickUniqueButton(identifier: "createExerciseButton", in: app) else { return false }
        guard safe(app, "\(name)の入力直前"),
              replaceText(identifier: "exerciseNameField", with: name, in: app),
              replaceText(identifier: "metricNameField0", with: metricName, in: app),
              replaceText(identifier: "metricUnitField0", with: unit, in: app) else { return false }
        if decimal {
            guard safe(app, "\(name)の小数形式選択直前"),
                  clickUniqueElement(app.popUpButtons, identifier: "metricFormatPicker0", in: app),
                  clickUniqueElement(app.menuItems, label: "小数（第3位まで）", in: app) else { return false }
            guard safe(app, "\(name)の形式確認直前"),
                  (app.popUpButtons["metricFormatPicker0"].value as? String) == "小数（第3位まで）" else {
                XCTFail("\(name)の形式が小数に切り替わったことを確認できません。操作を中断します。"); return false
            }
        }
        guard safe(app, "\(name)の保存直前"), clickUniqueButton(identifier: "saveExerciseButton", in: app),
              waitForDisappearance(app.buttons["saveExerciseButton"]) else { return false }
        guard app.staticTexts[name].waitForExistence(timeout: 5) else {
            XCTFail("作成した種目「\(name)」が一覧にありません。操作を中断します。"); return false
        }
        return true
    }

    /// 種目Aのセット2の削除ボタン。セット1とセット2の入力欄の間にある削除ボタンが1つだけであることを位置で確認する
    func setTwoDeleteButton(in app: XCUIApplication) -> XCUIElement? {
        guard let first = uniqueTextField("edit_set1_metric_重量", in: app),
              let second = uniqueTextField("edit_set2_metric_重量", in: app) else { return nil }
        guard (second.value as? String) == "57.5" else {
            XCTFail("セット2の値が想定と異なります。削除せずに中断します。"); return nil
        }
        let buttons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "deleteWorkoutSet_"))
        return uniqueElement(between: first, and: second, in: buttons, description: "セット2の削除ボタン")
    }

    /// 種目Bの種目記録削除ボタン。種目Aの入力欄と種目Bの入力欄の間にあるものが1つだけであることを位置で確認する
    func recordBDeleteButton(in app: XCUIApplication) -> XCUIElement? {
        guard let upper = uniqueTextField("edit_set1_metric_重量", in: app),
              let lower = uniqueTextField("edit_set1_metric_距離", in: app) else { return nil }
        let buttons = app.buttons.matching(NSPredicate(format: "label == %@", "この種目記録を削除"))
        return uniqueElement(between: upper, and: lower, in: buttons, description: "種目Bの種目記録削除ボタン")
    }

    func uniqueTextField(_ identifier: String, in app: XCUIApplication) -> XCUIElement? {
        let query = app.textFields.matching(identifier: identifier)
        guard query.firstMatch.waitForExistence(timeout: 5), query.count == 1 else {
            XCTFail("入力欄\(identifier)を一意に特定できません（\(query.count)件）。操作を中断します。"); return nil
        }
        return query.firstMatch
    }

    func uniqueElement(between upper: XCUIElement, and lower: XCUIElement, in query: XCUIElementQuery, description: String) -> XCUIElement? {
        // 座標系の向きに依存しないよう、2つの入力欄の中心Yの間にあるかで判定する
        let low = min(upper.frame.midY, lower.frame.midY)
        let high = max(upper.frame.midY, lower.frame.midY)
        let candidates = query.allElementsBoundByIndex.filter { $0.frame.midY > low && $0.frame.midY < high }
        guard candidates.count == 1 else {
            XCTFail("\(description)を一意に特定できません（\(candidates.count)件）。操作を中断します。"); return nil
        }
        return candidates[0]
    }

    /// 削除ボタンを押して確認ダイアログを開き、ダイアログ側のキャンセルボタンを返す。
    /// 編集画面にもキャンセルボタンがあるため、開く前に無かったキャンセルボタンだけを対象にする
    func openConfirmation(by button: XCUIElement, confirmIdentifier: String? = nil, confirmIdentifierPrefix: String? = nil, in app: XCUIApplication) -> XCUIElement? {
        let cancelQuery = app.buttons.matching(NSPredicate(format: "label == %@", "キャンセル"))
        let existingFrames = cancelQuery.allElementsBoundByIndex.map(\.frame)
        guard click(button) else { return nil }
        let confirm: XCUIElementQuery
        if let confirmIdentifier {
            confirm = app.buttons.matching(identifier: confirmIdentifier)
        } else if let confirmIdentifierPrefix {
            confirm = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", confirmIdentifierPrefix))
        } else {
            XCTFail("確認ボタンの指定がありません。操作を中断します。"); return nil
        }
        guard confirm.firstMatch.waitForExistence(timeout: 5), confirm.count == 1 else {
            XCTFail("削除確認ダイアログの確定ボタンが対象と一致しないか、一意ではありません。操作を中断します。"); return nil
        }
        let added = cancelQuery.allElementsBoundByIndex.filter { element in !existingFrames.contains(element.frame) }
        guard added.count == 1 else {
            XCTFail("削除確認ダイアログのキャンセルボタンを一意に特定できません（\(added.count)件）。操作を中断します。"); return nil
        }
        return added[0]
    }
}

private extension XCUIElement {
    func scratchReplaceText(_ value: String, check: (String) -> Bool) -> Bool {
        guard check("文字入力欄クリック直前") else { return false }
        click()
        if !((self.value as? String) ?? "").isEmpty {
            guard check("文字列選択直前") else { return false }
            typeKey("a", modifierFlags: .command)
            guard check("既存文字削除直前") else { return false }
            typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        }
        guard check("文字入力直前") else { return false }
        typeText(value)
        guard check("文字入力直後") else { return false }
        guard (self.value as? String) == value else {
            XCTFail("入力値を画面上で確認できません。以降の操作を中断します。")
            return false
        }
        return true
    }
}

// MARK: - 起動対象アプリ

/// 起動するテスト対象アプリ。runnerと同じBuild/Products/ScratchProbeにあるMelete.appを想定し、
/// 配置やbundle IDが想定と違えば起動しない（推測で別のアプリを起動しない）。
private struct ScratchTargetApp {
    /// locateで検査した、シンボリックリンク解決・標準化済みのMelete.appのファイルURL。起動にはこのURLを使う
    let appURL: URL
    let executablePath: String

    enum LocateError: Error {
        case unexpectedLayout
        case unexpectedBundle
    }

    static func locate(expectedBundleIdentifier: String) throws -> ScratchTargetApp {
        // .../ScratchProbe/MeleteUITests-Runner.app/Contents/PlugIns/MeleteUITests.xctest
        let testBundle = Bundle(for: ScratchProbeUITests.self).bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let plugIns = testBundle.deletingLastPathComponent()
        let contents = plugIns.deletingLastPathComponent()
        let runner = contents.deletingLastPathComponent()
        let products = runner.deletingLastPathComponent()
        guard testBundle.lastPathComponent == "MeleteUITests.xctest",
              plugIns.lastPathComponent == "PlugIns",
              contents.lastPathComponent == "Contents",
              runner.lastPathComponent == "MeleteUITests-Runner.app",
              products.lastPathComponent == "ScratchProbe" else { throw LocateError.unexpectedLayout }
        let appURL = products.appendingPathComponent("Melete.app", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == expectedBundleIdentifier,
              let executable = bundle.executableURL?.resolvingSymlinksInPath().standardizedFileURL,
              executable.path.hasPrefix(appURL.path + "/") else { throw LocateError.unexpectedBundle }
        // 検査に使ったURLをそのまま保持する（起動時に別の方法で探し直さない）
        return ScratchTargetApp(appURL: appURL, executablePath: executable.path)
    }
}

// MARK: - scratch fixture

private struct ScratchUIFixture {
    static let rootMarker = ".melete-ui-test-root"
    static let storeMarker = ".melete-ui-test-store"
    static let rootMarkerContents = "Melete UI test root v1"
    static let storeFileNames = ["Melete.store", "Melete.store-wal", "Melete.store-shm"]

    let root: URL
    let store: URL
    let storeMarkerContents: String

    enum CreateError: Error {
        case scratchUnavailable
        case insideSystemTemporaryDirectory
        case invalidAfterCreation
    }

    /// scratch直下に新規UUID名のroot、その中に新規UUID名のstoreを作る。
    /// 既存項目があれば作成に失敗する（上書きしない）。scratch自体は作らない・変更しない
    static func create() throws -> ScratchUIFixture {
        guard let base = trustedScratchBase() else { throw CreateError.scratchUnavailable }
        let manager = FileManager.default
        let root = base.appendingPathComponent(UUID().uuidString, isDirectory: true).standardizedFileURL
        let temporary = manager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard !root.path.hasPrefix(temporary.hasSuffix("/") ? temporary : temporary + "/") else {
            throw CreateError.insideSystemTemporaryDirectory
        }
        try makeNewDirectory(root)
        try makeNewFile(root.appendingPathComponent(rootMarker), contents: rootMarkerContents)
        let store = root.appendingPathComponent(UUID().uuidString, isDirectory: true).standardizedFileURL
        try makeNewDirectory(store)
        let marker = UUID().uuidString
        try makeNewFile(store.appendingPathComponent(storeMarker), contents: marker)
        let fixture = ScratchUIFixture(root: root, store: store, storeMarkerContents: marker)
        guard fixture.validationProblem() == nil else { throw CreateError.invalidAfterCreation }
        return fixture
    }

    /// アプリ側と同じく、パスワードDBのホーム配下の `.hermes/cache/scratch` を信頼条件付きで返す
    static func trustedScratchBase() -> URL? {
        guard let entry = getpwuid(getuid()), let homePointer = entry.pointee.pw_dir else { return nil }
        let home = URL(fileURLWithPath: String(cString: homePointer), isDirectory: true).standardizedFileURL
        guard home.path != "/", home.resolvingSymlinksInPath().standardizedFileURL == home else { return nil }
        var current = home
        for component in [".hermes", "cache", "scratch"] {
            current = current.appendingPathComponent(component, isDirectory: true)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
                  permissions & 0o022 == 0 else { return nil }
        }
        return current.standardizedFileURL
    }

    private static func makeNewDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (info.st_mode & 0o777) == 0o700,
              info.st_uid == getuid() else {
            throw CreateError.invalidAfterCreation
        }
    }

    private static func makeNewFile(_ url: URL, contents: String) throws {
        // .withoutOverwritingにより既存項目（symlink含む）があれば失敗し、上書きしない
        try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// root/storeの種類・所有者・権限・symlink・marker・中身を確認する。問題があれば理由を返す
    func validationProblem() -> String? {
        let manager = FileManager.default
        // URLの==は末尾スラッシュの有無で結果が変わるため、pathで比較する
        guard let base = Self.trustedScratchBase(),
              root.deletingLastPathComponent().standardizedFileURL.path == base.path,
              UUID(uuidString: root.lastPathComponent) != nil,
              store.deletingLastPathComponent().standardizedFileURL.path == root.path,
              UUID(uuidString: store.lastPathComponent) != nil else { return "root/storeの場所がscratch直下の新規UUIDではありません" }
        guard validDirectory(root), validDirectory(store) else { return "root/storeの種類・所有者・権限・symlinkが不正です" }
        guard validMarker(root.appendingPathComponent(Self.rootMarker), contents: Self.rootMarkerContents),
              UUID(uuidString: storeMarkerContents) != nil,
              validMarker(store.appendingPathComponent(Self.storeMarker), contents: storeMarkerContents) else {
            return "root/storeのmarkerが不正です"
        }
        guard let rootContents = try? manager.contentsOfDirectory(atPath: root.path),
              Set(rootContents) == Set([Self.rootMarker, store.lastPathComponent]) else { return "rootに想定外の項目があります" }
        guard let storeContents = try? manager.contentsOfDirectory(atPath: store.path),
              Set(storeContents).isSubset(of: Set(Self.storeFileNames + [Self.storeMarker])) else {
            return "storeに想定外の項目があります"
        }
        for name in storeContents where name != Self.storeMarker {
            guard let attributes = try? manager.attributesOfItem(atPath: store.appendingPathComponent(name).path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  (attributes[.referenceCount] as? NSNumber)?.uint64Value == 1 else { return "storeファイルの種類・所有者・リンク数が不正です" }
        }
        return nil
    }

    private func validDirectory(_ url: URL) -> Bool {
        // attributesOfItemはsymlinkをたどらない
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
            && (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            && (attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700
    }

    private func validMarker(_ url: URL, contents: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
            && (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            && (attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600
            && (attributes[.referenceCount] as? NSNumber)?.uint64Value == 1
            && (try? String(contentsOf: url, encoding: .utf8)) == contents
    }
}

private enum FixtureSetupError: Error {
    case failed
}

// MARK: - プロセス情報（読み取りのみ）

private enum ProcessProbe {
    /// 照合ロジックと共通の型（TestsShared/ScratchEvidencePolicy.swift）
    typealias Identity = ScratchProcessIdentity

    static func executablePathOf(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0, Int(length) < buffer.count else { return nil }
        buffer[Int(length)] = 0
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func ownerUID(of pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }

    static func identity(of pid: pid_t) -> Identity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Identity(pid: pid, ownerUID: info.pbi_uid, startSeconds: UInt64(info.pbi_start_tvsec), startMicroseconds: UInt32(info.pbi_start_tvusec))
    }

    /// プロセスが開いているファイル（vnode）のパス。1つでも読めなければnil（安全側に倒す）。
    /// パスは正規化せずOSが返した文字列のまま返す。相対・`.`/`..`入りの判定はScratchEvidencePolicyが行う
    static func openFilePaths(of pid: pid_t) -> [String]? {
        let required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard required > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var capacity = Int(required) / stride + 32
        var fds: [proc_fdinfo] = []
        var count = 0
        var complete = false
        for _ in 0..<5 {
            fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            guard filled > 0, Int(filled) % stride == 0 else { return nil }
            count = Int(filled) / stride
            if Int(filled) < fds.count * stride {
                complete = true
                break
            }
            capacity *= 2
        }
        guard complete else { return nil }
        var paths: [String] = []
        for fd in fds.prefix(count) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                ScratchEvidencePolicy.openFilePath(fromNULTerminatedBytes: raw)
            }
            guard let path else { return nil }
            paths.append(path)
        }
        return paths
    }
}
