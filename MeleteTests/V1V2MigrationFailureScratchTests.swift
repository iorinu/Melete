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
final class V1V2MigrationFailureScratchTests: XCTestCase {
    private enum InjectedFailure: Error { case expected }
    private static var failurePhaseWasInvoked = false

    override func setUpWithError() throws {
        // fixture作成、SQLite出力、内容検証は実装済みだが、同一UIDの主体によるパス置換を
        // 防ぐ保証と、SwiftDataのread-write ModelContainer再オープン中のstore lifetime安全性が
        // 未解決のため、I/O前の無条件skipを維持する。失敗注入はテスト専用planの模擬である。
        throw XCTSkip("同一UIDによるパス置換とSwiftData store lifetime安全性が未解決のため停止中")
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

        let store = directory.appendingPathComponent("source.sqlite")
        let backup = directory.appendingPathComponent("backup.sqlite")
        let restoredURL = directory.appendingPathComponent("restored.sqlite")
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

        do {
            let container = try ModelContainer(for: schema, configurations: [sourceConfig])
            let context = ModelContext(container)
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
        let fixtureIDs = FixtureIDs(exercise: exerciseID, metric: metricID, workout: workoutID, record: recordID, set: setID, nilValue: nilValueID, zeroValue: zeroValueID, exerciseCreatedAt: exerciseCreatedAt, workoutCreatedAt: workoutCreatedAt, setCreatedAt: setCreatedAt)
        try Self.assertValues(at: store, schema: schema, configName: "MigrationFailureV1Before", ids: fixtureIDs)
        try Self.assertIntegrity(store)
        try Self.onlineBackup(from: store, toNew: backup)
        try Self.assertIntegrity(backup)

        // これは失敗を明示注入したテスト専用planであり、本番 MeleteMigrationPlan の失敗ではない。
        let candidateSchema = Schema(versionedSchema: MeleteSchemaV2.self)
        let candidateConfig = ModelConfiguration("MigrationFailureInjectedCandidate", schema: candidateSchema, url: store, cloudKitDatabase: .none)
        XCTAssertEqual(candidateConfig.url.standardizedFileURL, store.standardizedFileURL, "candidateもfixture URLに固定しfallbackを許さない")
        Self.failurePhaseWasInvoked = false
        XCTAssertThrowsError(try ModelContainer(for: candidateSchema, migrationPlan: DeterministicFailingPlan.self, configurations: [candidateConfig])) { error in
            XCTAssertNotNil(error, "テスト専用migration phaseが注入するエラーで失敗する")
        }
        XCTAssertTrue(Self.failurePhaseWasInvoked, "テスト専用のwillMigrate failure phaseが実行された")

        // 失敗後のsourceが開けるか確認し、独立したbackupから新規URLへ戻す。
        try Self.assertValues(at: store, schema: schema, configName: "MigrationFailureV1After", ids: fixtureIDs)
        try Self.assertIntegrity(store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredURL.path), "restore先は新規URL")
        try Self.onlineBackup(from: backup, toNew: restoredURL)
        try Self.assertIntegrity(restoredURL)
        let restoredConfig = ModelConfiguration("MigrationFailureV1Restored", schema: schema, url: restoredURL, cloudKitDatabase: .none)
        XCTAssertEqual(restoredConfig.url.standardizedFileURL, restoredURL.standardizedFileURL)
        try Self.assertValues(at: restoredURL, schema: schema, configName: "MigrationFailureV1Restored", ids: fixtureIDs)

        func assertIDsAndValues(_ url: URL, _ label: String) throws {
            let config = ModelConfiguration(label, schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
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
        try assertIDsAndValues(store, "MigrationFailureV1SourceFinal")
        try assertIDsAndValues(restoredURL, "MigrationFailureV1RestoreFinal")
    }

    private struct FixtureIDs {
        let exercise: UUID, metric: UUID, workout: UUID, record: UUID, set: UUID, nilValue: UUID, zeroValue: UUID
        let exerciseCreatedAt: Date, workoutCreatedAt: Date, setCreatedAt: Date
    }

    private static func assertValues(at url: URL, schema: Schema, configName: String, ids: FixtureIDs) throws {
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(configName, schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)
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

    private static func assertIntegrity(_ url: URL) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard openResult == SQLITE_OK, let database else { if let database { sqlite3_close_v2(database) }; throw FailureTestError.sqlite }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else { if let statement { sqlite3_finalize(statement) }; throw FailureTestError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw FailureTestError.sqlite }
        XCTAssertEqual(String(cString: text), "ok")
    }
}

private enum FailureTestError: Error { case unsafeFixture, invalidBackupPath, sqlite }
#endif
