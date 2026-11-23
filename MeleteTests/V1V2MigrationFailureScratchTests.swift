import Foundation
import Darwin
import SQLite3
import SwiftData
import XCTest
@testable import Melete

#if DEBUG
/// テスト専用のcustom migration phaseを故意に失敗させ、V1 backupからの復元を検証する。
/// 本番 MeleteMigrationPlan は lightweight migration であり、このテストは本番移行の失敗を再現しない。
/// SwiftDataにおける本番candidate migrationの確実な失敗注入APIがないため、実際の失敗時挙動は未検証。
/// scratch直下に新しいUUID fixtureだけを作り、削除・上書き・system temporary directory利用をしない。
/// 同一UIDの悪意ある別プロセスによるパス置換は脅威モデル対象外（ユーザー承認済み）。
/// 誤操作・symlink/hardlinkの取り違え・read-write ModelContainerの重複openは、各フェーズ間のgateで検出して停止する。
/// fd残存の検出はlibprocのPROC_PIDLISTFDSで自プロセスのfdを列挙して行うが、未実行・未検証（StoreLifetimeProbe.openDescriptorCounts参照）。
final class V1V2MigrationFailureScratchTests: XCTestCase {
    private enum InjectedFailure: Error { case expected }
    private static var failurePhaseWasInvoked = false

    override func setUpWithError() throws {
        // フェーズ間のlifetime gate（container解放・fixture内ファイルへのfd残存・inode固定）は実装済みだが、
        // 一度も実行されておらず、SwiftDataがcontainer解放時にSQLite接続を閉じることを観測で確かめていない。
        // V1V2MigrationFailureLifetimeProbeTests でgate自体の動作を確認するまで、I/O前の無条件skipを維持する。
        // fd走査はPROC_PIDLISTFDSによる列挙に置き換えたが、実機で一度も実行しておらず、
        // 「報告件数がバッファ容量未満なら切り詰めなし」というカーネル側の挙動も公式文書では確認できていない。
        throw XCTSkip("SwiftData read-write ModelContainerのlifetime gateが未実行・未検証のため停止中")
    }

    /// 本番V1/V2モデルを使うが、失敗を注入するのはこのテスト専用の別plan。
    private enum DeterministicFailingPlan: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] { [MeleteSchemaV1.self, MeleteSchemaV2.self] }
        static var stages: [MigrationStage] {
            [.custom(fromVersion: MeleteSchemaV1.self, toVersion: MeleteSchemaV2.self,
                     willMigrate: { _ in
                         V1V2MigrationFailureScratchTests.failurePhaseWasInvoked = true
                         throw InjectedFailure.expected
                     }, didMigrate: nil)]
        }
    }

    @MainActor
    func testInjectedCandidatePhaseFailureLeavesV1ReadableAndBackupRestoresToNewV1URL() throws {
        guard let scratch = UITestStoreIsolation.trustedScratchBase() else {
#if MELETE_SCRATCH_ISOLATION
            XCTFail("信頼できるscratch領域が必要")
            throw XCTSkip("scratch unavailable")
#else
            throw XCTSkip("信頼できるscratch領域がない")
#endif
        }
        let directory = scratch.appendingPathComponent("MeleteV1V2MigrationFailure-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else {
            throw FailureTestError.invalidBackupPath
        }
        var directoryStat = stat()
        guard lstat(directory.path, &directoryStat) == 0,
              (directoryStat.st_mode & S_IFMT) == S_IFDIR,
              directoryStat.st_uid == geteuid(),
              (directoryStat.st_mode & 0o777) == 0o700,
              UITestStoreIsolation.isTrustedDirectory(directory, manager: .default),
              directory.deletingLastPathComponent().standardizedFileURL == scratch.standardizedFileURL,
              !directory.resolvingSymlinksInPath().path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path) else {
            XCTFail("fixture directoryがscratch外または信頼できない")
            throw FailureTestError.unsafeFixture
        }
        // 作成直後のdirectoryのinodeを固定し、以降のgateで別のdirectoryへの取り違えを検出する
        let directoryIdentity = StoreLifetimeProbe.FileIdentity(directoryStat)
        // gateで内容が固定されるファイル名→inode。作成されたフェーズで追加する
        var pinned: [String: StoreLifetimeProbe.FileIdentity] = [:]
        func gate(_ phase: String) throws {
            try StoreLifetimeProbe.requirePhaseClosed(phase, directory: directory, directoryIdentity: directoryIdentity, pinned: pinned)
        }
        // mkdir直後は空であること（既存ファイルを再利用しない）。XCTAssertでは続行してしまうのでthrowで止める
        try gate("fixture directory作成直後")
        try StoreLifetimeProbe.requireEmptyDirectory(directory, phase: "fixture directory作成直後")

        let store = directory.appendingPathComponent(StoreLifetimeProbe.sourceName)
        let backup = directory.appendingPathComponent(StoreLifetimeProbe.backupName)
        let restoredURL = directory.appendingPathComponent(StoreLifetimeProbe.restoredName)
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        // V1 sourceをfixture URLに固定し、一致しなければcontainerを開く前に止める（fallbackを許さない）
        let sourceConfig = try StoreLifetimeProbe.pinnedConfiguration("MigrationFailureV1Source", schema: schema, url: store)
        let exerciseID = UUID(), metricID = UUID(), workoutID = UUID(), recordID = UUID(), setID = UUID()
        let nilValueID = UUID(), zeroValueID = UUID()
        let exerciseCreatedAt = Date(timeIntervalSince1970: 1_650_000_000)
        let workoutCreatedAt = Date(timeIntervalSince1970: 1_660_000_000)
        let setCreatedAt = Date(timeIntervalSince1970: 1_670_000_000)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        utcCalendar.locale = Locale(identifier: "en_US_POSIX")
        let workoutDay = utcCalendar.date(from: DateComponents(year: 2023, month: 11, day: 14))!

        // フェーズ1: V1 fixture作成（read-write）。container・context・モデル参照はこのスコープ内に閉じ込める
        try StoreLifetimeProbe.withReleasedContainer("V1 fixture作成", schema: schema, configuration: sourceConfig) { context in
            let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
            metric.id = metricID
            let exercise = Exercise(name: "合成種目", metrics: [metric])
            exercise.id = exerciseID
            exercise.createdAt = exerciseCreatedAt
            let nilValue = MetricValue(metric: metric, scaledValue: nil)
            nilValue.id = nilValueID
            let zeroValue = MetricValue(metric: metric, scaledValue: 0)
            zeroValue.id = zeroValueID
            let set = SetRecord(sortOrder: 0, values: [nilValue, zeroValue]); set.id = setID
            set.createdAt = setCreatedAt
            let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [set]); record.id = recordID
            let workout = Workout(day: workoutDay, records: [record], calendar: utcCalendar); workout.id = workoutID
            workout.createdAt = workoutCreatedAt
            context.insert(exercise); context.insert(workout)
            try context.save()
        }
        // SwiftDataが作ったsourceは通常ファイル・hardlink 1本・自分の所有であること。以降このinodeから変わらないことを確認する
        pinned[StoreLifetimeProbe.sourceName] = try StoreLifetimeProbe.identity(ofRegularFileAt: store)
        try gate("V1 fixture作成後")

        let fixtureIDs = FixtureIDs(exercise: exerciseID, metric: metricID, workout: workoutID, record: recordID, set: setID, nilValue: nilValueID, zeroValue: zeroValueID, exerciseCreatedAt: exerciseCreatedAt, workoutCreatedAt: workoutCreatedAt, setCreatedAt: setCreatedAt)
        // フェーズ2: 移行前の読み戻し（SwiftDataはread-writeで開く）
        try Self.assertValues(at: store, schema: schema, configName: "MigrationFailureV1Before", ids: fixtureIDs)
        try gate("移行前V1読み戻し後")
        try Self.requireIntegrity(store)
        try gate("移行前integrity_check後")

        // フェーズ3: SwiftDataのcontainerが全て閉じた後にだけbackupする
        try Self.onlineBackup(from: store, toNew: backup)
        pinned[StoreLifetimeProbe.backupName] = try StoreLifetimeProbe.identity(ofRegularFileAt: backup)
        try gate("backup作成後")
        try Self.requireIntegrity(backup)
        try gate("backup integrity_check後")

        // フェーズ4: これは失敗を明示注入したテスト専用planであり、本番 MeleteMigrationPlan の失敗ではない。
        let candidateSchema = Schema(versionedSchema: MeleteSchemaV2.self)
        // candidateもfixture URLに固定し、一致しなければ移行を試す前に止める
        let candidateConfig = try StoreLifetimeProbe.pinnedConfiguration("MigrationFailureInjectedCandidate", schema: candidateSchema, url: store)
        Self.failurePhaseWasInvoked = false
        var candidateOpenThrew = false
        // 失敗経路でCore Data内部のautoreleaseオブジェクトが接続を保持し続けないよう、poolを閉じてからgateを通す
        autoreleasepool {
            do {
                // 想定外に成功した場合も、戻り値を保持せずにすぐ解放する
                _ = try ModelContainer(for: candidateSchema, migrationPlan: DeterministicFailingPlan.self, configurations: [candidateConfig])
            } catch {
                candidateOpenThrew = true
            }
        }
        // 移行が想定外に成功していたらsourceはV2になっている可能性があるため、V1で開き直す前に止める
        guard candidateOpenThrew, Self.failurePhaseWasInvoked else {
            XCTFail("テスト専用のwillMigrate failure phaseが実行され、candidate openが失敗すること")
            throw FailureTestError.unexpectedMigrationResult
        }
        try gate("注入したcandidate migration失敗後")

        // フェーズ5: 失敗後のsourceが開けるか確認し、独立したbackupから新規URLへ戻す。
        try Self.assertValues(at: store, schema: schema, configName: "MigrationFailureV1After", ids: fixtureIDs)
        try gate("移行失敗後V1読み戻し後")
        try Self.requireIntegrity(store)
        try gate("移行失敗後integrity_check後")
        // restore先は新規URL。onlineBackupもO_EXCLで拒否するが、ここでも続行せず止める
        guard !FileManager.default.fileExists(atPath: restoredURL.path) else {
            throw FailureTestError.invalidBackupPath
        }
        try Self.onlineBackup(from: backup, toNew: restoredURL)
        pinned[StoreLifetimeProbe.restoredName] = try StoreLifetimeProbe.identity(ofRegularFileAt: restoredURL)
        try gate("restore作成後")
        try Self.requireIntegrity(restoredURL)
        try gate("restore integrity_check後")
        // restore先のURL固定はassertValues内のpinnedConfigurationで、container open前に確認する
        try Self.assertValues(at: restoredURL, schema: schema, configName: "MigrationFailureV1Restored", ids: fixtureIDs)
        try gate("restore読み戻し後")

        // ローカル関数は囲んでいる@MainActorのテストメソッドのisolationを引き継ぐ
        func assertIDsAndValues(_ url: URL, _ label: String) throws {
            let config = try StoreLifetimeProbe.pinnedConfiguration(label, schema: schema, url: url)
            try StoreLifetimeProbe.withReleasedContainer(label, schema: schema, configuration: config) { context in
                let exercises = try context.fetch(FetchDescriptor<Exercise>())
                let workouts = try context.fetch(FetchDescriptor<Workout>())
                XCTAssertEqual(exercises.count, 1); XCTAssertEqual(workouts.count, 1)
                XCTAssertEqual(exercises.map(\.id), [exerciseID]); XCTAssertEqual(workouts.map(\.id), [workoutID])
                let loadedRecord = try XCTUnwrap(workouts.first?.records.first)
                XCTAssertEqual(loadedRecord.id, recordID)
                XCTAssertEqual(loadedRecord.sets.map(\.id), [setID])
                let values = loadedRecord.sets.flatMap(\.values)
                XCTAssertEqual(values.count, 2); XCTAssertEqual(Set(values.map(\.id)), Set([nilValueID, zeroValueID]))
                XCTAssertEqual(values.first { $0.id == nilValueID }?.scaledValue, nil)
                XCTAssertEqual(values.first { $0.id == zeroValueID }?.scaledValue, 0)
            }
        }
        try assertIDsAndValues(store, "MigrationFailureV1SourceFinal")
        try gate("source最終確認後")
        try assertIDsAndValues(restoredURL, "MigrationFailureV1RestoreFinal")
        try gate("restore最終確認後")
    }

    private struct FixtureIDs {
        let exercise: UUID, metric: UUID, workout: UUID, record: UUID, set: UUID, nilValue: UUID, zeroValue: UUID
        let exerciseCreatedAt: Date, workoutCreatedAt: Date, setCreatedAt: Date
    }

    @MainActor
    private static func assertValues(at url: URL, schema: Schema, configName: String, ids: FixtureIDs) throws {
        let configuration = try StoreLifetimeProbe.pinnedConfiguration(configName, schema: schema, url: url)
        try StoreLifetimeProbe.withReleasedContainer(configName, schema: schema, configuration: configuration) { context in
            let exercises = try context.fetch(FetchDescriptor<Exercise>())
            let metrics = try context.fetch(FetchDescriptor<MetricDefinition>())
            let workouts = try context.fetch(FetchDescriptor<Workout>())
            let records = try context.fetch(FetchDescriptor<ExerciseRecord>())
            let sets = try context.fetch(FetchDescriptor<SetRecord>())
            let values = try context.fetch(FetchDescriptor<MetricValue>())
            XCTAssertEqual(exercises.count, 1); XCTAssertEqual(metrics.count, 1)
            XCTAssertEqual(workouts.count, 1); XCTAssertEqual(records.count, 1)
            XCTAssertEqual(sets.count, 1); XCTAssertEqual(values.count, 2)
            XCTAssertEqual(Set(exercises.map(\.id)).count, exercises.count); XCTAssertEqual(Set(metrics.map(\.id)).count, metrics.count)
            XCTAssertEqual(Set(workouts.map(\.id)).count, workouts.count); XCTAssertEqual(Set(records.map(\.id)).count, records.count)
            XCTAssertEqual(Set(sets.map(\.id)).count, sets.count); XCTAssertEqual(Set(values.map(\.id)).count, values.count)
            XCTAssertEqual(exercises.map(\.id), [ids.exercise]); XCTAssertEqual(metrics.map(\.id), [ids.metric])
            XCTAssertEqual(workouts.map(\.id), [ids.workout]); XCTAssertEqual(records.map(\.id), [ids.record])
            XCTAssertEqual(sets.map(\.id), [ids.set]); XCTAssertEqual(Set(values.map(\.id)), Set([ids.nilValue, ids.zeroValue]))
            let exercise = try XCTUnwrap(exercises.first)
            let metric = try XCTUnwrap(metrics.first)
            let workout = try XCTUnwrap(workouts.first)
            let record = try XCTUnwrap(records.first)
            let set = try XCTUnwrap(sets.first)
            XCTAssertEqual(exercise.name, "合成種目"); XCTAssertFalse(exercise.isArchived)
            XCTAssertEqual(exercise.createdAt, ids.exerciseCreatedAt)
            XCTAssertEqual(exercise.metrics.map(\.id), [ids.metric]); XCTAssertEqual(metric.name, "重量")
            XCTAssertEqual(metric.unit, "kg"); XCTAssertTrue(metric.allowsDecimal); XCTAssertFalse(metric.isRequired)
            XCTAssertEqual(metric.sortOrder, 0); XCTAssertTrue(metric.isActive); XCTAssertEqual(metric.exercise?.id, ids.exercise)
            XCTAssertEqual(workout.day, "2023-11-14"); XCTAssertEqual(workout.records.map(\.id), [ids.record])
            XCTAssertEqual(workout.createdAt, ids.workoutCreatedAt)
            XCTAssertEqual(record.exerciseID, ids.exercise); XCTAssertEqual(record.exerciseName, "合成種目")
            XCTAssertEqual(record.sortOrder, 0); XCTAssertEqual(record.workout?.id, ids.workout)
            XCTAssertEqual(record.sets.map(\.id), [ids.set]); XCTAssertEqual(set.sortOrder, 0)
            XCTAssertEqual(set.createdAt, ids.setCreatedAt)
            XCTAssertEqual(set.exerciseRecord?.id, ids.record); XCTAssertEqual(Set(set.values.map(\.id)), Set([ids.nilValue, ids.zeroValue]))
            XCTAssertEqual(values.first { $0.id == ids.nilValue }?.setRecord?.id, ids.set)
            XCTAssertEqual(values.first { $0.id == ids.zeroValue }?.setRecord?.id, ids.set)
            for value in values {
                XCTAssertEqual(value.metricID, ids.metric); XCTAssertEqual(value.name, "重量"); XCTAssertEqual(value.unit, "kg")
                XCTAssertTrue(value.allowsDecimal); XCTAssertFalse(value.isRequired)
            }
            XCTAssertNil(values.first { $0.id == ids.nilValue }?.scaledValue)
            XCTAssertEqual(values.first { $0.id == ids.zeroValue }?.scaledValue, 0)
            // 読み戻しでは書き込まない
            XCTAssertFalse(context.hasChanges)
        }
    }

    private static func onlineBackup(from sourceURL: URL, toNew destinationURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw FailureTestError.invalidBackupPath
        }

        var source: OpaquePointer?
        let sourceResult = sqlite3_open_v2(
            sourceURL.path, &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil
        )
        guard sourceResult == SQLITE_OK, let source else {
            if let source { sqlite3_close_v2(source) }
            throw FailureTestError.sqlite
        }
        defer { sqlite3_close_v2(source) }

        // SQLiteには出力パスを渡さず、メモリDBへbackupしてからバイト列を安全に作ったFDへ書く。
        // backup/serialize部分は SQLiteMemoryBackup に共通化し、SQLiteMemoryBackupTests で :memory: のみで検証する。
        let serialized = try SQLiteMemoryBackup.serializedCopy(of: source)

        let outputFD = open(destinationURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputFD >= 0 else { throw FailureTestError.invalidBackupPath }
        var outputClosed = false
        defer { if !outputClosed { _ = close(outputFD) } }
        var createdStat = stat()
        guard fstat(outputFD, &createdStat) == 0,
              (createdStat.st_mode & S_IFMT) == S_IFREG,
              (createdStat.st_mode & 0o777) == 0o600 else { throw FailureTestError.invalidBackupPath }

        try serialized.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var written = 0
            while written < bytes.count {
                guard let base = bytes.baseAddress else { throw FailureTestError.sqlite }
                let count = Darwin.write(outputFD, base.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw FailureTestError.sqlite }
                written += count
            }
        }
        guard close(outputFD) == 0 else { throw FailureTestError.sqlite }
        outputClosed = true
    }

    /// integrity_checkが"ok"でなければthrowし、後続phaseに進ませない（XCTAssertだけでは続行してしまう）
    private static func requireIntegrity(_ url: URL) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard openResult == SQLITE_OK, let database else { if let database { sqlite3_close_v2(database) }; throw FailureTestError.sqlite }
        defer { sqlite3_close_v2(database) }
        try SQLiteIntegrityCheck.requireOK(database, label: url.lastPathComponent)
    }
}

/// PRAGMA integrity_check の結果判定。DBを開く処理とは分け、:memory: と行の配列だけで単体テストできるようにする
private enum SQLiteIntegrityCheck {
    /// integrity_checkの全行を読む。ROW/DONE以外のstepやNULL列は判定不能としてthrowする
    static func rows(of database: OpaquePointer) throws -> [String] {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else { if let statement { sqlite3_finalize(statement) }; throw FailureTestError.sqlite }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw FailureTestError.sqlite }
            rows.append(String(cString: text))
        }
        return rows
    }

    /// 正常なDBではSQLiteは"ok"の1行だけを返す。問題の列挙・空・大文字違い・余分な行は全て失敗扱い
    static func require(rows: [String], label: String) throws {
        guard rows == ["ok"] else {
            throw FailureTestError.integrityCheckFailed(label)
        }
    }

    static func requireOK(_ database: OpaquePointer, label: String) throws {
        try require(rows: try rows(of: database), label: label)
    }
}

/// 上のscratchテストのフェーズ間gateに使う部品の動作確認。
/// ファイルを作成・変更せず、テストバンドル実行ファイルの読み取り専用open（とその高fdへの複製）、
/// 自プロセスのfd列挙、合成メモリ、in-memory containerだけを使う。既存fdは閉じず、RLIMIT_NOFILEも変更しない。
/// scratch・通常ストア・system temporary directoryには触れないので、skipしない。
final class V1V2MigrationFailureLifetimeProbeTests: XCTestCase {
    /// fd走査が、自分で開いた読み取り専用fdを数え、closeで元に戻ることを確認する
    func testDescriptorScanCountsAndReleasesReadOnlyDescriptorOnTestBundleExecutable() throws {
        let executable = try XCTUnwrap(Bundle(for: Self.self).executableURL, "テストバンドルの実行ファイル")
        let before = try StoreLifetimeProbe.openDescriptorCounts()

        // O_RDONLYなので内容は変更しない。O_NOFOLLOWでsymlink経由の別ファイルを開かない
        let fd = open(executable.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0, "読み取り専用で開ける")
        guard fd >= 0 else { return }
        var closed = false
        defer { if !closed { _ = close(fd) } }
        var info = stat()
        // inout引数をXCTAssertのautoclosure内で渡さないよう、先に結果を取り出す
        let fstatResult = fstat(fd, &info)
        XCTAssertEqual(fstatResult, 0)
        let identity = StoreLifetimeProbe.FileIdentity(info)

        let whileOpen = try StoreLifetimeProbe.openDescriptorCounts()
        // 他のfdが同じinodeを既に開いていても判定できるよう、絶対数ではなく差分で比べる
        XCTAssertEqual(whileOpen[identity, default: 0], before[identity, default: 0] + 1, "開いたfdが1本増えて見える")
        XCTAssertThrowsError(try StoreLifetimeProbe.requireNoOpenDescriptors(to: [identity], phase: "fd保持中"),
                             "開いたfdがあるとgateは停止する")

        XCTAssertEqual(close(fd), 0)
        closed = true
        let afterClose = try StoreLifetimeProbe.openDescriptorCounts()
        XCTAssertEqual(afterClose[identity, default: 0], before[identity, default: 0], "closeで元の本数に戻る")
        if before[identity, default: 0] == 0 {
            XCTAssertNoThrow(try StoreLifetimeProbe.requireNoOpenDescriptors(to: [identity], phase: "close後"))
        }
    }

    /// in-memory V1 containerが、スコープ終了時に解放されることをweak参照で観測する。
    /// SQLiteファイルを使うcontainerでも同じとは限らないため、scratchテスト本体ではfd走査も併用する。
    @MainActor
    func testInMemoryV1ContainerIsReleasedWhenScopeEnds() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("V1LifetimeProbe-\(UUID().uuidString)", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        // 解放されなければcontainerStillAliveがthrowされ、テストは失敗する
        try StoreLifetimeProbe.withReleasedContainer("in-memory V1", schema: schema, configuration: configuration) { context in
            let exercise = Exercise(name: "合成種目", metrics: [MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0)])
            context.insert(exercise)
            try context.save()
            XCTAssertEqual(try context.fetch(FetchDescriptor<Exercise>()).count, 1)
        }
    }

    /// containerがスコープ外へ持ち出されたら、gateが停止することを確認する
    @MainActor
    func testReleasedContainerGateStopsWhenContainerEscapesScope() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("V1LifetimeEscape-\(UUID().uuidString)", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        var escaped: ModelContainer?
        do {
            try StoreLifetimeProbe.withReleasedContainer("持ち出し", schema: schema, configuration: configuration) { context in
                escaped = context.container
            }
            XCTFail("持ち出されたcontainerを見逃さない")
        } catch FailureTestError.containerStillAlive(_) {
            // 期待どおり停止した
        } catch {
            XCTFail("container残存として停止する: \(error)")
        }
        XCTAssertNotNil(escaped)
        escaped = nil
    }

    /// 通常ファイル以外（ディレクトリ）はstore候補として拒否する
    func testRegularFileIdentityRejectsDirectory() throws {
        let bundleDirectory = Bundle(for: Self.self).bundleURL
        XCTAssertThrowsError(try StoreLifetimeProbe.identity(ofRegularFileAt: bundleDirectory))
    }

    /// 読み取り専用で開いた実行ファイルのfdを、既存のどのfdより大きい番号へ複製し、列挙で見えることを確認する。
    /// 自分で開いた・複製したfdだけを閉じ、既存fdには触れない。RLIMIT_NOFILEは読むだけで変更しない。
    /// limitを下げないので「rlim_cur以上に残ったfd」そのものは再現しない（番号範囲に依存しない列挙の対照に留まる）
    func testDescriptorListFindsReadOnlyExecutableDuplicatedToHighDescriptor() throws {
        let executable = try XCTUnwrap(Bundle(for: Self.self).executableURL, "テストバンドルの実行ファイル")
        let before = try StoreLifetimeProbe.openDescriptorCounts()
        let highestExisting = try XCTUnwrap(try StoreLifetimeProbe.listOpenDescriptors(using: StoreLifetimeProbe.systemDescriptorListQuery).last?.fd)

        let fd = open(executable.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0, "読み取り専用で開ける")
        guard fd >= 0 else { return }
        var closed = false
        defer { if !closed { _ = close(fd) } }
        var info = stat()
        let fstatResult = fstat(fd, &info)
        XCTAssertEqual(fstatResult, 0)
        let identity = StoreLifetimeProbe.FileIdentity(info)

        // 既存の最大番号より十分上を狙う。F_DUPFDはsoft limit未満しか使えないので、届かなければ未検証としてskipする
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { throw XCTSkip("RLIMIT_NOFILEを読めず高fdの対照は未検証") }
        let target = Int(highestExisting) + 256
        guard let target32 = Int32(exactly: target), rlim_t(target) < limit.rlim_cur else {
            throw XCTSkip("soft limit \(limit.rlim_cur) が低く高fdの対照は未検証")
        }
        // F_DUPFD_CLOEXECは target以上で空いている最小の番号に複製する（既存fdを上書き・closeしない）
        let high = fcntl(fd, F_DUPFD_CLOEXEC, target32)
        guard high >= 0 else { throw XCTSkip("高fdへの複製ができず未検証 errno=\(errno)") }
        var highClosed = false
        defer { if !highClosed { _ = close(high) } }
        XCTAssertGreaterThanOrEqual(high, target32)
        XCTAssertGreaterThan(high, highestExisting, "既存のどのfdよりも大きい番号")

        let listed = try StoreLifetimeProbe.listOpenDescriptors(using: StoreLifetimeProbe.systemDescriptorListQuery)
        XCTAssertEqual(listed.first { $0.fd == high }?.type, UInt32(PROX_FDTYPE_VNODE), "高い番号の複製fdがvnodeとして列挙される")
        XCTAssertEqual(listed.first { $0.fd == fd }?.type, UInt32(PROX_FDTYPE_VNODE), "元のfdも列挙される")
        let whileOpen = try StoreLifetimeProbe.openDescriptorCounts()
        XCTAssertEqual(whileOpen[identity, default: 0], before[identity, default: 0] + 2, "元のfdと高fdの2本が増えて見える")
        XCTAssertThrowsError(try StoreLifetimeProbe.requireNoOpenDescriptors(to: [identity], phase: "高fd保持中"),
                             "高い番号のfdだけが残っていてもgateは停止する")

        // 低い番号を先に閉じ、高fdだけが残った状態でも検出できることを確認する
        XCTAssertEqual(close(fd), 0)
        closed = true
        let onlyHigh = try StoreLifetimeProbe.openDescriptorCounts()
        XCTAssertEqual(onlyHigh[identity, default: 0], before[identity, default: 0] + 1, "高fd1本が残って見える")
        XCTAssertThrowsError(try StoreLifetimeProbe.requireNoOpenDescriptors(to: [identity], phase: "高fdのみ保持中"))

        XCTAssertEqual(close(high), 0)
        highClosed = true
        let afterClose = try StoreLifetimeProbe.openDescriptorCounts()
        XCTAssertEqual(afterClose[identity, default: 0], before[identity, default: 0], "closeで元の本数に戻る")
    }

    // MARK: - 列挙の注入テスト（合成メモリのみ。実fd・カーネルには触れない）

    private static func entry(_ fd: Int32, _ type: UInt32 = 1) -> proc_fdinfo {
        proc_fdinfo(proc_fd: fd, proc_fdtype: type)
    }

    private static func bytes(_ count: Int) -> Int32 {
        Int32(count * MemoryLayout<proc_fdinfo>.stride)
    }

    func testDescriptorListReturnsAllEntriesWhenBufferHasSpareRoom() throws {
        let query = SyntheticDescriptorQuery(estimate: (Self.bytes(4), 0)) { _, _ in
            ([Self.entry(0), Self.entry(1), Self.entry(2), Self.entry(70_000, 2)], Self.bytes(4), 0)
        }
        let listed = try StoreLifetimeProbe.listOpenDescriptors(using: query.call)
        XCTAssertEqual(listed.map(\.fd), [0, 1, 2, 70_000], "番号の大きさに関係なく報告された全件を返す")
        XCTAssertEqual(listed.last?.type, 2)
        XCTAssertEqual(query.sizingCalls, 1, "最初にサイズ見積もりだけを1回行う")
        XCTAssertEqual(query.capacities.count, 1)
        XCTAssertGreaterThan(query.capacities[0], 4, "見積もりより余裕のある容量で取得する")
    }

    func testDescriptorListRetriesWithLargerBufferWhenPossiblyTruncated() throws {
        // 1回目はバッファ容量ちょうどまで埋める（切り詰めの可能性）。2回目は1回目より1本多いが、広げた容量には余裕が残る
        var firstCapacity = 0
        let query = SyntheticDescriptorQuery(estimate: (Self.bytes(1), 0)) { attempt, capacity in
            if attempt == 0 { firstCapacity = capacity }
            let count = attempt == 0 ? capacity : firstCapacity + 1
            return ((0..<Int32(count)).map { Self.entry($0) }, Self.bytes(count), 0)
        }
        let listed = try StoreLifetimeProbe.listOpenDescriptors(using: query.call)
        XCTAssertEqual(query.capacities.count, 2, "埋まっていたら取り直す")
        XCTAssertEqual(query.capacities[1], query.capacities[0] * 2, "容量を広げて取り直す")
        XCTAssertEqual(listed.count, query.capacities[0] + 1)
    }

    func testDescriptorListStopsWhenEveryAttemptMayBeTruncated() {
        let query = SyntheticDescriptorQuery(estimate: (Self.bytes(1), 0)) { _, capacity in
            ((0..<Int32(capacity)).map { Self.entry($0) }, Self.bytes(capacity), 0)
        }
        XCTAssertThrowsError(try StoreLifetimeProbe.listOpenDescriptors(using: query.call)) { error in
            guard case FailureTestError.descriptorListTruncated = error else {
                return XCTFail("切り詰めの可能性として停止する: \(error)")
            }
        }
        XCTAssertEqual(query.capacities.count, StoreLifetimeProbe.descriptorListAttempts, "取り直しは上限回数まで")
    }

    func testDescriptorListStopsWhenRequiredBufferExceedsBound() {
        let tooMany = StoreLifetimeProbe.descriptorListMaxEntries
        let query = SyntheticDescriptorQuery(estimate: (Self.bytes(tooMany), 0)) { _, _ in ([], 0, 0) }
        XCTAssertThrowsError(try StoreLifetimeProbe.listOpenDescriptors(using: query.call)) { error in
            guard case FailureTestError.descriptorListTooLarge = error else {
                return XCTFail("上限超過として停止する: \(error)")
            }
        }
        XCTAssertTrue(query.capacities.isEmpty, "上限を超えるバッファは確保しない")
    }

    func testDescriptorListStopsOnQueryFailure() {
        // 見積もり段階の失敗（0は「fdなし」と区別できないので失敗扱い）
        for estimate in [(Int32(0), EPERM), (Int32(0), Int32(0)), (Int32(-1), ESRCH)] {
            let query = SyntheticDescriptorQuery(estimate: estimate) { _, _ in ([Self.entry(0)], Self.bytes(1), 0) }
            XCTAssertThrowsError(try StoreLifetimeProbe.listOpenDescriptors(using: query.call), "見積もり\(estimate)で停止") { error in
                guard case FailureTestError.descriptorListFailed(let errorNumber) = error else {
                    return XCTFail("取得失敗として停止する: \(error)")
                }
                XCTAssertEqual(errorNumber, estimate.1)
            }
            XCTAssertTrue(query.capacities.isEmpty)
        }
        // 取得段階の失敗
        let failing = SyntheticDescriptorQuery(estimate: (Self.bytes(2), 0)) { _, _ in ([], 0, EPERM) }
        XCTAssertThrowsError(try StoreLifetimeProbe.listOpenDescriptors(using: failing.call)) { error in
            guard case FailureTestError.descriptorListFailed(EPERM) = error else {
                return XCTFail("取得失敗として停止する: \(error)")
            }
        }
    }

    func testDescriptorListStopsOnMalformedResult() {
        let stride = Int32(MemoryLayout<proc_fdinfo>.stride)
        // 見積もりがエントリサイズの倍数でない
        let oddEstimate = SyntheticDescriptorQuery(estimate: (stride + 1, 0)) { _, _ in ([Self.entry(0)], Self.bytes(1), 0) }
        XCTAssertThrowsError(try StoreLifetimeProbe.listOpenDescriptors(using: oddEstimate.call))

        let malformed: [(String, [proc_fdinfo], (Int) -> Int32)] = [
            ("倍数でない戻り値", [Self.entry(0), Self.entry(1)], { _ in stride + 1 }),
            ("容量を超える戻り値", [Self.entry(0)], { capacity in Self.bytes(capacity + 1) }),
            ("負のfd", [Self.entry(-1), Self.entry(1)], { _ in Self.bytes(2) }),
            ("重複したfd", [Self.entry(3), Self.entry(3)], { _ in Self.bytes(2) }),
            ("昇順でないfd", [Self.entry(5), Self.entry(4)], { _ in Self.bytes(2) }),
        ]
        for (label, entries, reported) in malformed {
            let query = SyntheticDescriptorQuery(estimate: (Self.bytes(2), 0)) { _, capacity in (entries, reported(capacity), 0) }
            XCTAssertThrowsError(try StoreLifetimeProbe.listOpenDescriptors(using: query.call), label) { error in
                guard case FailureTestError.descriptorListMalformed = error else {
                    return XCTFail("\(label): 形状不正として停止する: \(error)")
                }
            }
        }
    }

    // MARK: - 列挙→fstat→再列挙の注入テスト（実fdには触れない）

    private static func syntheticStat(device: dev_t, inode: ino_t) -> stat {
        var info = stat()
        info.st_dev = device
        info.st_ino = inode
        return info
    }

    func testDescriptorSnapshotCountsEveryListedDescriptorWhenStable() throws {
        let listed = [StoreLifetimeProbe.ListedDescriptor(fd: 0, type: 1), StoreLifetimeProbe.ListedDescriptor(fd: 90_000, type: 1)]
        var listingCalls = 0
        var statted: [Int32] = []
        let counts = try StoreLifetimeProbe.openDescriptorCounts(listing: { listingCalls += 1; return listed }) { fd, info in
            statted.append(fd)
            info = Self.syntheticStat(device: 7, inode: 42)
            return 0
        }
        XCTAssertEqual(statted, [0, 90_000], "列挙されたfdだけをfstatする（番号範囲を走査しない）")
        XCTAssertEqual(listingCalls, 2, "fstat後に再列挙して一致を確認する")
        XCTAssertEqual(counts, [StoreLifetimeProbe.FileIdentity(Self.syntheticStat(device: 7, inode: 42)): 2])
    }

    func testDescriptorSnapshotRetriesWhenListedDescriptorClosedDuringScan() throws {
        let listed = [StoreLifetimeProbe.ListedDescriptor(fd: 3, type: 1)]
        var statCalls = 0
        let counts = try StoreLifetimeProbe.openDescriptorCounts(listing: { listed }) { _, info in
            statCalls += 1
            // 1回目は列挙後に閉じられた状況を真似る
            guard statCalls > 1 else { return EBADF }
            info = Self.syntheticStat(device: 1, inode: 2)
            return 0
        }
        XCTAssertEqual(statCalls, 2, "EBADFを読み飛ばさず、スナップショットを取り直す")
        XCTAssertEqual(counts, [StoreLifetimeProbe.FileIdentity(Self.syntheticStat(device: 1, inode: 2)): 1])
    }

    func testDescriptorSnapshotStopsWhenListedDescriptorKeepsDisappearing() {
        var listingCalls = 0
        XCTAssertThrowsError(try StoreLifetimeProbe.openDescriptorCounts(listing: {
            listingCalls += 1
            return [StoreLifetimeProbe.ListedDescriptor(fd: 3, type: 1)]
        }) { _, _ in EBADF }) { error in
            guard case FailureTestError.descriptorSnapshotUnstable = error else {
                return XCTFail("不安定として停止する: \(error)")
            }
        }
        XCTAssertEqual(listingCalls, StoreLifetimeProbe.descriptorSnapshotAttempts, "取り直しは上限回数まで")
    }

    func testDescriptorSnapshotStopsWhenListKeepsChanging() {
        var listingCalls = 0
        XCTAssertThrowsError(try StoreLifetimeProbe.openDescriptorCounts(listing: {
            listingCalls += 1
            // 呼ぶたびにfdが1本ずつ増える（走査中にfdが開かれ続ける状況）
            return (0..<Int32(listingCalls)).map { StoreLifetimeProbe.ListedDescriptor(fd: $0, type: 1) }
        }) { _, info in
            info = Self.syntheticStat(device: 1, inode: 1)
            return 0
        }) { error in
            guard case FailureTestError.descriptorSnapshotUnstable = error else {
                return XCTFail("不安定として停止する: \(error)")
            }
        }
        XCTAssertEqual(listingCalls, StoreLifetimeProbe.descriptorSnapshotAttempts * 2)
    }

    func testDescriptorSnapshotStopsOnListingError() {
        XCTAssertThrowsError(try StoreLifetimeProbe.openDescriptorCounts(listing: {
            throw FailureTestError.descriptorListTruncated
        }) { _, _ in 0 }) { error in
            guard case FailureTestError.descriptorListTruncated = error else {
                return XCTFail("列挙の失敗をそのまま伝える: \(error)")
            }
        }
    }

    func testDescriptorSnapshotStopsOnNonBadDescriptorError() {
        // EBADF以外は「閉じている」と断定できないので、全て停止すること
        let listed = [StoreLifetimeProbe.ListedDescriptor(fd: 0, type: 1), StoreLifetimeProbe.ListedDescriptor(fd: 1, type: 1)]
        for injected in [EIO, EINTR, EOVERFLOW, EACCES, Int32(-1)] {
            XCTAssertThrowsError(try StoreLifetimeProbe.openDescriptorCounts(listing: { listed }) { fd, _ in
                fd == 1 ? injected : 0
            }, "errno \(injected) で停止する") { error in
                guard case FailureTestError.descriptorStatFailed(let fd, let errorNumber) = error else {
                    return XCTFail("fstat失敗として停止する: \(error)")
                }
                XCTAssertEqual(fd, 1)
                XCTAssertEqual(errorNumber, injected)
            }
        }
    }

    /// integrity_checkが"ok"の1行以外なら、XCTAssertで続行せずthrowすること
    func testIntegrityCheckRejectsAnythingButSingleOKRow() {
        let badResults: [[String]] = [
            [], ["OK"], [" ok"], ["ok", "ok"],
            ["*** in database main ***", "Page 3: never used"],
        ]
        for rows in badResults {
            XCTAssertThrowsError(try SQLiteIntegrityCheck.require(rows: rows, label: "合成"), "\(rows) は失敗") { error in
                guard case FailureTestError.integrityCheckFailed = error else {
                    return XCTFail("integrity失敗として停止する: \(error)")
                }
            }
        }
        XCTAssertNoThrow(try SQLiteIntegrityCheck.require(rows: ["ok"], label: "合成"))
    }

    /// 新規fixture directoryに1件でも名前があれば、XCTAssertで続行せずthrowすること。
    /// ディレクトリは読まず、合成した名前一覧だけを渡す
    func testEmptyListingRequirementStopsOnAnyEntry() {
        let nonEmptyListings: [[String]] = [
            [StoreLifetimeProbe.sourceName], [StoreLifetimeProbe.sourceName + "-wal"],
            [".DS_Store"], ["unexpected"], ["a", "b"],
        ]
        for names in nonEmptyListings {
            XCTAssertThrowsError(try StoreLifetimeProbe.requireEmptyListing(names, phase: "合成"), "\(names) は停止") { error in
                guard case FailureTestError.directoryNotEmpty = error else {
                    return XCTFail("空でないdirectoryとして停止する: \(error)")
                }
            }
        }
        XCTAssertNoThrow(try StoreLifetimeProbe.requireEmptyListing([], phase: "合成"))
    }

    /// ModelConfigurationのURLがfixture URLと違えば、containerを開く前にthrowすること。
    /// 存在しない合成パスの値だけを比べる（isDirectory指定でURL生成時のファイルシステム確認も避ける）
    func testConfigurationURLRequirementStopsOnMismatch() {
        let expected = URL(fileURLWithPath: "/melete-synthetic-nonexistent/fixture/source.sqlite", isDirectory: false)
        let mismatches: [URL] = [
            URL(fileURLWithPath: "/melete-synthetic-nonexistent/fixture/backup.sqlite", isDirectory: false),
            URL(fileURLWithPath: "/melete-synthetic-nonexistent/other/source.sqlite", isDirectory: false),
            // in-memory store等が使う別の場所へのfallbackを想定
            URL(fileURLWithPath: "/dev/null", isDirectory: false),
            URL(string: "https://example.invalid/melete-synthetic-nonexistent/fixture/source.sqlite")!,
        ]
        for actual in mismatches {
            XCTAssertThrowsError(try StoreLifetimeProbe.requireSameFileURL(actual, expected: expected, label: "合成"), "\(actual) は停止") { error in
                guard case FailureTestError.configurationURLMismatch = error else {
                    return XCTFail("URL不一致として停止する: \(error)")
                }
            }
        }
        // 期待値側が非file URLでも一致扱いにしない
        let nonFile = URL(string: "https://example.invalid/source.sqlite")!
        XCTAssertThrowsError(try StoreLifetimeProbe.requireSameFileURL(nonFile, expected: nonFile, label: "合成"))
        XCTAssertNoThrow(try StoreLifetimeProbe.requireSameFileURL(expected, expected: expected, label: "合成"))
        // ".."は字句的に標準化されてから比べる
        let dotted = URL(fileURLWithPath: "/melete-synthetic-nonexistent/fixture/sub/../source.sqlite", isDirectory: false)
        XCTAssertNoThrow(try StoreLifetimeProbe.requireSameFileURL(dotted, expected: expected, label: "合成"))
    }

    /// ファイルを作らない :memory: DBで、実際のPRAGMA結果の読み取りと判定がつながっていることを確認する
    func testIntegrityCheckReadsOKFromInMemoryDatabase() throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(":memory:", &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        defer { if let database { sqlite3_close_v2(database) } }
        XCTAssertEqual(openResult, SQLITE_OK)
        let memory = try XCTUnwrap(database)
        XCTAssertEqual(try SQLiteIntegrityCheck.rows(of: memory), ["ok"])
        XCTAssertNoThrow(try SQLiteIntegrityCheck.requireOK(memory, label: ":memory:"))
    }
}

/// proc_pidinfo(PROC_PIDLISTFDS)の応答を合成メモリだけで真似る注入用の関数。実fd・カーネル・ファイルには触れない
private final class SyntheticDescriptorQuery {
    /// 1回の取得への応答。(何回目か, バッファ容量のエントリ数) を受け取り、書き込むエントリと報告するバイト数を返す
    typealias Response = (_ attempt: Int, _ capacity: Int) -> (entries: [proc_fdinfo], bytes: Int32, errno: Int32)

    private let estimate: (bytes: Int32, errno: Int32)
    private let respond: Response
    private(set) var sizingCalls = 0
    /// bufferありで呼ばれた時の容量（エントリ数）。取り直しの回数と広げ方を確認するのに使う
    private(set) var capacities: [Int] = []

    init(estimate: (bytes: Int32, errno: Int32), respond: @escaping Response) {
        self.estimate = estimate
        self.respond = respond
    }

    func call(_ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> (bytes: Int32, errno: Int32) {
        guard let buffer else {
            sizingCalls += 1
            return estimate
        }
        let capacity = Int(size) / MemoryLayout<proc_fdinfo>.stride
        let response = respond(capacities.count, capacity)
        capacities.append(capacity)
        // 呼び出し元は[proc_fdinfo]のメモリを渡すので、その型として書き込む。容量を超えては書かない
        let typed = buffer.assumingMemoryBound(to: proc_fdinfo.self)
        for (index, entry) in response.entries.prefix(capacity).enumerated() {
            typed[index] = entry
        }
        return (response.bytes, response.errno)
    }
}

/// フェーズ間の安全確認。全て読み取りだけで、ファイルを作成・変更・削除しない。
/// 同一UIDの悪意ある並行置換（TOCTOU）は防がない。誤操作や取り違えの検出が目的。
private enum StoreLifetimeProbe {
    static let sourceName = "source.sqlite"
    static let backupName = "backup.sqlite"
    static let restoredName = "restored.sqlite"

    /// fixture内に存在してよい名前。SQLiteの付随ファイル以外（移行用一時ファイル等）が出たら停止する
    static let allowedNames: Set<String> = Set([sourceName, backupName, restoredName].flatMap { base in
        [base, base + "-wal", base + "-shm", base + "-journal"]
    })

    /// パスではなく(device, inode)で同一ファイルを判定する。hardlinkの別名も同じinodeとして扱える
    struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }

    /// read-writeのModelContainerを1つだけ開き、bodyの後でcontainerが解放されたことをweak参照で確かめる。
    /// autoreleasepoolで囲み、Core Data内部のautoreleaseされた参照がスコープ外に残らないようにする。
    @MainActor
    static func withReleasedContainer(_ phase: String, schema: Schema, configuration: ModelConfiguration, _ body: (ModelContext) throws -> Void) throws {
        // weak参照は対象を保持しないので、解放されればnilになる
        weak var observed: ModelContainer?
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            observed = container
            try body(ModelContext(container))
        }
        guard observed == nil else {
            throw FailureTestError.containerStillAlive(phase)
        }
    }

    /// 名前一覧が空であることを要求する。1件でもあれば既存ファイルを再利用しうるので、次のI/O前に停止する
    static func requireEmptyListing(_ names: [String], phase: String) throws {
        guard names.isEmpty else {
            throw FailureTestError.directoryNotEmpty("\(phase): \(names.sorted())")
        }
    }

    /// 作成直後のfixture directoryが空であることを要求する（読み取りのみ）
    static func requireEmptyDirectory(_ directory: URL, phase: String) throws {
        try requireEmptyListing(try FileManager.default.contentsOfDirectory(atPath: directory.path), phase: phase)
    }

    /// ModelConfigurationが持つURLが、意図したfixture URLと一致することを要求する。
    /// 一致しなければ既定ストア等の別の場所を開くおそれがあるため、containerを開く前に停止する
    static func requireSameFileURL(_ actual: URL, expected: URL, label: String) throws {
        guard actual.isFileURL, expected.isFileURL,
              actual.standardizedFileURL == expected.standardizedFileURL else {
            throw FailureTestError.configurationURLMismatch(label)
        }
    }

    /// fixture URLに固定したModelConfigurationを作る。URLが一致しなければ返さずにthrowする
    static func pinnedConfiguration(_ name: String, schema: Schema, url: URL) throws -> ModelConfiguration {
        let configuration = ModelConfiguration(name, schema: schema, url: url, cloudKitDatabase: .none)
        try requireSameFileURL(configuration.url, expected: url, label: name)
        return configuration
    }

    /// symlinkをたどらずに調べ、通常ファイル・hardlink 1本・自分の所有の場合だけinodeを返す
    static func identity(ofRegularFileAt url: URL) throws -> FileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == geteuid() else {
            throw FailureTestError.unexpectedFile(url.lastPathComponent)
        }
        return FileIdentity(info)
    }

    /// PROC_PIDLISTFDSが返す1エントリ（fd番号と種類）。2回の列挙結果を比べられるようEquatableにする
    struct ListedDescriptor: Equatable {
        let fd: Int32
        let type: UInt32
    }

    /// 列挙バッファの上限（エントリ数）。これを超える数のfdは想定外として停止する（512KiB相当）
    static let descriptorListMaxEntries = 1 << 16
    /// 切り詰めの可能性があるときにバッファを広げて取り直す回数の上限
    static let descriptorListAttempts = 4
    /// 列挙→fstat→再列挙の結果が一致するまで取り直す回数の上限
    static let descriptorSnapshotAttempts = 4

    /// 自プロセスが実際に開いているfdを列挙し、inodeごとの本数を返す。
    /// fd番号の範囲（rlim_cur等）は使わないので、soft limitより上に残っている高い番号のfdも列挙対象になる。
    /// 列挙・fstatの失敗、切り詰めの可能性、不正な形状、走査中のfd変動が解消しない場合は全て停止する（fail closed）。
    /// 注意: 「戻り値がバッファ容量未満なら全件」というPROC_PIDLISTFDSの挙動はxnuの実装に基づく前提で、公式文書では確認していない。
    static func openDescriptorCounts() throws -> [FileIdentity: Int] {
        try openDescriptorCounts(listing: { try listOpenDescriptors(using: systemDescriptorListQuery) },
                                 using: systemDescriptorStat)
    }

    /// fstatの結果を「成功なら0、失敗ならerrno」で返す関数の型。テストで失敗を注入できるよう差し替え可能にする
    typealias DescriptorStat = (Int32, inout stat) -> Int32

    static func systemDescriptorStat(_ fd: Int32, _ info: inout stat) -> Int32 {
        guard fstat(fd, &info) != 0 else { return 0 }
        // errnoは次の呼び出しで上書きされうるので失敗直後に読む。0なら原因不明として成功と区別できる値にする
        let error = errno
        return error == 0 ? -1 : error
    }

    /// proc_pidinfo(自pid, PROC_PIDLISTFDS, 0, buffer, size) と同じ形の関数型。(戻り値, 直後のerrno) を返す。
    /// テストでは合成メモリに書き込む関数を渡し、実プロセスのfdやカーネルに触れずに判定を確かめる
    typealias DescriptorListQuery = (UnsafeMutableRawPointer?, Int32) -> (bytes: Int32, errno: Int32)

    /// 自プロセスだけを対象にする（他プロセスのpidは渡さない）。fdを開閉せず、情報を読むだけ
    static func systemDescriptorListQuery(_ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> (bytes: Int32, errno: Int32) {
        // 失敗時のproc_pidinfoは0を返してerrnoを設定するので、前の値が残らないよう先に0にしておく
        errno = 0
        let result = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, buffer, size)
        return (result, errno)
    }

    /// 1回分の列挙結果を検証する。全件取れたと確認できればエントリを返し、
    /// バッファが埋まって切り詰めの可能性があるときはnil（呼び出し側が広げて取り直す）。それ以外の異常はthrowする
    static func decodeDescriptorList(returnedBytes: Int32, errno errorNumber: Int32, buffer: [proc_fdinfo]) throws -> [ListedDescriptor]? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        // 0は「失敗」と「fdが1本もない」を区別できない。テスト実行中のプロセスがfd 0本はありえないので失敗扱い
        guard returnedBytes > 0 else {
            throw FailureTestError.descriptorListFailed(errno: errorNumber)
        }
        guard Int(returnedBytes) % stride == 0 else {
            throw FailureTestError.descriptorListMalformed("戻り値\(returnedBytes)がエントリサイズの倍数でない")
        }
        let count = Int(returnedBytes) / stride
        guard count <= buffer.count else {
            throw FailureTestError.descriptorListMalformed("戻り値\(count)件がバッファ容量\(buffer.count)件を超える")
        }
        // 容量ちょうどまで埋まっていたら、入りきらなかったfdがある可能性を否定できない
        guard count < buffer.count else { return nil }
        var entries: [ListedDescriptor] = []
        entries.reserveCapacity(count)
        for raw in buffer.prefix(count) {
            // xnuはfd番号の昇順で返す。負の番号・重複・順序の乱れは形状不正として停止する
            guard raw.proc_fd >= 0, raw.proc_fd > (entries.last?.fd ?? -1) else {
                throw FailureTestError.descriptorListMalformed("fd番号が負・重複・昇順でない: \(raw.proc_fd)")
            }
            entries.append(ListedDescriptor(fd: raw.proc_fd, type: raw.proc_fdtype))
        }
        return entries
    }

    /// サイズ見積もり→取得を行い、切り詰めの可能性があれば上限付きでバッファを広げて取り直す
    static func listOpenDescriptors(using query: DescriptorListQuery) throws -> [ListedDescriptor] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        // bufferにnilを渡すと必要バイト数の見積もりだけが返る
        let estimate = query(nil, 0)
        guard estimate.bytes > 0 else {
            throw FailureTestError.descriptorListFailed(errno: estimate.errno)
        }
        guard Int(estimate.bytes) % stride == 0 else {
            throw FailureTestError.descriptorListMalformed("見積もり\(estimate.bytes)がエントリサイズの倍数でない")
        }
        // 見積もり後にfdが増えても1回で収まりやすいよう余裕を足す
        var capacity = Int(estimate.bytes) / stride + 32
        for _ in 0..<descriptorListAttempts {
            guard capacity <= descriptorListMaxEntries else {
                throw FailureTestError.descriptorListTooLarge(capacity)
            }
            // ゼロ初期化した配列をそのまま書き込み先にする。サイズはエントリ数×strideで、Int32に必ず収まる
            var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let result = buffer.withUnsafeMutableBytes { raw in
                query(raw.baseAddress, Int32(raw.count))
            }
            if let entries = try decodeDescriptorList(returnedBytes: result.bytes, errno: result.errno, buffer: buffer) {
                return entries
            }
            // 倍にした値を上限で頭打ちにし、上限でも埋まったら次のループ先頭のguardで停止させる
            capacity = capacity >= descriptorListMaxEntries ? descriptorListMaxEntries + 1 : min(capacity * 2, descriptorListMaxEntries)
        }
        throw FailureTestError.descriptorListTruncated
    }

    /// 列挙したfdを全てfstatし、もう一度列挙して同じ結果であることを確かめてからinodeごとの本数を返す。
    /// - 列挙後に閉じられたfd（fstatがEBADF）は数えずに読み飛ばさず、スナップショットごと取り直す
    /// - 再列挙の結果が違えば（走査中に開閉があれば）取り直す
    /// - 上限回数で一致しなければ停止する。EBADF以外のfstat失敗は即停止する
    static func openDescriptorCounts(listing: () throws -> [ListedDescriptor], using statDescriptor: DescriptorStat) throws -> [FileIdentity: Int] {
        attempts: for _ in 0..<descriptorSnapshotAttempts {
            let listed = try listing()
            var counts: [FileIdentity: Int] = [:]
            for entry in listed {
                var info = stat()
                let result = statDescriptor(entry.fd, &info)
                if result == 0 {
                    counts[FileIdentity(info), default: 0] += 1
                    continue
                }
                guard result == EBADF else {
                    throw FailureTestError.descriptorStatFailed(fd: entry.fd, errno: result)
                }
                // 列挙からfstatまでの間に閉じられた。このスナップショットは信用せず最初から取り直す
                continue attempts
            }
            guard try listing() == listed else { continue attempts }
            return counts
        }
        throw FailureTestError.descriptorSnapshotUnstable
    }

    /// 指定したinodeを開いているfdが1本でもあれば停止する
    static func requireNoOpenDescriptors(to identities: Set<FileIdentity>, phase: String) throws {
        let counts = try openDescriptorCounts()
        guard identities.allSatisfy({ counts[$0, default: 0] == 0 }) else {
            throw FailureTestError.openDescriptor(phase)
        }
    }

    /// フェーズ終了時のgate。次のフェーズでstoreを開く前に呼ぶ。
    /// - directoryが作成時と同じinodeで、所有者・権限が変わっていない
    /// - 中身が許可した名前だけで、全て通常ファイル・hardlink 1本
    /// - 作成済みのstore/backup/restoreが作成時と同じinodeのまま
    /// - fixture内のどのファイルも、PROC_PIDLISTFDSで列挙した自プロセスのfdから開かれていない
    static func requirePhaseClosed(_ phase: String, directory: URL, directoryIdentity: FileIdentity, pinned: [String: FileIdentity]) throws {
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              (directoryInfo.st_mode & 0o777) == 0o700,
              FileIdentity(directoryInfo) == directoryIdentity else {
            throw FailureTestError.identityChanged("\(phase): fixture directory")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard Set(names).isSubset(of: allowedNames) else {
            throw FailureTestError.unexpectedFile("\(phase): \(names.sorted())")
        }
        var identities: Set<FileIdentity> = []
        for name in names {
            identities.insert(try identity(ofRegularFileAt: directory.appendingPathComponent(name)))
        }
        for (name, expected) in pinned {
            guard try identity(ofRegularFileAt: directory.appendingPathComponent(name)) == expected else {
                throw FailureTestError.identityChanged("\(phase): \(name)")
            }
        }
        try requireNoOpenDescriptors(to: identities, phase: phase)
    }
}

private enum FailureTestError: Error {
    case unsafeFixture, invalidBackupPath, sqlite
    case unexpectedMigrationResult
    case descriptorListFailed(errno: Int32)
    case descriptorListMalformed(String)
    case descriptorListTruncated
    case descriptorListTooLarge(Int)
    case descriptorSnapshotUnstable
    case descriptorStatFailed(fd: Int32, errno: Int32)
    case integrityCheckFailed(String)
    case containerStillAlive(String)
    case directoryNotEmpty(String)
    case configurationURLMismatch(String)
    case openDescriptor(String)
    case unexpectedFile(String)
    case identityChanged(String)
}
#endif
