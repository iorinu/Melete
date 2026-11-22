import XCTest
import SwiftData
@testable import Melete

@MainActor
final class WorkoutValueEditingV1StaleTests: XCTestCase {
    private let workoutDay = Date(timeIntervalSince1970: 1_700_000_000)

    func testV1SaveRejectsStaleValueAfterAnotherContextSaves() throws {
        let fixture = try makeFixture()
        var staleEdits = WorkoutValueEditing.drafts(for: fixture.workoutA)
        staleEdits[0].text = "9"
        let baseline = WorkoutAdditionBaseline(fixture.workoutA)

        let workoutB = try XCTUnwrap(fixture.contextB.fetch(FetchDescriptor<Workout>()).first { $0.id == fixture.workoutID })
        let valueB = try XCTUnwrap(workoutB.records.flatMap(\.sets).flatMap(\.values).first)
        valueB.scaledValue = 11_000
        try fixture.contextB.save()

        XCTAssertEqual(valueB.scaledValue, 11_000)

        // 古いbaselineとdraftを、実際のV1保存境界へ渡す。
        let attemptedDay = try XCTUnwrap(WorkoutValueEditing.date(from: "2023-11-17", calendar: calendar))
        var persistCount = 0
        XCTAssertThrowsError(
            try WorkoutSetAdditionV1.save(
                staleEdits, additions: [], baseline: baseline, day: attemptedDay, to: fixture.workoutA,
                exercises: [], in: fixture.contextA, calendar: calendar, now: attemptedDay
            ) { context in persistCount += 1; try context.save() },
            "V1の通常編集は、別contextで更新された値を古いbaselineで上書きしない"
        )

        XCTAssertEqual(persistCount, 0, "拒否時に永続化処理を呼ばない")
        let verificationContext = ModelContext(fixture.contextA.container)
        let persistedWorkout = try XCTUnwrap(verificationContext.fetch(FetchDescriptor<Workout>()).first { $0.id == fixture.workoutID })
        let persistedValue = try XCTUnwrap(persistedWorkout.records.flatMap(\.sets).flatMap(\.values).first)
        XCTAssertEqual(persistedWorkout.day, "2023-11-14", "保存済みの日付を保つ")
        XCTAssertEqual(persistedValue.scaledValue, 11_000, "Bが保存した値を保つ")
    }

    func testV1SaveRejectsStaleDayAfterAnotherContextSaves() throws {
        let fixture = try makeFixture()
        let staleEdits = WorkoutValueEditing.drafts(for: fixture.workoutA)
        let baseline = WorkoutAdditionBaseline(fixture.workoutA)
        let workoutB = try XCTUnwrap(fixture.contextB.fetch(FetchDescriptor<Workout>()).first { $0.id == fixture.workoutID })
        workoutB.day = "2023-11-16"
        try fixture.contextB.save()

        var persistCount = 0
        let attemptedDay = try XCTUnwrap(WorkoutValueEditing.date(from: "2023-11-17", calendar: calendar))
        XCTAssertThrowsError(try WorkoutSetAdditionV1.save(
            staleEdits, additions: [], baseline: baseline, day: attemptedDay, to: fixture.workoutA,
            exercises: [], in: fixture.contextA, calendar: calendar, now: attemptedDay
        ) { _ in persistCount += 1 })

        XCTAssertEqual(persistCount, 0)
        let verificationContext = ModelContext(fixture.contextA.container)
        let persistedWorkout = try XCTUnwrap(verificationContext.fetch(FetchDescriptor<Workout>()).first { $0.id == fixture.workoutID })
        let persistedValue = try XCTUnwrap(persistedWorkout.records.flatMap(\.sets).flatMap(\.values).first)
        XCTAssertEqual(persistedWorkout.day, "2023-11-16")
        XCTAssertEqual(persistedValue.scaledValue, 7_000)
    }

    func testV1SaveAcceptsNormalEditAgainstUnchangedWorkout() throws {
        let fixture = try makeFixture()
        var drafts = WorkoutValueEditing.drafts(for: fixture.workoutA)
        drafts[0].text = "9"
        fixture.exerciseA.isArchived = true
        try fixture.contextA.save()
        let refreshedBaseline = WorkoutAdditionBaseline(fixture.workoutA)
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: fixture.workoutA.day, calendar: calendar))
        var persistCount = 0

        XCTAssertNoThrow(
            try WorkoutSetAdditionV1.save(
                drafts, additions: [], baseline: refreshedBaseline, day: day, to: fixture.workoutA,
                exercises: [fixture.exerciseA], in: fixture.contextA, calendar: calendar, now: day
            ) { context in persistCount += 1; try context.save() }
        )

        XCTAssertEqual(persistCount, 1)
        let verificationContext = ModelContext(fixture.contextA.container)
        let persistedWorkout = try XCTUnwrap(verificationContext.fetch(FetchDescriptor<Workout>()).first { $0.id == fixture.workoutID })
        let persistedValue = try XCTUnwrap(persistedWorkout.records.flatMap(\.sets).flatMap(\.values).first)
        XCTAssertEqual(persistedValue.scaledValue, 9_000)
        XCTAssertEqual(persistedWorkout.day, "2023-11-14")
    }

    func testV1SaveRejectsDirtyContextAndPreservesUnrelatedChanges() throws {
        let fixture = try makeFixture()
        let baseline = WorkoutAdditionBaseline(fixture.workoutA)
        var drafts = WorkoutValueEditing.drafts(for: fixture.workoutA)
        drafts[0].text = "9"
        let unrelated = Exercise(name: "未保存の別変更", metrics: [])
        fixture.contextA.insert(unrelated)
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: fixture.workoutA.day, calendar: calendar))
        var persistCount = 0

        XCTAssertThrowsError(try WorkoutSetAdditionV1.save(
            drafts, additions: [], baseline: baseline, day: day, to: fixture.workoutA,
            exercises: [], in: fixture.contextA, calendar: calendar, now: day
        ) { _ in persistCount += 1 })

        XCTAssertEqual(persistCount, 0)
        XCTAssertTrue(fixture.contextA.hasChanges)
        XCTAssertEqual(fixture.valueA.scaledValue, 7_000)
    }

    func testV1SaveFailureRollsBackAndCanRetryWithoutAdditions() throws {
        let fixture = try makeFixture()
        let baseline = WorkoutAdditionBaseline(fixture.workoutA)
        var drafts = WorkoutValueEditing.drafts(for: fixture.workoutA)
        drafts[0].text = "9"
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: fixture.workoutA.day, calendar: calendar))
        var persistCount = 0

        XCTAssertThrowsError(try WorkoutSetAdditionV1.save(
            drafts, additions: [], baseline: baseline, day: day, to: fixture.workoutA,
            exercises: [], in: fixture.contextA, calendar: calendar, now: day
        ) { _ in persistCount += 1; throw TestSaveError.injected })
        XCTAssertFalse(fixture.contextA.hasChanges)
        XCTAssertEqual(fixture.workoutA.day, "2023-11-14")
        XCTAssertEqual(fixture.valueA.scaledValue, 7_000)
        XCTAssertEqual(persistCount, 1)

        XCTAssertNoThrow(try WorkoutSetAdditionV1.save(
            drafts, additions: [], baseline: baseline, day: day, to: fixture.workoutA,
            exercises: [], in: fixture.contextA, calendar: calendar, now: day
        ) { context in persistCount += 1; try context.save() })
        XCTAssertEqual(persistCount, 2)
        let verificationContext = ModelContext(fixture.contextA.container)
        let persistedWorkout = try XCTUnwrap(verificationContext.fetch(FetchDescriptor<Workout>()).first { $0.id == fixture.workoutID })
        let persistedValue = try XCTUnwrap(persistedWorkout.records.flatMap(\.sets).flatMap(\.values).first)
        XCTAssertEqual(persistedValue.scaledValue, 9_000)
    }

    private enum TestSaveError: Error { case injected }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeFixture() throws -> Fixture {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration(
            "MeleteV1WorkoutValueEditingStale-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(container)
        contextA.autosaveEnabled = false

        let metric = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let value = MetricValue(metric: metric, scaledValue: 7_000)
        let set = SetRecord(sortOrder: 1, values: [value])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [set])
        let workout = Workout(day: workoutDay, records: [record], calendar: calendar)
        contextA.insert(exercise)
        contextA.insert(workout)
        try contextA.save()

        let contextB = ModelContext(container)
        contextB.autosaveEnabled = false
        let workoutA = try XCTUnwrap(contextA.fetch(FetchDescriptor<Workout>()).first { $0.id == workout.id })
        let valueA = try XCTUnwrap(workoutA.records.flatMap(\.sets).flatMap(\.values).first)
        return Fixture(
            contextA: contextA, contextB: contextB, exerciseA: exercise,
            workoutA: workoutA, valueA: valueA, workoutID: workout.id
        )
    }

    private struct Fixture {
        let contextA: ModelContext
        let contextB: ModelContext
        let exerciseA: Exercise
        let workoutA: Workout
        let valueA: MetricValue
        let workoutID: UUID
    }
}
