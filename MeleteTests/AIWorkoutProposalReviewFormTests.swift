import XCTest
import SwiftData
@testable import Melete

// AIの記録候補の確認画面で使う「組(ReviewSession)」とボタン操作の結果を、合成in-memoryデータで確かめる。
// 実データ・通常ストア・ネットワークは一切使わない。画面の見た目そのものは検証しない
@MainActor
final class AIWorkoutProposalReviewFormTests: XCTestCase {
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let exercise: Exercise
        let weight: MetricDefinition
        let reps: MetricDefinition
        let assist: MetricDefinition
        let coordinator: AIWorkoutProposalCoordinator
        let session: AIWorkoutProposalCoordinator.ReviewSession
    }

    private struct PersistFailure: Error {}

    // 日付の解釈を実行環境のタイムゾーンに依存させない
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        return calendar
    }

    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("AIWorkoutProposalReviewFormMemory-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeFixture() throws -> Fixture {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let weight = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let reps = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 1)
        let assist = MetricDefinition(name: "補助", unit: "段階", allowsDecimal: false, isRequired: false, sortOrder: 2)
        let exercise = Exercise(name: "合成種目A", metrics: [weight, reps, assist])
        context.insert(exercise)
        try context.save()

        let coordinator = AIWorkoutProposalCoordinator()
        let request = try coordinator.beginRequest(in: context)
        let set: [String: Any] = ["values": [
            ["metricID": weight.id.uuidString, "value": "60", "unit": "kg"],
            ["metricID": reps.id.uuidString, "value": "10", "unit": "回"],
        ]]
        let data = try JSONSerialization.data(withJSONObject: [
            "kind": "createWorkout",
            "day": "2026-01-15",
            "entries": [["exerciseID": exercise.id.uuidString, "sets": [set, set]]],
        ])
        let session = try coordinator.reviewSession(for: request.id, proposal: AIWorkoutProposal.decode(from: data), in: context, calendar: calendar)
        return Fixture(container: container, context: context, exercise: exercise, weight: weight, reps: reps, assist: assist, coordinator: coordinator, session: session)
    }

    private func workoutCount(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<Workout>())
    }

    private func firstSetID(_ fixture: Fixture) throws -> UUID {
        try XCTUnwrap(fixture.session.review.entries.first?.sets.first?.id)
    }

    private func setValue(_ fixture: Fixture, _ text: String, metric: MetricDefinition) throws {
        try fixture.session.review.setValue(text, exerciseID: fixture.exercise.id, setID: firstSetID(fixture), metricID: metric.id)
    }

    private func firstSetValue(_ fixture: Fixture, metric: MetricDefinition) throws -> String? {
        try XCTUnwrap(fixture.session.review.entries.first?.sets.first).values[metric.id]
    }

    // MARK: - 組の作成

    func testSessionWrapsTheSameReviewAsCoordinatorForTheSameResponse() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(fixture.session.id, fixture.session.review.id)
        XCTAssertEqual(fixture.session.status, .reviewing)
        XCTAssertEqual(fixture.session.review.dayString, "2026-01-15")
        // 確認画面に出すのは、種目の有効な項目定義（名前・単位・必須）と候補の値
        let entry = try XCTUnwrap(fixture.session.review.entries.first)
        XCTAssertEqual(entry.exerciseName, "合成種目A")
        XCTAssertEqual(entry.metricSnapshots.map(\.name), ["重量", "回数", "補助"])
        XCTAssertEqual(entry.metricSnapshots.map(\.isRequired), [true, true, false])
        XCTAssertEqual(entry.sets.count, 2)
        XCTAssertNil(try firstSetValue(fixture, metric: fixture.assist))
        XCTAssertEqual(try workoutCount(fixture.container), 0)
    }

    // MARK: - 承認

    func testApproveSavesEditedValuesOnceAndRepeatedTapsDoNotSaveAgain() throws {
        let fixture = try makeFixture()
        try setValue(fixture, "62.5", metric: fixture.weight)
        try setValue(fixture, "2", metric: fixture.assist)

        let outcome = AIWorkoutProposalReviewFormAction.approve(fixture.session, in: fixture.context)
        guard case let .saved(workoutID) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(fixture.session.status, .saved(workoutID: workoutID))

        // 閉じる途中の再タップ・連打を想定。保存済みの結果を返すだけで、2件目は作らない
        XCTAssertEqual(AIWorkoutProposalReviewFormAction.approve(fixture.session, in: fixture.context), .saved(workoutID: workoutID))
        XCTAssertEqual(try workoutCount(fixture.container), 1)

        let workout = try XCTUnwrap(ModelContext(fixture.container).fetch(FetchDescriptor<Workout>()).first)
        XCTAssertEqual(workout.id, workoutID)
        XCTAssertEqual(workout.day, "2026-01-15")
        let sets = try XCTUnwrap(workout.records.first).sets.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(sets.count, 2)
        let first = Dictionary(uniqueKeysWithValues: sets[0].values.map { ($0.metricID, $0.scaledValue) })
        XCTAssertEqual(first[fixture.weight.id], 62_500)
        XCTAssertEqual(first[fixture.reps.id], 10_000)
        XCTAssertEqual(first[fixture.assist.id], 2_000)
        // 修正していないセットはAIの候補のまま。省略された任意項目はnil（0ではない）
        let second = Dictionary(uniqueKeysWithValues: sets[1].values.map { ($0.metricID, $0.scaledValue) })
        XCTAssertEqual(second[fixture.weight.id], 60_000)
        XCTAssertEqual(second[fixture.assist.id], .some(nil))
    }

    func testInvalidEditIsExplainedAndNothingIsSaved() throws {
        let fixture = try makeFixture()
        try setValue(fixture, "10.5", metric: fixture.reps)

        let message = try XCTUnwrap(fixture.session.review.validationMessage())
        XCTAssertTrue(message.contains("回数"), message)
        XCTAssertEqual(AIWorkoutProposalReviewFormAction.approve(fixture.session, in: fixture.context), .failed(message))
        XCTAssertEqual(fixture.session.review.state, .pending)
        XCTAssertEqual(try firstSetValue(fixture, metric: fixture.reps), "10.5")
        XCTAssertEqual(try workoutCount(fixture.container), 0)

        // 必須項目を空にした場合も同じく保存しない
        try setValue(fixture, "", metric: fixture.reps)
        guard case .failed = AIWorkoutProposalReviewFormAction.approve(fixture.session, in: fixture.context) else { return XCTFail() }
        XCTAssertEqual(try workoutCount(fixture.container), 0)
    }

    func testSaveFailureKeepsEditsAndAllowsRetry() throws {
        let fixture = try makeFixture()
        try setValue(fixture, "70", metric: fixture.weight)

        let outcome = AIWorkoutProposalReviewFormAction.approve(fixture.session, in: fixture.context) { _ in throw PersistFailure() }
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(fixture.session.review.state, .pending)
        XCTAssertEqual(fixture.session.status, .reviewing)
        XCTAssertEqual(try firstSetValue(fixture, metric: fixture.weight), "70")
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture.container), 0)

        guard case .saved = AIWorkoutProposalReviewFormAction.approve(fixture.session, in: fixture.context) else { return XCTFail() }
        XCTAssertEqual(try workoutCount(fixture.container), 1)
    }

    func testDefinitionChangedElsewhereIsRejectedAndEditsAreKept() throws {
        let fixture = try makeFixture()
        try setValue(fixture, "65", metric: fixture.weight)
        // 確認中に別のcontextで項目定義が変わった場合
        let other = ModelContext(fixture.container)
        let exerciseID = fixture.exercise.id
        let stored = try XCTUnwrap(other.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID })).first)
        let storedWeight = try XCTUnwrap(stored.metrics.first { $0.name == "重量" })
        storedWeight.unit = "lb"
        try other.save()

        guard case .failed = AIWorkoutProposalReviewFormAction.approve(fixture.session, in: fixture.context) else { return XCTFail() }
        XCTAssertEqual(fixture.session.review.state, .pending)
        XCTAssertEqual(try firstSetValue(fixture, metric: fixture.weight), "65")
        XCTAssertEqual(try workoutCount(fixture.container), 0)
    }

    func testApproveWithContextFromAnotherStoreIsRejectedWithoutChangingEitherStore() throws {
        let fixture = try makeFixture()
        let otherContainer = try Self.makeContainer()

        guard case .failed = AIWorkoutProposalReviewFormAction.approve(fixture.session, in: ModelContext(otherContainer)) else { return XCTFail() }
        XCTAssertEqual(fixture.session.review.state, .pending)
        XCTAssertEqual(try workoutCount(fixture.container), 0)
        XCTAssertEqual(try workoutCount(otherContainer), 0)
    }

    // MARK: - キャンセル

    func testCancelClosesWithoutSavingAndLaterApproveDoesNotSave() throws {
        let fixture = try makeFixture()

        XCTAssertEqual(AIWorkoutProposalReviewFormAction.cancel(fixture.session), .closed)
        XCTAssertEqual(fixture.session.status, .cancelled)
        XCTAssertEqual(fixture.session.review.state, .cancelled)
        // 二度目のキャンセルも閉じるだけ
        XCTAssertEqual(AIWorkoutProposalReviewFormAction.cancel(fixture.session), .closed)
        // キャンセル後の承認タップは保存を試みない
        XCTAssertEqual(AIWorkoutProposalReviewFormAction.approve(fixture.session, in: fixture.context), .closed)
        XCTAssertThrowsError(try fixture.session.review.setValue("1", exerciseID: fixture.exercise.id, setID: firstSetID(fixture), metricID: fixture.weight.id))
        XCTAssertEqual(try workoutCount(fixture.container), 0)
    }

    func testCancelAfterSaveIsRejectedAndDoesNotReportCancellation() throws {
        let fixture = try makeFixture()
        guard case let .saved(workoutID) = AIWorkoutProposalReviewFormAction.approve(fixture.session, in: fixture.context) else { return XCTFail() }

        guard case .failed = AIWorkoutProposalReviewFormAction.cancel(fixture.session) else { return XCTFail() }
        XCTAssertEqual(fixture.session.status, .saved(workoutID: workoutID))
        XCTAssertEqual(try workoutCount(fixture.container), 1)
    }
}
