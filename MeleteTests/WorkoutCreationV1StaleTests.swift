import XCTest
import SwiftData
@testable import Melete

@MainActor
final class WorkoutCreationV1StaleTests: XCTestCase {
    func testStaleEntryDraftIsRejectedAfterRequiredMetricIsDeactivated() throws {
        let metricA = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let metricB = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 1)
        let exercise = Exercise(name: "ベンチプレス", metrics: [metricA, metricB])
        var entry = WorkoutEntryDraft(exercise: exercise)
        entry.sets[0].values[metricA.id] = "1"
        entry.sets[0].values[metricB.id] = "2"

        metricB.isActive = false

        guard case .failure = WorkoutSetDraftEditing.validatedEntries([entry]) else {
            XCTFail("下書き作成後に無効化された必須項目を含む下書きは拒否される")
            return
        }
        XCTAssertEqual(entry.sets[0].values[metricA.id], "1")
        XCTAssertEqual(entry.sets[0].values[metricB.id], "2")
    }

    func testUnchangedEntryDraftValidatesAndParsesBothMetrics() throws {
        let metricA = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let metricB = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 1)
        let exercise = Exercise(name: "ベンチプレス", metrics: [metricA, metricB])
        var entry = WorkoutEntryDraft(exercise: exercise)
        entry.sets[0].values[metricA.id] = "1"
        entry.sets[0].values[metricB.id] = "2"

        guard case let .success(validatedEntries) = WorkoutSetDraftEditing.validatedEntries([entry]) else {
            XCTFail("変更のない有効な下書きは検証に成功する")
            return
        }

        let validatedSet = try XCTUnwrap(validatedEntries.first?.sets.first)
        XCTAssertEqual(validatedSet.values[metricA.id], "1")
        XCTAssertEqual(validatedSet.values[metricB.id], "2")
        let parsedA = try XCTUnwrap(validatedSet.parsedValues[metricA.id] ?? nil)
        let parsedB = try XCTUnwrap(validatedSet.parsedValues[metricB.id] ?? nil)
        XCTAssertEqual(parsedA, 1_000)
        XCTAssertEqual(parsedB, 2_000)
    }

    func testV1BoundaryPersistsNilAndZeroValues() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("V1WorkoutCreationMemory-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let optional = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let required = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 1)
        let exercise = Exercise(name: "V1保存確認", metrics: [optional, required])
        context.insert(exercise)
        try context.save()
        var entry = WorkoutEntryDraft(exercise: exercise)
        entry.sets[0].values[optional.id] = ""
        entry.sets[0].values[required.id] = "0"

        let workout = try WorkoutCreationV1.save(day: .now, entries: [entry], in: context)
        let verifier = ModelContext(container)
        let saved = try XCTUnwrap(try verifier.fetch(FetchDescriptor<Workout>()).first { $0.id == workout.id })
        let values = try XCTUnwrap(saved.records.first?.sets.first?.values)
        let optionalValue = try XCTUnwrap(values.first { $0.metricID == optional.id })
        let requiredValue = try XCTUnwrap(values.first { $0.metricID == required.id })
        XCTAssertNil(optionalValue.scaledValue)
        XCTAssertEqual(requiredValue.scaledValue, 0)
        XCTAssertEqual(Set(values.map(\.metricID)).count, values.count)
    }

    func testV1BoundaryPreservesDirtyContextAndDoesNotPersistWorkout() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("V1WorkoutCreationDirtyMemory-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let metric = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "V1未保存確認", metrics: [metric])
        context.insert(exercise)
        try context.save()
        var entry = WorkoutEntryDraft(exercise: exercise)
        entry.sets[0].values[metric.id] = "2"
        exercise.name = "未保存の名前"

        XCTAssertThrowsError(try WorkoutCreationV1.save(day: .now, entries: [entry], in: context))
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(exercise.name, "未保存の名前")
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Workout>()).isEmpty)
    }

    func testSeparateContextMetricDeactivationRejectsCreation() throws {
        try assertStaleCreation { exercise, context in
            let metricID = try XCTUnwrap(exercise.metrics.first?.id)
            let metric = try XCTUnwrap(exercise.metrics.first { $0.id == metricID })
            metric.isActive = false
            try context.save()
        }
    }

    func testSeparateContextRequiredMetricAdditionRejectsCreation() throws {
        try assertStaleCreation { exercise, context in
            exercise.metrics.append(MetricDefinition(name: "距離", unit: "m", allowsDecimal: true, isRequired: true, sortOrder: 1))
            try context.save()
        }
    }

    func testSeparateContextExerciseArchiveRejectsCreation() throws {
        try assertStaleCreation { exercise, context in
            exercise.isArchived = true
            try context.save()
        }
    }

    func testSeparateContextExerciseDeletionRejectsCreation() throws {
        try assertStaleCreation { exercise, context in
            context.delete(exercise)
            try context.save()
        }
    }

    private func assertStaleCreation(
        mutate: (Exercise, ModelContext) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("V1CreationStaleMemory-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(container)
        let metric = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "作成stale確認", metrics: [metric])
        contextA.insert(exercise)
        try contextA.save()
        var entry = WorkoutEntryDraft(exercise: exercise)
        entry.sets[0].values[metric.id] = "3"

        let contextB = ModelContext(container)
        let exerciseID = exercise.id
        let persistedExercise = try XCTUnwrap(contextB.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID })).first, file: file, line: line)
        try mutate(persistedExercise, contextB)

        XCTAssertThrowsError(try WorkoutCreationV1.save(day: .now, entries: [entry], in: contextA), file: file, line: line) { error in
            guard case WorkoutCreationV1Error.staleDefinition = error else {
                XCTFail("staleDefinitionで拒否されること: \(error)", file: file, line: line)
                return
            }
        }
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Workout>()).isEmpty, file: file, line: line)
    }

    func testV1BoundaryRollsBackInjectedFailureAndAllowsRetry() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("V1WorkoutCreationRetryMemory-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let metric = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "V1再試行確認", metrics: [metric])
        context.insert(exercise)
        try context.save()
        var entry = WorkoutEntryDraft(exercise: exercise)
        entry.sets[0].values[metric.id] = "2"
        enum InjectedPersistenceError: Error { case expected }
        var injectedFailureReached = false
        XCTAssertThrowsError(try WorkoutCreationV1.save(day: .now, entries: [entry], in: context) { _ in
            injectedFailureReached = true
            throw InjectedPersistenceError.expected
        }) { error in
            guard case InjectedPersistenceError.expected = error else {
                XCTFail("注入した永続化エラーが返ること: \(error)")
                return
            }
        }
        XCTAssertTrue(injectedFailureReached)
        XCTAssertFalse(context.hasChanges)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Workout>()).isEmpty)

        _ = try WorkoutCreationV1.save(day: .now, entries: [entry], in: context)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Workout>()).count, 1)
    }
}
