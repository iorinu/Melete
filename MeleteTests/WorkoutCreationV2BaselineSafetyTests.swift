import XCTest
import SwiftData
@testable import Melete

@MainActor
final class WorkoutCreationV2BaselineSafetyTests: XCTestCase {
    private func makeConfiguration(schema: Schema, name: String) -> ModelConfiguration {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).sqlite")
        return ModelConfiguration(name, schema: schema, url: url, cloudKitDatabase: .none)
    }

    func testNoHistoryWorkoutDraftIsRejectedAfterAnotherContainerCreatesFirstRevision() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = makeConfiguration(schema: schema, name: "MeleteV2WorkoutNoHistoryRace")
        let containerA = try ModelContainer(for: schema, configurations: [configuration])
        let contextA = ModelContext(containerA)

        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exerciseA = Exercise(name: "新規Workout履歴baseline種目", metrics: [metric])
        contextA.insert(exerciseA)
        try contextA.save()

        var staleEntry = try WorkoutCreationV2.makeEntryDraft(for: exerciseA, in: contextA)
        staleEntry.sets[0].values[metric.id] = "12.5"
        XCTAssertEqual(staleEntry.historyBaseline?.history[metric.id], .noHistory)
        XCTAssertTrue(try contextA.fetch(FetchDescriptor<MetricDefinitionRevision>()).isEmpty)

        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let exerciseB = try XCTUnwrap(
            try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseA.id }
        )
        var entryB = try WorkoutCreationV2.makeEntryDraft(for: exerciseB, in: contextB)
        entryB.sets[0].values[metric.id] = "7.25"
        let workoutB = try WorkoutCreationV2.save(
            day: Date(timeIntervalSince1970: 1_700_000_000), entries: [entryB], in: contextB
        )
        let revisionB = try XCTUnwrap(
            try contextB.fetch(FetchDescriptor<MetricDefinitionRevision>()).first { $0.metricID == metric.id }
        )
        let valueB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<MetricValue>()).first)
        let linkB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<MetricValueRevisionLink>()).first)
        XCTAssertEqual(revisionB.revision, 1)
        XCTAssertEqual(revisionB.name, "重量")
        XCTAssertEqual(revisionB.unit, "kg")
        XCTAssertEqual(valueB.scaledValue, 7_250)
        XCTAssertEqual(linkB.valueID, valueB.id)
        XCTAssertEqual(linkB.revisionID, revisionB.id)
        XCTAssertFalse(contextB.hasChanges)

        XCTAssertThrowsError(
            try WorkoutCreationV2.save(
                day: Date(timeIntervalSince1970: 1_700_000_100), entries: [staleEntry], in: contextA
            ),
            "noHistory draft後に別containerが作成した初回revisionを拒否する"
        ) { error in
            guard case WorkoutCreationV2Error.missingReference = error else {
                return XCTFail("初回revision後の古いbaselineはmissingReferenceで拒否する: \(error)")
            }
        }
        XCTAssertFalse(contextA.hasChanges, "拒否後にAのcontextはclean")

        let verificationContainer = try ModelContainer(for: schema, configurations: [configuration])
        let verificationContext = ModelContext(verificationContainer)
        let savedWorkouts = try verificationContext.fetch(FetchDescriptor<Workout>())
        let savedWorkoutB = try XCTUnwrap(savedWorkouts.first { $0.id == workoutB.id })
        XCTAssertEqual(savedWorkouts.map(\.id), [workoutB.id], "Aの拒否でWorkoutを追加しない")
        XCTAssertEqual(savedWorkoutB.records.count, 1)
        XCTAssertEqual(savedWorkoutB.records[0].exerciseID, exerciseA.id)
        XCTAssertEqual(savedWorkoutB.records[0].sets.count, 1)
        let savedValue = try XCTUnwrap(savedWorkoutB.records[0].sets[0].values.first)
        XCTAssertEqual(savedValue.id, valueB.id)
        XCTAssertEqual(savedValue.metricID, metric.id)
        XCTAssertEqual(savedValue.scaledValue, 7_250)

        let revisions = try verificationContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
        XCTAssertEqual(revisions.map(\.id), [revisionB.id])
        XCTAssertEqual(revisions.first?.revision, 1)
        let links = try verificationContext.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(links.map(\.id), [linkB.id])
        XCTAssertEqual(links.first?.valueID, valueB.id)
        XCTAssertEqual(links.first?.revisionID, revisionB.id)
        XCTAssertEqual(try verificationContext.fetch(FetchDescriptor<ExerciseRecord>()).count, 1)
        XCTAssertEqual(try verificationContext.fetch(FetchDescriptor<SetRecord>()).count, 1)
        XCTAssertEqual(try verificationContext.fetch(FetchDescriptor<MetricValue>()).map(\.id), [valueB.id])
    }

    func testV1WorkoutEntryDraftWithoutBaselineIsRejectedWithoutInsertingGraphOrRevision() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = makeConfiguration(schema: schema, name: "MeleteV2WorkoutNilBaseline")
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let metric = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "V1 draft baseline欠落種目", metrics: [metric])
        context.insert(exercise)
        try context.save()

        // V1経路の初期化はnilのまま。V2で作るnoHistory baselineとは異なる状態を検証する。
        let v1Draft = WorkoutEntryDraft(exercise: exercise)
        XCTAssertNil(v1Draft.historyBaseline)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).isEmpty)

        XCTAssertThrowsError(
            try WorkoutCreationV2.save(
                day: Date(timeIntervalSince1970: 1_700_000_000), entries: [v1Draft], in: context
            ),
            "baseline nilのV1 draftは、noHistory baselineとして扱わず拒否する"
        ) { error in
            guard case WorkoutCreationV2Error.missingReference = error else {
                return XCTFail("baseline未取得はmissingReferenceで拒否する: \(error)")
            }
        }
        XCTAssertFalse(context.hasChanges, "拒否後にcontextはclean")

        let verificationContainer = try ModelContainer(for: schema, configurations: [configuration])
        let verificationContext = ModelContext(verificationContainer)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<Workout>()).isEmpty)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<ExerciseRecord>()).isEmpty)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<SetRecord>()).isEmpty)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<MetricValue>()).isEmpty)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<MetricDefinitionRevision>()).isEmpty)
        let savedExercise = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<Exercise>()).first { $0.id == exercise.id }
        )
        XCTAssertEqual(savedExercise.metrics.map(\.id), [metric.id])
    }
}
