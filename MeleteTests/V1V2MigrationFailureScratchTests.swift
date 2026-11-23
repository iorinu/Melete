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
final class V1V2MigrationFailureScratchTests: XCTestCase {
    private enum InjectedFailure: Error { case expected }
    private static var failurePhaseWasInvoked = false

    override func setUpWithError() throws {
        // フェーズ間のlifetime gate（container解放・fixture内ファイルへのfd残存・inode固定）は実装済みだが、
        // 一度も実行されておらず、SwiftDataがcontainer解放時にSQLite接続を閉じることを観測で確かめていない。
        // V1V2MigrationFailureLifetimeProbeTests でgate自体の動作を確認するまで、I/O前の無条件skipを維持する。
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
        // mkdir直後は空であること（既存ファイルを再利用しない）
        try gate("fixture directory作成直後")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "新規fixture directoryは空")

        let store = directory.appendingPathComponent(StoreLifetimeProbe.sourceName)
        let backup = directory.appendingPathComponent(StoreLifetimeProbe.backupName)
        let restoredURL = directory.appendingPathComponent(StoreLifetimeProbe.restoredName)
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let sourceConfig = ModelConfiguration("MigrationFailureV1Source", schema: schema, url: store, cloudKitDatabase: .none)
        XCTAssertEqual(sourceConfig.url.standardizedFileURL, store.standardizedFileURL, "V1 sourceをfixture URLに固定しfallbackを許さない")
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
        let candidateConfig = ModelConfiguration("MigrationFailureInjectedCandidate", schema: candidateSchema, url: store, cloudKitDatabase: .none)
        XCTAssertEqual(candidateConfig.url.standardizedFileURL, store.standardizedFileURL, "candidateもfixture URLに固定しfallbackを許さない")
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredURL.path), "restore先は新規URL")
        try Self.onlineBackup(from: backup, toNew: restoredURL)
        pinned[StoreLifetimeProbe.restoredName] = try StoreLifetimeProbe.identity(ofRegularFileAt: restoredURL)
        try gate("restore作成後")
        try Self.requireIntegrity(restoredURL)
        try gate("restore integrity_check後")
        let restoredConfig = ModelConfiguration("MigrationFailureV1Restored", schema: schema, url: restoredURL, cloudKitDatabase: .none)
        XCTAssertEqual(restoredConfig.url.standardizedFileURL, restoredURL.standardizedFileURL)
        try Self.assertValues(at: restoredURL, schema: schema, configName: "MigrationFailureV1Restored", ids: fixtureIDs)
        try gate("restore読み戻し後")

        // ローカル関数は囲んでいる@MainActorのテストメソッドのisolationを引き継ぐ
        func assertIDsAndValues(_ url: URL, _ label: String) throws {
            let config = ModelConfiguration(label, schema: schema, url: url, cloudKitDatabase: .none)
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
        let configuration = ModelConfiguration(configName, schema: schema, url: url, cloudKitDatabase: .none)
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
/// ファイルを作成・変更せず、テストバンドル実行ファイルの読み取り専用openとin-memory containerだけを使う。
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

    /// 実fdには触れず、注入したfstat結果だけで走査の判定を確認する
    func testDescriptorScanSkipsOnlyBadDescriptorErrors() throws {
        let counts = try StoreLifetimeProbe.openDescriptorCounts(scanning: 4) { fd, info in
            guard fd == 2 else { return EBADF }
            info.st_dev = 7
            info.st_ino = 42
            return 0
        }
        var expected = stat()
        expected.st_dev = 7
        expected.st_ino = 42
        XCTAssertEqual(counts, [StoreLifetimeProbe.FileIdentity(expected): 1], "EBADFのfdは数えず、成功したfdだけを数える")
    }

    func testDescriptorScanStopsOnNonBadDescriptorError() {
        // EBADF以外は「閉じている」と断定できないので、全て停止すること
        for injected in [EIO, EINTR, EOVERFLOW, EACCES, Int32(-1)] {
            XCTAssertThrowsError(try StoreLifetimeProbe.openDescriptorCounts(scanning: 4) { fd, _ in
                fd == 1 ? injected : EBADF
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

    /// このプロセスが開いている全fdを走査し、inodeごとの本数を返す。
    /// fstatは状態を変えない。走査範囲が決められない場合やEBADF以外のfstat失敗は判定不能として停止する（fail closed）。
    static func openDescriptorCounts() throws -> [FileIdentity: Int] {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0,
              limit.rlim_cur > 0,
              limit.rlim_cur <= rlim_t(1 << 20) else {
            throw FailureTestError.descriptorScanUnavailable
        }
        return try openDescriptorCounts(scanning: Int32(limit.rlim_cur), using: systemDescriptorStat)
    }

    /// fstatの結果を「成功なら0、失敗ならerrno」で返す関数の型。テストで失敗を注入できるよう差し替え可能にする
    typealias DescriptorStat = (Int32, inout stat) -> Int32

    static func systemDescriptorStat(_ fd: Int32, _ info: inout stat) -> Int32 {
        guard fstat(fd, &info) != 0 else { return 0 }
        // errnoは次の呼び出しで上書きされうるので失敗直後に読む。0なら原因不明として成功と区別できる値にする
        let error = errno
        return error == 0 ? -1 : error
    }

    /// 0..<limit のfdを走査する。EBADF（そのfd番号は未使用）だけを読み飛ばし、
    /// それ以外の失敗はfdが開いているか判定できないので停止する（fail closed）
    static func openDescriptorCounts(scanning limit: Int32, using statDescriptor: DescriptorStat) throws -> [FileIdentity: Int] {
        var counts: [FileIdentity: Int] = [:]
        for fd in 0..<limit {
            var info = stat()
            let result = statDescriptor(fd, &info)
            if result == 0 {
                counts[FileIdentity(info), default: 0] += 1
                continue
            }
            guard result == EBADF else {
                throw FailureTestError.descriptorStatFailed(fd: fd, errno: result)
            }
        }
        return counts
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
    /// - fixture内のどのファイルも、このプロセスのfdで開かれていない
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
    case descriptorScanUnavailable
    case descriptorStatFailed(fd: Int32, errno: Int32)
    case integrityCheckFailed(String)
    case containerStillAlive(String)
    case openDescriptor(String)
    case unexpectedFile(String)
    case identityChanged(String)
}
#endif
