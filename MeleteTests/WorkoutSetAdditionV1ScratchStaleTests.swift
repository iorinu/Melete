import XCTest
import SwiftData
@testable import Melete

@MainActor
final class WorkoutSetAdditionV1ScratchStaleTests: XCTestCase {
    private let workoutDay = Date(timeIntervalSince1970: 1_700_000_000)

    func testV1SaveRejectsAdditionDraftAfterMetricDefinitionChangesInAnotherContext() throws {
        let fixture = try makeFixture()
        let baseline = WorkoutAdditionBaseline(fixture.workoutA)
        let drafts = WorkoutValueEditing.drafts(for: fixture.workoutA)
        let staleAddition = try XCTUnwrap(
            WorkoutValueEditing.appendSetDraft(for: fixture.recordA, exercise: fixture.exerciseA)
        )
        var addition = staleAddition
        addition.values[fixture.metricID] = "8"

        let exerciseB = try XCTUnwrap(
            fixture.contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == fixture.exerciseID }
        )
        var definitionDrafts = MetricDefinitionEditing.draft(for: exerciseB)
        definitionDrafts[0].isActive = false
        try MetricDefinitionEditingV1.save(definitionDrafts, for: exerciseB, in: fixture.contextB)
        XCTAssertFalse(fixture.contextB.hasChanges)
        XCTAssertEqual(exerciseB.metrics[0].isActive, false, "BはV1編集経路で無効化されている")
        XCTAssertEqual(fixture.exerciseA.metrics[0].isActive, true, "Aには古い定義が残っている")

        let originalDay = fixture.workoutA.day
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: originalDay))
        XCTAssertThrowsError(
            try WorkoutSetAdditionV1.save(
                drafts, additions: [addition],
                baseline: baseline, day: day, to: fixture.workoutA, exercises: [fixture.exerciseA], in: fixture.contextA,
                now: workoutDay
            ),
            "V1の追加セット保存は、別contextで更新された項目定義に対する古いdraftを拒否する"
        ) { error in
            guard case WorkoutValueEditError.metricsChanged = error else {
                return XCTFail("古い項目定義はmetricsChangedで拒否する: \(error)")
            }
        }
        XCTAssertFalse(fixture.contextA.hasChanges)

        let verifier = separateContext(fixture)
        let savedWorkout = try XCTUnwrap(
            verifier.fetch(FetchDescriptor<Workout>()).first { $0.id == fixture.workoutID }
        )
        XCTAssertEqual(savedWorkout.day, originalDay)
        XCTAssertEqual(savedWorkout.records.map(\.id), [fixture.recordID])
        XCTAssertEqual(savedWorkout.records[0].sets.map(\.id), [fixture.setID])
        XCTAssertEqual(savedWorkout.records[0].sets[0].values.map(\.id), [fixture.valueID])
        let savedValue = try XCTUnwrap(verifier.fetch(FetchDescriptor<MetricValue>()).first)
        XCTAssertEqual(WorkoutValueSnapshot(savedValue), fixture.originalValueSnapshot)
    }

    func testV1SaveRejectsStaleBaselineAfterWorkoutChangesInAnotherContext() throws {
        let fixture = try makeFixture()
        let baseline = WorkoutAdditionBaseline(fixture.workoutA)
        var drafts = WorkoutValueEditing.drafts(for: fixture.workoutA)
        drafts[0].text = "9"
        var addition = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: fixture.recordA, exercise: fixture.exerciseA))
        addition.values[fixture.metricID] = "8"

        let workoutB = try XCTUnwrap(fixture.contextB.fetch(FetchDescriptor<Workout>()).first { $0.id == fixture.workoutID })
        let changedValue = try XCTUnwrap(workoutB.records.flatMap(\.sets).flatMap(\.values).first)
        changedValue.scaledValue = 11_000
        workoutB.day = "2023-11-16"
        try fixture.contextB.save()

        let contextA = ModelContext(fixture.container)
        contextA.autosaveEnabled = false
        let workoutA = try XCTUnwrap(contextA.fetch(FetchDescriptor<Workout>()).first { $0.id == fixture.workoutID })
        let exerciseA = try XCTUnwrap(contextA.fetch(FetchDescriptor<Exercise>()).first { $0.id == fixture.exerciseID })
        XCTAssertThrowsError(try WorkoutSetAdditionV1.save(
            drafts, additions: [addition], baseline: baseline,
            day: try XCTUnwrap(WorkoutValueEditing.date(from: workoutA.day)), to: workoutA,
            exercises: [exerciseA], in: contextA, now: workoutDay
        )) { error in
            guard case WorkoutValueEditError.workoutContextMismatch = error else {
                return XCTFail("更新済みWorkoutに古いbaselineを使った保存を拒否する: \(error)")
            }
        }
        XCTAssertFalse(contextA.hasChanges)

        let verifier = separateContext(fixture)
        let persisted = try XCTUnwrap(verifier.fetch(FetchDescriptor<Workout>()).first { $0.id == fixture.workoutID })
        XCTAssertEqual(persisted.day, "2023-11-16")
        XCTAssertEqual(persisted.records.flatMap(\.sets).flatMap(\.values).map(\.scaledValue), [11_000])
    }

    func testV1AdditionAcceptsEqualSortOrderMetricsInDeterministicOrder() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("MeleteV1EqualMetricOrder-\(UUID().uuidString)", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let first = MetricDefinition(name: "先", unit: "x", allowsDecimal: false, isRequired: false, sortOrder: 4)
        let second = MetricDefinition(name: "後", unit: "x", allowsDecimal: false, isRequired: false, sortOrder: 4)
        let exercise = Exercise(name: "同順序", metrics: [second, first])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: first, scaledValue: 1)])])
        let workout = Workout(day: workoutDay, records: [record])
        context.insert(exercise); context.insert(workout); try context.save()
        let addition = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
        let expected = [first, second].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)
        XCTAssertEqual(addition.metrics.map(\.id), expected)
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day))
        XCTAssertNoThrow(try WorkoutSetAdditionV1.save(
            [], additions: [addition], baseline: WorkoutAdditionBaseline(workout), day: day,
            to: workout, exercises: [exercise], in: context, now: workoutDay
        ))
        XCTAssertEqual(record.sets.count, 2)
    }

    func testV1AdditionRejectsDeletedWorkoutAndPreservesDirtyUnrelatedChange() throws {
        let fixture = try makeFixture()
        let baseline = WorkoutAdditionBaseline(fixture.workoutA)
        let drafts = WorkoutValueEditing.drafts(for: fixture.workoutA)
        var addition = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: fixture.recordA, exercise: fixture.exerciseA))
        addition.values[fixture.metricID] = "8"

        let deletingContext = ModelContext(fixture.container)
        deletingContext.autosaveEnabled = false
        let deleted = try XCTUnwrap(deletingContext.fetch(FetchDescriptor<Workout>()).first { $0.id == fixture.workoutID })
        deletingContext.delete(deleted)
        try deletingContext.save()

        XCTAssertThrowsError(try WorkoutSetAdditionV1.save(
            drafts, additions: [addition], baseline: baseline,
            day: try XCTUnwrap(WorkoutValueEditing.date(from: fixture.workoutA.day)), to: fixture.workoutA,
            exercises: [fixture.exerciseA], in: fixture.contextA, now: workoutDay
        )) { error in
            guard case WorkoutValueEditError.workoutContextMismatch = error else { return XCTFail("削除済みWorkoutを拒否する: \(error)") }
        }
        XCTAssertFalse(fixture.contextA.hasChanges)

        fixture.exerciseA.name = "未保存の無関係変更"
        XCTAssertThrowsError(try WorkoutSetAdditionV1.save(
            drafts, additions: [addition], baseline: baseline,
            day: try XCTUnwrap(WorkoutValueEditing.date(from: fixture.workoutA.day)), to: fixture.workoutA,
            exercises: [fixture.exerciseA], in: fixture.contextA, now: workoutDay
        )) { error in
            guard case WorkoutValueEditError.unsavedContext = error else { return XCTFail("dirty contextを拒否する: \(error)") }
        }
        XCTAssertEqual(fixture.exerciseA.name, "未保存の無関係変更")
        XCTAssertTrue(fixture.contextA.hasChanges)
    }

    func testV1SaveAcceptsAdditionDraftWhenMetricDefinitionIsUnchanged() throws {
        let fixture = try makeFixture()
        var addition = try XCTUnwrap(
            WorkoutValueEditing.appendSetDraft(for: fixture.recordA, exercise: fixture.exerciseA)
        )
        addition.values[fixture.metricID] = "8"
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: fixture.workoutA.day))

        try WorkoutSetAdditionV1.save(
            WorkoutValueEditing.drafts(for: fixture.workoutA), additions: [addition],
            baseline: WorkoutAdditionBaseline(fixture.workoutA), day: day, to: fixture.workoutA, exercises: [fixture.exerciseA], in: fixture.contextA,
            now: workoutDay
        )

        let savedWorkout = try XCTUnwrap(separateContext(fixture).fetch(FetchDescriptor<Workout>()).first { $0.id == fixture.workoutID })
        let savedSets = savedWorkout.records[0].sets.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(savedSets.map(\.sortOrder), [1, 2])
        XCTAssertEqual(savedSets[1].values.map(\.scaledValue), [8_000])
    }

    func testV1AdditionRejectsDirtyContextWithoutRollingBackUnrelatedChange() throws {
        let fixture = try makeFixture()
        var addition = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: fixture.recordA, exercise: fixture.exerciseA))
        addition.values[fixture.metricID] = "8"
        fixture.exerciseA.name = "未保存の別変更"
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: fixture.workoutA.day))

        XCTAssertThrowsError(try WorkoutSetAdditionV1.save(
            WorkoutValueEditing.drafts(for: fixture.workoutA), additions: [addition], baseline: WorkoutAdditionBaseline(fixture.workoutA), day: day,
            to: fixture.workoutA, exercises: [fixture.exerciseA], in: fixture.contextA, now: workoutDay
        )) { error in
            guard case WorkoutValueEditError.unsavedContext = error else { return XCTFail("dirty contextを拒否する: \(error)") }
        }
        XCTAssertEqual(fixture.exerciseA.name, "未保存の別変更")
        XCTAssertEqual(fixture.workoutA.records[0].sets.count, 1)
    }

    func testV1AdditionRejectsWorkoutOwnedByAnotherContext() throws {
        let fixture = try makeFixture()
        var addition = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: fixture.recordA, exercise: fixture.exerciseA))
        addition.values[fixture.metricID] = "8"
        let foreignContext = ModelContext(fixture.container)
        foreignContext.autosaveEnabled = false
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: fixture.workoutA.day))

        XCTAssertThrowsError(try WorkoutSetAdditionV1.save(
            WorkoutValueEditing.drafts(for: fixture.workoutA), additions: [addition], baseline: WorkoutAdditionBaseline(fixture.workoutA), day: day,
            to: fixture.workoutA, exercises: [fixture.exerciseA], in: foreignContext, now: workoutDay
        )) { error in
            guard case WorkoutValueEditError.workoutContextMismatch = error else { return XCTFail("別context所有のWorkoutを拒否する: \(error)") }
        }
        XCTAssertEqual(fixture.workoutA.records[0].sets.count, 1)
    }

    func testV1AdditionRestoresModelsWhenPersistenceFails() throws {
        let fixture = try makeFixture()
        var addition = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: fixture.recordA, exercise: fixture.exerciseA))
        addition.values[fixture.metricID] = "8"
        let originalDay = fixture.workoutA.day
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: originalDay)).addingTimeInterval(86_400)
        let failure = NSError(domain: "WorkoutSetAdditionV1Scratch", code: 1)

        var drafts = WorkoutValueEditing.drafts(for: fixture.workoutA)
        drafts[0].text = "9"
        XCTAssertThrowsError(try WorkoutSetAdditionV1.save(
            drafts, additions: [addition], baseline: WorkoutAdditionBaseline(fixture.workoutA), day: day,
            to: fixture.workoutA, exercises: [fixture.exerciseA], in: fixture.contextA, now: day,
            persist: { _ in throw failure }
        ))
        XCTAssertEqual(fixture.workoutA.records[0].sets.map(\.id), [fixture.setID])
        XCTAssertEqual(fixture.workoutA.records[0].sets[0].values[0].scaledValue, 7_000)
        XCTAssertEqual(fixture.workoutA.day, originalDay)
        XCTAssertFalse(fixture.contextA.hasChanges)

        let verifier = separateContext(fixture)
        let persisted = try XCTUnwrap(verifier.fetch(FetchDescriptor<Workout>()).first { $0.id == fixture.workoutID })
        XCTAssertEqual(persisted.day, originalDay)
        XCTAssertEqual(persisted.records.flatMap(\.sets).flatMap(\.values).map(\.scaledValue), [7_000])

        try WorkoutSetAdditionV1.save(
            drafts, additions: [addition], baseline: WorkoutAdditionBaseline(fixture.workoutA), day: day, to: fixture.workoutA,
            exercises: [fixture.exerciseA], in: fixture.contextA, now: day
        )
        XCTAssertFalse(fixture.contextA.hasChanges)
        XCTAssertEqual(fixture.workoutA.records[0].sets.sorted { $0.sortOrder < $1.sortOrder }.map(\.sortOrder), [1, 2])
        XCTAssertEqual(fixture.workoutA.records[0].sets.first { $0.sortOrder == 1 }?.values.first?.scaledValue, 9_000)
    }

    func testV1AdditionUsesPassedCalendarAndNow() throws {
        let fixture = try makeFixture()
        var addition = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: fixture.recordA, exercise: fixture.exerciseA))
        addition.values[fixture.metricID] = "8"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 14 * 60 * 60)!
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: "2023-11-15", calendar: calendar))

        try WorkoutSetAdditionV1.save(
            WorkoutValueEditing.drafts(for: fixture.workoutA), additions: [addition], baseline: WorkoutAdditionBaseline(fixture.workoutA), day: day,
            to: fixture.workoutA, exercises: [fixture.exerciseA], in: fixture.contextA,
            calendar: calendar, now: day
        )

        XCTAssertEqual(fixture.workoutA.day, "2023-11-15")
    }

    private func makeFixture() throws -> Fixture {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("MeleteV1SetAdditionScratch", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(container)
        contextA.autosaveEnabled = false

        let metric = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let value = MetricValue(metric: metric, scaledValue: 7_000)
        let set = SetRecord(sortOrder: 1, values: [value])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [set])
        let workout = Workout(day: workoutDay, records: [record])
        contextA.insert(exercise)
        contextA.insert(workout)
        try contextA.save()

        let contextB = ModelContext(container)
        contextB.autosaveEnabled = false
        let exerciseA = try XCTUnwrap(
            contextA.fetch(FetchDescriptor<Exercise>()).first { $0.id == exercise.id }
        )
        let workoutA = try XCTUnwrap(
            contextA.fetch(FetchDescriptor<Workout>()).first { $0.id == workout.id }
        )
        let recordA = try XCTUnwrap(workoutA.records.first { $0.id == record.id })
        return Fixture(
            container: container, contextA: contextA, contextB: contextB,
            exerciseA: exerciseA, workoutA: workoutA, recordA: recordA,
            exerciseID: exercise.id, workoutID: workout.id, recordID: record.id,
            setID: set.id, valueID: value.id, metricID: metric.id,
            originalValueSnapshot: WorkoutValueSnapshot(value)
        )
    }

    // 同じインメモリcontainer上の別contextで確認する。永続ストアを開き直す検証ではない。
    private func separateContext(_ fixture: Fixture) -> ModelContext {
        let context = ModelContext(fixture.container)
        context.autosaveEnabled = false
        return context
    }

    private struct Fixture {
        let container: ModelContainer
        let contextA: ModelContext
        let contextB: ModelContext
        let exerciseA: Exercise
        let workoutA: Workout
        let recordA: ExerciseRecord
        let exerciseID: UUID
        let workoutID: UUID
        let recordID: UUID
        let setID: UUID
        let valueID: UUID
        let metricID: UUID
        let originalValueSnapshot: WorkoutValueSnapshot
    }
}
