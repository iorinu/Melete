import XCTest
import SwiftData
@testable import Melete

@MainActor
final class WorkoutSetAdditionV2BaselineTests: XCTestCase {
    private func makeConfiguration(schema: Schema, name: String) -> ModelConfiguration {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).sqlite")
        return ModelConfiguration(name, schema: schema, url: url, cloudKitDatabase: .none)
    }

    func testStaleAdditionDraftIsRejectedWhenAnotherContextAddsActiveRequiredMetric() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = makeConfiguration(schema: schema, name: "MeleteV2AddedActiveMetricRace")
        let containerA = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(containerA)

        let weight = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "競合種目", metrics: [weight])
        let oldValue = MetricValue(metric: weight, scaledValue: 12_500)
        let oldSet = SetRecord(sortOrder: 1, values: [oldValue])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [oldSet])
        let workout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [record])
        contextA.insert(exercise)
        contextA.insert(workout)
        try contextA.save()

        let originalRevision = MetricDefinitionRevision(
            metricID: weight.id, revision: 1, name: "重量", unit: "kg",
            allowsDecimal: true, isRequired: false, sortOrder: 0
        )
        contextA.insert(originalRevision)
        try contextA.save()
        let originalLink = try MetricValueRevisionLinking.register(value: oldValue, revision: originalRevision, in: contextA)
        try contextA.save()

        var staleAddition = try XCTUnwrap(
            WorkoutValueEditingV2.appendSetDraft(for: record, exercise: exercise, in: contextA)
        )
        staleAddition.values[weight.id] = "20.5"

        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let exerciseB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == exercise.id })
        var definitionDrafts = try MetricDefinitionEditingV2.draft(for: exerciseB, in: contextB)
        let repetition = MetricDefinitionDraft(name: "回数", unit: "回", allowsDecimal: false, isRequired: true)
        definitionDrafts.append(repetition)
        try MetricDefinitionEditingV2.save(definitionDrafts, for: exerciseB, in: contextB)
        XCTAssertFalse(contextB.hasChanges, "Bの定義保存後はcontextがcleanである")
        let savedExerciseB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == exercise.id })
        let savedRepetition = try XCTUnwrap(savedExerciseB.metrics.first { $0.id != weight.id })
        XCTAssertEqual(savedRepetition.name, "回数")
        XCTAssertEqual(savedRepetition.unit, "回")
        XCTAssertFalse(savedRepetition.allowsDecimal)
        XCTAssertTrue(savedRepetition.isRequired)
        XCTAssertTrue(savedRepetition.isActive)

        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day))
        XCTAssertThrowsError(
            try WorkoutValueEditingV2.save(
                [], additions: [staleAddition], day: day, to: workout,
                exercises: [exercise], in: contextA
            ),
            "別contextが追加した有効項目を含まない古いセットdraftを拒否する"
        ) { error in
            guard case WorkoutValueEditError.metricsChanged = error else {
                return XCTFail("有効項目集合の変更はmetricsChangedで拒否する: \(error)")
            }
        }
        XCTAssertFalse(contextA.hasChanges, "拒否後にAのcontextはcleanである")

        let verificationContainer = try ModelContainer(for: schema, configurations: [configuration])
        let verificationContext = ModelContext(verificationContainer)
        let savedWorkout = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workout.id }
        )
        XCTAssertEqual(savedWorkout.day, workout.day)
        XCTAssertEqual(savedWorkout.records.map(\.id), [record.id])
        XCTAssertEqual(savedWorkout.records[0].sets.map(\.id), [oldSet.id], "古いセットだけが残る")
        XCTAssertEqual(savedWorkout.records[0].sets[0].values.map(\.id), [oldValue.id])

        let savedValues = try verificationContext.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(savedValues.map(\.id), [oldValue.id], "新セットの値を追加しない")
        XCTAssertEqual(WorkoutValueSnapshot(try XCTUnwrap(savedValues.first)), WorkoutValueSnapshot(oldValue))
        let savedLinks = try verificationContext.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(savedLinks.map(\.id), [originalLink.id], "既存値のrevision linkを保持する")
        XCTAssertEqual(savedLinks[0].valueID, oldValue.id)
        XCTAssertEqual(savedLinks[0].revisionID, originalRevision.id)

        let savedExercise = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<Exercise>()).first { $0.id == exercise.id }
        )
        let savedDefinitions = savedExercise.metrics.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(savedDefinitions.map(\.id), [weight.id, savedRepetition.id])
        XCTAssertEqual(savedDefinitions.map(\.isActive), [true, true])
        XCTAssertEqual(savedDefinitions[0].name, "重量")
        XCTAssertEqual(savedDefinitions[0].unit, "kg")
        XCTAssertEqual(savedDefinitions[0].allowsDecimal, true)
        XCTAssertEqual(savedDefinitions[0].isRequired, false)
        XCTAssertEqual(savedDefinitions[1].name, "回数")
        XCTAssertEqual(savedDefinitions[1].unit, "回")
        XCTAssertEqual(savedDefinitions[1].allowsDecimal, false)
        XCTAssertEqual(savedDefinitions[1].isRequired, true)
        let revisions = try verificationContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
            .filter { $0.metricID == weight.id }
        XCTAssertEqual(revisions.map(\.id), [originalRevision.id])
        XCTAssertEqual(try verificationContext.fetch(FetchDescriptor<Workout>()).count, 1)
    }

    func testNoHistoryDraftIsRejectedWhenAnotherContainerCreatesFirstRevision() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = makeConfiguration(schema: schema, name: "MeleteV2FirstRevisionRace")
        let containerA = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(containerA)

        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let originalValue = MetricValue(metric: metric, scaledValue: 12_500)
        let originalRecord = ExerciseRecord(
            exercise: exercise,
            sortOrder: 0,
            sets: [SetRecord(sortOrder: 1, values: [originalValue])]
        )
        let originalWorkout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [originalRecord])
        contextA.insert(exercise)
        contextA.insert(originalWorkout)
        try contextA.save()

        let staleAddition = try XCTUnwrap(
            WorkoutValueEditingV2.appendSetDraft(for: originalRecord, exercise: exercise, in: contextA)
        )
        XCTAssertEqual(staleAddition.historyBaselines?[metric.id], .noHistory)

        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let exerciseB = try XCTUnwrap(
            try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == exercise.id }
        )
        var entry = try WorkoutCreationV2.makeEntryDraft(for: exerciseB, in: contextB)
        entry.sets[0].values[metric.id] = "7.25"
        guard case let .success(entries) = WorkoutSetDraftEditing.validatedEntries([entry]) else {
            return XCTFail("Bの新規Workout入力を検証できる")
        }

        let workoutB = try WorkoutCreationV2.save(
            day: Date(timeIntervalSince1970: 1_700_000_100), entries: entries, in: contextB
        )
        let revisionB = try XCTUnwrap(
            try contextB.fetch(FetchDescriptor<MetricDefinitionRevision>()).first { $0.metricID == metric.id }
        )
        XCTAssertEqual(revisionB.revision, 1)
        XCTAssertEqual(revisionB.name, staleAddition.metrics[0].name)
        XCTAssertEqual(revisionB.unit, staleAddition.metrics[0].unit)
        XCTAssertEqual(revisionB.allowsDecimal, staleAddition.metrics[0].allowsDecimal)
        XCTAssertEqual(revisionB.isRequired, staleAddition.metrics[0].isRequired)

        let day = try XCTUnwrap(WorkoutValueEditing.date(from: originalWorkout.day))
        XCTAssertThrowsError(
            try WorkoutValueEditingV2.save(
                [], additions: [staleAddition], day: day, to: originalWorkout,
                exercises: [exercise], in: contextA
            ),
            "定義snapshotが同一でも、noHistory後に作られた初回revisionを古いdraftで拒否する"
        ) { error in
            guard case WorkoutValueEditError.metricsChanged = error else {
                return XCTFail("初回revisionとのbaseline不一致はmetricsChangedで拒否する: \(error)")
            }
        }
        XCTAssertFalse(contextA.hasChanges)

        let verificationContainer = try ModelContainer(for: schema, configurations: [configuration])
        let verificationContext = ModelContext(verificationContainer)
        let savedWorkouts = try verificationContext.fetch(FetchDescriptor<Workout>())
        let savedOriginal = try XCTUnwrap(savedWorkouts.first { $0.id == originalWorkout.id })
        let savedB = try XCTUnwrap(savedWorkouts.first { $0.id == workoutB.id })
        XCTAssertEqual(savedWorkouts.count, 2)
        XCTAssertEqual(savedOriginal.records.map(\.id), [originalRecord.id])
        XCTAssertEqual(savedOriginal.records[0].sets.map(\.id), [originalRecord.sets[0].id])
        XCTAssertEqual(savedOriginal.records[0].sets[0].values.map(\.id), [originalValue.id])

        let savedBValues = savedB.records.flatMap(\.sets).flatMap(\.values)
        XCTAssertEqual(savedBValues.count, 1)
        XCTAssertEqual(savedBValues[0].name, "重量")
        XCTAssertEqual(savedBValues[0].unit, "kg")
        XCTAssertEqual(savedBValues[0].scaledValue, 7_250)
        let links = try verificationContext.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].valueID, savedBValues[0].id)
        XCTAssertEqual(links[0].revisionID, revisionB.id)
        XCTAssertEqual(try verificationContext.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [revisionB.id])
    }

    func testDuplicatedUnsavedAdditionSetsPersistInOrderWithOneInitialRevision() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = makeConfiguration(schema: schema, name: "MeleteV2DuplicatedAddition")
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "複製種目", metrics: [metric])
        let originalValue = MetricValue(metric: metric, scaledValue: 1_000)
        let originalSet = SetRecord(sortOrder: 4, values: [originalValue])
        let record = ExerciseRecord(
            exercise: exercise,
            sortOrder: 0,
            sets: [originalSet]
        )
        let workout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [record])
        context.insert(exercise)
        context.insert(workout)
        try context.save()

        var additions = WorkoutSetAdditionDrafts()
        let firstDraft = try XCTUnwrap(
            WorkoutValueEditingV2.appendSetDraft(for: record, exercise: exercise, in: context)
        )
        additions.append(firstDraft)
        additions.setValue("0", draftID: firstDraft.id, metricID: metric.id)
        additions.duplicate(id: firstDraft.id)
        XCTAssertEqual(additions.items.count, 2)
        let copiedDraft = try XCTUnwrap(additions.items.first { $0.id != firstDraft.id })
        additions.setValue("2.5", draftID: copiedDraft.id, metricID: metric.id)
        XCTAssertEqual(additions.value(draftID: firstDraft.id, metricID: metric.id), "0")
        XCTAssertEqual(additions.value(draftID: copiedDraft.id, metricID: metric.id), "2.5")

        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day))
        try WorkoutValueEditingV2.save(
            [], additions: additions.items, day: day, to: workout, exercises: [exercise], in: context
        )

        let orderedContextSets = record.sets.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(orderedContextSets.map(\.sortOrder), [4, 5, 6])
        XCTAssertEqual(orderedContextSets.first?.id, originalSet.id)
        let addedSets = orderedContextSets.dropFirst().map { $0 }
        XCTAssertEqual(addedSets.count, 2)
        let addedValues = try addedSets.map { try XCTUnwrap($0.values.first) }
        XCTAssertEqual(addedValues.map(\.scaledValue), [0, 2_500])
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).count, 1)
        let revision = try XCTUnwrap(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).first)
        XCTAssertEqual(revision.metricID, metric.id)
        XCTAssertEqual(revision.revision, 1)

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let savedWorkout = try XCTUnwrap(
            try reopenedContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workout.id }
        )
        let savedRecord = try XCTUnwrap(savedWorkout.records.first { $0.id == record.id })
        let orderedSets = savedRecord.sets.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(orderedSets.map(\.sortOrder), [4, 5, 6])
        XCTAssertEqual(orderedSets.map(\.id), [originalSet.id, addedSets[0].id, addedSets[1].id])
        let savedAddedValues = orderedSets.dropFirst().compactMap { $0.values.first }
        XCTAssertEqual(savedAddedValues.map(\.scaledValue), [0, 2_500])
        XCTAssertEqual(savedAddedValues.map(\.name), ["重量", "重量"])
        XCTAssertEqual(savedAddedValues.map(\.unit), ["kg", "kg"])

        let savedRevisions = try reopenedContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
            .filter { $0.metricID == metric.id }
        XCTAssertEqual(savedRevisions.count, 1)
        XCTAssertEqual(savedRevisions[0].revision, 1)
        let links = try reopenedContext.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(Set(links.map(\.valueID)), Set(savedAddedValues.map(\.id)))
        XCTAssertEqual(Set(links.map(\.revisionID)), [savedRevisions[0].id])
    }
}
