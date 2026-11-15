import XCTest
import SwiftData
@testable import Melete

final class MeleteTests: XCTestCase {
    func testUITestStoreSelectionRequiresValidOwnedPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteIsolationTests-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try Data("Melete UI test root v1".utf8).write(to: root.appendingPathComponent(".melete-ui-test-root"))

        let store = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path)
        try Data(UUID().uuidString.utf8).write(to: store.appendingPathComponent(".melete-ui-test-store"))

        let validArguments = ["--melete-ui-test-root", root.path, "--melete-ui-test-store", store.path]
        XCTAssertNotNil(UITestStoreIsolation.storeURL(arguments: validArguments))
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("MeleteUITest", schema: schema, url: store.appendingPathComponent("Melete.store"), cloudKitDatabase: .none)
        _ = try ModelContainer(for: schema, configurations: [configuration])
        XCTAssertNotNil(UITestStoreIsolation.storeURL(arguments: validArguments), "初回起動後に作成されるストア関連ファイルを許可する")
        XCTAssertTrue(Set(try FileManager.default.contentsOfDirectory(atPath: store.path)).isSubset(of: [".melete-ui-test-store", "Melete.store", "Melete.store-wal", "Melete.store-shm"]))
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: []))
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: ["--melete-ui-test-root", root.path, "--melete-ui-test-store"]))

        try Data("not-a-uuid".utf8).write(to: store.appendingPathComponent(".melete-ui-test-store"))
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: validArguments))
        try Data(UUID().uuidString.utf8).write(to: store.appendingPathComponent(".melete-ui-test-store"))

        let unknown = store.appendingPathComponent("unexpected")
        try Data().write(to: unknown)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: validArguments))
        try FileManager.default.removeItem(at: unknown)

        let storeLink = store.appendingPathComponent("Melete.store-link")
        try FileManager.default.createSymbolicLink(at: storeLink, withDestinationURL: store.appendingPathComponent("Melete.store"))
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: validArguments))
        try FileManager.default.removeItem(at: storeLink)

        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data(UUID().uuidString.utf8).write(to: outside.appendingPathComponent(".melete-ui-test-store"))
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: ["--melete-ui-test-root", root.path, "--melete-ui-test-store", outside.path]))

        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: ["--melete-ui-test-root", root.path, "--melete-ui-test-store", link.path]))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: validArguments))
    }

    func testMetricInputBoundaries() {
        XCTAssertEqual(MetricInput.parse("0", allowsDecimal: false), 0)
        XCTAssertEqual(MetricInput.parse("12", allowsDecimal: false), 12_000)
        XCTAssertNil(MetricInput.parse("1.2", allowsDecimal: false))
        XCTAssertEqual(MetricInput.parse("1.234", allowsDecimal: true), 1_234)
        XCTAssertNil(MetricInput.parse("1.2345", allowsDecimal: true))
        XCTAssertNil(MetricInput.parse("-1", allowsDecimal: true))
        XCTAssertNil(MetricInput.parse("12kg", allowsDecimal: true))
        XCTAssertNil(MetricInput.parse("9223372036854776", allowsDecimal: true))
        XCTAssertNil(MetricInput.parse("", allowsDecimal: true))
    }

    func testWorkoutDayIsStableAcrossTimeZones() {
        let cases: [(String, Int, Int, Int, Int)] = [
            ("Pacific/Kiritimati", 2026, 11, 14, 0),
            ("Asia/Tokyo", 2026, 11, 14, 0),
            ("Pacific/Honolulu", 2026, 11, 14, 0),
            ("Pacific/Kiritimati", 2026, 11, 14, 23),
        ]

        for (timeZoneID, year, month, day, hour) in cases {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneID)!
            let selectedDate = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
            let stored = Workout(day: selectedDate, records: [], calendar: calendar).day
            XCTAssertEqual(stored, "2026-11-14", "\(timeZoneID) の \(hour) 時を選択した場合")
            XCTAssertEqual(Workout.dayFormatter.date(from: stored).map { Workout.dayFormatter.string(from: $0) }, "2026-11-14")
        }
    }

    func testCalendarGridUsesMondayFirstAndLeapFebruary() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = WorkoutCalendarLogic.calendar(timeZone: utc)
        let february = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 19)))
        let grid = WorkoutCalendarLogic.monthGrid(for: february, calendar: calendar)
        XCTAssertEqual(grid.dayCount, 29)
        XCTAssertEqual(grid.weekdayOffset, 3) // 2024-02-01 は木曜日
        XCTAssertEqual(grid.cellCount, 35)
        XCTAssertEqual(WorkoutCalendarLogic.date(day: 1, in: grid, calendar: calendar), try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 1))))
        XCTAssertEqual(WorkoutCalendarLogic.date(day: 29, in: grid, calendar: calendar), try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 29))))
        XCTAssertNil(WorkoutCalendarLogic.date(day: 30, in: grid, calendar: calendar))
    }

    func testCalendarGridHandlesMonthEndAndYearChange() throws {
        let calendar = WorkoutCalendarLogic.calendar(timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        let december = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 12, day: 31)))
        let decemberGrid = WorkoutCalendarLogic.monthGrid(for: december, calendar: calendar)
        XCTAssertEqual(decemberGrid.dayCount, 31)
        XCTAssertEqual(WorkoutCalendarLogic.dayKey(try XCTUnwrap(WorkoutCalendarLogic.date(day: 31, in: decemberGrid, calendar: calendar)), calendar: calendar), "2024-12-31")
        let january = try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: decemberGrid.start))
        let januaryGrid = WorkoutCalendarLogic.monthGrid(for: january, calendar: calendar)
        XCTAssertEqual(calendar.component(.year, from: januaryGrid.start), 2025)
        XCTAssertEqual(calendar.component(.month, from: januaryGrid.start), 1)
        XCTAssertEqual(januaryGrid.dayCount, 31)
    }

    func testDateKeysInTokyoHonoluluAndAcrossDaylightSavingBoundary() throws {
        let tokyo = WorkoutCalendarLogic.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo")))
        let honolulu = WorkoutCalendarLogic.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu")))
        let instant = Date(timeIntervalSince1970: 1_710_000_000) // 固定時刻: 2024-03-09 UTC
        XCTAssertEqual(WorkoutCalendarLogic.dayKey(instant, calendar: tokyo), "2024-03-10")
        XCTAssertEqual(WorkoutCalendarLogic.dayKey(instant, calendar: honolulu), "2024-03-09")

        let losAngeles = WorkoutCalendarLogic.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")))
        let beforeDST = Date(timeIntervalSince1970: 1_710_064_799) // 2024-03-10 01:59:59 PST
        let afterDST = Date(timeIntervalSince1970: 1_710_064_800) // 2024-03-10 03:00:00 PDT
        XCTAssertEqual(WorkoutCalendarLogic.dayKey(beforeDST, calendar: losAngeles), "2024-03-10")
        XCTAssertEqual(WorkoutCalendarLogic.dayKey(afterDST, calendar: losAngeles), "2024-03-10")
    }

    func testWorkoutFilterReturnsSameDayRecordsOrAllHistory() {
        let first = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [])
        let sameDay = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [])
        let otherDay = Workout(day: Date(timeIntervalSince1970: 1_700_086_400), records: [])
        let workouts = [first, sameDay, otherDay]
        XCTAssertEqual(WorkoutCalendarLogic.workouts(on: first.day, from: workouts).map(\.id), [first.id, sameDay.id])
        XCTAssertEqual(WorkoutCalendarLogic.workouts(on: nil, from: workouts).map(\.id), workouts.map(\.id))
        XCTAssertTrue(WorkoutCalendarLogic.workouts(on: "2099-01-01", from: workouts).isEmpty)
    }

    func testArchiveAndFileStoreRoundTripPreserveHistoryAndSetOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("Test", schema: schema, url: url, cloudKitDatabase: .none)

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
            let exercise = Exercise(name: "テスト種目", metrics: [metric])
            let sets = [1_000, 2_500, 3_000].enumerated().map { index, value in
                SetRecord(sortOrder: index + 1, values: [MetricValue(metric: metric, scaledValue: Int64(value))])
            }
            let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: sets)
            let workout = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [record])
            exercise.isArchived = true
            context.insert(exercise)
            context.insert(workout)
            try context.save()
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(reopened)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let workouts = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(exercises.count, 1)
        XCTAssertTrue(exercises[0].isArchived)
        XCTAssertEqual(workouts.count, 1)
        let orderedSets = workouts[0].records[0].sets.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(orderedSets.map(\.sortOrder), [1, 2, 3])
        XCTAssertEqual(orderedSets.compactMap { $0.values.first?.scaledValue }, [1_000, 2_500, 3_000])
    }

    func testDeletingWorkoutRemovesOnlyTargetAndCascadesWithoutRemovingExercise() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteDeleteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("DeleteTest", schema: schema, url: url, cloudKitDatabase: .none)
        let targetID = UUID()
        let otherID = UUID()
        let exerciseID: UUID

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: false, isRequired: true, sortOrder: 0)
            let exercise = Exercise(name: "テスト種目", metrics: [metric])
            exerciseID = exercise.id
            let targetSet = SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: 10_000)])
            let targetRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [targetSet])
            let target = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [targetRecord])
            target.id = targetID
            let otherSet = SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: 20_000)])
            let otherRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [otherSet])
            let other = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [otherRecord])
            other.id = otherID
            context.insert(exercise)
            context.insert(target)
            context.insert(other)
            try context.save()

            try WorkoutDeletion.delete(workoutID: targetID, in: context)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).map(\.id), [otherID])
            XCTAssertTrue(try context.fetch(FetchDescriptor<ExerciseRecord>()).allSatisfy { $0.workout?.id == otherID })
            XCTAssertEqual(try context.fetch(FetchDescriptor<SetRecord>()).count, 1)
            XCTAssertEqual(try context.fetch(FetchDescriptor<MetricValue>()).count, 1)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Exercise>()).map(\.id), [exerciseID])
            try context.save()
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<Workout>()).map(\.id), [otherID])
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<Exercise>()).map(\.id), [exerciseID])
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<ExerciseRecord>()).count, 1)
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<SetRecord>()).count, 1)
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<MetricValue>()).count, 1)
    }
}
