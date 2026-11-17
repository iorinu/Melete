import XCTest
import SwiftData
@testable import Melete

// revision導入候補。旧MetricDefinitionにrevisionを推定付与せず、将来の履歴は独立した行で表す。
@Model private final class MetricDefinitionRevisionCandidate {
    var id: UUID
    var metricID: UUID
    var name: String
    var unit: String
    var allowsDecimal: Bool
    var isRequired: Bool
    var revision: Int

    init(id: UUID, metricID: UUID, name: String, unit: String, allowsDecimal: Bool, isRequired: Bool, revision: Int) {
        self.id = id
        self.metricID = metricID
        self.name = name
        self.unit = unit
        self.allowsDecimal = allowsDecimal
        self.isRequired = isRequired
        self.revision = revision
    }
}

private enum MeleteRevisionSpikeSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    // V1の実model型をそのまま使い、追加entityだけをテスト候補として加える。
    static var models: [any PersistentModel.Type] {
        MeleteSchemaV1.models + [MetricDefinitionRevisionCandidate.self]
    }
}

private enum MeleteRevisionSpikeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MeleteSchemaV1.self, MeleteRevisionSpikeSchemaV2.self] }
    static var stages: [MigrationStage] {
        [MigrationStage.lightweight(fromVersion: MeleteSchemaV1.self, toVersion: MeleteRevisionSpikeSchemaV2.self)]
    }
}

private enum MeleteFailingMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MeleteSchemaV1.self, MeleteRevisionSpikeSchemaV2.self] }
    static var stages: [MigrationStage] {
        [MigrationStage.custom(
            fromVersion: MeleteSchemaV1.self,
            toVersion: MeleteRevisionSpikeSchemaV2.self,
            willMigrate: { _ in throw InjectedMigrationFailure.expected },
            didMigrate: nil
        )]
    }
}

private enum InjectedMigrationFailure: Error {
    case expected
}

final class MeleteTests: XCTestCase {
    private func makeCandidateV2Context() throws -> ModelContext {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteCandidateV2ReadOnlyReview-\(UUID().uuidString).sqlite")
        let configuration = ModelConfiguration("MeleteCandidateV2ReadOnlyReview", schema: schema, url: url, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }

    func testCandidateV2AppBoundaryValidatesBeforeInsertingRevisionLink() throws {
        let context = try makeCandidateV2Context()
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let value = MetricValue(metric: metric, scaledValue: 1_000)
        let revision = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        context.insert(metric)
        context.insert(value)
        context.insert(revision)

        let absentValue = MetricValue(metric: metric, scaledValue: nil)
        XCTAssertThrowsError(try MetricValueRevisionLinking.register(value: absentValue, revision: revision, in: context))
        XCTAssertThrowsError(try MetricValueRevisionLinking.register(value: value, revision: MetricDefinitionRevision(metricID: metric.id, revision: 2, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0), in: context))

        let otherMetricRevision = MetricDefinitionRevision(metricID: UUID(), revision: 1, name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 1)
        context.insert(otherMetricRevision)
        XCTAssertThrowsError(try MetricValueRevisionLinking.register(value: value, revision: otherMetricRevision, in: context))

        context.insert(MetricValueRevisionLink(valueID: value.id, revisionID: revision.id))
        XCTAssertThrowsError(try MetricValueRevisionLinking.register(value: value, revision: revision, in: context))
        context.delete(try XCTUnwrap(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).first))

        let duplicatePair = MetricDefinitionRevision(metricID: metric.id, revision: revision.revision, name: "重量の重複", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        context.insert(duplicatePair)
        XCTAssertThrowsError(try MetricValueRevisionLinking.register(value: value, revision: duplicatePair, in: context))
        context.delete(duplicatePair)

        let link = try MetricValueRevisionLinking.register(value: value, revision: revision, in: context)
        XCTAssertEqual(link.valueID, value.id)
        XCTAssertEqual(link.revisionID, revision.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).count, 1)
    }

    @MainActor func testCandidateV2LinkDoesNotBecomeOrphanWhenMetricValueIsDeleted() throws {
        let context = try makeCandidateV2Context()
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let value = MetricValue(metric: metric, scaledValue: 1_000)
        let revision = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "削除対象", metrics: [metric])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [value])])
        let workout = Workout(day: .now, records: [record])
        context.insert(exercise)
        context.insert(workout)
        context.insert(revision)
        _ = try MetricValueRevisionLinking.register(value: value, revision: revision, in: context)
        try context.save()

        let target = try WorkoutDeletionV2.captureWorkoutDeletionTarget(workout: workout, in: context)
        try WorkoutDeletionV2.delete(target, in: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty, "値の削除で対応するrevision linkも削除されるべき")
    }

    func testCandidateV2RejectsDuplicateValueLinksAndMetricRevisionPairs() throws {
        let context = try makeCandidateV2Context()
        let metricID = UUID()
        let revision = MetricDefinitionRevision(metricID: metricID, revision: 1, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let duplicateRevisionPair = [
            revision,
            MetricDefinitionRevision(metricID: metricID, revision: 1, name: "重量(複製)", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        ]
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let value = MetricValue(metric: metric, scaledValue: 1)
        let exercise = Exercise(name: "重複検査", metrics: [metric])
        context.insert(exercise)
        context.insert(value)
        context.insert(revision)
        duplicateRevisionPair.dropFirst().forEach(context.insert)
        XCTAssertThrowsError(try MetricValueRevisionLinking.register(value: value, revision: revision, in: context), "重複改定番号をアプリ境界で拒否")
    }

    func testCandidateV2RejectsLinkToRevisionOfDifferentMetric() throws {
        let context = try makeCandidateV2Context()
        let firstMetric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let value = MetricValue(metric: firstMetric, scaledValue: 1_000)
        let otherRevision = MetricDefinitionRevision(metricID: UUID(), revision: 1, name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 0)
        context.insert(firstMetric)
        context.insert(value)
        context.insert(otherRevision)
        XCTAssertThrowsError(try MetricValueRevisionLinking.register(value: value, revision: otherRevision, in: context), "値とrevisionのmetricIDが一致しないリンクをアプリ境界で拒否")
    }

    @MainActor func testCandidateV2BothWorkoutValueCreationPathsCreateRevisionLinks() throws {
        let context = try makeCandidateV2Context()
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let revision = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        context.insert(exercise)
        context.insert(revision)

        var initialEntry = WorkoutEntryDraft(exercise: exercise)
        initialEntry.sets[0].values[metric.id] = "1"
        guard case .success(let validated) = WorkoutSetDraftEditing.validatedEntries([initialEntry]) else {
            return XCTFail("新規Workoutの入力を検証できる")
        }
        let workout = Workout(day: .now, records: MainView.workoutRecords(from: validated))
        context.insert(workout)
        try context.save()
        let initialValues = workout.records.flatMap(\.sets).flatMap(\.values)
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day))
        let addition = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: workout.records[0], exercise: exercise))
        var filledAddition = addition
        filledAddition.values[metric.id] = "2"
        try WorkoutValueEditingV2.save([], additions: [filledAddition], day: day, to: workout, exercises: [exercise], in: context)

        let values = workout.records.flatMap(\.sets).flatMap(\.values)
        XCTAssertEqual(values.count, 2)
        let links = try context.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(links.map(\.valueID), [values.last!.id], "既存Workoutへの追加値だけにrevision linkが必要")
        XCTAssertFalse(links.contains { initialValues.map(\.id).contains($0.valueID) }, "既存のlegacy値にrevisionを後付けしない")
        XCTAssertEqual(initialValues.count, 1)
    }

    @MainActor func testV2ExistingWorkoutAdditionPersistsOnlyNewValuesAndMatchingRevisions() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteV2ExistingWorkout-\(UUID().uuidString).sqlite")
        let configuration = ModelConfiguration("MeleteV2ExistingWorkout", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let metricA = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let metricB = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 1)
        let metricC = MetricDefinition(name: "距離", unit: "m", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exerciseA = Exercise(name: "合成種目A", metrics: [metricA, metricB])
        let exerciseB = Exercise(name: "合成種目B", metrics: [metricC])
        let legacyA = MetricValue(metric: metricA, scaledValue: 0)
        let legacyNil = MetricValue(metric: metricB, scaledValue: nil)
        let legacyB = MetricValue(metric: metricC, scaledValue: 12_500)
        let recordA = ExerciseRecord(exercise: exerciseA, sortOrder: 4, sets: [SetRecord(sortOrder: 2, values: [legacyA, legacyNil])])
        let recordB = ExerciseRecord(exercise: exerciseB, sortOrder: 8, sets: [SetRecord(sortOrder: 5, values: [legacyB])])
        let workout = Workout(day: .now, records: [recordA, recordB])
        let otherValue = MetricValue(metric: metricA, scaledValue: 77_000)
        let otherWorkout = Workout(day: .now, records: [ExerciseRecord(exercise: exerciseA, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [otherValue])])])
        let oldRevision = MetricDefinitionRevision(metricID: metricA.id, revision: 3, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 6)
        context.insert(exerciseA); context.insert(exerciseB); context.insert(workout); context.insert(otherWorkout); context.insert(oldRevision)
        try context.save()

        var additions = WorkoutSetAdditionDrafts()
        let additionA1 = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: recordA, exercise: exerciseA))
        let additionA2 = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: recordA, exercise: exerciseA))
        let additionB = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: recordB, exercise: exerciseB))
        additions.append(additionA1); additions.append(additionA2); additions.append(additionB)
        additions.setValue("2.5", draftID: additionA1.id, metricID: metricA.id)
        additions.setValue("", draftID: additionA1.id, metricID: metricB.id)
        additions.setValue("3", draftID: additionA2.id, metricID: metricA.id)
        additions.setValue("4", draftID: additionA2.id, metricID: metricB.id)
        additions.setValue("0", draftID: additionB.id, metricID: metricC.id)
        let originalLegacy = [legacyA, legacyNil, legacyB].map(WorkoutValueSnapshot.init)
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day))
        try WorkoutValueEditingV2.save([], additions: additions.items, day: day, to: workout, exercises: [exerciseA, exerciseB], in: context)

        XCTAssertEqual(recordA.sets.map(\.sortOrder).sorted(), [2, 3, 4])
        XCTAssertEqual(recordB.sets.count, 2)
        XCTAssertEqual(recordB.sets.map(\.sortOrder).sorted(), [5, 6])
        XCTAssertEqual([legacyA, legacyNil, legacyB].map(WorkoutValueSnapshot.init), originalLegacy)
        let revisions = try context.fetch(FetchDescriptor<MetricDefinitionRevision>())
        XCTAssertEqual(revisions.count, 3)
        let revisionA = try XCTUnwrap(revisions.first { $0.metricID == metricA.id })
        XCTAssertEqual(revisionA.revision, 3)
        XCTAssertEqual(revisionA.name, oldRevision.name)
        let revisionB = try XCTUnwrap(revisions.first { $0.metricID == metricB.id })
        XCTAssertEqual(revisionB.revision, 1)
        let revisionC = try XCTUnwrap(revisions.first { $0.metricID == metricC.id })
        XCTAssertEqual(revisionC.revision, 1)
        let additionsByMetric = workout.records.flatMap(\.sets).flatMap(\.values).filter { ![legacyA.id, legacyNil.id, legacyB.id].contains($0.id) }
        let links = try context.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(links.count, additionsByMetric.count)
        for value in additionsByMetric {
            let link = try XCTUnwrap(links.first { $0.valueID == value.id })
            XCTAssertEqual(link.revisionID, [revisionA, revisionB, revisionC].first { $0.metricID == value.metricID }?.id)
        }
        XCTAssertFalse(links.contains { [legacyA.id, legacyNil.id, legacyB.id].contains($0.valueID) })
        XCTAssertEqual(additionsByMetric.first { $0.metricID == metricB.id && $0.scaledValue == nil }?.scaledValue, nil)
        XCTAssertTrue(additionsByMetric.contains { $0.metricID == metricC.id && $0.scaledValue == 0 })
        XCTAssertEqual(otherWorkout.records.first?.sets.first?.values.first?.scaledValue, 77_000)

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let savedWorkout = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workout.id })
        XCTAssertEqual(savedWorkout.records.first { $0.id == recordA.id }?.sets.map(\.sortOrder).sorted(), [2, 3, 4])
        XCTAssertEqual(savedWorkout.records.first { $0.id == recordB.id }?.sets.map(\.sortOrder).sorted(), [5, 6])
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).count, 5)
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<Workout>()).first { $0.id == otherWorkout.id }?.records.first?.sets.first?.values.first?.scaledValue, 77_000)
    }

    @MainActor func testV2SavesRejectMismatchedCurrentRevisionBeforeChangingContext() throws {
        for mismatch in ["metric-name", "metric-unit", "metric-decimal", "metric-required", "revision-name", "revision-unit", "revision-decimal", "revision-required"] {
            let context = try makeCandidateV2Context()
            let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
            switch mismatch {
            case "metric-name": metric.name = "metric不一致"
            case "metric-unit": metric.unit = "lb"
            case "metric-decimal": metric.allowsDecimal = false
            case "metric-required": metric.isRequired = true
            default: break
            }
            let exercise = Exercise(name: "合成種目", metrics: [metric])
            let revision = MetricDefinitionRevision(metricID: metric.id, revision: 2, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 8)
            switch mismatch {
            case "revision-name": revision.name = "revision不一致"
            case "revision-unit": revision.unit = "lb"
            case "revision-decimal": revision.allowsDecimal = false
            case "revision-required": revision.isRequired = true
            default: break
            }
            context.insert(exercise); context.insert(revision); try context.save()
            XCTAssertFalse(context.hasChanges)

            var entry = WorkoutEntryDraft(exercise: exercise)
            entry.sets[0].values[metric.id] = "1"
            guard case let .success(entries) = WorkoutSetDraftEditing.validatedEntries([entry]) else { return XCTFail("入力を検証できる") }
            XCTAssertThrowsError(try WorkoutCreationV2.save(day: .now, entries: entries, in: context), "新規Workout: \(mismatch)") { error in
                guard case MetricValueRevisionLinkingError.snapshotMismatch = error else { return XCTFail("snapshot不一致の明示エラーが必要: \(error)") }
            }
            XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>()).isEmpty)
            XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValue>()).isEmpty)
            XCTAssertEqual(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [revision.id])
            XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)
            XCTAssertFalse(context.hasChanges, "拒否時に新規保存データを残さない")

            let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 4, values: [MetricValue(metric: metric, scaledValue: 1)])])
            let workout = Workout(day: .now, records: [record])
            context.insert(workout); try context.save()
            let addition = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
            XCTAssertThrowsError(try WorkoutValueEditingV2.save([], additions: [addition], day: try XCTUnwrap(WorkoutValueEditing.date(from: workout.day)), to: workout, exercises: [exercise], in: context), "既存Workout追加: \(mismatch)") { error in
                guard case MetricValueRevisionLinkingError.snapshotMismatch = error else { return XCTFail("snapshot不一致の明示エラーが必要: \(error)") }
            }
            XCTAssertEqual(record.sets.map(\.sortOrder), [4])
            XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)
            XCTAssertEqual(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [revision.id])
            XCTAssertFalse(context.hasChanges, "拒否時に追加値・revision/linkを残さない")
        }
    }

    func testV2RevisionLinkingRequiresMatchingValueAndRevisionSnapshots() throws {
        for mismatch in ["name", "unit", "decimal", "required"] {
            let context = try makeCandidateV2Context()
            let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
            let value = MetricValue(metric: metric, scaledValue: 1)
            let revision = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 9)
            switch mismatch {
            case "name": value.name = "別名"
            case "unit": value.unit = "lb"
            case "decimal": value.allowsDecimal = false
            default: value.isRequired = true
            }
            context.insert(metric); context.insert(value); context.insert(revision)
            XCTAssertThrowsError(try MetricValueRevisionLinking.register(value: value, revision: revision, in: context), "値snapshot不一致: \(mismatch)") { error in
                guard case MetricValueRevisionLinkingError.snapshotMismatch = error else { return XCTFail("snapshot不一致の明示エラーが必要: \(error)") }
            }
            XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)
        }
    }

    @MainActor func testV2ExistingWorkoutAdditionRejectsChangedMissingArchivedDefinitionsAndDirtyContext() throws {
        for rejection in ["changed", "missing", "archived"] {
            let context = try makeCandidateV2Context()
            let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
            let exercise = Exercise(name: "合成種目", metrics: [metric])
            let value = MetricValue(metric: metric, scaledValue: 10)
            let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 2, values: [value])])
            let workout = Workout(day: .now, records: [record])
            context.insert(exercise); context.insert(workout); try context.save()
            let draft = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
            var changedDraft = draft
            changedDraft.values[metric.id] = "20"
            switch rejection {
            case "changed": metric.name = "変更後"
            case "missing": exercise.metrics.removeAll { $0.id == metric.id }
            default: exercise.isArchived = true
            }
            XCTAssertThrowsError(try WorkoutValueEditingV2.save([], additions: [changedDraft], day: try XCTUnwrap(WorkoutValueEditing.date(from: workout.day)), to: workout, exercises: [exercise], in: context))
            XCTAssertEqual(record.sets.map(\.sortOrder), [2])
            XCTAssertEqual(value.scaledValue, 10)
            XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)
            XCTAssertTrue(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).isEmpty)
        }

        let context = try makeCandidateV2Context()
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "dirty", metrics: [metric])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: 1)])])
        let workout = Workout(day: .now, records: [record])
        context.insert(exercise); context.insert(workout); try context.save()
        let draft = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
        metric.name = "未保存変更"
        XCTAssertThrowsError(try WorkoutValueEditingV2.save([], additions: [draft], day: try XCTUnwrap(WorkoutValueEditing.date(from: workout.day)), to: workout, exercises: [exercise], in: context))
        XCTAssertTrue(context.hasChanges, "拒否時に呼び出し元のdirty contextをsave/rollbackしない")
        XCTAssertEqual(record.sets.count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).isEmpty)
    }

    @MainActor func testV2ExistingWorkoutAdditionInjectedPersistFailureRemovesOnlyNewGraph() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteV2ExistingWorkoutFailure-\(UUID().uuidString).sqlite")
        let configuration = ModelConfiguration("MeleteV2ExistingWorkoutFailure", schema: schema, url: url, cloudKitDatabase: .none)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let legacy = MetricValue(metric: metric, scaledValue: 9_000)
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 4, values: [legacy])])
        let workout = Workout(day: .now, records: [record])
        let other = Workout(day: .now, records: [ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: 8_000)])])])
        let revision = MetricDefinitionRevision(metricID: metric.id, revision: 2, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        context.insert(exercise); context.insert(workout); context.insert(other); context.insert(revision); try context.save()
        XCTAssertFalse(context.hasChanges, "注入失敗を試す前はcontextがclean")
        let draft = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
        var filled = draft
        filled.values[metric.id] = "10"
        let oldDay = workout.day
        let oldLegacyValue = legacy.scaledValue
        XCTAssertThrowsError(try WorkoutValueEditingV2.save([], additions: [filled], day: try XCTUnwrap(WorkoutValueEditing.date(from: workout.day)), to: workout, exercises: [exercise], in: context) { _ in throw InjectedMigrationFailure.expected })
        XCTAssertEqual(workout.day, oldDay)
        XCTAssertEqual(record.sets.map(\.sortOrder), [4])
        XCTAssertEqual(legacy.scaledValue, oldLegacyValue)
        XCTAssertEqual(other.records.first?.sets.first?.values.first?.scaledValue, 8_000)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [revision.id])
        XCTAssertFalse(context.hasChanges, "注入例外後は追加graphの変更が残らない")

        // 後続の無関係なsaveが失敗時のrevision/link/追加値を誤って永続化しないことを確認。
        let unrelatedMetric = MetricDefinition(name: "無関係", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 1)
        context.insert(Exercise(name: "無関係", metrics: [unrelatedMetric]))
        try context.save()
        let afterUnrelatedSave = try ModelContainer(for: schema, configurations: [configuration])
        let afterUnrelatedSaveContext = ModelContext(afterUnrelatedSave)
        XCTAssertEqual(try afterUnrelatedSaveContext.fetch(FetchDescriptor<MetricValue>()).count, 2)
        XCTAssertTrue(try afterUnrelatedSaveContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)
        XCTAssertEqual(try afterUnrelatedSaveContext.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [revision.id])
        XCTAssertEqual(try afterUnrelatedSaveContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workout.id }?.records.first?.sets.map(\.sortOrder), [4])

        // 失敗後も同じ値で再試行できる。
        try WorkoutValueEditingV2.save([], additions: [filled], day: try XCTUnwrap(WorkoutValueEditing.date(from: workout.day)), to: workout, exercises: [exercise], in: context)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(record.sets.map(\.sortOrder).sorted(), [4, 5])
        let afterRetry = try ModelContainer(for: schema, configurations: [configuration])
        let afterRetryContext = ModelContext(afterRetry)
        XCTAssertEqual(try afterRetryContext.fetch(FetchDescriptor<MetricValue>()).count, 3)
        XCTAssertEqual(try afterRetryContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).count, 1)
        XCTAssertEqual(try afterRetryContext.fetch(FetchDescriptor<MetricDefinitionRevision>()).count, 1)
    }

    @MainActor func testV2DeleteSetRemovesOnlyItsLinkAndPreservesOtherWorkoutsAndRevision() throws {
        let context = try makeCandidateV2Context()
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let revision = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        func makeWorkout(_ sets: [SetRecord]) -> Workout {
            Workout(day: .now, records: [ExerciseRecord(exercise: exercise, sortOrder: 0, sets: sets)])
        }
        let targetValue = MetricValue(metric: metric, scaledValue: 10)
        let retainedValue = MetricValue(metric: metric, scaledValue: 20)
        let otherWorkoutValue = MetricValue(metric: metric, scaledValue: 30)
        let setA = SetRecord(sortOrder: 1, values: [targetValue])
        let setB = SetRecord(sortOrder: 2, values: [retainedValue])
        let workoutA = makeWorkout([setA, setB])
        let workoutB = makeWorkout([SetRecord(sortOrder: 1, values: [otherWorkoutValue])])
        context.insert(exercise); context.insert(workoutA); context.insert(workoutB); context.insert(revision)
        for value in [targetValue, retainedValue, otherWorkoutValue] { _ = try MetricValueRevisionLinking.register(value: value, revision: revision, in: context) }
        try context.save()

        let deletionTarget = try WorkoutDeletionV2.captureSetDeletionTarget(workout: workoutA, record: workoutA.records[0], set: setA, in: context)
        try WorkoutDeletionV2.deleteSet(deletionTarget, in: context)
        XCTAssertEqual(workoutA.records.first?.sets.map(\.id), [setB.id])
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.valueID)), [retainedValue.id, otherWorkoutValue.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [revision.id])
    }

    @MainActor func testV2DeleteRecordLastChildCascadesAndFailedSaveRestoresGraphAndLinks() throws {
        let context = try makeCandidateV2Context()
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let revision = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let value = MetricValue(metric: metric, scaledValue: 10)
        let set = SetRecord(sortOrder: 1, values: [value])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [set])
        let workout = Workout(day: .now, records: [record])
        context.insert(exercise); context.insert(workout); context.insert(revision)
        _ = try MetricValueRevisionLinking.register(value: value, revision: revision, in: context)
        try context.save()
        let target = try WorkoutDeletionV2.captureRecordDeletionTarget(workout: workout, record: record, in: context)
        XCTAssertThrowsError(try WorkoutDeletionV2.deleteRecord(target, in: context) { _ in throw InjectedMigrationFailure.expected })
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).map(\.id), [workout.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExerciseRecord>()).map(\.id), [record.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<SetRecord>()).map(\.id), [set.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricValue>()).map(\.id), [value.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.valueID), [value.id])

        try WorkoutDeletionV2.deleteRecord(target, in: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ExerciseRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SetRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValue>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [revision.id])
    }

    @MainActor func testV2DeletionRejectsDirtyContextWithoutDeleting() throws {
        let context = try makeCandidateV2Context()
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let value = MetricValue(metric: metric, scaledValue: 10)
        let set = SetRecord(sortOrder: 1, values: [value])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [set])
        let workout = Workout(day: .now, records: [record])
        context.insert(exercise); context.insert(workout); try context.save()
        let target = try WorkoutDeletionV2.captureSetDeletionTarget(workout: workout, record: record, set: set, in: context)
        metric.name = "未保存変更"
        XCTAssertThrowsError(try WorkoutDeletionV2.deleteSet(target, in: context))
        XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>()).contains { $0.id == workout.id })
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValue>()).contains { $0.id == value.id })
    }

    @MainActor func testV2NewWorkoutSaveCreatesAndReopensRevisionLinksAtomically() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteV2NewWorkout-\(UUID().uuidString).sqlite")
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteV2NewWorkout", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let metricA = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let metricB = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 1)
        let metricC = MetricDefinition(name: "距離", unit: "m", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exerciseA = Exercise(name: "合成種目A", metrics: [metricA, metricB])
        let exerciseB = Exercise(name: "合成種目B", metrics: [metricC])
        context.insert(exerciseA)
        context.insert(exerciseB)
        let existingRevision = MetricDefinitionRevision(metricID: metricA.id, revision: 4, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 3)
        context.insert(existingRevision)
        try context.save()

        var entryA = WorkoutEntryDraft(exercise: exerciseA)
        entryA.sets[0].values[metricA.id] = "0"
        entryA.sets[0].values[metricB.id] = ""
        var secondSet = WorkoutSetDraft()
        secondSet.values[metricA.id] = "2.5"
        entryA.sets.append(secondSet)
        var entryB = WorkoutEntryDraft(exercise: exerciseB)
        entryB.sets[0].values[metricC.id] = "3"
        guard case let .success(entries) = WorkoutSetDraftEditing.validatedEntries([entryA, entryB]) else {
            return XCTFail("合成入力の検証に成功する")
        }
        let workout = try WorkoutCreationV2.save(day: .now, entries: entries, in: context)
        let savedIDs = workout.records.flatMap(\.sets).flatMap(\.values).map(\.id)
        let savedLinks = try context.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(Set(savedLinks.map(\.valueID)), Set(savedIDs))
        let revisions = try context.fetch(FetchDescriptor<MetricDefinitionRevision>())
        XCTAssertEqual(revisions.first { $0.metricID == metricA.id }?.revision, 4)
        XCTAssertEqual(revisions.first { $0.metricID == metricA.id }?.name, "重量")
        XCTAssertEqual(revisions.first { $0.metricID == metricB.id }?.revision, 1)
        XCTAssertEqual(revisions.first { $0.metricID == metricC.id }?.revision, 1)
        XCTAssertEqual(workout.records.count, 2)
        XCTAssertEqual(workout.records.flatMap(\.sets).count, 3)
        let zero = try XCTUnwrap(workout.records.flatMap(\.sets).flatMap(\.values).first { $0.metricID == metricA.id && $0.scaledValue == 0 })
        XCTAssertTrue(savedLinks.contains { $0.valueID == zero.id && $0.revisionID == existingRevision.id })
        XCTAssertEqual(zero.name, existingRevision.name)
        XCTAssertEqual(zero.unit, existingRevision.unit)
        XCTAssertTrue(zero.allowsDecimal)
        XCTAssertFalse(zero.isRequired)
        XCTAssertTrue(workout.records.flatMap(\.sets).flatMap(\.values).contains { $0.metricID == metricB.id && $0.scaledValue == nil })

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let reopenedWorkout = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workout.id })
        XCTAssertEqual(reopenedWorkout.records.count, 2)
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).count, 5)
    }

    @MainActor func testV2NewWorkoutSaveFailureRemovesOnlyItsInsertsAndDirtyContextIsRejected() throws {
        let context = try makeCandidateV2Context()
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        context.insert(exercise)
        try context.save()
        var entry = WorkoutEntryDraft(exercise: exercise)
        entry.sets[0].values[metric.id] = "1"
        guard case let .success(entries) = WorkoutSetDraftEditing.validatedEntries([entry]) else { return XCTFail("入力を検証できる") }
        XCTAssertThrowsError(try WorkoutCreationV2.save(day: .now, entries: entries, in: context) { _ in throw InjectedMigrationFailure.expected })
        XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValue>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)

        let unrelated = MetricDefinition(name: "未保存", unit: "x", allowsDecimal: false, isRequired: false, sortOrder: 1)
        exercise.metrics.append(unrelated)
        XCTAssertThrowsError(try WorkoutCreationV2.save(day: .now, entries: entries, in: context))
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>()).isEmpty)
    }

    @MainActor func testV2NewWorkoutSaveRejectsFutureDayWithoutChangingContext() throws {
        let context = try makeCandidateV2Context()
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目・日付", metrics: [metric])
        context.insert(exercise)
        try context.save()

        var entry = WorkoutEntryDraft(exercise: exercise)
        entry.sets[0].values[metric.id] = "1"
        let entries = [entry]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = Date.now
        let today = calendar.startOfDay(for: fixedNow)
        let laterToday = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 59, second: 0, of: today))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))

        XCTAssertThrowsError(try WorkoutCreationV2.save(day: tomorrow, entries: entries, in: context, calendar: calendar))
        XCTAssertFalse(context.hasChanges)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)

        XCTAssertNoThrow(try WorkoutCreationV2.save(day: laterToday, entries: entries, in: context, calendar: calendar))
        try context.save()
        XCTAssertNoThrow(try WorkoutCreationV2.save(day: yesterday, entries: entries, in: context, calendar: calendar))
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 2)
    }

    @MainActor func testV2NewWorkoutSaveRejectsEmptyAndDuplicateExerciseEntries() throws {
        let context = try makeCandidateV2Context()
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目・重複", metrics: [metric])
        context.insert(exercise)
        try context.save()

        var entry = WorkoutEntryDraft(exercise: exercise)
        entry.sets[0].values[metric.id] = "1"
        let day = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertThrowsError(try WorkoutCreationV2.save(day: day, entries: [], in: context)) { error in
            guard case WorkoutCreationV2Error.invalidEntries = error else {
                return XCTFail("空入力はinvalidEntriesで拒否される: \(error)")
            }
        }
        XCTAssertFalse(context.hasChanges)
        XCTAssertThrowsError(try WorkoutCreationV2.save(day: day, entries: [entry, entry], in: context)) { error in
            guard case WorkoutCreationV2Error.invalidEntries = error else {
                return XCTFail("重複種目入力はinvalidEntriesで拒否される: \(error)")
            }
        }
        XCTAssertFalse(context.hasChanges)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)
    }

    @MainActor func testV2NewWorkoutSavePersistFailurePreservesExistingGraphAndAllowsRetry() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2NewWorkoutPersistFailure-\(UUID().uuidString).sqlite")
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteV2NewWorkoutPersistFailure", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目・失敗復元", metrics: [metric])
        let existingValue = MetricValue(metric: metric, scaledValue: 2_000)
        let existingSet = SetRecord(sortOrder: 1, values: [existingValue])
        let existingRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [existingSet])
        let existingWorkout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [existingRecord])
        let existingRevision = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: metric.sortOrder)
        context.insert(exercise); context.insert(existingValue); context.insert(existingRevision)
        let existingLink = try MetricValueRevisionLinking.register(value: existingValue, revision: existingRevision, in: context)
        context.insert(existingWorkout)
        try context.save()

        var entry = WorkoutEntryDraft(exercise: exercise)
        entry.sets[0].values[metric.id] = "3"
        guard case let .success(entries) = WorkoutSetDraftEditing.validatedEntries([entry]) else {
            return XCTFail("合成入力の検証に成功する")
        }
        let newDay = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertThrowsError(try WorkoutCreationV2.save(day: newDay, entries: entries, in: context) { _ in
            throw InjectedMigrationFailure.expected
        })
        XCTAssertFalse(context.hasChanges)

        let workoutsAfterFailure = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(workoutsAfterFailure.map(\.id), [existingWorkout.id])
        let preservedWorkout = try XCTUnwrap(workoutsAfterFailure.first)
        XCTAssertEqual(preservedWorkout.records.map(\.id), [existingRecord.id])
        XCTAssertEqual(preservedWorkout.records[0].sets.map(\.id), [existingSet.id])
        XCTAssertEqual(preservedWorkout.records[0].sets[0].values.map(\.id), [existingValue.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [existingRevision.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.id), [existingLink.id])

        // 通常saveを挟んでも失敗した追加グラフは残らず、同じ入力で保存を再試行できる。
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).map(\.id), [existingWorkout.id])
        let retriedWorkout = try WorkoutCreationV2.save(day: newDay, entries: entries, in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 2)
        XCTAssertEqual(retriedWorkout.records.count, 1)
        XCTAssertEqual(retriedWorkout.records[0].sets.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [existingRevision.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).count, 2)
    }

    func testFailedMigrationLeavesSyntheticV1StoreReadable() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteFailedMigration-\(UUID().uuidString).sqlite")
        let v1Schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let v1Configuration = ModelConfiguration("MeleteFailedMigrationV1", schema: v1Schema, url: storeURL, cloudKitDatabase: .none)

        let exerciseID = UUID()
        let metricIDs = [UUID(), UUID()]
        let workoutID = UUID()
        let recordID = UUID()
        let setIDs = [UUID(), UUID()]
        let valueIDs = [UUID(), UUID(), UUID()]
        let exerciseDate = Date(timeIntervalSince1970: 1_700_000_010.125)
        let workoutDate = Date(timeIntervalSince1970: 1_700_000_020.25)
        let setDate = Date(timeIntervalSince1970: 1_700_000_030.5)
        let workoutDay = "2023-11-14"

        // 実V1 schemaへ合成データを保存し、移行失敗後もfixtureを残す。
        do {
            let container = try ModelContainer(for: v1Schema, configurations: [v1Configuration])
            let context = ModelContext(container)
            let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 2)
            metric.id = metricIDs[0]
            let optionalMetric = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 0)
            optionalMetric.id = metricIDs[1]
            let exercise = Exercise(name: "合成種目", metrics: [metric, optionalMetric])
            exercise.id = exerciseID
            exercise.createdAt = exerciseDate
            exercise.isArchived = true

            let snapshot = MetricValue(metric: metric, scaledValue: 82_500)
            snapshot.id = valueIDs[0]
            snapshot.name = "記録時の重量"
            snapshot.unit = "kg"
            snapshot.allowsDecimal = true
            snapshot.isRequired = false
            let nilValue = MetricValue(metric: optionalMetric, scaledValue: nil)
            nilValue.id = valueIDs[1]
            let firstSet = SetRecord(sortOrder: 3, values: [snapshot, nilValue])
            firstSet.id = setIDs[0]
            firstSet.createdAt = setDate
            let zeroValue = MetricValue(metric: metric, scaledValue: 0)
            zeroValue.id = valueIDs[2]
            let zeroSet = SetRecord(sortOrder: 7, values: [zeroValue])
            zeroSet.id = setIDs[1]
            let record = ExerciseRecord(exercise: exercise, sortOrder: 4, sets: [firstSet, zeroSet])
            record.id = recordID
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let workout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [record], calendar: utc)
            workout.id = workoutID
            workout.createdAt = workoutDate
            context.insert(exercise)
            context.insert(workout)
            try context.save()
        }

        let v2Schema = Schema(versionedSchema: MeleteRevisionSpikeSchemaV2.self)
        let v2Configuration = ModelConfiguration("MeleteFailedMigrationV2", schema: v2Schema, url: storeURL, cloudKitDatabase: .none)
        XCTAssertThrowsError(try ModelContainer(
            for: v2Schema,
            migrationPlan: MeleteFailingMigrationPlan.self,
            configurations: [v2Configuration]
        ))

        // 失敗後はV2で再試行せず、同じURLを実V1 schemaでのみ再openする。
        let reopened = try ModelContainer(for: v1Schema, configurations: [v1Configuration])
        let context = ModelContext(reopened)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(exercises.count, 1)
        let savedExercise = try XCTUnwrap(exercises.first)
        XCTAssertEqual(savedExercise.id, exerciseID)
        XCTAssertEqual(savedExercise.name, "合成種目")
        XCTAssertTrue(savedExercise.isArchived)
        XCTAssertEqual(savedExercise.createdAt, exerciseDate)
        let definitions = Dictionary(uniqueKeysWithValues: savedExercise.metrics.map { ($0.id, $0) })
        XCTAssertEqual(Set(definitions.keys), Set(metricIDs))
        XCTAssertEqual(definitions[metricIDs[0]]?.name, "重量")
        XCTAssertEqual(definitions[metricIDs[0]]?.unit, "kg")
        XCTAssertEqual(definitions[metricIDs[0]]?.allowsDecimal, true)
        XCTAssertEqual(definitions[metricIDs[0]]?.isRequired, true)
        XCTAssertEqual(definitions[metricIDs[0]]?.sortOrder, 2)
        XCTAssertEqual(definitions[metricIDs[1]]?.name, "回数")
        XCTAssertEqual(definitions[metricIDs[1]]?.unit, "回")
        XCTAssertEqual(definitions[metricIDs[1]]?.allowsDecimal, false)
        XCTAssertEqual(definitions[metricIDs[1]]?.isRequired, false)
        XCTAssertEqual(definitions[metricIDs[1]]?.sortOrder, 0)

        let workouts = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(workouts.count, 1)
        let savedWorkout = try XCTUnwrap(workouts.first)
        XCTAssertEqual(savedWorkout.id, workoutID)
        XCTAssertEqual(savedWorkout.day, workoutDay)
        XCTAssertEqual(savedWorkout.createdAt, workoutDate)
        XCTAssertEqual(savedWorkout.records.count, 1)
        let savedRecord = try XCTUnwrap(savedWorkout.records.first)
        XCTAssertEqual(savedRecord.id, recordID)
        XCTAssertEqual(savedRecord.exerciseID, exerciseID)
        XCTAssertEqual(savedRecord.exerciseName, "合成種目")
        XCTAssertEqual(savedRecord.sortOrder, 4)
        XCTAssertEqual(savedRecord.workout?.id, workoutID)
        XCTAssertEqual(savedRecord.sets.count, 2)
        let sets = Dictionary(uniqueKeysWithValues: savedRecord.sets.map { ($0.id, $0) })
        XCTAssertEqual(Set(sets.keys), Set(setIDs))
        let savedSet = try XCTUnwrap(sets[setIDs[0]])
        XCTAssertEqual(savedSet.sortOrder, 3)
        XCTAssertEqual(savedSet.createdAt, setDate)
        XCTAssertEqual(savedSet.exerciseRecord?.id, recordID)
        XCTAssertEqual(Set(savedSet.values.map(\.id)), Set(valueIDs.prefix(2)))
        let values = Dictionary(uniqueKeysWithValues: savedSet.values.map { ($0.id, $0) })
        let savedValue = try XCTUnwrap(values[valueIDs[0]])
        XCTAssertEqual(savedValue.metricID, metricIDs[0])
        XCTAssertEqual(savedValue.name, "記録時の重量")
        XCTAssertEqual(savedValue.unit, "kg")
        XCTAssertTrue(savedValue.allowsDecimal)
        XCTAssertFalse(savedValue.isRequired)
        XCTAssertEqual(savedValue.scaledValue, 82_500)
        XCTAssertEqual(savedValue.setRecord?.id, setIDs[0])
        let savedNilValue = try XCTUnwrap(values[valueIDs[1]])
        XCTAssertEqual(savedNilValue.metricID, metricIDs[1])
        XCTAssertNil(savedNilValue.scaledValue)
        XCTAssertEqual(savedNilValue.name, "回数")
        let savedZeroSet = try XCTUnwrap(sets[setIDs[1]])
        XCTAssertEqual(savedZeroSet.sortOrder, 7)
        XCTAssertEqual(savedZeroSet.values.count, 1)
        XCTAssertEqual(savedZeroSet.values.first?.id, valueIDs[2])
        XCTAssertEqual(savedZeroSet.values.first?.metricID, metricIDs[0])
        XCTAssertEqual(savedZeroSet.values.first?.scaledValue, 0)
        XCTAssertEqual(workoutDay, "2023-11-14")
    }

    func testRevisionSpikeMigratesActualV1StoreAndPreservesLegacyAsUnrevised() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteRevisionSpike-\(UUID().uuidString).sqlite")
        let v1Schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let v1Configuration = ModelConfiguration("MeleteRevisionSpikeV1", schema: v1Schema, url: storeURL, cloudKitDatabase: .none)

        let exerciseID = UUID()
        let metricIDs = [UUID(), UUID()]
        let workoutIDs = [UUID(), UUID()]
        let recordIDs = [UUID(), UUID()]
        let setIDs = [UUID(), UUID()]
        let valueIDs = [UUID(), UUID(), UUID()]
        let exerciseCreatedAt = Date(timeIntervalSince1970: 1_700_000_010.125)
        let workoutCreatedAt = Date(timeIntervalSince1970: 1_700_000_020.25)
        let setCreatedAt = Date(timeIntervalSince1970: 1_700_000_030.5)

        // この出発点は本番Models.swiftのMeleteSchemaV1.selfそのもの。
        do {
            let v1Container = try ModelContainer(for: v1Schema, configurations: [v1Configuration])
            let context = ModelContext(v1Container)
            let metricA = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 3)
            metricA.id = metricIDs[0]
            let metricB = MetricDefinition(name: "旧回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 1)
            metricB.id = metricIDs[1]
            let exercise = Exercise(name: "合成種目", metrics: [metricA, metricB])
            exercise.id = exerciseID
            exercise.createdAt = exerciseCreatedAt
            exercise.isArchived = true

            let firstValue = MetricValue(metric: metricA, scaledValue: 82_500)
            firstValue.id = valueIDs[0]
            firstValue.name = "当時の重量"
            firstValue.unit = "kg"
            firstValue.allowsDecimal = true
            firstValue.isRequired = false
            let nilValue = MetricValue(metric: metricB, scaledValue: nil)
            nilValue.id = valueIDs[1]
            let firstSet = SetRecord(sortOrder: 4, values: [firstValue, nilValue])
            firstSet.id = setIDs[0]
            firstSet.createdAt = setCreatedAt
            let firstRecord = ExerciseRecord(exercise: exercise, sortOrder: 2, sets: [firstSet])
            firstRecord.id = recordIDs[0]

            let zeroValue = MetricValue(metric: metricA, scaledValue: 0)
            zeroValue.id = valueIDs[2]
            let secondSet = SetRecord(sortOrder: 1, values: [zeroValue])
            secondSet.id = setIDs[1]
            let secondRecord = ExerciseRecord(exercise: exercise, sortOrder: 5, sets: [secondSet])
            secondRecord.id = recordIDs[1]
            var utcCalendar = Calendar(identifier: .gregorian)
            utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let workoutA = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [firstRecord, secondRecord], calendar: utcCalendar)
            workoutA.id = workoutIDs[0]
            workoutA.createdAt = workoutCreatedAt
            let workoutB = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [], calendar: utcCalendar)
            workoutB.id = workoutIDs[1]

            context.insert(exercise)
            context.insert(workoutA)
            context.insert(workoutB)
            try context.save()
        }

        let v2Schema = Schema(versionedSchema: MeleteRevisionSpikeSchemaV2.self)
        let v2Configuration = ModelConfiguration("MeleteRevisionSpikeV2", schema: v2Schema, url: storeURL, cloudKitDatabase: .none)
        let migrated = try ModelContainer(
            for: v2Schema,
            migrationPlan: MeleteRevisionSpikeMigrationPlan.self,
            configurations: [v2Configuration]
        )
        let migratedContext = ModelContext(migrated)

        // revision表に旧定義の行を作らないため、既存値のrevisionは推測せずnil相当。
        XCTAssertEqual(try migratedContext.fetch(FetchDescriptor<MetricDefinitionRevisionCandidate>()).count, 0)
        let exercises = try migratedContext.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(exercises.count, 1)
        let migratedExercise = try XCTUnwrap(exercises.first)
        XCTAssertEqual(migratedExercise.id, exerciseID)
        XCTAssertEqual(migratedExercise.name, "合成種目")
        XCTAssertTrue(migratedExercise.isArchived)
        XCTAssertEqual(migratedExercise.createdAt, exerciseCreatedAt)
        let definitions = Dictionary(uniqueKeysWithValues: migratedExercise.metrics.map { ($0.id, $0) })
        XCTAssertEqual(definitions.count, 2)
        XCTAssertEqual(definitions[metricIDs[0]]?.name, "重量")
        XCTAssertEqual(definitions[metricIDs[0]]?.unit, "kg")
        XCTAssertEqual(definitions[metricIDs[0]]?.sortOrder, 3)
        XCTAssertEqual(definitions[metricIDs[0]]?.allowsDecimal, true)
        XCTAssertEqual(definitions[metricIDs[0]]?.isRequired, true)
        XCTAssertEqual(definitions[metricIDs[0]]?.isActive, true)
        XCTAssertEqual(definitions[metricIDs[1]]?.name, "旧回数")
        XCTAssertEqual(definitions[metricIDs[1]]?.unit, "回")
        XCTAssertEqual(definitions[metricIDs[1]]?.sortOrder, 1)
        XCTAssertEqual(definitions[metricIDs[1]]?.allowsDecimal, false)
        XCTAssertEqual(definitions[metricIDs[1]]?.isRequired, false)
        XCTAssertEqual(definitions[metricIDs[1]]?.isActive, true)

        let workouts = try migratedContext.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(Set(workouts.map(\.id)), Set(workoutIDs))
        let migratedWorkout = try XCTUnwrap(workouts.first { $0.id == workoutIDs[0] })
        XCTAssertEqual(migratedWorkout.day, "2023-11-14")
        XCTAssertEqual(migratedWorkout.createdAt, workoutCreatedAt)
        XCTAssertEqual(migratedWorkout.records.count, 2)
        let emptyWorkout = try XCTUnwrap(workouts.first { $0.id == workoutIDs[1] })
        XCTAssertEqual(emptyWorkout.day, "2023-11-03")
        XCTAssertTrue(emptyWorkout.records.isEmpty)
        let records = Dictionary(uniqueKeysWithValues: migratedWorkout.records.map { ($0.id, $0) })
        XCTAssertEqual(records[recordIDs[0]]?.exerciseID, exerciseID)
        XCTAssertEqual(records[recordIDs[0]]?.exerciseName, "合成種目")
        XCTAssertEqual(records[recordIDs[0]]?.sortOrder, 2)
        XCTAssertEqual(records[recordIDs[0]]?.workout?.id, workoutIDs[0])
        XCTAssertEqual(records[recordIDs[1]]?.sortOrder, 5)
        XCTAssertEqual(records[recordIDs[1]]?.workout?.id, workoutIDs[0])
        let migratedSet = try XCTUnwrap(records[recordIDs[0]]?.sets.first)
        XCTAssertEqual(migratedSet.id, setIDs[0])
        XCTAssertEqual(migratedSet.sortOrder, 4)
        XCTAssertEqual(migratedSet.createdAt, setCreatedAt)
        XCTAssertEqual(migratedSet.exerciseRecord?.id, recordIDs[0])
        XCTAssertEqual(Set(migratedSet.values.map(\.id)), Set(valueIDs.prefix(2)))
        let migratedValues = Dictionary(uniqueKeysWithValues: migratedSet.values.map { ($0.id, $0) })
        XCTAssertEqual(migratedValues[valueIDs[0]]?.metricID, metricIDs[0])
        XCTAssertEqual(migratedValues[valueIDs[0]]?.name, "当時の重量")
        XCTAssertEqual(migratedValues[valueIDs[0]]?.unit, "kg")
        XCTAssertEqual(migratedValues[valueIDs[0]]?.allowsDecimal, true)
        XCTAssertEqual(migratedValues[valueIDs[0]]?.isRequired, false)
        XCTAssertEqual(migratedValues[valueIDs[0]]?.scaledValue, 82_500)
        XCTAssertEqual(migratedValues[valueIDs[0]]?.setRecord?.id, setIDs[0])
        XCTAssertNil(migratedValues[valueIDs[1]]?.scaledValue)
        XCTAssertEqual(migratedValues[valueIDs[1]]?.name, "旧回数")
        let zeroSet = try XCTUnwrap(records[recordIDs[1]]?.sets.first)
        XCTAssertEqual(zeroSet.id, setIDs[1])
        XCTAssertEqual(zeroSet.values.first?.id, valueIDs[2])
        XCTAssertEqual(zeroSet.values.first?.scaledValue, 0)

        // 新しいcontainerで再openし、移行後の永続値を再照合する。
        let reopened = try ModelContainer(
            for: v2Schema,
            migrationPlan: MeleteRevisionSpikeMigrationPlan.self,
            configurations: [v2Configuration]
        )
        let reopenedContext = ModelContext(reopened)
        XCTAssertEqual(Set(try reopenedContext.fetch(FetchDescriptor<Workout>()).map(\.id)), Set(workoutIDs))
        let reopenedWorkout = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workoutIDs[0] })
        XCTAssertEqual(reopenedWorkout.records.count, 2)
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<MetricDefinitionRevisionCandidate>()).count, 0)
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<Exercise>()).first?.metrics.count, 2)
    }

    func testProductionCandidateV2MigratesAndReopensSyntheticV1StoreWithoutInventingRevisionLinks() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteProductionV2Candidate-\(UUID().uuidString).sqlite")
        let v1Schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let v1Configuration = ModelConfiguration("MeleteProductionV2CandidateV1", schema: v1Schema, url: storeURL, cloudKitDatabase: .none)
        let exerciseID = UUID()
        let metricID = UUID()
        let workoutID = UUID()
        let recordID = UUID()
        let setID = UUID()
        let valueIDs = [UUID(), UUID()]
        let exerciseDate = Date(timeIntervalSince1970: 1_700_000_010.125)
        let workoutDate = Date(timeIntervalSince1970: 1_700_000_020.25)
        let setDate = Date(timeIntervalSince1970: 1_700_000_030.5)

        do {
            let container = try ModelContainer(for: v1Schema, configurations: [v1Configuration])
            let context = ModelContext(container)
            let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 4)
            metric.id = metricID
            let exercise = Exercise(name: "合成種目", metrics: [metric])
            exercise.id = exerciseID
            exercise.createdAt = exerciseDate
            exercise.isArchived = true
            let snapshot = MetricValue(metric: metric, scaledValue: 12_500)
            snapshot.id = valueIDs[0]
            snapshot.name = "記録時の重量"
            snapshot.unit = "lb"
            snapshot.allowsDecimal = false
            snapshot.isRequired = false
            let nilValue = MetricValue(metric: metric, scaledValue: nil)
            nilValue.id = valueIDs[1]
            let set = SetRecord(sortOrder: 8, values: [snapshot, nilValue])
            set.id = setID
            set.createdAt = setDate
            let record = ExerciseRecord(exercise: exercise, sortOrder: 6, sets: [set])
            record.id = recordID
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let workout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [record], calendar: calendar)
            workout.id = workoutID
            workout.createdAt = workoutDate
            context.insert(exercise)
            context.insert(workout)
            try context.save()
        }

        let v2Schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let v2Configuration = ModelConfiguration("MeleteProductionV2CandidateV2", schema: v2Schema, url: storeURL, cloudKitDatabase: .none)
        let migrated = try ModelContainer(for: v2Schema, migrationPlan: MeleteMigrationPlan.self, configurations: [v2Configuration])
        let context = ModelContext(migrated)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)

        let exercise = try XCTUnwrap(try context.fetch(FetchDescriptor<Exercise>()).first)
        XCTAssertEqual(exercise.id, exerciseID)
        XCTAssertEqual(exercise.createdAt, exerciseDate)
        XCTAssertTrue(exercise.isArchived)
        XCTAssertEqual(exercise.metrics.first?.id, metricID)
        XCTAssertEqual(exercise.metrics.first?.sortOrder, 4)
        let workout = try XCTUnwrap(try context.fetch(FetchDescriptor<Workout>()).first)
        XCTAssertEqual(workout.id, workoutID)
        XCTAssertEqual(workout.day, "2023-11-14")
        XCTAssertEqual(workout.createdAt, workoutDate)
        let record = try XCTUnwrap(workout.records.first)
        XCTAssertEqual(record.id, recordID)
        XCTAssertEqual(record.exerciseID, exerciseID)
        XCTAssertEqual(record.exerciseName, "合成種目")
        XCTAssertEqual(record.sortOrder, 6)
        XCTAssertEqual(record.workout?.id, workoutID)
        let set = try XCTUnwrap(record.sets.first)
        XCTAssertEqual(set.id, setID)
        XCTAssertEqual(set.sortOrder, 8)
        XCTAssertEqual(set.createdAt, setDate)
        XCTAssertEqual(set.exerciseRecord?.id, recordID)
        let values = Dictionary(uniqueKeysWithValues: set.values.map { ($0.id, $0) })
        XCTAssertEqual(Set(values.keys), Set(valueIDs))
        XCTAssertEqual(values[valueIDs[0]]?.metricID, metricID)
        XCTAssertEqual(values[valueIDs[0]]?.name, "記録時の重量")
        XCTAssertEqual(values[valueIDs[0]]?.unit, "lb")
        XCTAssertFalse(values[valueIDs[0]]?.allowsDecimal ?? true)
        XCTAssertFalse(values[valueIDs[0]]?.isRequired ?? true)
        XCTAssertEqual(values[valueIDs[0]]?.scaledValue, 12_500)
        XCTAssertEqual(values[valueIDs[0]]?.setRecord?.id, setID)
        XCTAssertNil(values[valueIDs[1]]?.scaledValue)

        let reopened = try ModelContainer(for: v2Schema, migrationPlan: MeleteMigrationPlan.self, configurations: [v2Configuration])
        let reopenedContext = ModelContext(reopened)
        let reopenedWorkout = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Workout>()).first)
        XCTAssertEqual(reopenedWorkout.id, workoutID)
        XCTAssertEqual(reopenedWorkout.records.first?.sets.first?.values.count, 2)
        XCTAssertTrue(try reopenedContext.fetch(FetchDescriptor<MetricDefinitionRevision>()).isEmpty)
        XCTAssertTrue(try reopenedContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)
        XCTAssertTrue(try reopenedContext.fetch(FetchDescriptor<Exercise>()).first?.isArchived == true)
    }

    func testCandidateV2PersistsExplicitMetricRevisionSeriesIDsAcrossReopen() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteCandidateV2SeriesID-\(UUID().uuidString).sqlite")
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteCandidateV2SeriesID", schema: schema, url: storeURL, cloudKitDatabase: .none)
        let metricID = UUID()
        let inputConditionSeriesID = UUID()
        let renamedUnitSeriesID = UUID()
        let revisionIDs = [UUID(), UUID(), UUID()]

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let revisions = [
                MetricDefinitionRevision(id: revisionIDs[0], metricID: metricID, seriesID: inputConditionSeriesID, revision: 1, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 2),
                // 入力条件だけの変更は、同じmetricの次revisionでも同じseriesに属する。
                MetricDefinitionRevision(id: revisionIDs[1], metricID: metricID, seriesID: inputConditionSeriesID, revision: 2, name: "重量", unit: "kg", allowsDecimal: false, isRequired: true, sortOrder: 2),
                // 名前・単位の変更は別seriesとして明示し、IDを推測しない。
                MetricDefinitionRevision(id: revisionIDs[2], metricID: metricID, seriesID: renamedUnitSeriesID, revision: 3, name: "負荷", unit: "lb", allowsDecimal: false, isRequired: true, sortOrder: 2)
            ]
            revisions.forEach(context.insert)
            try context.save()
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let revisions = try reopenedContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
            .sorted { $0.revision < $1.revision }

        XCTAssertEqual(revisions.map(\.id), revisionIDs)
        XCTAssertEqual(revisions.map(\.metricID), [metricID, metricID, metricID])
        XCTAssertEqual(revisions.map(\.seriesID), [inputConditionSeriesID, inputConditionSeriesID, renamedUnitSeriesID])
        XCTAssertEqual(revisions.map(\.name), ["重量", "重量", "負荷"])
        XCTAssertEqual(revisions.map(\.unit), ["kg", "kg", "lb"])
        XCTAssertEqual(revisions.map(\.allowsDecimal), [true, false, false])
        XCTAssertEqual(revisions.map(\.isRequired), [false, true, true])
        XCTAssertEqual(revisions.map(\.sortOrder), [2, 2, 2])
    }

    @MainActor func testMetricDefinitionEditingV2RevisesSeriesAndPreservesLegacyValueAcrossReopen() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteMetricEditingV2-\(UUID().uuidString).sqlite")
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteMetricEditingV2", schema: schema, url: storeURL, cloudKitDatabase: .none)
        let metricID = UUID()
        let legacyValueID = UUID()
        let originalSeriesID = UUID()
        let exerciseID = UUID()
        let legacyWorkoutID = UUID()
        var generatedValueIDs: [UUID] = []

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
            metric.id = metricID
            let exercise = Exercise(name: "合成種目", metrics: [metric])
            exercise.id = exerciseID
            let legacyValue = MetricValue(metric: metric, scaledValue: 12_500)
            legacyValue.id = legacyValueID
            let workout = Workout(day: .now, records: [ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [legacyValue])])])
            workout.id = legacyWorkoutID
            context.insert(exercise)
            context.insert(workout)
            context.insert(MetricDefinitionRevision(metricID: metricID, seriesID: originalSeriesID, revision: 1, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0))
            try context.save()

            func saveEdit(unit: String, allowsDecimal: Bool, isRequired: Bool) throws {
                let currentExercise = try XCTUnwrap(context.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseID })
                var drafts = try MetricDefinitionEditingV2.draft(for: currentExercise, in: context)
                drafts[0].unit = unit
                drafts[0].allowsDecimal = allowsDecimal
                drafts[0].isRequired = isRequired
                try MetricDefinitionEditingV2.save(drafts, for: currentExercise, in: context)

                var entry = WorkoutEntryDraft(exercise: currentExercise)
                entry.sets[0].values[metricID] = allowsDecimal ? "8.5" : "8"
                let generatedWorkout = try WorkoutCreationV2.save(day: .now, entries: [entry], in: context)
                generatedValueIDs.append(try XCTUnwrap(generatedWorkout.records.first?.sets.first?.values.first?.id))
            }

            try saveEdit(unit: "lb", allowsDecimal: true, isRequired: false)
            try saveEdit(unit: "lb", allowsDecimal: false, isRequired: true)
            try saveEdit(unit: "kg", allowsDecimal: false, isRequired: true)
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let revisions = try reopenedContext.fetch(FetchDescriptor<MetricDefinitionRevision>()).sorted { $0.revision < $1.revision }
        XCTAssertEqual(revisions.map(\.metricID), [metricID, metricID, metricID, metricID])
        XCTAssertEqual(revisions.map(\.revision), [1, 2, 3, 4])
        XCTAssertEqual(revisions.map(\.unit), ["kg", "lb", "lb", "kg"])
        XCTAssertEqual(revisions[0].seriesID, originalSeriesID)
        XCTAssertNotEqual(revisions[1].seriesID, revisions[0].seriesID)
        XCTAssertEqual(revisions[2].seriesID, revisions[1].seriesID)
        XCTAssertNotEqual(revisions[3].seriesID, revisions[0].seriesID)
        XCTAssertNotEqual(revisions[3].seriesID, revisions[1].seriesID)

        let savedWorkout = try XCTUnwrap(reopenedContext.fetch(FetchDescriptor<Workout>()).first { $0.id == legacyWorkoutID })
        let legacyValue = try XCTUnwrap(savedWorkout.records.first?.sets.first?.values.first { $0.id == legacyValueID })
        XCTAssertEqual(legacyValue.metricID, metricID)
        XCTAssertEqual(legacyValue.name, "重量")
        XCTAssertEqual(legacyValue.unit, "kg")
        XCTAssertEqual(legacyValue.scaledValue, 12_500)
        XCTAssertTrue(try reopenedContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).allSatisfy { $0.valueID != legacyValueID }, "revision linkのない旧値を推測で分類しない")

        let linksByValueID = Dictionary(uniqueKeysWithValues: try reopenedContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).map { ($0.valueID, $0.revisionID) })
        let valuesByID = Dictionary(uniqueKeysWithValues: try reopenedContext.fetch(FetchDescriptor<MetricValue>()).map { ($0.id, $0) })
        XCTAssertEqual(generatedValueIDs.count, 3)
        for (index, valueID) in generatedValueIDs.enumerated() {
            let value = try XCTUnwrap(valuesByID[valueID])
            let linkedRevisionID = try XCTUnwrap(linksByValueID[valueID])
            let linkedRevision = try XCTUnwrap(revisions.first { $0.id == linkedRevisionID })
            XCTAssertEqual(linkedRevision.id, revisions[index + 1].id)
            XCTAssertTrue(MetricValueRevisionLinking.matchesSnapshot(name: value.name, unit: value.unit, allowsDecimal: value.allowsDecimal, isRequired: value.isRequired, revision: linkedRevision))
        }
    }

    func testV1SyntheticFixtureRoundTripsWithoutMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteV1Fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("MeleteV1Fixture", schema: schema, url: directory.appendingPathComponent("fixture.sqlite"), cloudKitDatabase: .none)

        let activeExerciseID = UUID()
        let archivedExerciseID = UUID()
        let metricIDs = [UUID(), UUID(), UUID()]
        let workoutIDs = [UUID(), UUID()]
        let firstSetID = UUID()
        let secondSetID = UUID()
        let archivedSetID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_123.25)

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)

            let metricA = MetricDefinition(name: "旧重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 4)
            metricA.id = metricIDs[0]
            let metricB = MetricDefinition(name: "重量", unit: "lb", allowsDecimal: false, isRequired: false, sortOrder: 1)
            metricB.id = metricIDs[1]
            let metricC = MetricDefinition(name: "旧重量", unit: "kg", allowsDecimal: false, isRequired: false, sortOrder: 7)
            metricC.id = metricIDs[2]
            let activeExercise = Exercise(name: "種目", metrics: [metricA, metricB, metricC])
            activeExercise.id = activeExerciseID

            let archivedMetric = MetricDefinition(name: "距離", unit: "m", allowsDecimal: true, isRequired: false, sortOrder: 2)
            let archivedExercise = Exercise(name: "アーカイブ済み", metrics: [archivedMetric])
            archivedExercise.id = archivedExerciseID
            archivedExercise.isArchived = true

            let firstValues = [
                MetricValue(metric: metricA, scaledValue: 82_500),
                MetricValue(metric: metricB, scaledValue: nil),
                MetricValue(metric: metricC, scaledValue: 0)
            ]
            // V1の保存値snapshotは、後に現在の定義が変わった想定でも保持できることを確認する。
            firstValues[0].name = "記録時の名前"
            firstValues[0].unit = "kg"
            firstValues[0].allowsDecimal = true
            firstValues[0].isRequired = false
            let firstSet = SetRecord(sortOrder: 3, values: firstValues)
            firstSet.id = firstSetID
            firstSet.createdAt = createdAt
            let secondSet = SetRecord(sortOrder: 8, values: [MetricValue(metric: metricA, scaledValue: 0)])
            secondSet.id = secondSetID
            let activeRecord = ExerciseRecord(exercise: activeExercise, sortOrder: 5, sets: [firstSet, secondSet])
            let activeWorkout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [activeRecord])
            activeWorkout.id = workoutIDs[0]

            let archivedSet = SetRecord(sortOrder: 2, values: [MetricValue(metric: archivedMetric, scaledValue: nil)])
            archivedSet.id = archivedSetID
            let archivedRecord = ExerciseRecord(exercise: archivedExercise, sortOrder: 6, sets: [archivedSet])
            let archivedWorkout = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [archivedRecord])
            archivedWorkout.id = workoutIDs[1]

            context.insert(activeExercise)
            context.insert(archivedExercise)
            context.insert(activeWorkout)
            context.insert(archivedWorkout)
            try context.save()
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(reopened)
        let workouts = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(Set(workouts.map(\.id)), Set(workoutIDs))

        let activeWorkout = try XCTUnwrap(workouts.first { $0.id == workoutIDs[0] })
        let activeRecord = try XCTUnwrap(activeWorkout.records.first)
        XCTAssertEqual(activeRecord.sortOrder, 5)
        let sets = activeRecord.sets.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(sets.map(\.sortOrder), [3, 8])
        XCTAssertEqual(sets[0].id, firstSetID)
        XCTAssertEqual(sets[0].createdAt, createdAt)
        let oldSnapshots = Dictionary(uniqueKeysWithValues: sets[0].values.map { ($0.metricID, $0) })
        let oldWeight = try XCTUnwrap(oldSnapshots[metricIDs[0]])
        XCTAssertEqual(oldWeight.name, "記録時の名前")
        XCTAssertEqual(oldWeight.unit, "kg")
        XCTAssertTrue(oldWeight.allowsDecimal)
        XCTAssertFalse(oldWeight.isRequired)
        XCTAssertEqual(oldWeight.scaledValue, 82_500)
        let poundSnapshot = try XCTUnwrap(oldSnapshots[metricIDs[1]])
        XCTAssertEqual(poundSnapshot.name, "重量")
        XCTAssertEqual(poundSnapshot.unit, "lb")
        XCTAssertFalse(poundSnapshot.allowsDecimal)
        XCTAssertFalse(poundSnapshot.isRequired)
        XCTAssertNil(poundSnapshot.scaledValue)
        let zeroSnapshot = try XCTUnwrap(oldSnapshots[metricIDs[2]])
        XCTAssertEqual(zeroSnapshot.name, "旧重量")
        XCTAssertEqual(zeroSnapshot.unit, "kg")
        XCTAssertFalse(zeroSnapshot.allowsDecimal)
        XCTAssertFalse(zeroSnapshot.isRequired)
        XCTAssertEqual(zeroSnapshot.scaledValue, 0)
        XCTAssertEqual(sets[1].sortOrder, 8)
        XCTAssertEqual(sets[1].values.first?.metricID, metricIDs[0])
        XCTAssertEqual(sets[1].values.first?.scaledValue, 0)

        let archivedWorkout = try XCTUnwrap(workouts.first { $0.id == workoutIDs[1] })
        let archivedRecord = try XCTUnwrap(archivedWorkout.records.first)
        XCTAssertEqual(archivedRecord.sortOrder, 6)
        XCTAssertEqual(archivedRecord.sets.first?.id, archivedSetID)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let archivedExercise = try XCTUnwrap(exercises.first { $0.id == archivedExerciseID })
        XCTAssertTrue(archivedExercise.isArchived)
        XCTAssertEqual(archivedExercise.metrics.first?.sortOrder, 2)
        let activeExercise = try XCTUnwrap(exercises.first { $0.id == activeExerciseID })
        XCTAssertFalse(activeExercise.isArchived)
        XCTAssertEqual(activeExercise.metrics.sorted { $0.sortOrder < $1.sortOrder }.map(\.id), [metricIDs[1], metricIDs[0], metricIDs[2]])
    }

    func testMetricDefinitionEditingAddsAndTogglesWithoutChangingSnapshots() throws {
        let existing = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "種目", metrics: [existing])
        let oldValue = MetricValue(metric: existing, scaledValue: 12_500)
        let oldSet = SetRecord(sortOrder: 1, values: [oldValue])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [oldSet])
        let workout = Workout(day: .now, records: [record])
        var draft = MetricDefinitionEditing.draft(for: exercise)
        draft.append(MetricDefinitionDraft(name: " 回数 ", unit: " 回 ", allowsDecimal: false, isRequired: false))
        draft[0].isActive = false

        XCTAssertNoThrow(try MetricDefinitionEditing.save(draft, for: exercise) {})
        XCTAssertEqual(exercise.metrics.map(\.id), [existing.id, exercise.metrics[1].id])
        XCTAssertFalse(existing.isActive)
        XCTAssertEqual(exercise.metrics[1].name, "回数")
        XCTAssertEqual(exercise.metrics[1].unit, "回")
        XCTAssertFalse(exercise.metrics[1].allowsDecimal)
        XCTAssertFalse(exercise.metrics[1].isRequired)
        XCTAssertEqual(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise)?.metrics.map(\.name), ["回数"])
        XCTAssertEqual(oldValue.metricID, existing.id)
        XCTAssertEqual(oldValue.name, "重量")
        XCTAssertEqual(oldValue.scaledValue, 12_500)
        XCTAssertEqual(workout.records.first?.sets.first?.values.count, 1)

        let addition = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
        var filledAddition = addition
        filledAddition.values[exercise.metrics[1].id] = "8"
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day))
        XCTAssertNoThrow(try WorkoutValueEditing.save([], additions: [filledAddition], day: day, to: workout, exercises: [exercise]) {})
        let addedSet = try XCTUnwrap(record.sets.first { $0.sortOrder == 2 })
        XCTAssertEqual(addedSet.values.map(\.metricID), [exercise.metrics[1].id])
        XCTAssertEqual(addedSet.values.first?.scaledValue, 8_000)

        exercise.metrics[1].isActive = false
        XCTAssertThrowsError(try WorkoutValueEditing.save([], additions: [addition], day: day, to: workout, exercises: [exercise]) {}) { error in
            XCTAssertEqual((error as? WorkoutValueEditError)?.errorDescription, WorkoutValueEditError.metricsChanged.errorDescription)
        }
        XCTAssertTrue(record.sets.allSatisfy { $0.values.count == 1 || $0.sortOrder == 2 })
    }

    func testMetricDefinitionEditingRejectsInvalidNamesAndSortOrderOverflowWithoutMutation() throws {
        let first = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: Int.max)
        let exercise = Exercise(name: "種目", metrics: [first])
        for candidate in [
            MetricDefinitionDraft(name: " 重量 ", unit: "lb", allowsDecimal: false, isRequired: false),
            MetricDefinitionDraft(name: "  ", unit: "回", allowsDecimal: false, isRequired: false),
            MetricDefinitionDraft(name: "回数", unit: " \n", allowsDecimal: false, isRequired: false)
        ] {
            XCTAssertThrowsError(try MetricDefinitionEditing.save([MetricDefinitionDraft(existing: first), candidate], for: exercise) {})
            XCTAssertEqual(exercise.metrics.map(\.id), [first.id])
            XCTAssertEqual(first.name, "重量")
        }

        let valid = [MetricDefinitionDraft(existing: first), MetricDefinitionDraft(name: "回数", unit: "回", allowsDecimal: false, isRequired: true)]
        XCTAssertThrowsError(try MetricDefinitionEditing.save(valid, for: exercise) {}) { error in
            XCTAssertEqual((error as? MetricDefinitionEditingError)?.errorDescription, MetricDefinitionEditingError.sortOrderOverflow.errorDescription)
        }
        XCTAssertEqual(exercise.metrics.map(\.id), [first.id])
    }

    func testMetricDefinitionEditingRestoresOnlyTargetOnSaveFailureAndRejectsStaleDraft() throws {
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "種目", metrics: [metric])
        let other = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 0)
        let otherExercise = Exercise(name: "別種目", metrics: [other])
        var draft = MetricDefinitionEditing.draft(for: exercise)
        draft[0].isActive = false
        draft.append(MetricDefinitionDraft(name: "距離", unit: "m", allowsDecimal: true, isRequired: false))
        other.name = "未保存の変更"

        XCTAssertThrowsError(try MetricDefinitionEditing.save(draft, for: exercise) {
            throw NSError(domain: "InjectedSaveFailure", code: 1)
        })
        XCTAssertTrue(metric.isActive)
        XCTAssertEqual(exercise.metrics.map(\.id), [metric.id])
        XCTAssertEqual(other.name, "未保存の変更")
        XCTAssertEqual(otherExercise.metrics.first?.name, "未保存の変更")

        var stale = MetricDefinitionEditing.draft(for: exercise)
        stale[0].isActive = false
        metric.name = "別画面の変更"
        XCTAssertThrowsError(try MetricDefinitionEditing.save(stale, for: exercise) {}) { error in
            XCTAssertEqual((error as? MetricDefinitionEditingError)?.errorDescription, MetricDefinitionEditingError.changed.errorDescription)
        }
        XCTAssertEqual(metric.name, "別画面の変更")
        XCTAssertTrue(metric.isActive)
    }

    func testMetricDefinitionEditingPersistsAndReopensAddedAndInactiveDefinitions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteMetricDefinitionEdit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("MetricDefinitionEdit", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        let exerciseID = UUID()
        let existingMetricID = UUID()
        let newMetricID: UUID

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let existing = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
            existing.id = existingMetricID
            let exercise = Exercise(name: "種目", metrics: [existing])
            exercise.id = exerciseID
            let oldValue = MetricValue(metric: existing, scaledValue: 12_500)
            let workout = Workout(day: .now, records: [ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [oldValue])])])
            context.insert(exercise)
            context.insert(workout)
            try context.save()

            var drafts = MetricDefinitionEditing.draft(for: exercise)
            drafts[0].isActive = false
            drafts.append(MetricDefinitionDraft(name: " 回数 ", unit: " 回 ", allowsDecimal: false, isRequired: false))
            try MetricDefinitionEditing.save(drafts, for: exercise, insert: { context.insert($0) }, discard: { context.delete($0) }) { try context.save() }
            newMetricID = try XCTUnwrap(exercise.metrics.first { $0.name == "回数" }?.id)
            XCTAssertEqual(oldValue.name, "重量")
            XCTAssertEqual(oldValue.scaledValue, 12_500)
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let savedExercise = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseID })
        let savedExisting = try XCTUnwrap(savedExercise.metrics.first { $0.id == existingMetricID })
        let savedNew = try XCTUnwrap(savedExercise.metrics.first { $0.id == newMetricID })
        XCTAssertFalse(savedExisting.isActive)
        XCTAssertEqual(savedExisting.sortOrder, 0)
        XCTAssertEqual(savedNew.name, "回数")
        XCTAssertEqual(savedNew.unit, "回")
        XCTAssertFalse(savedNew.allowsDecimal)
        XCTAssertFalse(savedNew.isRequired)
        XCTAssertTrue(savedNew.isActive)
        XCTAssertEqual(savedNew.sortOrder, 1)
        let savedWorkout = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Workout>()).first)
        let savedValue = try XCTUnwrap(savedWorkout.records.first?.sets.first?.values.first)
        XCTAssertEqual(savedValue.metricID, existingMetricID)
        XCTAssertEqual(savedValue.name, "重量")
        XCTAssertEqual(savedValue.scaledValue, 12_500)
    }

    func testMetricDefinitionEditingAllowsNoActiveItemsButBlocksNewWorkoutSet() throws {
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "種目", metrics: [metric])
        var drafts = MetricDefinitionEditing.draft(for: exercise)
        drafts[0].isActive = false
        XCTAssertNoThrow(try MetricDefinitionEditing.save(drafts, for: exercise) {})
        XCTAssertFalse(metric.isActive)

        let entry = WorkoutEntryDraft(exercise: exercise)
        if case .success = WorkoutSetDraftEditing.validatedEntries([entry]) {
            XCTFail("有効項目がない種目の新規セット入力を拒否する")
        }
        XCTAssertTrue(exercise.metrics.contains { !$0.isActive }, "項目定義自体は復帰可能な状態で保持する")
        var restoredDrafts = MetricDefinitionEditing.draft(for: exercise)
        restoredDrafts[0].isActive = true
        XCTAssertNoThrow(try MetricDefinitionEditing.save(restoredDrafts, for: exercise) {})
        XCTAssertTrue(exercise.metrics[0].isActive)
    }

    func testWorkoutSetDraftCopyKeepsRawInputsButGetsIndependentIdentityAndNoParsedCache() {
        let metricID = UUID()
        var source = WorkoutSetDraft(values: [metricID: " 1.2345 ", UUID(): ""])
        source.parsedValues[metricID] = 1_234

        let copy = WorkoutSetDraft(copying: source)

        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.values, source.values, "不正な文字列や空欄も加工せず複製する")
        XCTAssertTrue(copy.parsedValues.isEmpty, "検証済みキャッシュを複製せず、保存時に再検証する")
        XCTAssertEqual(copy.values[metricID], " 1.2345 ")
        source.values[metricID] = "2"
        XCTAssertEqual(copy.values[metricID], " 1.2345 ", "複製後の編集は元draftに影響しない")
    }

    func testWorkoutSetDraftEditingUsesFormOperationsForOrderingRemovalAndSafeNoOps() throws {
        let required = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let optional = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 1)
        let exercise = Exercise(name: "種目", metrics: [required, optional])
        let otherExercise = Exercise(name: "別種目", metrics: [required])
        let firstEntry = WorkoutEntryDraft(exercise: exercise)
        let otherEntry = WorkoutEntryDraft(exercise: otherExercise)
        var entries = [firstEntry, otherEntry]
        entries[0].sets[0].values = [required.id: "0", optional.id: "", UUID(): "partial"]
        entries[0].sets[0].parsedValues[required.id] = 99
        let originalSet = entries[0].sets[0]

        WorkoutSetDraftEditing.duplicate(entryID: firstEntry.id, setID: originalSet.id, in: &entries)
        XCTAssertEqual(entries[0].sets.count, 2)
        let copy = try XCTUnwrap(entries[0].sets.last)
        XCTAssertEqual(copy.values, originalSet.values, "空欄・0・部分入力を含むraw値をそのまま保持")
        XCTAssertNotEqual(copy.id, originalSet.id)
        XCTAssertTrue(copy.parsedValues.isEmpty)
        XCTAssertEqual(entries[1].sets.map(\.id), otherEntry.sets.map(\.id), "他種目のセットは変更しない")

        entries[0].sets[0].values[required.id] = "4"
        XCTAssertEqual(entries[0].sets[1].values[required.id], "0", "複製後の編集は独立")
        let middle = WorkoutSetDraft(values: [required.id: "5"])
        entries[0].sets.append(middle)
        WorkoutSetDraftEditing.remove(entryID: firstEntry.id, setID: copy.id, from: &entries)
        XCTAssertEqual(entries[0].sets.map(\.id), [originalSet.id, middle.id], "削除後も残存セットIDで操作可能")
        WorkoutSetDraftEditing.duplicate(entryID: firstEntry.id, setID: middle.id, in: &entries)
        XCTAssertEqual(entries[0].sets.map(\.values[required.id]), ["4", "5", "5"])

        let unchanged = entries
        WorkoutSetDraftEditing.duplicate(entryID: UUID(), setID: middle.id, in: &entries)
        WorkoutSetDraftEditing.duplicate(entryID: firstEntry.id, setID: UUID(), in: &entries)
        WorkoutSetDraftEditing.remove(entryID: firstEntry.id, setID: UUID(), from: &entries)
        XCTAssertEqual(entries[0].sets.map(\.id), unchanged[0].sets.map(\.id), "無効IDは安全な無操作")
        for set in entries[0].sets.dropFirst() {
            WorkoutSetDraftEditing.remove(entryID: firstEntry.id, setID: set.id, from: &entries)
        }
        let onlySetID = try XCTUnwrap(entries[0].sets.first?.id)
        WorkoutSetDraftEditing.remove(entryID: firstEntry.id, setID: onlySetID, from: &entries)
        XCTAssertEqual(entries[0].sets.map(\.id), [onlySetID], "最後のセットは削除不可")
    }

    func testWorkoutSetDraftValidationAndSavePersistOrderedUniqueCopies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteWorkoutSetDraft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("WorkoutSetDraft", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let required = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let optional = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 1)
        let exercise = Exercise(name: "種目", metrics: [required, optional])
        let otherMetric = MetricDefinition(name: "距離", unit: "m", allowsDecimal: false, isRequired: true, sortOrder: 0)
        let otherExercise = Exercise(name: "別種目", metrics: [otherMetric])
        var entries = [WorkoutEntryDraft(exercise: exercise), WorkoutEntryDraft(exercise: otherExercise)]
        entries[0].sets[0].values = [required.id: "1.25", optional.id: ""]
        WorkoutSetDraftEditing.duplicate(entryID: entries[0].id, setID: entries[0].sets[0].id, in: &entries)
        entries[0].sets[1].values[required.id] = "0"
        entries[0].sets[1].values[optional.id] = "0"
        entries[1].sets[0].values[otherMetric.id] = "8"

        var invalid = entries
        invalid[0].sets[1].values[required.id] = "1.2345"
        if case .success = WorkoutSetDraftEditing.validatedEntries(invalid) { XCTFail("複製後の不正値を拒否") }
        invalid = entries
        invalid[0].sets[1].values[required.id] = ""
        if case .success = WorkoutSetDraftEditing.validatedEntries(invalid) { XCTFail("複製後の必須空欄を拒否") }
        invalid = entries
        invalid[1].sets[0].values[otherMetric.id] = "bad"
        if case .success = WorkoutSetDraftEditing.validatedEntries(invalid) { XCTFail("別セットの不正値があれば全体を拒否") }
        invalid = entries
        invalid[1].sets[0].values[otherMetric.id] = ""
        if case .success = WorkoutSetDraftEditing.validatedEntries(invalid) { XCTFail("別種目の必須空欄があれば全体を拒否") }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 0, "検証失敗した値は永続処理へ渡さない")

        guard case .success(let validated) = WorkoutSetDraftEditing.validatedEntries(entries) else {
            return XCTFail("有効な入力を検証")
        }
        XCTAssertEqual(validated[0].sets.map { $0.parsedValues[required.id] ?? nil }, [1_250, 0])
        XCTAssertNil(validated[0].sets[0].parsedValues[optional.id] ?? nil)
        XCTAssertEqual(validated[0].sets[1].parsedValues[optional.id] ?? nil, 0)
        XCTAssertTrue(entries[0].sets.allSatisfy { $0.parsedValues.isEmpty }, "入力draft自体のキャッシュを汚染しない")

        let records = MainView.workoutRecords(from: validated)
        let workout = Workout(day: .now, records: records)
        context.insert(exercise)
        context.insert(otherExercise)
        context.insert(workout)
        try context.save()
        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let saved = try XCTUnwrap(reopenedContext.fetch(FetchDescriptor<Workout>()).first)
        XCTAssertEqual(saved.records.sorted { $0.sortOrder < $1.sortOrder }.map(\.exerciseName), ["種目", "別種目"])
        XCTAssertEqual(saved.records.map(\.sortOrder).sorted(), [0, 1])
        XCTAssertEqual(Set(saved.records.map(\.id)).count, 2)
        let record = try XCTUnwrap(saved.records.first { $0.exerciseID == exercise.id })
        XCTAssertEqual(record.sets.sorted { $0.sortOrder < $1.sortOrder }.map(\.sortOrder), [1, 2])
        let savedSets = record.sets.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(savedSets.map { $0.values.first { $0.metricID == required.id }?.scaledValue }, [1_250, 0])
        XCTAssertNil(savedSets[0].values.first { $0.metricID == optional.id }?.scaledValue)
        XCTAssertEqual(savedSets[1].values.first { $0.metricID == optional.id }?.scaledValue, 0)
        XCTAssertEqual(Set(savedSets.map(\.id)).count, 2)
        XCTAssertEqual(Set(savedSets.flatMap(\.values).map(\.id)).count, 4)
        XCTAssertEqual(Set(saved.records.flatMap(\.sets).flatMap(\.values).map(\.id)).count, 5)
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<Workout>()).count, 1)
    }

    func testExerciseNameEditingTrimsRejectsEmptyAndAllowsDuplicateNames() throws {
        XCTAssertEqual(ExerciseNameEditing.validatedName("  ベンチプレス \n"), "ベンチプレス")
        XCTAssertNil(ExerciseNameEditing.validatedName(" \n\t"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteExerciseNameEdit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("ExerciseNameEdit", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        let inUseID = UUID()
        let archivedID = UUID()
        let inUseCreatedAt: Date
        let archivedCreatedAt: Date
        let metricID: UUID
        let oldRecordID: UUID

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: false, isRequired: true, sortOrder: 0)
            metricID = metric.id
            let inUse = Exercise(name: "使用中", metrics: [metric])
            inUse.id = inUseID
            inUseCreatedAt = inUse.createdAt
            let archivedMetric = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 0)
            let archived = Exercise(name: "アーカイブ済み", metrics: [archivedMetric])
            archived.id = archivedID
            archived.isArchived = true
            archivedCreatedAt = archived.createdAt
            let oldValue = MetricValue(metric: metric, scaledValue: 50_000)
            let oldSet = SetRecord(sortOrder: 1, values: [oldValue])
            let oldRecord = ExerciseRecord(exercise: inUse, sortOrder: 0, sets: [oldSet])
            oldRecordID = oldRecord.id
            context.insert(inUse)
            context.insert(archived)
            context.insert(Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [oldRecord]))
            try context.save()

            XCTAssertThrowsError(try ExerciseNameEditing.save(" \n", for: inUse) { try context.save() })
            XCTAssertEqual(inUse.name, "使用中", "空白名を拒否してモデル名を維持する")
            XCTAssertNoThrow(try ExerciseNameEditing.save(" 使用中 ", for: archived) { try context.save() })
            XCTAssertNoThrow(try ExerciseNameEditing.save(" 新名称 \n", for: inUse) { try context.save() })
            XCTAssertEqual(inUse.name, "新名称")

            let duplicate = Exercise(name: "重複可", metrics: [])
            context.insert(duplicate)
            try context.save()
            XCTAssertNoThrow(try ExerciseNameEditing.save(" 重複可 ", for: inUse) { try context.save() })
            XCTAssertEqual(inUse.name, duplicate.name, "重複名を許可する")
            try ExerciseNameEditing.save(" 新名称 ", for: inUse) { try context.save() }

            let other = Exercise(name: "別種目", metrics: [])
            context.insert(other)
            try context.save()
            other.name = "他の未保存変更"
            XCTAssertThrowsError(try ExerciseNameEditing.save("保存失敗後", for: inUse) {
                throw NSError(domain: "InjectedSaveFailure", code: 1)
            })
            XCTAssertEqual(inUse.name, "新名称", "失敗時に対象名だけ復元する")
            XCTAssertEqual(other.name, "他の未保存変更", "別モデルの未保存変更を保持する")
            let retainedInput = "保存失敗後"
            XCTAssertNoThrow(try ExerciseNameEditing.save(retainedInput, for: inUse) { try context.save() })
            XCTAssertEqual(inUse.name, retainedInput, "同じ入力で再試行できる")
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let exercises = try reopenedContext.fetch(FetchDescriptor<Exercise>())
        let savedInUse = try XCTUnwrap(exercises.first { $0.id == inUseID })
        let savedArchived = try XCTUnwrap(exercises.first { $0.id == archivedID })
        XCTAssertEqual(savedInUse.name, "保存失敗後")
        XCTAssertEqual(savedInUse.createdAt, inUseCreatedAt)
        XCTAssertFalse(savedInUse.isArchived)
        XCTAssertEqual(savedInUse.metrics.map(\.id), [metricID])
        XCTAssertEqual(savedArchived.name, "使用中")
        XCTAssertEqual(savedArchived.createdAt, archivedCreatedAt)
        XCTAssertTrue(savedArchived.isArchived)
        let workout = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Workout>()).first)
        let oldRecord = try XCTUnwrap(workout.records.first { $0.id == oldRecordID })
        XCTAssertEqual(oldRecord.exerciseName, "使用中", "既存Workoutのスナップショット名を維持する")
        XCTAssertEqual(oldRecord.sets.first?.values.first?.scaledValue, 50_000, "既存Workoutの値を維持する")
        let newRecord = ExerciseRecord(exercise: savedInUse, sortOrder: 1, sets: [])
        XCTAssertEqual(newRecord.exerciseName, "保存失敗後", "新規Workout記録には変更後の名前を使う")
    }

    func testExerciseNameEditingRestoresOnlyTargetNameAfterSaveFailure() throws {
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: false, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "旧名", metrics: [metric])
        exercise.isArchived = true
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [])
        let workout = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [record])
        let other = Exercise(name: "別種目", metrics: [])
        other.name = "未保存の変更"

        XCTAssertThrowsError(try ExerciseNameEditing.save("新名", for: exercise) {
            throw NSError(domain: "InjectedSaveFailure", code: 1)
        })
        XCTAssertEqual(exercise.name, "旧名")
        XCTAssertEqual(other.name, "未保存の変更")
        XCTAssertEqual(exercise.id, record.exerciseID)
        XCTAssertEqual(exercise.isArchived, true)
        XCTAssertEqual(record.exerciseName, "旧名")
        XCTAssertEqual(workout.records.first?.exerciseName, "旧名")
    }

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

    func testWorkoutValueEditingUsesSnapshotRulesAndKeepsDraftsSeparateUntilApply() throws {
        let metric = MetricDefinition(name: "旧重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "アーカイブ済み種目", metrics: [metric])
        exercise.isArchived = true
        let zero = MetricValue(metric: metric, scaledValue: 0)
        let optional = MetricValue(metric: metric, scaledValue: nil)
        let set = SetRecord(sortOrder: 1, values: [zero, optional])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [set])
        let workout = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [record])

        var drafts = WorkoutValueEditing.drafts(for: workout)
        XCTAssertEqual(drafts.map(\.text), ["0", ""])
        XCTAssertTrue(drafts.allSatisfy { $0.name == "旧重量" && $0.unit == "kg" && $0.allowsDecimal && !$0.isRequired })
        drafts[0].text = "12.345"
        drafts[1].text = "0"
        XCTAssertEqual(zero.scaledValue, 0)
        XCTAssertNil(optional.scaledValue)

        guard case let .success(values) = WorkoutValueEditing.validatedValues(from: drafts) else {
            return XCTFail("有効な編集値を受け付ける")
        }
        XCTAssertEqual(values.first { $0.valueID == zero.id }?.scaledValue, 12_345)
        XCTAssertEqual(values.first { $0.valueID == optional.id }?.scaledValue, 0)
        WorkoutValueEditing.apply(values, to: workout)
        XCTAssertEqual(zero.scaledValue, 12_345)
        XCTAssertEqual(optional.scaledValue, 0)

        drafts[0].text = "-1"
        if case .success = WorkoutValueEditing.validatedValues(from: drafts) {
            XCTFail("負数を拒否する")
        }
        var requiredDraft = drafts[0]
        requiredDraft.text = ""
        let requiredValue = WorkoutValueEditDraft(
            valueID: requiredDraft.valueID,
            exerciseName: requiredDraft.exerciseName,
            setOrder: requiredDraft.setOrder,
            name: requiredDraft.name,
            unit: requiredDraft.unit,
            allowsDecimal: requiredDraft.allowsDecimal,
            isRequired: true,
            text: requiredDraft.text
        )
        if case .success = WorkoutValueEditing.validatedValues(from: [requiredValue]) {
            XCTFail("必須項目の空欄を拒否する")
        }
    }

    func testWorkoutValueEditSavePersistsOnlyValuesAndPreservesSnapshotAndHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteWorkoutValueEdit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("WorkoutValueEdit", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        let targetID = UUID()
        let otherWorkoutID = UUID()
        let targetValueID: UUID
        let otherOriginalDay: String
        let targetCreatedAt: Date
        let recordCreatedAt: Date
        var testCalendar = Calendar(identifier: .gregorian)
        testCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let fixedNow = try XCTUnwrap(testCalendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)))
        let editedDay = try XCTUnwrap(testCalendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 18)))
        let editedDayString = Workout.dayString(from: editedDay, calendar: testCalendar)

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let metric = MetricDefinition(name: "旧重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
            let exercise = Exercise(name: "過去の種目名", metrics: [metric])
            exercise.isArchived = true
            metric.name = "現在の項目名"
            metric.unit = "lb"
            let targetValue = MetricValue(metric: metric, scaledValue: 8_000)
            targetValue.name = "旧重量"
            targetValue.unit = "kg"
            targetValue.allowsDecimal = true
            targetValue.isRequired = false
            targetValueID = targetValue.id
            let secondValue = MetricValue(metric: metric, scaledValue: nil)
            secondValue.name = "任意項目"
            secondValue.unit = "回"
            secondValue.allowsDecimal = false
            secondValue.isRequired = false
            let targetSet = SetRecord(sortOrder: 3, values: [targetValue, secondValue])
            let targetRecord = ExerciseRecord(exercise: exercise, sortOrder: 2, sets: [targetSet])
            let precedingRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: 4_000)])])
            let target = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [targetRecord, precedingRecord])
            target.id = targetID
            targetCreatedAt = target.createdAt
            recordCreatedAt = targetSet.createdAt

            let otherValue = MetricValue(metric: metric, scaledValue: 20_000)
            let other = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [otherValue])])])
            other.id = otherWorkoutID
            otherOriginalDay = other.day
            context.insert(exercise)
            context.insert(target)
            context.insert(other)
            try context.save()

            var drafts = WorkoutValueEditing.drafts(for: target)
            drafts[drafts.firstIndex { $0.valueID == targetValueID }!].text = ""
            drafts[drafts.firstIndex { $0.name == "任意項目" }!].text = "0"
            let discardedDraft = WorkoutValueEditing.drafts(for: target)
            XCTAssertEqual(targetValue.scaledValue, 8_000, "draftを作成・破棄してもモデル値を変えない")
            XCTAssertEqual(secondValue.scaledValue, nil)
            if case .failure = WorkoutValueEditing.validatedValues(from: drafts) {
                XCTFail("任意項目の空欄と0を受け付ける")
            }

            var invalidDrafts = drafts
            invalidDrafts[invalidDrafts.firstIndex { $0.valueID == targetValueID }!].text = "1.2345"
            if case .success = WorkoutValueEditing.validatedValues(from: invalidDrafts) {
                XCTFail("小数第4位を拒否する")
            }
            invalidDrafts[invalidDrafts.firstIndex { $0.valueID == targetValueID }!].text = "1.2"
            invalidDrafts[invalidDrafts.firstIndex { $0.name == "任意項目" }!].text = "1.5"
            if case .success = WorkoutValueEditing.validatedValues(from: invalidDrafts) {
                XCTFail("整数項目は小数を拒否")
            }
            XCTAssertEqual(targetValue.scaledValue, 8_000, "入力エラーでは対象のどの値も変更しない")
            XCTAssertNil(secondValue.scaledValue, "入力エラーでは他の項目値も変更しない")

            // 保存失敗を注入し、対象値を戻しつつ他の未保存変更を維持する。
            otherValue.scaledValue = 21_000
            let originalDay = target.day
            XCTAssertThrowsError(try WorkoutValueEditing.save(drafts, day: editedDay, to: target, calendar: testCalendar, now: fixedNow) { throw NSError(domain: "InjectedSaveFailure", code: 1) })
            XCTAssertEqual(targetValue.scaledValue, 8_000)
            XCTAssertNil(secondValue.scaledValue)
            XCTAssertEqual(target.day, originalDay, "保存失敗時は日付も復元する")
            XCTAssertEqual(otherValue.scaledValue, 21_000)
            XCTAssertEqual(drafts.first { $0.valueID == targetValueID }?.text, "", "失敗後も編集入力を保持する")
            XCTAssertEqual(discardedDraft.first { $0.valueID == targetValueID }?.text, "8", "破棄したdraftの値はモデルに反映しない")

            try WorkoutValueEditing.save(drafts, additions: [], day: editedDay, to: target, exercises: [exercise], calendar: testCalendar, now: fixedNow) { try context.save() }
            XCTAssertEqual(target.createdAt, targetCreatedAt)
            XCTAssertEqual(targetSet.createdAt, recordCreatedAt)
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let workouts = try reopenedContext.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(Set(workouts.map(\.id)), [targetID, otherWorkoutID])
        let savedWorkout = try XCTUnwrap(workouts.first { $0.id == targetID })
        XCTAssertEqual(savedWorkout.day, editedDayString)
        XCTAssertEqual(savedWorkout.createdAt, targetCreatedAt)
        XCTAssertEqual(savedWorkout.records.sorted { $0.sortOrder < $1.sortOrder }.map(\.sortOrder), [0, 2])
        let record = try XCTUnwrap(savedWorkout.records.first { $0.sortOrder == 2 })
        XCTAssertEqual(record.exerciseName, "過去の種目名")
        XCTAssertEqual(record.sortOrder, 2)
        let set = try XCTUnwrap(record.sets.first)
        XCTAssertEqual(set.sortOrder, 3)
        XCTAssertEqual(set.createdAt, recordCreatedAt)
        let savedEditedValue = try XCTUnwrap(set.values.first { $0.id == targetValueID })
        XCTAssertNil(savedEditedValue.scaledValue, "任意の既存値を空にする")
        XCTAssertEqual(savedEditedValue.name, "旧重量")
        XCTAssertEqual(savedEditedValue.unit, "kg")
        XCTAssertTrue(savedEditedValue.allowsDecimal)
        XCTAssertFalse(savedEditedValue.isRequired)
        XCTAssertEqual(set.values.first { $0.name == "任意項目" }?.scaledValue, 0, "nilを0にする")
        let otherWorkout = try XCTUnwrap(workouts.first { $0.id == otherWorkoutID })
        XCTAssertEqual(otherWorkout.day, otherOriginalDay, "別Workoutの日付を変更しない")
        XCTAssertEqual(otherWorkout.records.first?.sets.first?.values.first?.scaledValue, 21_000)
        let archivedExercise = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Exercise>()).first)
        XCTAssertTrue(archivedExercise.isArchived)
        XCTAssertEqual(archivedExercise.name, "過去の種目名")
    }

    func testWorkoutValueEditingRejectsInvalidDayOrDraftWithoutPartialChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)))
        let originalDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14)))
        let futureDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "テスト種目", metrics: [metric])
        let value = MetricValue(metric: metric, scaledValue: 5_000)
        let workout = Workout(day: originalDate, records: [ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [value])])], calendar: calendar)
        var drafts = WorkoutValueEditing.drafts(for: workout)
        drafts[0].text = "7"

        XCTAssertThrowsError(try WorkoutValueEditing.save(drafts, day: futureDate, to: workout, calendar: calendar, now: now) {})
        XCTAssertEqual(workout.day, "2026-11-14")
        XCTAssertEqual(value.scaledValue, 5_000)

        workout.day = "2026-02-30"
        XCTAssertThrowsError(try WorkoutValueEditing.save(drafts, day: originalDate, to: workout, calendar: calendar, now: now) {})
        XCTAssertEqual(workout.day, "2026-02-30", "壊れた保存日付は編集で上書きしない")
        XCTAssertEqual(value.scaledValue, 5_000)
        workout.day = "2026-11-14"

        drafts[0].text = "invalid"
        XCTAssertThrowsError(try WorkoutValueEditing.save(drafts, day: originalDate, to: workout, calendar: calendar, now: now) {})
        XCTAssertEqual(workout.day, "2026-11-14")
        XCTAssertEqual(value.scaledValue, 5_000)

        drafts[0].text = ""
        XCTAssertNoThrow(try WorkoutValueEditing.save(drafts, day: originalDate, to: workout, calendar: calendar, now: now) {})
        XCTAssertNil(value.scaledValue, "任意項目を空欄にした場合は値を消し、日付は一緒に扱う")
        XCTAssertEqual(workout.day, "2026-11-14")
    }

    func testWorkoutValueEditingSavesAdditionsAtomicallyAndReopensStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteWorkoutSetAddition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("WorkoutSetAddition", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)))
        let originalDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 28)))
        let editedDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 22)))
        let targetID = UUID()
        let metricID = UUID()
        let optionalMetricID = UUID()
        let oldValueID = UUID()
        let createdWorkoutAt: Date
        let createdRecordAt: Date
        var insertedSetIDs = Set<UUID>()
        let context: ModelContext
        let workout: Workout
        let record: ExerciseRecord
        let exercise: Exercise
        let oldValue: MetricValue

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            context = ModelContext(container)
            let required = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
            required.id = metricID
            let optional = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 1)
            optional.id = optionalMetricID
            exercise = Exercise(name: "種目", metrics: [required, optional])
            oldValue = MetricValue(metric: required, scaledValue: 5_000)
            oldValue.id = oldValueID
            let oldSet = SetRecord(sortOrder: 2, values: [oldValue, MetricValue(metric: optional, scaledValue: nil)])
            record = ExerciseRecord(exercise: exercise, sortOrder: 1, sets: [oldSet])
            workout = Workout(day: originalDay, records: [record], calendar: calendar)
            workout.id = targetID
            createdWorkoutAt = workout.createdAt
            createdRecordAt = oldSet.createdAt
            let other = Workout(day: now, records: [ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [])], calendar: calendar)
            context.insert(exercise)
            context.insert(workout)
            context.insert(other)
            try context.save()
        }

        var edits = WorkoutValueEditing.drafts(for: workout)
        edits[edits.firstIndex { $0.valueID == oldValueID }!].text = "6.25"
        var additions = WorkoutSetAdditionDrafts()
        let firstDraft = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
        let second = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
        additions.append(firstDraft)
        additions.append(second)
        additions.setValue("5", draftID: firstDraft.id, metricID: metricID)
        additions.duplicate(id: firstDraft.id)
        let copiedDraft = try XCTUnwrap(additions.items.first { $0.id != firstDraft.id && $0.recordID == firstDraft.recordID })
        XCTAssertEqual(additions.value(draftID: copiedDraft.id, metricID: metricID), "5", "複製直後にraw入力をコピー")
        additions.setValue("0", draftID: copiedDraft.id, metricID: metricID)
        additions.setValue("", draftID: copiedDraft.id, metricID: optionalMetricID)
        additions.setValue("7.5", draftID: second.id, metricID: metricID)
        additions.setValue("12", draftID: second.id, metricID: optionalMetricID)
        XCTAssertEqual(additions.items.map(\.id), [firstDraft.id, copiedDraft.id, second.id], "画面と同じ複製操作で直後に隣接挿入")
        XCTAssertNotEqual(copiedDraft.id, firstDraft.id)
        XCTAssertEqual(additions.value(draftID: firstDraft.id, metricID: metricID), "5", "複製後の入力変更は元に反映しない")
        additions.cancel(id: firstDraft.id)
        XCTAssertEqual(additions.items.map(\.id), [copiedDraft.id, second.id], "ID指定取消し後は残ったdraftだけ保存")
        XCTAssertEqual(record.sets.count, 1, "保存前はモデルに追加しない。キャンセル時も元のまま")
        XCTAssertEqual(oldValue.scaledValue, 5_000)

        var invalidAddition = copiedDraft
        invalidAddition.values[metricID] = ""
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [invalidAddition], day: editedDay, to: workout, exercises: [exercise], calendar: calendar, now: now) {})
        invalidAddition.values[metricID] = "-1"
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [invalidAddition], day: editedDay, to: workout, exercises: [exercise], calendar: calendar, now: now) {})
        invalidAddition.values[metricID] = "1.2345"
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [invalidAddition], day: editedDay, to: workout, exercises: [exercise], calendar: calendar, now: now) {})
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [copiedDraft, copiedDraft], day: editedDay, to: workout, exercises: [exercise], calendar: calendar, now: now) {}, "追加draft重複を拒否")
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [copiedDraft], day: now.addingTimeInterval(86_400), to: workout, exercises: [exercise], calendar: calendar, now: now) {}, "未来日を拒否")
        XCTAssertEqual(record.sets.count, 1, "入力拒否のどの場合もモデルを変更しない")
        XCTAssertEqual(workout.day, Workout.dayString(from: originalDay, calendar: calendar))
        XCTAssertEqual(oldValue.scaledValue, 5_000)

        let originalStoredDay = workout.day
        var unsavedOtherValue: MetricValue?
        // 他Workoutへの未保存変更も、対象の保存失敗時に巻き戻さない。
        let otherWorkout = try XCTUnwrap(try context.fetch(FetchDescriptor<Workout>()).first { $0.id != targetID })
        let otherMetric = exercise.metrics[0]
        unsavedOtherValue = MetricValue(metric: otherMetric, scaledValue: 99_000)
        let otherRecord = try XCTUnwrap(otherWorkout.records.first)
        let otherSet = SetRecord(sortOrder: 1, values: [unsavedOtherValue!])
        otherRecord.sets.append(otherSet)
        var discarded: [SetRecord] = []
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: additions.items, day: editedDay, to: workout, exercises: [exercise], calendar: calendar, now: now, discard: { set in discarded.append(set); context.delete(set) }) {
            throw NSError(domain: "InjectedSaveFailure", code: 1)
        })
        XCTAssertEqual(workout.day, originalStoredDay)
        XCTAssertEqual(oldValue.scaledValue, 5_000)
        XCTAssertEqual(otherRecord.sets.count, 1, "他の未保存変更は維持")
        XCTAssertEqual(discarded.count, 2)
        XCTAssertTrue(discarded.allSatisfy { $0.values.allSatisfy { $0.setRecord == nil } }, "失敗した新規Valueを孤児として残さない")
        XCTAssertEqual(record.sets.count, 1, "失敗時に追加セットを残さない")

        try WorkoutValueEditing.save(edits, additions: additions.items, day: editedDay, to: workout, exercises: [exercise], calendar: calendar, now: now) { try context.save() }
        XCTAssertEqual(record.sets.sorted { $0.sortOrder < $1.sortOrder }.map(\.sortOrder), [2, 3, 4])
        insertedSetIDs = Set(record.sets.filter { $0.sortOrder > 2 }.map(\.id))
        XCTAssertEqual(record.sets.filter { $0.sortOrder > 2 }.map(\.createdAt).count, 2)
        XCTAssertEqual(workout.createdAt, createdWorkoutAt)
        XCTAssertEqual(record.sets.first { $0.sortOrder == 2 }?.createdAt, createdRecordAt)

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let saved = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Workout>()).first { $0.id == targetID })
        XCTAssertEqual(saved.day, Workout.dayString(from: editedDay, calendar: calendar))
        XCTAssertEqual(saved.createdAt, createdWorkoutAt)
        let savedRecord = try XCTUnwrap(saved.records.first)
        XCTAssertEqual(savedRecord.exerciseName, "種目")
        XCTAssertEqual(savedRecord.sets.map(\.sortOrder).sorted(), [2, 3, 4], "再試行で重複セットを作らない")
        XCTAssertEqual(Set(savedRecord.sets.map(\.id)).count, 3)
        XCTAssertEqual(Set(savedRecord.sets.filter { $0.sortOrder > 2 }.map(\.id)), insertedSetIDs, "生成された永続セットIDを再オープン後も保持")
        XCTAssertEqual(insertedSetIDs.count, 2)
        XCTAssertEqual(savedRecord.sets.first { $0.sortOrder == 2 }?.values.first { $0.id == oldValueID }?.scaledValue, 6_250)
        let addedZero = try XCTUnwrap(savedRecord.sets.first { $0.sortOrder == 3 }?.values.first { $0.metricID == metricID })
        XCTAssertEqual(addedZero.scaledValue, 0, "0とnilを区別")
        XCTAssertNil(savedRecord.sets.first { $0.sortOrder == 3 }?.values.first { $0.name == "回数" }?.scaledValue)
        XCTAssertEqual(savedRecord.sets.first { $0.sortOrder == 4 }?.values.first { $0.name == "回数" }?.scaledValue, 12_000)
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<Workout>()).count, 2)
    }

    func testWorkoutSetAdditionRejectsUnavailableExercisesSnapshotDriftAndOverflow() throws {
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "種目", metrics: [metric])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: nil)])])
        let workout = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [record])
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day))
        let edits = WorkoutValueEditing.drafts(for: workout)
        let baseline = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))

        exercise.isArchived = true
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [baseline], day: day, to: workout, exercises: [exercise]) {})
        XCTAssertEqual(record.sets.count, 1)
        exercise.isArchived = false

        let nonexistent = WorkoutSetAdditionDraft(
            id: UUID(), recordID: baseline.recordID, exerciseID: UUID(),
            exerciseName: baseline.exerciseName, metrics: baseline.metrics, values: baseline.values
        )
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [nonexistent], day: day, to: workout, exercises: [exercise]) {})
        XCTAssertEqual(record.sets.count, 1)

        let changedMetricDraft = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
        for change in 0..<4 {
            let originalName = metric.name
            let originalUnit = metric.unit
            let originalRequired = metric.isRequired
            let originalActive = metric.isActive
            switch change {
            case 0: metric.name = "変更後"
            case 1: metric.unit = "lb"
            case 2: metric.isRequired = true
            default: metric.isActive = false
            }
            let beforeDay = workout.day
            let beforeValue = record.sets[0].values[0].scaledValue
            XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [changedMetricDraft], day: day, to: workout, exercises: [exercise]) {})
            XCTAssertEqual(workout.day, beforeDay)
            XCTAssertEqual(record.sets.count, 1)
            XCTAssertEqual(record.sets[0].values[0].scaledValue, beforeValue)
            metric.name = originalName
            metric.unit = originalUnit
            metric.isRequired = originalRequired
            metric.isActive = originalActive
        }

        record.sets[0].sortOrder = Int.max
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [baseline], day: day, to: workout, exercises: [exercise]) { XCTFail("overflow時はpersistしない") }) { error in
            XCTAssertEqual((error as? WorkoutValueEditError)?.errorDescription, WorkoutValueEditError.setOrderOverflow.errorDescription)
        }
        XCTAssertEqual(record.sets.count, 1, "順序overflow時に追加セットを残さない")
    }

    func testWorkoutSetAdditionDraftCancellationTargetsIDsAndSavesOnlyRemainingDrafts() throws {
        let metricA = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let metricB = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0)
        let exerciseA = Exercise(name: "種目A", metrics: [metricA])
        let exerciseB = Exercise(name: "種目B", metrics: [metricB])
        let recordA = ExerciseRecord(exercise: exerciseA, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metricA, scaledValue: 5_000)])])
        let recordB = ExerciseRecord(exercise: exerciseB, sortOrder: 1, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metricB, scaledValue: 8_000)])])
        let originalDay = Date(timeIntervalSince1970: 1_794_686_400)
        let workout = Workout(day: originalDay, records: [recordA, recordB])
        let originalDayString = workout.day
        let existingValues = [recordA, recordB].flatMap(\.sets).flatMap(\.values)
        var additions = WorkoutSetAdditionDrafts()
        let draftA1 = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: recordA, exercise: exerciseA))
        let draftB1 = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: recordB, exercise: exerciseB))
        let draftA2 = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: recordA, exercise: exerciseA))
        let draftB2 = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: recordB, exercise: exerciseB))
        let draftA3 = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: recordA, exercise: exerciseA))
        [draftA1, draftB1, draftA2, draftB2, draftA3].forEach { additions.append($0) }

        additions.setValue("11.5", draftID: draftA1.id, metricID: metricA.id)
        additions.setValue("12", draftID: draftA2.id, metricID: metricA.id)
        additions.setValue("13", draftID: draftA3.id, metricID: metricA.id)
        additions.setValue("21", draftID: draftB1.id, metricID: metricB.id)
        additions.setValue("22", draftID: draftB2.id, metricID: metricB.id)
        additions.cancel(id: draftA1.id) // 先頭
        additions.cancel(id: draftB1.id) // 別種目の先頭
        additions.cancel(id: draftB2.id) // 残存配列の中間
        additions.setValue("999", draftID: UUID(), metricID: metricA.id)

        XCTAssertEqual(additions.items.map(\.id), [draftA2.id, draftA3.id])
        XCTAssertEqual(additions.value(draftID: draftA2.id, metricID: metricA.id), "12")
        XCTAssertEqual(additions.value(draftID: draftA3.id, metricID: metricA.id), "13")
        XCTAssertEqual(additions.value(draftID: draftA1.id, metricID: metricA.id), "")
        XCTAssertEqual(additions.value(draftID: draftB2.id, metricID: metricB.id), "")
        XCTAssertTrue([recordA, recordB].allSatisfy { $0.sets.count == 1 }, "取消し前のdraftは保存済みセットに触れない")
        XCTAssertEqual(workout.day, originalDayString, "取消しではWorkoutの日付を変更しない")
        XCTAssertEqual(existingValues.map(\.scaledValue), [5_000, 8_000], "取消しでは保存済み値を変更しない")

        let editedDay = Date(timeIntervalSince1970: 1_706_659_200)
        try WorkoutValueEditing.save([], additions: additions.items, day: editedDay, to: workout, exercises: [exerciseA, exerciseB], now: Date(timeIntervalSince1970: 1_800_000_000)) {}
        XCTAssertEqual(workout.records.first { $0.id == recordA.id }?.sets.map(\.sortOrder).sorted(), [1, 2, 3])
        XCTAssertEqual(recordB.sets.map(\.sortOrder), [1], "取り消した種目Bのdraftは追加しない")
        XCTAssertEqual(recordA.sets.first { $0.sortOrder == 2 }?.values.first?.scaledValue, 12_000)
        XCTAssertEqual(recordA.sets.first { $0.sortOrder == 3 }?.values.first?.scaledValue, 13_000)
        XCTAssertEqual(workout.day, Workout.dayString(from: editedDay, calendar: .current), "残ったdraftを保存し、日付変更も反映する")
    }

    func testWorkoutSetAdditionDraftDuplicationCopiesRawValuesAndInsertsByID() {
        let metric = WorkoutSetMetricDraft(id: UUID(), name: "重量", unit: "kg", allowsDecimal: true, isRequired: false)
        let recordA = UUID()
        let recordB = UUID()
        let first = WorkoutSetAdditionDraft(id: UUID(), recordID: recordA, exerciseID: UUID(), exerciseName: "種目A", metrics: [metric], values: [metric.id: " 1.2345 "])
        let otherRecord = WorkoutSetAdditionDraft(id: UUID(), recordID: recordB, exerciseID: UUID(), exerciseName: "種目B", metrics: [metric], values: [:])
        let next = WorkoutSetAdditionDraft(id: UUID(), recordID: recordA, exerciseID: first.exerciseID, exerciseName: first.exerciseName, metrics: first.metrics, values: [metric.id: ""])
        var additions = WorkoutSetAdditionDrafts()
        [first, otherRecord, next].forEach { additions.append($0) }

        additions.duplicate(id: first.id)

        let copy = additions.items[1]
        XCTAssertEqual(additions.items.map(\.id), [first.id, copy.id, otherRecord.id, next.id])
        XCTAssertNotEqual(copy.id, first.id)
        XCTAssertEqual(copy.recordID, first.recordID)
        XCTAssertEqual(copy.exerciseID, first.exerciseID)
        XCTAssertEqual(copy.exerciseName, first.exerciseName)
        XCTAssertEqual(copy.metrics, first.metrics)
        XCTAssertEqual(copy.values, first.values)
        additions.setValue("不正値", draftID: copy.id, metricID: metric.id)
        XCTAssertEqual(additions.value(draftID: first.id, metricID: metric.id), " 1.2345 ")
        XCTAssertEqual(additions.value(draftID: copy.id, metricID: metric.id), "不正値")
        additions.cancel(id: first.id)
        XCTAssertEqual(additions.items.map(\.id), [copy.id, otherRecord.id, next.id])
        additions.duplicate(id: first.id)
        XCTAssertEqual(additions.items.map(\.id), [copy.id, otherRecord.id, next.id])
    }

    func testWorkoutSetAdditionAllowsEmptyOptionalSetAndKeepsZeroDistinct() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteOptionalSet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("OptionalSet", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        let workoutID = UUID()
        let recordID = UUID()
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let metric = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 0)
            let exercise = Exercise(name: "種目", metrics: [metric])
            let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [])
            record.id = recordID
            let workout = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [record])
            workout.id = workoutID
            context.insert(exercise)
            context.insert(workout)
            try context.save()

            let empty = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
            var zero = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
            zero.values[metric.id] = "0"
            try WorkoutValueEditing.save([], additions: [empty, zero], day: WorkoutValueEditing.date(from: workout.day)!, to: workout, exercises: [exercise]) { try context.save() }
        }
        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let savedWorkout = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workoutID })
        let savedRecord = try XCTUnwrap(savedWorkout.records.first { $0.id == recordID })
        let emptySet = try XCTUnwrap(savedRecord.sets.first { $0.sortOrder == 1 })
        let zeroSet = try XCTUnwrap(savedRecord.sets.first { $0.sortOrder == 2 })
        XCTAssertNil(emptySet.values.first?.scaledValue, "未入力はnilのまま保存")
        XCTAssertEqual(zeroSet.values.first?.scaledValue, 0, "入力した0はnilと区別して保存")
    }

    func testWorkoutStoredDayRejectsMalformedAndImpossibleDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        for invalid in ["2024-2-09", "2024-02-30", "2023-02-29", "abcd-01-01", "2024-01-01x"] {
            XCTAssertNil(WorkoutValueEditing.date(from: invalid, calendar: calendar), "不正日付を拒否: \(invalid)")
        }
        let leap = try XCTUnwrap(WorkoutValueEditing.date(from: "2024-02-29", calendar: calendar))
        XCTAssertEqual(Workout.dayString(from: leap, calendar: calendar), "2024-02-29")
    }

    func testWorkoutDayConversionUsesCalendarDaysAcrossZonesDSTLeapDayAndYearEnd() throws {
        let cases: [(String, DateComponents, String)] = [
            ("Asia/Tokyo", DateComponents(year: 2024, month: 2, day: 29, hour: 23), "2024-02-29"),
            ("Pacific/Honolulu", DateComponents(year: 2024, month: 3, day: 10, hour: 23), "2024-03-10"),
            ("America/Los_Angeles", DateComponents(year: 2024, month: 3, day: 10, hour: 3), "2024-03-10"),
            ("Asia/Tokyo", DateComponents(year: 2025, month: 12, day: 31, hour: 23), "2025-12-31"),
            ("Asia/Tokyo", DateComponents(year: 2026, month: 1, day: 1, hour: 0), "2026-01-01")
        ]
        for (zone, components, expected) in cases {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let date = try XCTUnwrap(calendar.date(from: components))
            XCTAssertEqual(Workout.dayString(from: date, calendar: calendar), expected, "\(zone) \(expected)")
            XCTAssertEqual(WorkoutValueEditing.date(from: expected, calendar: calendar).map { Workout.dayString(from: $0, calendar: calendar) }, expected)
        }
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

    func testWorkoutCalendarSelectionAndAddAvailabilityAtFixedNow() throws {
        let tokyo = WorkoutCalendarLogic.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo")))
        let honolulu = WorkoutCalendarLogic.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu")))
        let fixedNow = try XCTUnwrap(tokyo.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)))
        let today = try XCTUnwrap(WorkoutValueEditing.date(from: "2026-11-15", calendar: tokyo))
        let past = try XCTUnwrap(WorkoutValueEditing.date(from: "2024-02-29", calendar: tokyo))
        let future = try XCTUnwrap(WorkoutValueEditing.date(from: "2026-11-16", calendar: tokyo))

        XCTAssertEqual(WorkoutCalendarLogic.initialWorkoutDay(selectedDay: nil, now: fixedNow, calendar: tokyo), tokyo.startOfDay(for: fixedNow))
        XCTAssertEqual(WorkoutCalendarLogic.initialWorkoutDay(selectedDay: "2026-11-15", now: fixedNow, calendar: tokyo), tokyo.startOfDay(for: today))
        XCTAssertEqual(WorkoutCalendarLogic.initialWorkoutDay(selectedDay: "2024-02-29", now: fixedNow, calendar: tokyo), tokyo.startOfDay(for: past))
        XCTAssertEqual(WorkoutCalendarLogic.initialWorkoutDay(selectedDay: "2026-11-16", now: fixedNow, calendar: tokyo), tokyo.startOfDay(for: future))
        XCTAssertNil(WorkoutCalendarLogic.initialWorkoutDay(selectedDay: "2026-02-30", now: fixedNow, calendar: tokyo), "不正選択を今日にfallbackしない")

        XCTAssertTrue(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 1, selectedDay: nil, now: fixedNow, calendar: tokyo).isEmpty)
        XCTAssertTrue(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 1, selectedDay: "2026-11-15", now: fixedNow, calendar: tokyo).isEmpty)
        XCTAssertTrue(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 1, selectedDay: "2024-02-29", now: fixedNow, calendar: tokyo).isEmpty)
        XCTAssertEqual(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 1, selectedDay: "2026-11-16", now: fixedNow, calendar: tokyo), [.futureDay])
        XCTAssertEqual(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 0, selectedDay: nil, now: fixedNow, calendar: tokyo), [.noActiveExercises])
        XCTAssertEqual(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 0, selectedDay: "2026-11-16", now: fixedNow, calendar: tokyo), [.noActiveExercises, .futureDay])
        XCTAssertEqual(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 0, selectedDay: "2026-02-30", now: fixedNow, calendar: tokyo), [.noActiveExercises, .invalidSelectedDay])
        XCTAssertEqual(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 1, selectedDay: "2026-02-30", now: fixedNow, calendar: tokyo), [.invalidSelectedDay])
        XCTAssertTrue(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 1, selectedDay: nil, now: fixedNow, calendar: honolulu).isEmpty, "全履歴に戻すと未来日ブロックを解除")

        let timezoneCases: [(Calendar, String, String)] = [
            (tokyo, "2024-02-29", "2024-02-29"),
            (honolulu, "2024-03-10", "2024-03-10"),
            (tokyo, "2025-12-31", "2025-12-31"),
            (honolulu, "2026-01-01", "2026-01-01")
        ]
        for (calendar, key, expected) in timezoneCases {
            let date = try XCTUnwrap(WorkoutCalendarLogic.initialWorkoutDay(selectedDay: key, now: fixedNow, calendar: calendar))
            XCTAssertEqual(Workout.dayString(from: date, calendar: calendar), expected, "独立した期待日: \(key)")
        }
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

            let deletionTarget = try WorkoutDeletion.captureTarget(workout: try XCTUnwrap(context.fetch(FetchDescriptor<Workout>()).first { $0.id == targetID }), in: context)
            try WorkoutDeletion.delete(deletionTarget, in: context)
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

    @MainActor
    func testInvestigationSeparateContextSetDeletionRefreshesCachedWorkoutRelationships() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteContextRefreshProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("ContextRefreshProbe", schema: schema, url: directory.appendingPathComponent("probe.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let mainContext = container.mainContext
        let deletionContext = ModelContext(container)

        let metric = MetricDefinition(name: "Probe", unit: "unit", allowsDecimal: false, isRequired: false, sortOrder: 0)
        let sets = [1, 2, 3].map { order in
            SetRecord(sortOrder: order, values: [MetricValue(metric: metric, scaledValue: Int64(order * 1_000))])
        }
        let record = ExerciseRecord(exercise: Exercise(name: "Synthetic", metrics: [metric]), sortOrder: 0, sets: sets)
        let workout = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [record])
        let workoutID = workout.id
        let otherWorkout = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [])
        mainContext.insert(workout)
        mainContext.insert(otherWorkout)
        try mainContext.save()

        let targetID = try XCTUnwrap(sets.first { $0.sortOrder == 2 }?.id)
        let cachedWorkout = try XCTUnwrap(mainContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workoutID })
        let deletionWorkout = try XCTUnwrap(deletionContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workoutID })
        let cachedRecord = try XCTUnwrap(cachedWorkout.records.first)
        let deletionSet = try XCTUnwrap(deletionWorkout.records.first?.sets.first { $0.id == targetID })
        let before = cachedRecord.sets.map(\.sortOrder).sorted()
        otherWorkout.day = "unsaved-main-context-change"

        deletionContext.delete(deletionSet)
        try deletionContext.save()
        let immediatelyAfterSave = cachedRecord.sets.map(\.sortOrder).sorted()
        mainContext.processPendingChanges()
        let afterProcessing = cachedRecord.sets.map(\.sortOrder).sorted()
        let afterExplicitFetch = try mainContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workoutID }?.records.first?.sets.map(\.sortOrder).sorted() ?? []
        let freshContext = ModelContext(container)
        let freshResult = try freshContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workoutID }?.records.first?.sets.map(\.sortOrder).sorted() ?? []
        let unsavedOtherDayAfter = otherWorkout.day

        print("CONTEXT_REFRESH_PROBE before=\(before) afterSave=\(immediatelyAfterSave) afterProcessPendingChanges=\(afterProcessing) afterExplicitFetch=\(afterExplicitFetch) freshContext=\(freshResult) unsavedOtherWorkoutDay=\(unsavedOtherDayAfter)")
        XCTAssertEqual(before, [1, 2, 3])
        XCTAssertEqual(freshResult, [1, 3], "新規contextのfetchを永続化状態の比較基準とする")
        XCTAssertEqual(unsavedOtherDayAfter, "unsaved-main-context-change", "別Workoutの未保存変更を保持する")
    }

    @MainActor
    func testConfirmedPartialSetDeletionIsScopedAndRollsBackOnlyItsCleanContext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeletePartialDelete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("PartialDelete", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: false, isRequired: false, sortOrder: 0)
        let targetSets = [1, 2].map { SetRecord(sortOrder: $0, values: [MetricValue(metric: metric, scaledValue: Int64($0 * 1000))]) }
        let exercise = Exercise(name: "対象種目", metrics: [metric])
        let targetRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: targetSets)
        let targetWorkout = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [targetRecord])
        let otherRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [])])
        let otherWorkout = Workout(day: Date(timeIntervalSince1970: 1_794_772_800), records: [otherRecord])
        context.insert(targetWorkout)
        context.insert(otherWorkout)
        try context.save()

        let valueDrafts = WorkoutValueEditing.drafts(for: targetWorkout)
        let baseDay = try XCTUnwrap(WorkoutValueEditing.date(from: targetWorkout.day))
        XCTAssertTrue(WorkoutValueEditing.deletionDraftsAreClean(valueDrafts, originalDrafts: valueDrafts, day: baseDay, originalDay: baseDay, additions: []))
        var editedDrafts = valueDrafts
        editedDrafts[0].text = "99"
        XCTAssertFalse(WorkoutValueEditing.deletionDraftsAreClean(editedDrafts, originalDrafts: valueDrafts, day: baseDay, originalDay: baseDay, additions: []), "未保存の数値draftを拒否")
        let changedDay = Calendar.current.date(byAdding: .day, value: -1, to: baseDay)!
        XCTAssertFalse(WorkoutValueEditing.deletionDraftsAreClean(valueDrafts, originalDrafts: valueDrafts, day: changedDay, originalDay: baseDay, additions: []), "未保存の日付draftを拒否")
        let addition = WorkoutSetAdditionDraft(id: UUID(), recordID: targetRecord.id, exerciseID: exercise.id, exerciseName: exercise.name, metrics: [], values: [:])
        XCTAssertFalse(WorkoutValueEditing.deletionDraftsAreClean(valueDrafts, originalDrafts: valueDrafts, day: baseDay, originalDay: baseDay, additions: [addition]), "未保存の追加draftを拒否")

        let target = WorkoutSetDeletionTarget(workout: targetWorkout, record: targetRecord, set: targetSets[0])
        targetWorkout.day = "unsaved synthetic change"
        XCTAssertThrowsError(try WorkoutSetDeletion.delete(target, in: context) { try context.save() })
        XCTAssertEqual(try context.fetch(FetchDescriptor<SetRecord>()).count, 3, "未保存contextでは何も削除しない")
        context.rollback()

        let cleanTarget = WorkoutSetDeletionTarget(workout: targetWorkout, record: targetRecord, set: targetSets[0])
        XCTAssertThrowsError(try WorkoutSetDeletion.delete(cleanTarget, in: context) { throw NSError(domain: "SyntheticSaveFailure", code: 1) })
        XCTAssertEqual(try context.fetch(FetchDescriptor<SetRecord>()).count, 3, "合成save失敗時に削除をrollback")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 2)

        let stale = WorkoutSetDeletionTarget(workout: targetWorkout, record: targetRecord, set: targetSets[0])
        targetRecord.sets.append(SetRecord(sortOrder: 3, values: []))
        try context.save()
        XCTAssertThrowsError(try WorkoutSetDeletion.delete(stale, in: context) { try context.save() }, "確認後の内容変更を拒否")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SetRecord>()).count, 4)

        let staleValueTarget = WorkoutSetDeletionTarget(workout: targetWorkout, record: targetRecord, set: targetSets[1])
        try XCTUnwrap(targetSets[1].values.first).scaledValue = 999_000
        try context.save()
        XCTAssertThrowsError(try WorkoutSetDeletion.delete(staleValueTarget, in: context) { try context.save() }, "確認後に値が変わったセットを拒否")
        try XCTUnwrap(targetSets[1].values.first).scaledValue = 2_000
        try context.save()

        let freshRecord = try XCTUnwrap(try context.fetch(FetchDescriptor<ExerciseRecord>()).first { $0.id == targetRecord.id })
        let freshWorkout = try XCTUnwrap(try context.fetch(FetchDescriptor<Workout>()).first { $0.id == targetWorkout.id })
        let middleTarget = WorkoutSetDeletionTarget(workout: freshWorkout, record: freshRecord, set: try XCTUnwrap(freshRecord.sets.first { $0.sortOrder == 2 }))
        try WorkoutSetDeletion.delete(middleTarget, in: context) { try context.save() }
        XCTAssertEqual(try context.fetch(FetchDescriptor<SetRecord>()).filter { $0.exerciseRecord?.id == freshRecord.id }.map(\.sortOrder).sorted(), [1, 3], "対象Workoutの選択セットだけ削除")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).map(\.id).sorted { $0.uuidString < $1.uuidString }.count, 2, "別Workoutを保持")

        let remainingSet = try XCTUnwrap(freshRecord.sets.first { $0.sortOrder == 3 })
        let removeRecord = WorkoutSetDeletionTarget(workout: freshWorkout, record: freshRecord, set: remainingSet)
        try WorkoutSetDeletion.delete(removeRecord, in: context) { try context.save() }
        let finalSet = try XCTUnwrap(freshRecord.sets.first { $0.sortOrder == 1 })
        let deleteLastSet = WorkoutSetDeletionTarget(workout: freshWorkout, record: freshRecord, set: finalSet)
        try WorkoutSetDeletion.delete(deleteLastSet, in: context) { try context.save() }
        XCTAssertFalse(try context.fetch(FetchDescriptor<ExerciseRecord>()).contains { $0.id == freshRecord.id }, "最後のセット削除で親の種目記録も削除")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 1, "空になるWorkoutは削除し、別Workoutは保持")

        let reopenedContainer = try ModelContainer(for: schema, configurations: [configuration])
        let reopened = ModelContext(reopenedContainer)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<Workout>()).count, 1, "再オープン後も別Workoutだけを保持")
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<ExerciseRecord>()).count, 1)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<SetRecord>()).count, 1)
    }

    @MainActor
    func testLastSetAndLastRecordDeletionRemoveEmptyWorkoutAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteCascadeDelete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("CascadeDelete", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: false, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let finalRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: 75_000)])])
        let finalWorkout = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [finalRecord])
        let otherRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: 50_000)])])
        let survivingWorkout = Workout(day: Date(timeIntervalSince1970: 1_794_772_800), records: [otherRecord])
        context.insert(finalWorkout)
        context.insert(survivingWorkout)
        try context.save()

        let setTarget = WorkoutSetDeletionTarget(workout: finalWorkout, record: finalRecord, set: try XCTUnwrap(finalRecord.sets.first))
        try WorkoutSetDeletion.delete(setTarget, in: context) { try context.save() }
        XCTAssertFalse(try context.fetch(FetchDescriptor<Workout>()).contains { $0.id == finalWorkout.id }, "最後のセット→record→Workoutをまとめて削除")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>()).contains { $0.id == survivingWorkout.id }, "別Workoutを維持")

        let companion = ExerciseRecord(exercise: exercise, sortOrder: 1, sets: [SetRecord(sortOrder: 1, values: [])])
        let sharedWorkout = Workout(day: Date(timeIntervalSince1970: 1_794_945_600), records: [
            ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: 3_000)])]), companion
        ])
        context.insert(sharedWorkout)
        try context.save()
        let onlySetRecord = try XCTUnwrap(sharedWorkout.records.first { $0.id != companion.id })
        try WorkoutSetDeletion.delete(WorkoutSetDeletionTarget(workout: sharedWorkout, record: onlySetRecord, set: try XCTUnwrap(onlySetRecord.sets.first)), in: context) { try context.save() }
        XCTAssertEqual(sharedWorkout.records.map(\.id), [companion.id], "最後のセット削除でも他recordがあればWorkoutを保持")

        let twoRecordsWorkout = Workout(day: Date(timeIntervalSince1970: 1_794_859_200), records: [
            ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: 1_000)])]),
            ExerciseRecord(exercise: exercise, sortOrder: 1, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: 2_000)])])
        ])
        context.insert(twoRecordsWorkout)
        try context.save()
        let first = try XCTUnwrap(twoRecordsWorkout.records.first)
        let firstRecordTarget = WorkoutRecordDeletionTarget(workout: twoRecordsWorkout, record: first)
        XCTAssertThrowsError(try WorkoutRecordDeletion.delete(firstRecordTarget, in: context) { throw NSError(domain: "SyntheticRecordSaveFailure", code: 1) }, "record削除のsave失敗を注入")
        XCTAssertTrue(context.hasChanges == false, "失敗後rollbackでcontextをcleanに戻す")
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExerciseRecord>()).filter { $0.workout?.id == twoRecordsWorkout.id }.count, 2, "失敗時に両recordを保持")
        try WorkoutRecordDeletion.delete(firstRecordTarget, in: context) { try context.save() }
        XCTAssertEqual(twoRecordsWorkout.records.count, 1, "非最後のrecordだけを削除")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>()).contains { $0.id == twoRecordsWorkout.id })

        let finalRemainingRecord = try XCTUnwrap(twoRecordsWorkout.records.first)
        let stale = WorkoutRecordDeletionTarget(workout: twoRecordsWorkout, record: finalRemainingRecord)
        finalRemainingRecord.sets[0].values[0].scaledValue = 99_000
        try context.save()
        XCTAssertThrowsError(try WorkoutRecordDeletion.delete(stale, in: context) { try context.save() }, "確認後に値が変わったrecordを拒否")
        let current = try XCTUnwrap(try context.fetch(FetchDescriptor<Workout>()).first { $0.id == twoRecordsWorkout.id })
        try WorkoutRecordDeletion.delete(WorkoutRecordDeletionTarget(workout: current, record: try XCTUnwrap(current.records.first)), in: context) { try context.save() }
        XCTAssertFalse(try context.fetch(FetchDescriptor<Workout>()).contains { $0.id == twoRecordsWorkout.id }, "最後のrecord削除でWorkoutも削除")

        let reopenedContainer = try ModelContainer(for: schema, configurations: [configuration])
        let reopened = ModelContext(reopenedContainer)
        XCTAssertEqual(Set(try reopened.fetch(FetchDescriptor<Workout>()).map(\.id)), [survivingWorkout.id, sharedWorkout.id], "再オープン後は保護対象Workoutのみ")
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<ExerciseRecord>()).count, 2)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<SetRecord>()).count, 2)
    }
}

@MainActor
final class WorkoutRecordDeletionV2PersistenceTests: XCTestCase {
    func testV2DeleteRecordRejectsRevisionLinkChangedAfterConfirmationAndPreservesSQLiteState() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2RecordDeletionLinkChange-\(UUID().uuidString).sqlite")
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteV2RecordDeletionLinkChange", schema: schema, url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let metric = MetricDefinition(name: "合成負荷", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let revision1 = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: 0)
        let revision2 = MetricDefinitionRevision(metricID: metric.id, revision: 2, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: 0)
        let value1 = MetricValue(metric: metric, scaledValue: 12_500)
        let value2 = MetricValue(metric: metric, scaledValue: 13_500)
        let targetRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [
            SetRecord(sortOrder: 1, values: [value1]),
            SetRecord(sortOrder: 2, values: [value2]),
        ])
        let targetWorkout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [targetRecord])
        let otherValue = MetricValue(metric: metric, scaledValue: 87_500)
        let otherRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [otherValue])])
        let otherWorkout = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [otherRecord])
        context.insert(exercise); context.insert(targetWorkout); context.insert(otherWorkout)
        context.insert(revision1); context.insert(revision2)
        let link1 = try MetricValueRevisionLinking.register(value: value1, revision: revision1, in: context)
        let link2 = try MetricValueRevisionLinking.register(value: value2, revision: revision1, in: context)
        let otherLink = try MetricValueRevisionLinking.register(value: otherValue, revision: revision1, in: context)
        try context.save()

        let service = WorkoutWritingServiceV2(context: context)
        let target = try service.captureRecordDeletionTarget(workout: targetWorkout, record: targetRecord)
        let changedLink = MetricValueRevisionLink(valueID: value1.id, revisionID: revision2.id)
        context.delete(link1)
        context.insert(changedLink)
        try context.save()

        XCTAssertThrowsError(try service.deleteRecord(target), "確認後にrecord内の履歴linkだけが変わった場合も削除確認をやり直す") { error in
            guard case WorkoutSetDeletionError.changed = error else { return XCTFail("changedとして拒否する必要: \(error)") }
        }

        let reopenedContainer = try ModelContainer(for: schema, configurations: [configuration])
        let reopened = ModelContext(reopenedContainer)
        let workouts = try reopened.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(Set(workouts.map(\.id)), [targetWorkout.id, otherWorkout.id])
        let savedRecord = try XCTUnwrap(workouts.first { $0.id == targetWorkout.id }?.records.first)
        XCTAssertEqual(Set(savedRecord.sets.map(\.id)), Set(targetRecord.sets.map(\.id)))
        let savedValues = try reopened.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(Set(savedValues.map(\.id)), [value1.id, value2.id, otherValue.id])
        XCTAssertEqual(
            savedValues.map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString },
            [value1, value2, otherValue].map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        )
        let savedLinks = try reopened.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(Set(savedLinks.map(\.id)), [changedLink.id, link2.id, otherLink.id])
        XCTAssertEqual(try XCTUnwrap(savedLinks.first { $0.valueID == value1.id }).revisionID, revision2.id)
        XCTAssertTrue(workouts.contains { $0.id == otherWorkout.id })
    }

    func testV2DeleteSetRejectsRevisionLinkOnlyChangeCapturedForConfirmation() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2SetDeletionLinkChange-\(UUID().uuidString).sqlite")
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteV2SetDeletionLinkChange", schema: schema, url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let metric = MetricDefinition(name: "合成負荷", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let revision1 = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: 0)
        let revision2 = MetricDefinitionRevision(metricID: metric.id, revision: 2, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: 0)
        let value = MetricValue(metric: metric, scaledValue: 12_500)
        let targetSet = SetRecord(sortOrder: 1, values: [value])
        let targetRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [targetSet])
        let targetWorkout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [targetRecord])
        let otherValue = MetricValue(metric: metric, scaledValue: 87_500)
        let otherSet = SetRecord(sortOrder: 1, values: [otherValue])
        let otherRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [otherSet])
        let otherWorkout = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [otherRecord])
        context.insert(exercise); context.insert(targetWorkout); context.insert(otherWorkout)
        context.insert(revision1); context.insert(revision2)
        let linkR1 = try MetricValueRevisionLinking.register(value: value, revision: revision1, in: context)
        let otherLink = try MetricValueRevisionLinking.register(value: otherValue, revision: revision1, in: context)
        try context.save()

        let service = WorkoutWritingServiceV2(context: context)
        let target = try service.captureSetDeletionTarget(workout: targetWorkout, record: targetRecord, set: targetSet)
        let linkR2 = MetricValueRevisionLink(valueID: value.id, revisionID: revision2.id)
        context.delete(linkR1)
        context.insert(linkR2)
        try context.save()

        XCTAssertThrowsError(try service.deleteSet(target), "確認後のrevision linkだけが変わった場合も削除確認をやり直す") { error in
            guard case WorkoutSetDeletionError.changed = error else { return XCTFail("changedとして拒否する必要: \(error)") }
        }

        let reopenedContainer = try ModelContainer(for: schema, configurations: [configuration])
        let reopened = ModelContext(reopenedContainer)
        let workouts = try reopened.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(Set(workouts.map(\.id)), [targetWorkout.id, otherWorkout.id])
        let savedTarget = try XCTUnwrap(workouts.first { $0.id == targetWorkout.id })
        XCTAssertEqual(savedTarget.records.first?.sets.map(\.id), [targetSet.id])
        let savedValues = try reopened.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(Set(savedValues.map(\.id)), [value.id, otherValue.id])
        XCTAssertEqual(try XCTUnwrap(savedValues.first { $0.id == value.id }).scaledValue, 12_500)
        XCTAssertEqual(Set(try reopened.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.id)), [linkR2.id, otherLink.id])
        XCTAssertEqual(try XCTUnwrap(try reopened.fetch(FetchDescriptor<MetricValueRevisionLink>()).first { $0.valueID == value.id }).revisionID, revision2.id)
    }

    func testV2DeleteSetRejectsLinkOnlyChangeSavedBySeparateContainer() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2SetDeletionSeparateContainerLinkChange-\(UUID().uuidString).sqlite")
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteV2SetDeletionSeparateContainerLinkChange", schema: schema, url: storeURL, cloudKitDatabase: .none)
        let containerA = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(containerA)

        let metric = MetricDefinition(name: "合成負荷", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let revision1 = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: 0)
        let revision2 = MetricDefinitionRevision(metricID: metric.id, revision: 2, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: 0)
        let targetValue = MetricValue(metric: metric, scaledValue: 12_500)
        let retainedValue = MetricValue(metric: metric, scaledValue: 8_500)
        let targetSet = SetRecord(sortOrder: 1, values: [targetValue])
        let retainedSet = SetRecord(sortOrder: 2, values: [retainedValue])
        let targetRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [targetSet, retainedSet])
        let targetWorkout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [targetRecord])
        let otherValue = MetricValue(metric: metric, scaledValue: 87_500)
        let otherRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [otherValue])])
        let otherWorkout = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [otherRecord])
        contextA.insert(exercise); contextA.insert(targetWorkout); contextA.insert(otherWorkout)
        contextA.insert(revision1); contextA.insert(revision2)
        let targetLinkR1 = try MetricValueRevisionLinking.register(value: targetValue, revision: revision1, in: contextA)
        let retainedLink = try MetricValueRevisionLinking.register(value: retainedValue, revision: revision1, in: contextA)
        let otherLink = try MetricValueRevisionLinking.register(value: otherValue, revision: revision1, in: contextA)
        try contextA.save()
        XCTAssertFalse(contextA.hasChanges, "capture前にAをcleanにする")

        let target = try WorkoutWritingServiceV2(context: contextA).captureSetDeletionTarget(workout: targetWorkout, record: targetRecord, set: targetSet)
        let targetWorkoutSnapshot = target.workoutRecords
        let valueSnapshotsBefore = [targetValue, retainedValue, otherValue].map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let oldLinkB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<MetricValueRevisionLink>()).first { $0.valueID == targetValue.id })
        contextB.delete(oldLinkB)
        let targetLinkR2 = MetricValueRevisionLink(valueID: targetValue.id, revisionID: revision2.id)
        contextB.insert(targetLinkR2)
        try contextB.save()
        XCTAssertFalse(contextB.hasChanges, "Bのlink差し替え保存後はclean")
        XCTAssertFalse(contextA.hasChanges, "Bの保存後もAはclean")

        XCTAssertThrowsError(try WorkoutWritingServiceV2(context: contextA).deleteSet(target), "別containerでlinkだけがR1からR2へ変われば削除を拒否") { error in
            guard case WorkoutSetDeletionError.changed = error else { return XCTFail("changedとして拒否する必要: \(error)") }
        }
        XCTAssertFalse(contextA.hasChanges, "拒否後もAはclean")

        let thirdContainer = try ModelContainer(for: schema, configurations: [configuration])
        let thirdContext = ModelContext(thirdContainer)
        let workouts = try thirdContext.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(Set(workouts.map(\.id)), [targetWorkout.id, otherWorkout.id])
        XCTAssertEqual(workouts.first { $0.id == targetWorkout.id }?.records.map(WorkoutRecordSnapshot.init), targetWorkoutSnapshot)
        XCTAssertEqual(try thirdContext.fetch(FetchDescriptor<ExerciseRecord>()).map(WorkoutRecordSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }, (targetWorkoutSnapshot + [WorkoutRecordSnapshot(otherRecord)]).sorted { $0.id.uuidString < $1.id.uuidString })
        XCTAssertEqual(try thirdContext.fetch(FetchDescriptor<SetRecord>()).map(WorkoutSetSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }, (targetWorkoutSnapshot.flatMap(\.sets) + [WorkoutSetSnapshot(otherRecord.sets[0])]).sorted { $0.id.uuidString < $1.id.uuidString })
        let savedValues = try thirdContext.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(savedValues.map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }, valueSnapshotsBefore)
        let savedRevisions = try thirdContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
        let savedR1 = try XCTUnwrap(savedRevisions.first { $0.id == revision1.id })
        let savedR2 = try XCTUnwrap(savedRevisions.first { $0.id == revision2.id })
        XCTAssertEqual(savedR1.metricID, savedR2.metricID)
        XCTAssertEqual(savedR1.name, savedR2.name)
        XCTAssertEqual(savedR1.unit, savedR2.unit)
        XCTAssertEqual(savedR1.allowsDecimal, savedR2.allowsDecimal)
        XCTAssertEqual(savedR1.isRequired, savedR2.isRequired)
        XCTAssertEqual(savedR1.sortOrder, savedR2.sortOrder)
        let savedLinks = try thirdContext.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(Set(savedLinks.map(\.id)), [targetLinkR2.id, retainedLink.id, otherLink.id])
        XCTAssertEqual(try XCTUnwrap(savedLinks.first { $0.valueID == targetValue.id }).revisionID, savedR2.id)
        XCTAssertEqual(try XCTUnwrap(savedLinks.first { $0.valueID == retainedValue.id }).revisionID, savedR1.id)
        XCTAssertEqual(try XCTUnwrap(savedLinks.first { $0.valueID == otherValue.id }).revisionID, savedR1.id)
        XCTAssertNotEqual(targetLinkR1.id, targetLinkR2.id)
    }

    func testV2DeleteRecordRejectsLinkOnlyChangeSavedBySeparateContainer() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2RecordDeletionSeparateContainerLinkChange-\(UUID().uuidString).sqlite")
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteV2RecordDeletionSeparateContainerLinkChange", schema: schema, url: storeURL, cloudKitDatabase: .none)
        let containerA = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(containerA)

        let metric = MetricDefinition(name: "合成負荷", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let revision1 = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: false, sortOrder: 0)
        let revision2 = MetricDefinitionRevision(metricID: metric.id, revision: 2, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: false, sortOrder: 0)
        let valueA = MetricValue(metric: metric, scaledValue: 12_500)
        let valueB = MetricValue(metric: metric, scaledValue: 13_500)
        let targetRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [
            SetRecord(sortOrder: 1, values: [valueA]), SetRecord(sortOrder: 2, values: [valueB]),
        ])
        let targetWorkout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [targetRecord])
        let otherValue = MetricValue(metric: metric, scaledValue: 87_500)
        let otherRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [otherValue])])
        let otherWorkout = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [otherRecord])
        contextA.insert(exercise); contextA.insert(targetWorkout); contextA.insert(otherWorkout)
        contextA.insert(revision1); contextA.insert(revision2)
        let linkAR1 = try MetricValueRevisionLinking.register(value: valueA, revision: revision1, in: contextA)
        let linkB = try MetricValueRevisionLinking.register(value: valueB, revision: revision1, in: contextA)
        let otherLink = try MetricValueRevisionLinking.register(value: otherValue, revision: revision1, in: contextA)
        try contextA.save()
        XCTAssertFalse(contextA.hasChanges, "capture前にAをcleanにする")

        let target = try WorkoutWritingServiceV2(context: contextA).captureRecordDeletionTarget(workout: targetWorkout, record: targetRecord)
        let workoutRecordsBefore = target.workoutRecords
        let valueSnapshotsBefore = [valueA, valueB, otherValue].map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let oldLinkB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<MetricValueRevisionLink>()).first { $0.valueID == valueA.id })
        contextB.delete(oldLinkB)
        let linkAR2 = MetricValueRevisionLink(valueID: valueA.id, revisionID: revision2.id)
        contextB.insert(linkAR2)
        try contextB.save()
        XCTAssertFalse(contextB.hasChanges, "Bのlink差し替え保存後はclean")
        XCTAssertFalse(contextA.hasChanges, "Bの保存後もAはclean")

        XCTAssertThrowsError(try WorkoutWritingServiceV2(context: contextA).deleteRecord(target), "別containerでrecord内のlinkだけがR1からR2へ変われば削除を拒否") { error in
            guard case WorkoutSetDeletionError.changed = error else { return XCTFail("changedとして拒否する必要: \(error)") }
        }
        XCTAssertFalse(contextA.hasChanges, "拒否後もAはclean")

        let thirdContainer = try ModelContainer(for: schema, configurations: [configuration])
        let thirdContext = ModelContext(thirdContainer)
        let workouts = try thirdContext.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(Set(workouts.map(\.id)), [targetWorkout.id, otherWorkout.id])
        XCTAssertEqual(workouts.first { $0.id == targetWorkout.id }?.records.map(WorkoutRecordSnapshot.init), workoutRecordsBefore)
        XCTAssertEqual(try thirdContext.fetch(FetchDescriptor<ExerciseRecord>()).map(WorkoutRecordSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }, (workoutRecordsBefore + [WorkoutRecordSnapshot(otherRecord)]).sorted { $0.id.uuidString < $1.id.uuidString })
        XCTAssertEqual(try thirdContext.fetch(FetchDescriptor<SetRecord>()).map(WorkoutSetSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }, (workoutRecordsBefore.flatMap(\.sets) + [WorkoutSetSnapshot(otherRecord.sets[0])]).sorted { $0.id.uuidString < $1.id.uuidString })
        let savedValues = try thirdContext.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(savedValues.map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }, valueSnapshotsBefore)
        let savedRevisions = try thirdContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
        let savedR1 = try XCTUnwrap(savedRevisions.first { $0.id == revision1.id })
        let savedR2 = try XCTUnwrap(savedRevisions.first { $0.id == revision2.id })
        XCTAssertEqual(savedR1.metricID, savedR2.metricID)
        XCTAssertEqual(savedR1.name, savedR2.name)
        XCTAssertEqual(savedR1.unit, savedR2.unit)
        XCTAssertEqual(savedR1.allowsDecimal, savedR2.allowsDecimal)
        XCTAssertEqual(savedR1.isRequired, savedR2.isRequired)
        XCTAssertEqual(savedR1.sortOrder, savedR2.sortOrder)
        let savedLinks = try thirdContext.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(Set(savedLinks.map(\.id)), [linkAR2.id, linkB.id, otherLink.id])
        XCTAssertEqual(try XCTUnwrap(savedLinks.first { $0.valueID == valueA.id }).revisionID, savedR2.id)
        XCTAssertEqual(try XCTUnwrap(savedLinks.first { $0.valueID == valueB.id }).revisionID, savedR1.id)
        XCTAssertEqual(try XCTUnwrap(savedLinks.first { $0.valueID == otherValue.id }).revisionID, savedR1.id)
        XCTAssertNotEqual(linkAR1.id, linkAR2.id)
    }

    func testV2DeleteLastSetThroughServicePersistsEmptyRecordAndWorkoutCascadeInSQLite() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2LastSetDeletionPersistence-\(UUID().uuidString).sqlite")
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteV2LastSetDeletionPersistence", schema: schema, url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let metric = MetricDefinition(name: "合成負荷", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let revision = MetricDefinitionRevision(metricID: metric.id, revision: 4, name: "合成負荷", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let targetValue = MetricValue(metric: metric, scaledValue: 12_500)
        let targetSet = SetRecord(sortOrder: 1, values: [targetValue])
        let targetRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [targetSet])
        let targetWorkout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [targetRecord])
        let otherValue = MetricValue(metric: metric, scaledValue: 87_500)
        let otherSet = SetRecord(sortOrder: 1, values: [otherValue])
        let otherRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [otherSet])
        let otherWorkout = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [otherRecord])
        context.insert(exercise); context.insert(targetWorkout); context.insert(otherWorkout); context.insert(revision)
        let targetLink = try MetricValueRevisionLinking.register(value: targetValue, revision: revision, in: context)
        let otherLink = try MetricValueRevisionLinking.register(value: otherValue, revision: revision, in: context)
        try context.save()
        XCTAssertFalse(context.hasChanges, "削除確認前に合成fixtureを保存しcontextをcleanにする")

        let targetWorkoutID = targetWorkout.id
        let targetRecordID = targetRecord.id
        let targetSetID = targetSet.id
        let targetValueID = targetValue.id
        let targetLinkID = targetLink.id
        let otherWorkoutID = otherWorkout.id
        let otherRecordID = otherRecord.id
        let otherSetID = otherSet.id
        let otherValueID = otherValue.id
        let otherLinkID = otherLink.id
        let revisionID = revision.id

        let deletionService = WorkoutWritingServiceV2(context: context)
        let deletionTarget = try deletionService.captureSetDeletionTarget(workout: targetWorkout, record: targetRecord, set: targetSet)
        try deletionService.deleteSet(deletionTarget)

        let reopenedContainer = try ModelContainer(for: schema, configurations: [configuration])
        let reopened = ModelContext(reopenedContainer)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<Workout>()).map(\.id), [otherWorkoutID], "空になる対象Workoutを削除し、別Workoutを保持")
        XCTAssertFalse(try reopened.fetch(FetchDescriptor<Workout>()).contains { $0.id == targetWorkoutID })
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<ExerciseRecord>()).map(\.id), [otherRecordID], "最後のsetとともに空recordを削除")
        XCTAssertFalse(try reopened.fetch(FetchDescriptor<ExerciseRecord>()).contains { $0.id == targetRecordID })
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<SetRecord>()).map(\.id), [otherSetID])
        XCTAssertFalse(try reopened.fetch(FetchDescriptor<SetRecord>()).contains { $0.id == targetSetID })

        let persistedValues = try reopened.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(persistedValues.map(\.id), [otherValueID])
        XCTAssertFalse(persistedValues.contains { $0.id == targetValueID })
        let persistedOtherValue = try XCTUnwrap(persistedValues.first)
        XCTAssertEqual(persistedOtherValue.metricID, metric.id)
        XCTAssertEqual(persistedOtherValue.name, "合成負荷")
        XCTAssertEqual(persistedOtherValue.unit, "kg")
        XCTAssertTrue(persistedOtherValue.allowsDecimal)
        XCTAssertFalse(persistedOtherValue.isRequired)
        XCTAssertEqual(persistedOtherValue.scaledValue, 87_500)
        let persistedLinks = try reopened.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(persistedLinks.map(\.id), [otherLinkID])
        XCTAssertEqual(persistedLinks.map(\.valueID), [otherValueID])
        XCTAssertEqual(persistedLinks.map(\.revisionID), [revisionID])
        XCTAssertFalse(persistedLinks.contains { $0.id == targetLinkID || $0.valueID == targetValueID })
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [revisionID], "共有revisionを保持")
    }

    func testV2DeleteRecordThroughServicePersistsPartialAndLastRecordCascadesInSQLite() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2RecordDeletionPersistence-\(UUID().uuidString).sqlite")
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteV2RecordDeletionPersistence", schema: schema, url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let metricA = MetricDefinition(name: "負荷A", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let metricB = MetricDefinition(name: "負荷B", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exerciseA = Exercise(name: "合成種目A", metrics: [metricA])
        let exerciseB = Exercise(name: "合成種目B", metrics: [metricB])
        let revisionA = MetricDefinitionRevision(metricID: metricA.id, revision: 3, name: "負荷A", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let revisionB = MetricDefinitionRevision(metricID: metricB.id, revision: 1, name: "負荷B", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)

        func makeSet(_ order: Int, _ amount: Int64, metric: MetricDefinition) -> SetRecord {
            SetRecord(sortOrder: order, values: [MetricValue(metric: metric, scaledValue: amount)])
        }
        let removedRecord = ExerciseRecord(exercise: exerciseA, sortOrder: 0, sets: [makeSet(1, 11_000, metric: metricA), makeSet(2, 12_000, metric: metricA)])
        let retainedRecord = ExerciseRecord(exercise: exerciseB, sortOrder: 1, sets: [makeSet(1, 8_000, metric: metricB), makeSet(2, 9_000, metric: metricB)])
        let targetWorkout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [removedRecord, retainedRecord])
        let otherRecord = ExerciseRecord(exercise: exerciseA, sortOrder: 0, sets: [makeSet(1, 20_000, metric: metricA), makeSet(2, 21_000, metric: metricA)])
        let otherWorkout = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [otherRecord])
        context.insert(exerciseA)
        context.insert(exerciseB)
        context.insert(targetWorkout); context.insert(otherWorkout); context.insert(revisionA); context.insert(revisionB)

        let targetWorkoutID = targetWorkout.id
        let retainedRecordID = retainedRecord.id
        let otherWorkoutID = otherWorkout.id
        let otherRecordID = otherRecord.id
        let removedSetIDs = Set(removedRecord.sets.map(\.id))
        let retainedSetIDs = Set(retainedRecord.sets.map(\.id))
        let otherSetIDs = Set(otherRecord.sets.map(\.id))
        let removedValues = removedRecord.sets.flatMap(\.values)
        let retainedValues = retainedRecord.sets.flatMap(\.values)
        let otherValues = otherRecord.sets.flatMap(\.values)
        for value in removedValues + otherValues { _ = try MetricValueRevisionLinking.register(value: value, revision: revisionA, in: context) }
        for value in retainedValues { _ = try MetricValueRevisionLinking.register(value: value, revision: revisionB, in: context) }
        try context.save()

        let removedValueIDs = Set(removedValues.map(\.id))
        let retainedSnapshots = retainedValues.map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        let otherSnapshots = otherValues.map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        let linkIDsByValue = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).map { ($0.valueID, $0.id) })
        let revisionIDs = Set([revisionA.id, revisionB.id])

        let service = WorkoutWritingServiceV2(context: context)
        let removedTarget = try service.captureRecordDeletionTarget(workout: targetWorkout, record: removedRecord)
        try service.deleteRecord(removedTarget)

        let afterPartialContainer = try ModelContainer(for: schema, configurations: [configuration])
        let afterPartial = ModelContext(afterPartialContainer)
        let partialWorkouts = try afterPartial.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(Set(partialWorkouts.map(\.id)), Set([targetWorkoutID, otherWorkoutID]))
        let partialTarget = try XCTUnwrap(partialWorkouts.first { $0.id == targetWorkoutID })
        XCTAssertEqual(partialTarget.records.map(\.id), [retainedRecordID])
        XCTAssertEqual(Set(try afterPartial.fetch(FetchDescriptor<ExerciseRecord>()).map(\.id)), Set([retainedRecordID, otherRecordID]))
        XCTAssertEqual(Set(try afterPartial.fetch(FetchDescriptor<SetRecord>()).map(\.id)), retainedSetIDs.union(otherSetIDs))
        let partialValues = try afterPartial.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(Set(partialValues.map(\.id)), Set(retainedValues.map(\.id) + otherValues.map(\.id)))
        XCTAssertEqual(partialValues.map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }, (retainedSnapshots + otherSnapshots).sorted { $0.id.uuidString < $1.id.uuidString })
        let partialLinks = try afterPartial.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(Set(partialLinks.map(\.id)), Set(retainedValues.map { linkIDsByValue[$0.id]! } + otherValues.map { linkIDsByValue[$0.id]! }))
        XCTAssertFalse(partialLinks.contains { removedValueIDs.contains($0.valueID) })
        XCTAssertEqual(Set(try afterPartial.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id)), revisionIDs)

        let lastTarget = try XCTUnwrap(partialTarget.records.first { $0.id == retainedRecordID })
        let lastDeletionTarget = try WorkoutWritingServiceV2(context: afterPartial).captureRecordDeletionTarget(workout: partialTarget, record: lastTarget)
        try WorkoutWritingServiceV2(context: afterPartial).deleteRecord(lastDeletionTarget)

        let afterLastContainer = try ModelContainer(for: schema, configurations: [configuration])
        let afterLast = ModelContext(afterLastContainer)
        XCTAssertEqual(try afterLast.fetch(FetchDescriptor<Workout>()).map(\.id), [otherWorkoutID])
        XCTAssertEqual(try afterLast.fetch(FetchDescriptor<ExerciseRecord>()).map(\.id), [otherRecordID])
        XCTAssertEqual(Set(try afterLast.fetch(FetchDescriptor<SetRecord>()).map(\.id)), otherSetIDs)
        XCTAssertEqual(try afterLast.fetch(FetchDescriptor<MetricValue>()).map(\.id).sorted { $0.uuidString < $1.uuidString }, otherValues.map(\.id).sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(try afterLast.fetch(FetchDescriptor<MetricValue>()).map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }, otherSnapshots)
        XCTAssertEqual(Set(try afterLast.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.id)), Set(otherValues.map { linkIDsByValue[$0.id]! }))
        XCTAssertEqual(Set(try afterLast.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id)), revisionIDs)
        XCTAssertFalse(try afterLast.fetch(FetchDescriptor<Workout>()).contains { $0.id == targetWorkoutID })
        XCTAssertTrue(removedSetIDs.isDisjoint(with: Set(try afterLast.fetch(FetchDescriptor<SetRecord>()).map(\.id))))
    }

    func testV2DeleteSetRejectsValueChangedAndSavedBySeparateContainer() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2SetDeletionCrossContext-\(UUID().uuidString).sqlite")
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteV2SetDeletionCrossContext", schema: schema, url: storeURL, cloudKitDatabase: .none)
        let containerA = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(containerA)

        let metric = MetricDefinition(name: "合成負荷", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let revision = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: metric.sortOrder)
        let targetValue = MetricValue(metric: metric, scaledValue: 10_000)
        let retainedValue = MetricValue(metric: metric, scaledValue: 20_000)
        let otherValue = MetricValue(metric: metric, scaledValue: 30_000)
        let targetSet = SetRecord(sortOrder: 1, values: [targetValue])
        let retainedSet = SetRecord(sortOrder: 2, values: [retainedValue])
        let targetRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [targetSet, retainedSet])
        let otherRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [otherValue])])
        let targetWorkout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [targetRecord])
        let otherWorkout = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [otherRecord])
        contextA.insert(exercise); contextA.insert(targetWorkout); contextA.insert(otherWorkout); contextA.insert(revision)
        let targetLink = try MetricValueRevisionLinking.register(value: targetValue, revision: revision, in: contextA)
        let retainedLink = try MetricValueRevisionLinking.register(value: retainedValue, revision: revision, in: contextA)
        let otherLink = try MetricValueRevisionLinking.register(value: otherValue, revision: revision, in: contextA)
        try contextA.save()
        XCTAssertFalse(contextA.hasChanges)

        let service = WorkoutWritingServiceV2(context: contextA)
        let target = try service.captureSetDeletionTarget(workout: targetWorkout, record: targetRecord, set: targetSet)
        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let valueID = targetValue.id
        let valueB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<MetricValue>()).first { $0.id == valueID })
        valueB.scaledValue = 11_000
        try contextB.save()
        XCTAssertFalse(contextB.hasChanges, "Bの更新を保存した後はclean")

        XCTAssertFalse(contextA.hasChanges, "Bの保存が終わるまでAの確認対象に変更を加えない")
        XCTAssertThrowsError(try WorkoutWritingServiceV2(context: contextA).deleteSet(target), "別containerで値が更新された古い削除確認を拒否") { error in
            guard case WorkoutSetDeletionError.changed = error else { return XCTFail("changedとして拒否する必要: \(error)") }
        }

        let containerC = try ModelContainer(for: schema, configurations: [configuration])
        let contextC = ModelContext(containerC)
        let savedWorkout = try XCTUnwrap(try contextC.fetch(FetchDescriptor<Workout>()).first { $0.id == targetWorkout.id })
        XCTAssertEqual(savedWorkout.records.first?.sets.map(\.id).sorted { $0.uuidString < $1.uuidString }, [targetSet.id, retainedSet.id].sorted { $0.uuidString < $1.uuidString })
        let savedValues = try contextC.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(Set(savedValues.map(\.id)), [targetValue.id, retainedValue.id, otherValue.id])
        XCTAssertEqual(try XCTUnwrap(savedValues.first { $0.id == targetValue.id }).scaledValue, 11_000)
        XCTAssertEqual(try XCTUnwrap(savedValues.first { $0.id == retainedValue.id }).scaledValue, 20_000)
        XCTAssertEqual(try XCTUnwrap(savedValues.first { $0.id == otherValue.id }).scaledValue, 30_000)
        XCTAssertEqual(savedValues.map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id), [targetValue, retainedValue, otherValue].map(\.id).sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(Set(try contextC.fetch(FetchDescriptor<ExerciseRecord>()).map(\.id)), [targetRecord.id, otherRecord.id])
        XCTAssertEqual(Set(try contextC.fetch(FetchDescriptor<SetRecord>()).map(\.id)), [targetSet.id, retainedSet.id, otherRecord.sets[0].id])
        XCTAssertEqual(Set(try contextC.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.id)), [targetLink.id, retainedLink.id, otherLink.id])
        XCTAssertTrue(try contextC.fetch(FetchDescriptor<Workout>()).contains { $0.id == otherWorkout.id })
        XCTAssertEqual(try XCTUnwrap(try contextC.fetch(FetchDescriptor<MetricValue>()).first { $0.id == otherValue.id }).scaledValue, 30_000)
    }

    func testV2DeleteRecordRejectsSetAddedAndSavedBySeparateContainer() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2RecordDeletionCrossContext-\(UUID().uuidString).sqlite")
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteV2RecordDeletionCrossContext", schema: schema, url: storeURL, cloudKitDatabase: .none)
        let containerA = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(containerA)

        let metric = MetricDefinition(name: "合成負荷", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let revision = MetricDefinitionRevision(metricID: metric.id, revision: 2, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: 0)
        let originalValue = MetricValue(metric: metric, scaledValue: 10_000)
        let originalSet = SetRecord(sortOrder: 1, values: [originalValue])
        let targetRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [originalSet])
        let otherValue = MetricValue(metric: metric, scaledValue: 30_000)
        let otherRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [otherValue])])
        let targetWorkout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [targetRecord])
        let otherWorkout = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [otherRecord])
        contextA.insert(exercise); contextA.insert(targetWorkout); contextA.insert(otherWorkout); contextA.insert(revision)
        let originalLink = try MetricValueRevisionLinking.register(value: originalValue, revision: revision, in: contextA)
        let otherLink = try MetricValueRevisionLinking.register(value: otherValue, revision: revision, in: contextA)
        try contextA.save()
        XCTAssertFalse(contextA.hasChanges)

        let target = try WorkoutWritingServiceV2(context: contextA).captureRecordDeletionTarget(workout: targetWorkout, record: targetRecord)
        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let recordID = targetRecord.id
        let recordB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<ExerciseRecord>()).first { $0.id == recordID })
        let metricB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<MetricDefinition>()).first { $0.id == metric.id })
        let addedValue = MetricValue(metric: metricB, scaledValue: 15_000)
        let addedSet = SetRecord(sortOrder: 2, values: [addedValue])
        recordB.sets.append(addedSet)
        let addedLink = try MetricValueRevisionLinking.register(value: addedValue, revision: try XCTUnwrap(try contextB.fetch(FetchDescriptor<MetricDefinitionRevision>()).first { $0.id == revision.id }), in: contextB)
        try contextB.save()
        XCTAssertFalse(contextB.hasChanges, "Bのset/value/link追加を保存した後はclean")

        XCTAssertFalse(contextA.hasChanges, "Bの保存が終わるまでAの確認対象に変更を加えない")
        XCTAssertThrowsError(try WorkoutWritingServiceV2(context: contextA).deleteRecord(target), "別containerでsetが追加された古い削除確認を拒否") { error in
            guard case WorkoutSetDeletionError.changed = error else { return XCTFail("changedとして拒否する必要: \(error)") }
        }

        let containerC = try ModelContainer(for: schema, configurations: [configuration])
        let contextC = ModelContext(containerC)
        let savedWorkout = try XCTUnwrap(try contextC.fetch(FetchDescriptor<Workout>()).first { $0.id == targetWorkout.id })
        XCTAssertEqual(Set(savedWorkout.records.first?.sets.map(\.id) ?? []), [originalSet.id, addedSet.id])
        XCTAssertEqual(Set(try contextC.fetch(FetchDescriptor<ExerciseRecord>()).map(\.id)), [targetRecord.id, otherRecord.id])
        XCTAssertEqual(Set(try contextC.fetch(FetchDescriptor<SetRecord>()).map(\.id)), [originalSet.id, addedSet.id, otherRecord.sets[0].id])
        let savedValues = try contextC.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(Set(savedValues.map(\.id)), [originalValue.id, addedValue.id, otherValue.id])
        XCTAssertEqual(savedValues.map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }, [originalValue, addedValue, otherValue].map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString })
        XCTAssertEqual(Set(try contextC.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.id)), [originalLink.id, otherLink.id, addedLink.id])
        XCTAssertEqual(try XCTUnwrap(savedValues.first { $0.id == addedValue.id }).scaledValue, 15_000)
        XCTAssertEqual(try XCTUnwrap(savedValues.first { $0.id == otherValue.id }).scaledValue, 30_000)
        XCTAssertTrue(try contextC.fetch(FetchDescriptor<Workout>()).contains { $0.id == otherWorkout.id })
    }
}

// 移行実験専用モデル。実運用のMeleteSchemaV1と同名の永続モデル名を使わず、
// 実運用スキーマやfixtureを変更せずにSwiftDataの移行機構を隔離して調べる。
enum RevisionSpikeSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Exercise.self, Record.self, SetEntry.self, Value.self] }

    @Model final class Exercise {
        var id: UUID
        var name: String
        @Relationship(deleteRule: .cascade, inverse: \Record.exercise) var records: [Record]
        init(id: UUID, name: String, records: [Record] = []) { self.id = id; self.name = name; self.records = records }
    }
    @Model final class Record {
        var id: UUID
        var exerciseName: String
        var sortOrder: Int
        var day: Date
        var exercise: Exercise?
        @Relationship(deleteRule: .cascade, inverse: \SetEntry.record) var sets: [SetEntry]
        init(id: UUID, exerciseName: String, sortOrder: Int, day: Date, sets: [SetEntry] = []) {
            self.id = id; self.exerciseName = exerciseName; self.sortOrder = sortOrder; self.day = day; self.sets = sets
        }
    }
    @Model final class SetEntry {
        var id: UUID
        var sortOrder: Int
        var createdAt: Date
        var record: Record?
        @Relationship(deleteRule: .cascade, inverse: \Value.set) var values: [Value]
        init(id: UUID, sortOrder: Int, createdAt: Date, values: [Value] = []) {
            self.id = id; self.sortOrder = sortOrder; self.createdAt = createdAt; self.values = values
        }
    }
    @Model final class Value {
        var id: UUID
        var metricID: UUID
        var name: String
        var unit: String
        var allowsDecimal: Bool
        var isRequired: Bool
        var scaledValue: Int64?
        var set: SetEntry?
        init(id: UUID, metricID: UUID, name: String, unit: String, allowsDecimal: Bool, isRequired: Bool, scaledValue: Int64?) {
            self.id = id; self.metricID = metricID; self.name = name; self.unit = unit
            self.allowsDecimal = allowsDecimal; self.isRequired = isRequired; self.scaledValue = scaledValue
        }
    }
}

enum RevisionSpikeSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Exercise.self, Record.self, SetEntry.self, Value.self] }

    @Model final class Exercise {
        var id: UUID
        var name: String
        @Relationship(deleteRule: .cascade, inverse: \Record.exercise) var records: [Record]
        init(id: UUID, name: String, records: [Record] = []) { self.id = id; self.name = name; self.records = records }
    }
    @Model final class Record {
        var id: UUID
        var exerciseName: String
        var sortOrder: Int
        var day: Date
        var exercise: Exercise?
        @Relationship(deleteRule: .cascade, inverse: \SetEntry.record) var sets: [SetEntry]
        init(id: UUID, exerciseName: String, sortOrder: Int, day: Date, sets: [SetEntry] = []) {
            self.id = id; self.exerciseName = exerciseName; self.sortOrder = sortOrder; self.day = day; self.sets = sets
        }
    }
    @Model final class SetEntry {
        var id: UUID
        var sortOrder: Int
        var createdAt: Date
        var record: Record?
        @Relationship(deleteRule: .cascade, inverse: \Value.set) var values: [Value]
        init(id: UUID, sortOrder: Int, createdAt: Date, values: [Value] = []) {
            self.id = id; self.sortOrder = sortOrder; self.createdAt = createdAt; self.values = values
        }
    }
    @Model final class Value {
        var id: UUID
        var metricID: UUID
        var name: String
        var unit: String
        var allowsDecimal: Bool
        var isRequired: Bool
        var scaledValue: Int64?
        var revisionID: UUID?
        var set: SetEntry?
        init(id: UUID, metricID: UUID, name: String, unit: String, allowsDecimal: Bool, isRequired: Bool, scaledValue: Int64?, revisionID: UUID? = nil) {
            self.id = id; self.metricID = metricID; self.name = name; self.unit = unit
            self.allowsDecimal = allowsDecimal; self.isRequired = isRequired; self.scaledValue = scaledValue; self.revisionID = revisionID
        }
    }
}

enum RevisionSpikeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [RevisionSpikeSchemaV1.self, RevisionSpikeSchemaV2.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: RevisionSpikeSchemaV1.self, toVersion: RevisionSpikeSchemaV2.self)] }
}

extension MeleteTests {
    func testRevisionSpikeMigratesSyntheticV1StoreToV2() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteRevisionSpike-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let storeURL = directory.appendingPathComponent("revision-spike.store")
        let v1Schema = Schema(versionedSchema: RevisionSpikeSchemaV1.self)
        let v2Schema = Schema(versionedSchema: RevisionSpikeSchemaV2.self)
        let v1Configuration = ModelConfiguration("RevisionSpike", schema: v1Schema, url: storeURL, cloudKitDatabase: .none)
        let v2Configuration = ModelConfiguration("RevisionSpike", schema: v2Schema, url: storeURL, cloudKitDatabase: .none)

        let exerciseID = UUID(), recordID = UUID(), setID = UUID()
        let metricIDs = [UUID(), UUID()]
        let valueIDs = [UUID(), UUID()]
        let day = Date(timeIntervalSince1970: 1_700_000_000.125)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_123.25)
        do {
            let container = try ModelContainer(for: v1Schema, configurations: [v1Configuration])
            let context = ModelContext(container)
            let values = [
                RevisionSpikeSchemaV1.Value(id: valueIDs[0], metricID: metricIDs[0], name: "旧snapshot名", unit: "kg", allowsDecimal: true, isRequired: false, scaledValue: nil),
                RevisionSpikeSchemaV1.Value(id: valueIDs[1], metricID: metricIDs[1], name: "重量", unit: "lb", allowsDecimal: false, isRequired: true, scaledValue: 0)
            ]
            let set = RevisionSpikeSchemaV1.SetEntry(id: setID, sortOrder: 7, createdAt: createdAt, values: values)
            let record = RevisionSpikeSchemaV1.Record(id: recordID, exerciseName: "記録時の種目名", sortOrder: 3, day: day, sets: [set])
            let exercise = RevisionSpikeSchemaV1.Exercise(id: exerciseID, name: "現在の種目名", records: [record])
            context.insert(exercise)
            try context.save()
        }

        let migrated = try ModelContainer(for: v2Schema, migrationPlan: RevisionSpikeMigrationPlan.self, configurations: [v2Configuration])
        let context = ModelContext(migrated)
        let exercises = try context.fetch(FetchDescriptor<RevisionSpikeSchemaV2.Exercise>())
        let exercise = try XCTUnwrap(exercises.first { $0.id == exerciseID })
        XCTAssertEqual(exercises.count, 1)
        XCTAssertEqual(exercise.name, "現在の種目名")
        let record = try XCTUnwrap(exercise.records.first)
        XCTAssertEqual(record.id, recordID)
        XCTAssertEqual(record.exercise, exercise)
        XCTAssertEqual(record.exerciseName, "記録時の種目名")
        XCTAssertEqual(record.sortOrder, 3)
        XCTAssertEqual(record.day, day)
        let set = try XCTUnwrap(record.sets.first)
        XCTAssertEqual(set.id, setID)
        XCTAssertEqual(set.record, record)
        XCTAssertEqual(set.sortOrder, 7)
        XCTAssertEqual(set.createdAt, createdAt)
        XCTAssertEqual(Set(set.values.map(\.id)), Set(valueIDs))
        for (id, metricID, name, unit, decimal, required, value) in [
            (valueIDs[0], metricIDs[0], "旧snapshot名", "kg", true, false, nil as Int64?),
            (valueIDs[1], metricIDs[1], "重量", "lb", false, true, 0 as Int64?)
        ] {
            let saved = try XCTUnwrap(set.values.first { $0.id == id })
            XCTAssertEqual(saved.set, set)
            XCTAssertEqual(saved.metricID, metricID)
            XCTAssertEqual(saved.name, name)
            XCTAssertEqual(saved.unit, unit)
            XCTAssertEqual(saved.allowsDecimal, decimal)
            XCTAssertEqual(saved.isRequired, required)
            XCTAssertEqual(saved.scaledValue, value)
            XCTAssertNil(saved.revisionID, "V1のsnapshotからrevisionを推定しない")
        }

        let reopened = try ModelContainer(for: v2Schema, migrationPlan: RevisionSpikeMigrationPlan.self, configurations: [v2Configuration])
        let reopenedContext = ModelContext(reopened)
        let reopenedValue = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<RevisionSpikeSchemaV2.Value>()).first { $0.id == valueIDs[0] })
        XCTAssertNil(reopenedValue.revisionID, "再open後もlegacy分類のnilを保持")
        XCTAssertEqual(reopenedValue.name, "旧snapshot名")
        XCTAssertEqual(reopenedValue.unit, "kg")
        XCTAssertNil(reopenedValue.scaledValue)
    }

    func testMetricRevisionTransitionSeparatesHistoryFromSeriesIdentity() {
        let originalSeriesID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let renamedSeriesID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let revisionID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let restoredNameSeriesID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        let original = MetricRevisionSnapshot(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false)

        let renamed = MetricRevisionTransitionDecision.decide(MetricRevisionTransitionInput(
            current: original,
            proposed: MetricRevisionSnapshot(name: "重量", unit: "lb", allowsDecimal: true, isRequired: false),
            currentSeriesID: originalSeriesID,
            proposedRevisionID: revisionID,
            proposedSeriesID: renamedSeriesID
        ))
        XCTAssertEqual(renamed.kind, .nameOrUnitChanged)
        XCTAssertEqual(renamed.seriesID, renamedSeriesID, "名称／単位変更は新しい系列を使う")
        XCTAssertEqual(renamed.revisionID, revisionID, "履歴IDは系列IDと独立して割り当てる")
        XCTAssertNotEqual(renamed.seriesID, originalSeriesID)
        XCTAssertNotEqual(renamed.revisionID, renamed.seriesID)

        let conditionsOnly = MetricRevisionTransitionDecision.decide(MetricRevisionTransitionInput(
            current: original,
            proposed: MetricRevisionSnapshot(name: "重量", unit: "kg", allowsDecimal: false, isRequired: true),
            currentSeriesID: originalSeriesID,
            proposedRevisionID: revisionID,
            proposedSeriesID: renamedSeriesID
        ))
        XCTAssertEqual(conditionsOnly.kind, .inputConditionsChanged)
        XCTAssertEqual(conditionsOnly.seriesID, originalSeriesID, "入力条件のみの変更では系列を維持する")
        XCTAssertEqual(conditionsOnly.revisionID, revisionID, "入力条件変更には別revisionが必要")

        let unchanged = MetricRevisionTransitionDecision.decide(MetricRevisionTransitionInput(
            current: original,
            proposed: original,
            currentSeriesID: originalSeriesID,
            proposedRevisionID: revisionID,
            proposedSeriesID: renamedSeriesID
        ))
        XCTAssertEqual(unchanged.kind, .unchanged)
        XCTAssertEqual(unchanged.seriesID, originalSeriesID)
        XCTAssertNil(unchanged.revisionID, "同一内容ならrevision不要")

        let restoredName = MetricRevisionTransitionDecision.decide(MetricRevisionTransitionInput(
            current: MetricRevisionSnapshot(name: "重量", unit: "lb", allowsDecimal: true, isRequired: false),
            proposed: original,
            currentSeriesID: renamedSeriesID,
            proposedRevisionID: revisionID,
            proposedSeriesID: restoredNameSeriesID
        ))
        XCTAssertEqual(restoredName.kind, .nameOrUnitChanged)
        XCTAssertEqual(restoredName.seriesID, restoredNameSeriesID, "名前を戻しても別系列を割り当てる")
        XCTAssertNotEqual(restoredName.seriesID, originalSeriesID)
        XCTAssertNotEqual(restoredName.seriesID, renamedSeriesID)
    }
}

@MainActor
final class WorkoutDeletionV2ConfirmationSnapshotTests: XCTestCase {
    private func makeSQLiteContext(name: String) throws -> (ModelConfiguration, ModelContext) {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).sqlite")
        let configuration = ModelConfiguration(name, schema: schema, url: url, cloudKitDatabase: .none)
        return (configuration, ModelContext(try ModelContainer(for: schema, configurations: [configuration])))
    }

    func testWorkoutDeletionRejectsValueChangeAfterConfirmationAndPreservesSQLiteGraph() throws {
        let (configuration, context) = try makeSQLiteContext(name: "MeleteV2WorkoutDeletionValueSnapshot")
        let metric = MetricDefinition(name: "負荷", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "対象種目", metrics: [metric])
        let revision = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: 0)
        let valueA = MetricValue(metric: metric, scaledValue: 12_000)
        let valueB = MetricValue(metric: metric, scaledValue: 8_000)
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [
            SetRecord(sortOrder: 1, values: [valueA]), SetRecord(sortOrder: 2, values: [valueB]),
        ])
        let workout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [record])
        let otherValue = MetricValue(metric: metric, scaledValue: 30_000)
        let otherWorkout = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [
            ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [otherValue])]),
        ])
        context.insert(exercise); context.insert(workout); context.insert(otherWorkout); context.insert(revision)
        let links = try [valueA, valueB, otherValue].map { try MetricValueRevisionLinking.register(value: $0, revision: revision, in: context) }
        try context.save()

        let service = WorkoutWritingServiceV2(context: context)
        let target = try service.captureWorkoutDeletionTarget(workout: workout)
        valueA.scaledValue = 13_000
        try context.save()

        XCTAssertThrowsError(try service.deleteWorkout(target), "確認後にWorkout内の値が変われば全体削除を拒否") { error in
            guard case WorkoutSetDeletionError.changed = error else { return XCTFail("changedとして拒否する必要: \(error)") }
        }

        let thirdContainer = try ModelContainer(for: Schema(versionedSchema: MeleteSchemaV2.self), configurations: [configuration])
        let thirdContext = ModelContext(thirdContainer)
        let savedWorkouts = try thirdContext.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(Set(savedWorkouts.map(\.id)), [workout.id, otherWorkout.id])
        XCTAssertEqual(Set(try thirdContext.fetch(FetchDescriptor<ExerciseRecord>()).map(\.id)), [record.id, otherWorkout.records[0].id])
        XCTAssertEqual(Set(try thirdContext.fetch(FetchDescriptor<SetRecord>()).map(\.id)), Set(record.sets.map(\.id) + otherWorkout.records.flatMap(\.sets).map(\.id)))
        let savedValues = try thirdContext.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(Set(savedValues.map(\.id)), [valueA.id, valueB.id, otherValue.id])
        XCTAssertEqual(savedValues.first { $0.id == valueA.id }?.scaledValue, 13_000)
        XCTAssertEqual(savedValues.first { $0.id == valueB.id }?.scaledValue, 8_000)
        XCTAssertEqual(savedValues.first { $0.id == otherValue.id }?.scaledValue, 30_000)
        XCTAssertEqual(Set(try thirdContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.id)), Set(links.map(\.id)))
    }

    func testWorkoutDeletionRejectsHistoryLinkChangeAfterConfirmationAndPreservesSQLiteGraph() throws {
        let (configuration, context) = try makeSQLiteContext(name: "MeleteV2WorkoutDeletionLinkSnapshot")
        let metric = MetricDefinition(name: "負荷", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "対象種目", metrics: [metric])
        let revision1 = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: 0)
        let revision2 = MetricDefinitionRevision(metricID: metric.id, revision: 2, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: 0)
        let valueA = MetricValue(metric: metric, scaledValue: 12_000)
        let valueB = MetricValue(metric: metric, scaledValue: 8_000)
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [
            SetRecord(sortOrder: 1, values: [valueA]), SetRecord(sortOrder: 2, values: [valueB]),
        ])
        let workout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [record])
        let otherValue = MetricValue(metric: metric, scaledValue: 30_000)
        let otherWorkout = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [
            ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [otherValue])]),
        ])
        context.insert(exercise); context.insert(workout); context.insert(otherWorkout); context.insert(revision1); context.insert(revision2)
        let linkA = try MetricValueRevisionLinking.register(value: valueA, revision: revision1, in: context)
        let linkB = try MetricValueRevisionLinking.register(value: valueB, revision: revision1, in: context)
        let otherLink = try MetricValueRevisionLinking.register(value: otherValue, revision: revision1, in: context)
        try context.save()

        let service = WorkoutWritingServiceV2(context: context)
        let target = try service.captureWorkoutDeletionTarget(workout: workout)
        context.delete(linkA)
        let replacementLink = MetricValueRevisionLink(valueID: valueA.id, revisionID: revision2.id)
        context.insert(replacementLink)
        try context.save()

        XCTAssertThrowsError(try service.deleteWorkout(target), "確認後に履歴linkだけがR1からR2へ変われば全体削除を拒否") { error in
            guard case WorkoutSetDeletionError.changed = error else { return XCTFail("changedとして拒否する必要: \(error)") }
        }

        let thirdContainer = try ModelContainer(for: Schema(versionedSchema: MeleteSchemaV2.self), configurations: [configuration])
        let thirdContext = ModelContext(thirdContainer)
        let savedWorkouts = try thirdContext.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(Set(savedWorkouts.map(\.id)), [workout.id, otherWorkout.id])
        XCTAssertEqual(Set(try thirdContext.fetch(FetchDescriptor<ExerciseRecord>()).map(\.id)), [record.id, otherWorkout.records[0].id])
        XCTAssertEqual(Set(try thirdContext.fetch(FetchDescriptor<SetRecord>()).map(\.id)), Set(record.sets.map(\.id) + otherWorkout.records.flatMap(\.sets).map(\.id)))
        let savedValues = try thirdContext.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(Set(savedValues.map(\.id)), [valueA.id, valueB.id, otherValue.id])
        XCTAssertEqual(savedValues.first { $0.id == valueA.id }?.scaledValue, 12_000)
        XCTAssertEqual(savedValues.first { $0.id == valueB.id }?.scaledValue, 8_000)
        XCTAssertEqual(savedValues.first { $0.id == otherValue.id }?.scaledValue, 30_000)
        let savedLinks = try thirdContext.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(Set(savedLinks.map(\.id)), [replacementLink.id, linkB.id, otherLink.id])
        XCTAssertEqual(savedLinks.first { $0.valueID == valueA.id }?.revisionID, revision2.id)
    }
}

@MainActor
final class WorkoutDeletionV1ConfirmationSnapshotTests: XCTestCase {
    func testSetDeletionRejectsValueChangedAndSavedBySeparateContainer() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteV1SetDeletionCrossContext-\(UUID().uuidString).sqlite")
        let configuration = ModelConfiguration("MeleteV1SetDeletionCrossContext", schema: schema, url: url, cloudKitDatabase: .none)
        let containerA = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(containerA)
        let metric = MetricDefinition(name: "合成負荷", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let targetValue = MetricValue(metric: metric, scaledValue: 10_000)
        let retainedValue = MetricValue(metric: metric, scaledValue: 20_000)
        let targetSet = SetRecord(sortOrder: 1, values: [targetValue])
        let retainedSet = SetRecord(sortOrder: 2, values: [retainedValue])
        let targetRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [targetSet, retainedSet])
        let targetWorkout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [targetRecord])
        let otherValue = MetricValue(metric: metric, scaledValue: 30_000)
        let otherRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [otherValue])])
        let otherWorkout = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [otherRecord])
        contextA.insert(exercise); contextA.insert(targetWorkout); contextA.insert(otherWorkout)
        try contextA.save()
        XCTAssertFalse(contextA.hasChanges, "削除確認前はAをcleanにする")

        let target = WorkoutSetDeletionTarget(workout: targetWorkout, record: targetRecord, set: targetSet)
        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let valueB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<MetricValue>()).first { $0.id == targetValue.id })
        valueB.scaledValue = 11_000
        try contextB.save()
        XCTAssertFalse(contextB.hasChanges, "Bの更新保存後はclean")

        XCTAssertFalse(contextA.hasChanges, "Bの保存後もAはclean")
        XCTAssertThrowsError(try WorkoutSetDeletion.delete(target, in: contextA) { try contextA.save() }, "別containerで更新されたsetの削除確認を拒否") { error in
            guard case WorkoutSetDeletionError.changed = error else { return XCTFail("changedとして拒否する必要: \(error)") }
        }
        XCTAssertFalse(contextA.hasChanges, "拒否後もA contextはclean")

        let verificationContainer = try ModelContainer(for: schema, configurations: [configuration])
        let verificationContext = ModelContext(verificationContainer)
        let savedWorkouts = try verificationContext.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(Set(savedWorkouts.map(\.id)), [targetWorkout.id, otherWorkout.id])
        XCTAssertEqual(try XCTUnwrap(savedWorkouts.first { $0.id == targetWorkout.id }).records.first?.sets.map(\.id).sorted { $0.uuidString < $1.uuidString }, [targetSet.id, retainedSet.id].sorted { $0.uuidString < $1.uuidString })
        let savedValues = try verificationContext.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(Set(savedValues.map(\.id)), [targetValue.id, retainedValue.id, otherValue.id])
        XCTAssertEqual(try XCTUnwrap(savedValues.first { $0.id == targetValue.id }).scaledValue, 11_000)
        XCTAssertEqual(try XCTUnwrap(savedValues.first { $0.id == retainedValue.id }).scaledValue, 20_000)
        XCTAssertEqual(try XCTUnwrap(savedValues.first { $0.id == otherValue.id }).scaledValue, 30_000)
        XCTAssertEqual(Set(try verificationContext.fetch(FetchDescriptor<ExerciseRecord>()).map(\.id)), [targetRecord.id, otherRecord.id])
    }

    func testRecordDeletionRejectsSetAddedAndSavedBySeparateContainer() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteV1RecordDeletionCrossContext-\(UUID().uuidString).sqlite")
        let configuration = ModelConfiguration("MeleteV1RecordDeletionCrossContext", schema: schema, url: url, cloudKitDatabase: .none)
        let containerA = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(containerA)
        let metric = MetricDefinition(name: "合成負荷", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let originalValue = MetricValue(metric: metric, scaledValue: 10_000)
        let originalSet = SetRecord(sortOrder: 1, values: [originalValue])
        let retainedValue = MetricValue(metric: metric, scaledValue: 30_000)
        let retainedSet = SetRecord(sortOrder: 1, values: [retainedValue])
        let targetRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [originalSet])
        let retainedRecord = ExerciseRecord(exercise: exercise, sortOrder: 1, sets: [retainedSet])
        let targetWorkout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [targetRecord, retainedRecord])
        let otherValue = MetricValue(metric: metric, scaledValue: 40_000)
        let otherRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [otherValue])])
        let otherWorkout = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [otherRecord])
        contextA.insert(exercise); contextA.insert(targetWorkout); contextA.insert(otherWorkout)
        try contextA.save()
        XCTAssertFalse(contextA.hasChanges, "削除確認前はAをcleanにする")

        let target = WorkoutRecordDeletionTarget(workout: targetWorkout, record: targetRecord)
        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let recordB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<ExerciseRecord>()).first { $0.id == targetRecord.id })
        let addedValue = MetricValue(metric: try XCTUnwrap(try contextB.fetch(FetchDescriptor<MetricDefinition>()).first { $0.id == metric.id }), scaledValue: 15_000)
        let addedSet = SetRecord(sortOrder: 2, values: [addedValue])
        recordB.sets.append(addedSet)
        try contextB.save()
        XCTAssertFalse(contextB.hasChanges, "Bのset/value追加保存後はclean")

        XCTAssertFalse(contextA.hasChanges, "Bの保存後もAはclean")
        XCTAssertThrowsError(try WorkoutRecordDeletion.delete(target, in: contextA) { try contextA.save() }, "別containerでsetが追加されたrecordの削除確認を拒否") { error in
            guard case WorkoutSetDeletionError.changed = error else { return XCTFail("changedとして拒否する必要: \(error)") }
        }
        XCTAssertFalse(contextA.hasChanges, "拒否後もA contextはclean")

        let verificationContainer = try ModelContainer(for: schema, configurations: [configuration])
        let verificationContext = ModelContext(verificationContainer)
        let savedWorkouts = try verificationContext.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(Set(savedWorkouts.map(\.id)), [targetWorkout.id, otherWorkout.id])
        let savedTargetWorkout = try XCTUnwrap(savedWorkouts.first { $0.id == targetWorkout.id })
        let savedRecordIDs: Set<UUID> = Set(savedTargetWorkout.records.map { $0.id })
        XCTAssertEqual(savedRecordIDs, Set([targetRecord.id, retainedRecord.id]))
        let savedRecords = try verificationContext.fetch(FetchDescriptor<ExerciseRecord>())
        let savedRecordEntityIDs: Set<UUID> = Set(savedRecords.map { $0.id })
        XCTAssertEqual(savedRecordEntityIDs, Set([targetRecord.id, retainedRecord.id, otherRecord.id]))
        let savedSets = try verificationContext.fetch(FetchDescriptor<SetRecord>())
        let savedSetIDs: Set<UUID> = Set(savedSets.map { $0.id })
        XCTAssertEqual(savedSetIDs, Set([originalSet.id, addedSet.id, retainedSet.id, otherRecord.sets[0].id]))
        let savedValues = try verificationContext.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(Set(savedValues.map(\.id)), [originalValue.id, addedValue.id, retainedValue.id, otherValue.id])
        XCTAssertEqual(try XCTUnwrap(savedValues.first { $0.id == originalValue.id }).scaledValue, 10_000)
        XCTAssertEqual(try XCTUnwrap(savedValues.first { $0.id == addedValue.id }).scaledValue, 15_000)
        XCTAssertEqual(try XCTUnwrap(savedValues.first { $0.id == otherValue.id }).scaledValue, 40_000)
    }

    func testWorkoutDeletionRejectsSavedValueChangeAfterConfirmation() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteV1WorkoutDeletionSnapshot-\(UUID().uuidString).sqlite")
        let configuration = ModelConfiguration("MeleteV1WorkoutDeletionSnapshot", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let metric = MetricDefinition(name: "負荷", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let value = MetricValue(metric: metric, scaledValue: 12_000)
        let workout = Workout(day: .now, records: [ExerciseRecord(exercise: Exercise(name: "合成種目", metrics: [metric]), sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [value])])])
        context.insert(workout)
        try context.save()

        let target = try WorkoutDeletion.captureTarget(workout: workout, in: context)
        let externalContext = ModelContext(container)
        let externalWorkout = try XCTUnwrap(externalContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workout.id })
        let externalValue = try XCTUnwrap(externalWorkout.records.first?.sets.first?.values.first)
        externalValue.scaledValue = 13_000
        try externalContext.save()
        XCTAssertThrowsError(try WorkoutDeletion.delete(target, in: context)) { error in
            guard case WorkoutSetDeletionError.changed = error else { return XCTFail("changedとして拒否する必要: \(error)") }
        }
        let verificationContext = ModelContext(container)
        XCTAssertEqual(try verificationContext.fetch(FetchDescriptor<Workout>()).map(\.id), [workout.id])
        XCTAssertEqual(try verificationContext.fetch(FetchDescriptor<MetricValue>()).first?.scaledValue, 13_000)
    }
}

@MainActor
final class WorkoutDeletionV2CaptureDirtyContextTests: XCTestCase {
    func testCaptureDeletionTargetsRejectDirtyContextAsUnsavedAndPreserveSQLiteGraph() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2CaptureDirtyContext-\(UUID().uuidString).sqlite")
        let configuration = ModelConfiguration(
            "MeleteV2CaptureDirtyContext-\(UUID().uuidString)",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let metric = MetricDefinition(name: "対象外の指標", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let revision = MetricDefinitionRevision(
            metricID: metric.id,
            revision: 1,
            name: metric.name,
            unit: metric.unit,
            allowsDecimal: metric.allowsDecimal,
            isRequired: metric.isRequired,
            sortOrder: metric.sortOrder
        )
        let value = MetricValue(metric: metric, scaledValue: 12_000)
        let set = SetRecord(sortOrder: 1, values: [value])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [set])
        let workout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [record])
        context.insert(exercise)
        context.insert(workout)
        context.insert(revision)
        let link = try MetricValueRevisionLinking.register(value: value, revision: revision, in: context)
        try context.save()
        XCTAssertFalse(context.hasChanges, "合成SQLite fixtureの保存後はclean")

        metric.name = "未保存の指標名"
        XCTAssertTrue(context.hasChanges)

        let service = WorkoutWritingServiceV2(context: context)
        XCTAssertThrowsError(try service.captureWorkoutDeletionTarget(workout: workout)) { error in
            guard case WorkoutSetDeletionError.unsavedContext = error else {
                return XCTFail("unsavedContextとして拒否する必要: \(error)")
            }
        }
        XCTAssertThrowsError(try service.captureRecordDeletionTarget(workout: workout, record: record)) { error in
            guard case WorkoutSetDeletionError.unsavedContext = error else {
                return XCTFail("unsavedContextとして拒否する必要: \(error)")
            }
        }
        XCTAssertThrowsError(try service.captureSetDeletionTarget(workout: workout, record: record, set: set)) { error in
            guard case WorkoutSetDeletionError.unsavedContext = error else {
                return XCTFail("unsavedContextとして拒否する必要: \(error)")
            }
        }

        XCTAssertEqual(metric.name, "未保存の指標名", "capture拒否後も未保存変更をrollbackしない")
        XCTAssertTrue(context.hasChanges, "capture拒否後もcontextのdirty状態を保持")
        XCTAssertEqual(workout.records.map(\.id), [record.id])
        XCTAssertEqual(record.sets.map(\.id), [set.id])
        XCTAssertEqual(set.values.map(\.id), [value.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.id), [link.id])
    }
}
