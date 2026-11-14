import XCTest
import SwiftData
@testable import Melete

final class MeleteTests: XCTestCase {
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
}
