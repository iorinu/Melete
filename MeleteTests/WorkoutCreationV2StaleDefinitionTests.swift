import XCTest
import SwiftData
@testable import Melete

@MainActor
final class WorkoutCreationV2StaleDefinitionTests: XCTestCase {
    func testStaleNewWorkoutDraftIsRejectedAfterMetricUnitRoundTrip() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2StaleWorkoutUnitRoundTrip-\(UUID().uuidString).sqlite")
        let configuration = ModelConfiguration(
            "MeleteV2StaleWorkoutUnitRoundTrip-\(UUID().uuidString)",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        let containerA = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(containerA)
        let weight = MetricDefinition(
            name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0
        )
        let exerciseA = Exercise(name: "新規記録単位往復種目", metrics: [weight])
        contextA.insert(exerciseA)
        try contextA.save()

        // 先行Workoutを作り、重量定義のrevision 1と既存値・linkを永続化する。
        var originalEntry = try WorkoutCreationV2.makeEntryDraft(for: exerciseA, in: contextA)
        originalEntry.sets[0].values[weight.id] = "12.5"
        let originalWorkout = try WorkoutCreationV2.save(
            day: Date(timeIntervalSince1970: 1_700_000_000), entries: [originalEntry], in: contextA
        )
        let originalRevision = try XCTUnwrap(
            try contextA.fetch(FetchDescriptor<MetricDefinitionRevision>()).first { $0.metricID == weight.id }
        )
        XCTAssertEqual(originalRevision.revision, 1)
        let originalValue = try XCTUnwrap(try contextA.fetch(FetchDescriptor<MetricValue>()).first)
        let originalLink = try XCTUnwrap(try contextA.fetch(FetchDescriptor<MetricValueRevisionLink>()).first)

        // Aは現行の新規Workout入力と同じ初期化経路で、保存前のdraftを保持する。
        var staleEntry = try WorkoutCreationV2.makeEntryDraft(for: exerciseA, in: contextA)
        staleEntry.sets[0].values[weight.id] = "20.5"

        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let exerciseB = try XCTUnwrap(
            try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseA.id }
        )
        var toPounds = try MetricDefinitionEditingV2.draft(for: exerciseB, in: contextB)
        toPounds[0].unit = "lb"
        try MetricDefinitionEditingV2.save(toPounds, for: exerciseB, in: contextB)

        let refreshedExerciseB = try XCTUnwrap(
            try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseA.id }
        )
        var backToKilograms = try MetricDefinitionEditingV2.draft(for: refreshedExerciseB, in: contextB)
        backToKilograms[0].unit = "kg"
        try MetricDefinitionEditingV2.save(backToKilograms, for: refreshedExerciseB, in: contextB)
        XCTAssertFalse(contextB.hasChanges, "Bの定義保存後はcontextがclean")

        XCTAssertThrowsError(
            try WorkoutCreationV2.save(
                day: Date(timeIntervalSince1970: 1_700_000_100), entries: [staleEntry], in: contextA
            ),
            "定義がkgに戻っても履歴の変化した古いdraftを拒否する"
        ) { error in
            guard case WorkoutCreationV2Error.missingReference = error else {
                return XCTFail("古い定義参照はmissingReferenceで拒否する: \(error)")
            }
        }
        XCTAssertFalse(contextA.hasChanges, "拒否後にAのcontextはclean")

        // 第三containerで再読込し、拒否が既存履歴やBのrevisionを壊していないことを確認する。
        let verificationContainer = try ModelContainer(for: schema, configurations: [configuration])
        let verificationContext = ModelContext(verificationContainer)
        let savedExercise = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseA.id }
        )
        let savedMetric = try XCTUnwrap(savedExercise.metrics.first { $0.id == weight.id })
        XCTAssertEqual(savedMetric.unit, "kg")

        let revisions = try verificationContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
            .filter { $0.metricID == weight.id }
            .sorted { $0.revision < $1.revision }
        XCTAssertEqual(revisions.map(\.revision), [1, 2, 3])
        XCTAssertEqual(revisions.map(\.unit), ["kg", "lb", "kg"])
        XCTAssertEqual(revisions.first?.id, originalRevision.id)
        XCTAssertNotEqual(revisions[0].seriesID, revisions[1].seriesID)
        XCTAssertNotEqual(revisions[1].seriesID, revisions[2].seriesID)
        XCTAssertNotEqual(revisions[0].seriesID, revisions[2].seriesID)

        let savedWorkouts = try verificationContext.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(savedWorkouts.map(\.id), [originalWorkout.id], "古いdraftの拒否でWorkoutを追加しない")
        XCTAssertEqual(try verificationContext.fetch(FetchDescriptor<ExerciseRecord>()).count, 1)
        XCTAssertEqual(try verificationContext.fetch(FetchDescriptor<SetRecord>()).count, 1)
        let savedValues = try verificationContext.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(savedValues.map(\.id), [originalValue.id], "元の値だけを保持する")
        let savedLinks = try verificationContext.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(savedLinks.map(\.id), [originalLink.id], "元のrevision linkだけを保持する")
        XCTAssertEqual(savedLinks.first?.valueID, originalValue.id)
        XCTAssertEqual(savedLinks.first?.revisionID, originalRevision.id)
    }

    func testStaleNewWorkoutDraftIsRejectedWhenAnotherContextAddsActiveRequiredMetric() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2StaleWorkoutCreation-\(UUID().uuidString).sqlite")
        let configuration = ModelConfiguration(
            "MeleteV2StaleWorkoutCreation-\(UUID().uuidString)",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        let containerA = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(containerA)
        let weight = MetricDefinition(
            name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0
        )
        let exerciseA = Exercise(name: "新規記録競合種目", metrics: [weight])
        let originalDefinitionCount = exerciseA.metrics.count
        contextA.insert(exerciseA)
        try contextA.save()

        var entryA = try WorkoutCreationV2.makeEntryDraft(for: exerciseA, in: contextA)
        entryA.sets[0].values[weight.id] = "20.5"
        XCTAssertEqual(entryA.exercise.metrics.map(\.id), [weight.id], "Aのdraftは重量定義だけを保持する")

        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let exerciseB = try XCTUnwrap(
            try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseA.id }
        )
        XCTAssertEqual(exerciseB.id, exerciseA.id, "別containerのA・Bで同じ種目IDを参照する")
        var definitionDrafts = try MetricDefinitionEditingV2.draft(for: exerciseB, in: contextB)
        definitionDrafts.append(
            MetricDefinitionDraft(name: "回数", unit: "回", allowsDecimal: false, isRequired: true)
        )
        try MetricDefinitionEditingV2.save(definitionDrafts, for: exerciseB, in: contextB)
        XCTAssertFalse(contextB.hasChanges, "Bの定義保存後はcontextがclean")

        let persistedExerciseB = try XCTUnwrap(
            try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseA.id }
        )
        let persistedDefinitionsB = persistedExerciseB.metrics.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(persistedDefinitionsB.count, originalDefinitionCount + 1, "Bの保存で定義が1件増えた")
        XCTAssertTrue(persistedDefinitionsB.contains { $0.id == weight.id })
        XCTAssertEqual(persistedDefinitionsB.map(\.name), ["重量", "回数"])
        let repetition = try XCTUnwrap(persistedDefinitionsB.first { $0.name == "回数" })
        XCTAssertEqual(repetition.unit, "回")
        XCTAssertFalse(repetition.allowsDecimal)
        XCTAssertTrue(repetition.isRequired)
        XCTAssertTrue(repetition.isActive)

        let entries: [WorkoutEntryDraft]
        guard case let .success(validatedEntries) = WorkoutSetDraftEditing.validatedEntries([entryA]) else {
            return XCTFail("Aの古いdraftを入力検証できる")
        }
        entries = validatedEntries
        XCTAssertThrowsError(
            try WorkoutCreationV2.save(
                day: Date(timeIntervalSince1970: 1_700_000_000), entries: entries, in: contextA
            ),
            "新規Workout draft作成後に別contextが必須metricを追加したため拒否する"
        ) { error in
            guard case WorkoutCreationV2Error.missingReference = error else {
                return XCTFail("古い定義参照はmissingReferenceで拒否する: \(error)")
            }
        }
        XCTAssertFalse(contextA.hasChanges, "拒否後にAのcontextはclean")

        let verificationContainer = try ModelContainer(for: schema, configurations: [configuration])
        let verificationContext = ModelContext(verificationContainer)
        let savedExercises = try verificationContext.fetch(FetchDescriptor<Exercise>())
        let savedExercise = try XCTUnwrap(savedExercises.first { $0.id == exerciseA.id })
        XCTAssertEqual(savedExercises.count, 1)
        XCTAssertEqual(savedExercise.metrics.map(\.id).sorted { $0.uuidString < $1.uuidString },
                       [weight.id, repetition.id].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(savedExercise.metrics.count, 2, "Aの失敗でBが追加した定義を失わない")

        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<Workout>()).isEmpty,
                      "Aの拒否でWorkoutを追加しない")
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<ExerciseRecord>()).isEmpty,
                      "Aの拒否で種目別記録を追加しない")
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<SetRecord>()).isEmpty,
                      "Aの拒否でセットを追加しない")
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<MetricValue>()).isEmpty,
                      "Aの拒否で値を追加しない")
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty,
                      "Aの拒否でrevision linkを追加しない")
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<MetricDefinitionRevision>()).isEmpty,
                      "Aの拒否でrevisionを追加しない")
    }
}
