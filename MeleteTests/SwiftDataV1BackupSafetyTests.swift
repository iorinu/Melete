import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import Melete

final class SwiftDataV1BackupSafetyTests: XCTestCase {
    private struct Fixture: Equatable {
        let exerciseID: UUID
        let metricIDs: [UUID]
        let workoutID: UUID
        let recordID: UUID
        let setIDs: [UUID]
        let valueIDs: [UUID]
        let valueSnapshots: [WorkoutValueSnapshot]
    }

    private enum BackupError: Error, CustomStringConvertible {
        case sqlite(operation: String, code: Int32, message: String)
        case unexpectedResult(String)

        var description: String {
            switch self {
            case let .sqlite(operation, code, message): "\(operation) failed (\(code)): \(message)"
            case let .unexpectedResult(message): message
            }
        }
    }

    @MainActor
    func testV1OnlineBackupAndRestorePreserveSyntheticStoreWithoutMutatingSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV1BackupSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let sourceURL = directory.appendingPathComponent("source.sqlite")
        let backupURL = directory.appendingPathComponent("backup.sqlite")
        let restoreURL = directory.appendingPathComponent("restore.sqlite")
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let sourceConfiguration = ModelConfiguration("MeleteV1BackupSafetySource", schema: schema, url: sourceURL, cloudKitDatabase: .none)

        let fixture: Fixture
        var sourceContainer: ModelContainer?
        do {
            let container = try ModelContainer(for: schema, configurations: [sourceConfiguration])
            sourceContainer = container
            let context = ModelContext(container)
            let metricA = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
            metricA.id = UUID()
            let metricB = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 1)
            metricB.id = UUID()
            let exercise = Exercise(name: "合成種目", metrics: [metricA, metricB])
            exercise.id = UUID()

            let nilValue = MetricValue(metric: metricA, scaledValue: nil)
            let zeroValue = MetricValue(metric: metricB, scaledValue: 0)
            let nonzeroValue = MetricValue(metric: metricA, scaledValue: 82_500)
            let firstSet = SetRecord(sortOrder: 2, values: [nilValue, zeroValue])
            let secondSet = SetRecord(sortOrder: 5, values: [nonzeroValue])
            let record = ExerciseRecord(exercise: exercise, sortOrder: 3, sets: [firstSet, secondSet])
            let workout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [record])
            context.insert(exercise)
            context.insert(workout)
            try context.save()

            fixture = Fixture(
                exerciseID: exercise.id,
                metricIDs: [metricA.id, metricB.id],
                workoutID: workout.id,
                recordID: record.id,
                setIDs: [firstSet.id, secondSet.id],
                valueIDs: [nilValue.id, zeroValue.id, nonzeroValue.id].sorted { $0.uuidString < $1.uuidString },
                valueSnapshots: [nilValue, zeroValue, nonzeroValue].map(WorkoutValueSnapshot.init)
                    .sorted { $0.id.uuidString < $1.id.uuidString }
            )
        }

        let walURL = URL(fileURLWithPath: sourceURL.path + "-wal")
        let walAttributes = try? FileManager.default.attributesOfItem(atPath: walURL.path)
        let walWasPresentAndNonempty = ((walAttributes?[.size] as? NSNumber)?.intValue ?? 0) > 0
        XCTAssertTrue(walWasPresentAndNonempty, "合成V1ストアでWALが生成され、backup前に非空であること")

        try Self.onlineBackup(readOnlySource: sourceURL, newDestination: backupURL)
        // source containerが開いている間のWALをbackup APIが読み込み、snapshotを作成する。
        try Self.assertIntegrity(of: backupURL)
        try Self.onlineBackup(readOnlySource: backupURL, newDestination: restoreURL)
        try Self.assertIntegrity(of: restoreURL)

        let restoreConfiguration = ModelConfiguration("MeleteV1BackupSafetyRestore", schema: schema, url: restoreURL, cloudKitDatabase: .none)
        let restoredContainer = try ModelContainer(for: schema, configurations: [restoreConfiguration])
        let restored = try Self.readFixture(from: ModelContext(restoredContainer), expected: fixture)
        XCTAssertEqual(restored.exerciseID, fixture.exerciseID)
        XCTAssertEqual(restored.workoutID, fixture.workoutID)
        XCTAssertEqual(restored.recordID, fixture.recordID)
        XCTAssertEqual(restored.metricIDs, fixture.metricIDs)
        XCTAssertEqual(restored.setIDs, fixture.setIDs)
        XCTAssertEqual(Set(restored.valueIDs), Set(fixture.valueIDs))
        XCTAssertEqual(restored.valueSnapshots, fixture.valueSnapshots)

        sourceContainer = nil
        let reopenedSource = try ModelContainer(for: schema, configurations: [sourceConfiguration])
        let reopened = try Self.readFixture(from: ModelContext(reopenedSource), expected: fixture)
        XCTAssertEqual(reopened, restored, "backup後も元ストアの内容が変わらないこと")
    }

    func testReadOnlyBackupRejectsMissingSourceWithoutCreatingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV1BackupMissingSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let missingSource = directory.appendingPathComponent("must-not-be-created.sqlite")
        let destination = directory.appendingPathComponent("must-not-be-created-backup.sqlite")

        XCTAssertFalse(FileManager.default.fileExists(atPath: missingSource.path))
        XCTAssertThrowsError(try Self.onlineBackup(readOnlySource: missingSource, newDestination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingSource.path), "READONLY source接続で欠落元ファイルを作成しない")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "source接続失敗時にdestinationを作成しない")
    }

    @MainActor
    private static func readFixture(from context: ModelContext, expected: Fixture) throws -> Fixture {
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let workouts = try context.fetch(FetchDescriptor<Workout>())
        let exercise = try XCTUnwrap(exercises.first { $0.id == expected.exerciseID })
        let workout = try XCTUnwrap(workouts.first { $0.id == expected.workoutID })
        XCTAssertEqual(exercises.count, 1)
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(exercise.name, "合成種目")
        let metrics = exercise.metrics.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(metrics.map(\.id), expected.metricIDs)
        XCTAssertEqual(metrics.map(\.sortOrder), [0, 1])
        XCTAssertEqual(metrics.map(\.name), ["重量", "回数"])
        XCTAssertEqual(workout.records.map(\.id), [expected.recordID])
        let record = try XCTUnwrap(workout.records.first)
        XCTAssertEqual(record.exerciseID, exercise.id)
        XCTAssertEqual(record.exerciseName, exercise.name)
        XCTAssertEqual(record.sortOrder, 3)
        XCTAssertEqual(record.workout?.id, workout.id)
        let sets = record.sets.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(sets.map(\.id), expected.setIDs)
        XCTAssertEqual(sets.map(\.sortOrder), [2, 5])
        XCTAssertTrue(sets.allSatisfy { $0.exerciseRecord?.id == record.id })
        let values = sets.flatMap(\.values).sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(Set(values.map(\.id)), Set(expected.valueIDs))
        XCTAssertTrue(values.allSatisfy { value in sets.contains { $0.id == value.setRecord?.id } })
        XCTAssertEqual(values.filter { $0.scaledValue == nil }.count, 1)
        XCTAssertEqual(values.filter { $0.scaledValue == 0 }.count, 1)
        XCTAssertEqual(values.filter { $0.scaledValue == 82_500 }.count, 1)
        return Fixture(
            exerciseID: exercise.id,
            metricIDs: metrics.map(\.id),
            workoutID: workout.id,
            recordID: record.id,
            setIDs: sets.map(\.id),
            valueIDs: values.map(\.id).sorted { $0.uuidString < $1.uuidString },
            valueSnapshots: values.map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    private static func onlineBackup(readOnlySource sourceURL: URL, newDestination destinationURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw BackupError.unexpectedResult("source file does not exist: \(sourceURL.lastPathComponent)")
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw BackupError.unexpectedResult("destination must be a new file: \(destinationURL.lastPathComponent)")
        }
        var source: OpaquePointer?
        var destination: OpaquePointer?
        let sourceResult = sqlite3_open_v2(sourceURL.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard sourceResult == SQLITE_OK, let source else {
            defer { if let source { sqlite3_close_v2(source) } }
            throw BackupError.sqlite(operation: "open readonly source", code: sourceResult, message: source.map { String(cString: sqlite3_errmsg($0)) } ?? "no database handle")
        }
        defer { sqlite3_close_v2(source) }

        let destinationResult = sqlite3_open_v2(destinationURL.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE | SQLITE_OPEN_FULLMUTEX, nil)
        guard destinationResult == SQLITE_OK, let destination else {
            defer { if let destination { sqlite3_close_v2(destination) } }
            throw BackupError.sqlite(operation: "create new destination", code: destinationResult, message: destination.map { String(cString: sqlite3_errmsg($0)) } ?? "no database handle")
        }
        defer { sqlite3_close_v2(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw BackupError.sqlite(operation: "initialize online backup", code: sqlite3_errcode(destination), message: String(cString: sqlite3_errmsg(destination)))
        }
        var result = sqlite3_backup_step(backup, -1)
        var retryCount = 0
        while (result == SQLITE_BUSY || result == SQLITE_LOCKED) && retryCount < 40 {
            sqlite3_sleep(25)
            result = sqlite3_backup_step(backup, -1)
            retryCount += 1
        }
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE else {
            throw BackupError.sqlite(operation: "copy online backup", code: result, message: String(cString: sqlite3_errmsg(destination)))
        }
        guard finishResult == SQLITE_OK else {
            throw BackupError.sqlite(operation: "finish online backup", code: finishResult, message: String(cString: sqlite3_errmsg(destination)))
        }

        var journalStatement: OpaquePointer?
        let journalPrepareResult = sqlite3_prepare_v2(destination, "PRAGMA journal_mode=DELETE", -1, &journalStatement, nil)
        guard journalPrepareResult == SQLITE_OK, let journalStatement else {
            throw BackupError.sqlite(operation: "prepare destination journal mode", code: journalPrepareResult, message: String(cString: sqlite3_errmsg(destination)))
        }
        defer { sqlite3_finalize(journalStatement) }
        guard sqlite3_step(journalStatement) == SQLITE_ROW,
              let journalMode = sqlite3_column_text(journalStatement, 0),
              String(cString: journalMode).lowercased() == "delete" else {
            throw BackupError.sqlite(operation: "set destination journal mode to DELETE", code: sqlite3_errcode(destination), message: String(cString: sqlite3_errmsg(destination)))
        }
    }

    private static func assertIntegrity(of url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard openResult == SQLITE_OK, let database else {
            throw BackupError.sqlite(operation: "open for integrity_check", code: openResult, message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "no database handle")
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw BackupError.sqlite(operation: "prepare integrity_check", code: prepareResult, message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw BackupError.sqlite(operation: "run integrity_check", code: sqlite3_errcode(database), message: String(cString: sqlite3_errmsg(database)))
        }
        XCTAssertEqual(String(cString: text), "ok", file: file, line: line)
    }
}
