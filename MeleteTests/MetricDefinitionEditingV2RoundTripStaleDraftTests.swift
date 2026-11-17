import XCTest
import SwiftData
@testable import Melete

@MainActor
final class MetricDefinitionEditingV2RoundTripStaleDraftTests: XCTestCase {
    func testStaleDraftIsRejectedAfterSeparateContextReturnsDefinitionToOriginalUnit() throws {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2RoundTripStaleDraft-\(UUID().uuidString).sqlite")
        let configuration = ModelConfiguration(
            "MeleteV2RoundTripStaleDraft",
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
        exercise.metrics = [metric]
        let workout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [
            ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [oldValue])])
        ])
        contextA.insert(exercise)
        contextA.insert(workout)
        contextA.insert(firstRevision)
        try contextA.save()
        let oldLink = try MetricValueRevisionLinking.register(value: oldValue, revision: firstRevision, in: contextA)
        try contextA.save()

        // Aが編集開始時に保持したdraftは、最終的なkg定義のsnapshotと一致する。
        let staleDrafts = try MetricDefinitionEditingV2.draft(for: exercise, in: contextA)

        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let exerciseB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == exercise.id })

        var toPounds = try MetricDefinitionEditingV2.draft(for: exerciseB, in: contextB)
        toPounds[0].unit = "lb"
        try MetricDefinitionEditingV2.save(toPounds, for: exerciseB, in: contextB)

        // 各保存の直前に、B自身が最新定義から新しいdraftを作る。
        let refreshedExerciseB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == exercise.id })
        var backToKilograms = try MetricDefinitionEditingV2.draft(for: refreshedExerciseB, in: contextB)
        backToKilograms[0].unit = "kg"
        try MetricDefinitionEditingV2.save(backToKilograms, for: refreshedExerciseB, in: contextB)

        var staleOunces = staleDrafts
        staleOunces[0].unit = "oz"
        XCTAssertThrowsError(try MetricDefinitionEditingV2.save(staleOunces, for: exercise, in: contextA)) { error in
            switch error {
            case MetricDefinitionEditingV2Error.changed, MetricValueRevisionLinkingError.snapshotMismatch:
                break
            default:
                XCTFail("往復改訂後の古いdraftはchangedまたはsnapshotMismatchで拒否する必要: \(error)")
            }
        }
        XCTAssertFalse(contextA.hasChanges)

        // 第三のcontainerからSQLiteを開き直し、両contextのキャッシュに依存せず永続状態を確認する。
        let verificationContainer = try ModelContainer(for: schema, configurations: [configuration])
        let verificationContext = ModelContext(verificationContainer)
        let savedExercise = try XCTUnwrap(try verificationContext.fetch(FetchDescriptor<Exercise>()).first { $0.id == exercise.id })
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

        let savedValue = try XCTUnwrap(try verificationContext.fetch(FetchDescriptor<MetricValue>()).first { $0.id == oldValue.id })
        XCTAssertEqual(WorkoutValueSnapshot(savedValue), WorkoutValueSnapshot(oldValue))
        let links = try verificationContext.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(links.map(\.id), [oldLink.id])
        XCTAssertEqual(links.first?.valueID, oldValue.id)
        XCTAssertEqual(links.first?.revisionID, firstRevision.id)
    }
}
