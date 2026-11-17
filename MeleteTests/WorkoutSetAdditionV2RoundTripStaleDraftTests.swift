import XCTest
import SwiftData
@testable import Melete

@MainActor
final class WorkoutSetAdditionV2RoundTripStaleDraftTests: XCTestCase {
    func testStaleSetAdditionDraftIsRejectedAfterDefinitionReturnsToOriginalUnit() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2SetAdditionRoundTrip-\(UUID().uuidString).sqlite")
        let configuration = ModelConfiguration(
            "MeleteV2SetAdditionRoundTrip",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let containerA = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(containerA)
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        let firstRevision = MetricDefinitionRevision(
            metricID: metric.id,
            revision: 1,
            name: "重量",
            unit: "kg",
            allowsDecimal: true,
            isRequired: false,
            sortOrder: 0
        )
        let oldValue = MetricValue(metric: metric, scaledValue: 12_500)
        let record = ExerciseRecord(
            exercise: exercise,
            sortOrder: 0,
            sets: [SetRecord(sortOrder: 1, values: [oldValue])]
        )
        let workout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [record])
        contextA.insert(exercise)
        contextA.insert(workout)
        contextA.insert(firstRevision)
        try contextA.save()
        let oldLink = try MetricValueRevisionLinking.register(value: oldValue, revision: firstRevision, in: contextA)
        try contextA.save()

        // Aは既存Workoutの追加フォームと同じ経路でdraftを作り、保存せずに保持する。
        let staleAddition = try XCTUnwrap(WorkoutValueEditingV2.appendSetDraft(for: record, exercise: exercise, in: contextA))

        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let exerciseB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == exercise.id })

        var toPounds = try MetricDefinitionEditingV2.draft(for: exerciseB, in: contextB)
        toPounds[0].unit = "lb"
        try MetricDefinitionEditingV2.save(toPounds, for: exerciseB, in: contextB)

        let refreshedExerciseB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == exercise.id })
        var backToKilograms = try MetricDefinitionEditingV2.draft(for: refreshedExerciseB, in: contextB)
        backToKilograms[0].unit = "kg"
        try MetricDefinitionEditingV2.save(backToKilograms, for: refreshedExerciseB, in: contextB)

        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day))
        XCTAssertThrowsError(
            try WorkoutValueEditingV2.save(
                [], additions: [staleAddition], day: day, to: workout, exercises: [exercise], in: contextA
            ),
            "定義がkgへ戻っても、revision履歴が変わった古いセット追加draftを拒否する"
        ) { error in
            guard case WorkoutValueEditError.metricsChanged = error else {
                return XCTFail("metricsChanged が返ること")
            }
        }
        XCTAssertFalse(contextA.hasChanges, "拒否後にAのcontextはcleanである")

        // さらに別のcontainerからSQLiteを開き、永続状態を検証する。
        let verificationContainer = try ModelContainer(for: schema, configurations: [configuration])
        let verificationContext = ModelContext(verificationContainer)
        let savedWorkout = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workout.id }
        )
        XCTAssertEqual(savedWorkout.day, workout.day)
        XCTAssertEqual(savedWorkout.records.map(\.id), [record.id])
        XCTAssertEqual(savedWorkout.records[0].sets.map(\.id), [record.sets[0].id])

        let savedExercise = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<Exercise>()).first { $0.id == exercise.id }
        )
        let savedMetric = try XCTUnwrap(savedExercise.metrics.first { $0.id == metric.id })
        XCTAssertEqual(savedMetric.unit, "kg")

        let revisions = try verificationContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
            .filter { $0.metricID == metric.id }
            .sorted { $0.revision < $1.revision }
        XCTAssertEqual(revisions.map(\.revision), [1, 2, 3])
        XCTAssertEqual(revisions.map(\.unit), ["kg", "lb", "kg"])
        XCTAssertEqual(revisions.first?.id, firstRevision.id)
        XCTAssertNotEqual(revisions[0].seriesID, revisions[1].seriesID)
        XCTAssertNotEqual(revisions[1].seriesID, revisions[2].seriesID)
        XCTAssertNotEqual(revisions[0].seriesID, revisions[2].seriesID)

        let savedValues = try verificationContext.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(savedValues.map(\.id), [oldValue.id], "古い値だけが残り、新しいセット値は追加されない")
        XCTAssertEqual(WorkoutValueSnapshot(try XCTUnwrap(savedValues.first)), WorkoutValueSnapshot(oldValue))
        let links = try verificationContext.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(links.map(\.id), [oldLink.id], "元のリンクだけを保持し、新セット用リンクを追加しない")
        XCTAssertEqual(links.first?.valueID, oldValue.id)
        XCTAssertEqual(links.first?.revisionID, firstRevision.id)
    }
}
