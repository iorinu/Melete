import XCTest
import SwiftData
@testable import Melete

// Presentationと実coordinatorの接続契約を、合成provider・memory-only storeで確かめる。
@MainActor
final class AIWorkoutChatPresentationTests: XCTestCase {
    private final class SyntheticProvider: AIWorkoutChatProvider {
        enum Reply {
            case question
            case proposal
            case failure(SyntheticFailure)
        }

        var replies: [Reply]
        private(set) var requests: [AIWorkoutChatRequest] = []

        init(replies: [Reply]) { self.replies = replies }
        init(failingWith failure: SyntheticFailure) { replies = [.failure(failure)] }

        func send(_ request: AIWorkoutChatRequest) async throws -> AIWorkoutChatResponse {
            requests.append(request)
            switch replies.removeFirst() {
            case .question:
                return AIWorkoutChatResponse(json: try JSONSerialization.data(withJSONObject: ["kind": "askQuestion", "question": "何セットですか？"]))
            case .proposal:
                // 実データの名前・値・単位を参照せず、送信catalogのIDと固定の合成値だけで組み立てる。
                guard let exercise = request.catalog.exercises.first,
                      let metric = exercise.metrics.first else { throw SyntheticFailure() }
                let json: [String: Any] = [
                    "kind": "createWorkout", "day": "2026-01-15",
                    "entries": [["exerciseID": exercise.id.uuidString, "sets": [["values": [[
                        "metricID": metric.id.uuidString, "value": "7", "unit": "回",
                    ]]]]]],
                ]
                return AIWorkoutChatResponse(json: try JSONSerialization.data(withJSONObject: json))
            case let .failure(error): throw error
            }
        }
    }

    private struct SyntheticFailure: Error {}

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let exercise: Exercise
        let metric: MetricDefinition
        let presentation: AIWorkoutChatPresentation
        let provider: SyntheticProvider
    }

    private func makeFixture() throws -> Fixture {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("AIWorkoutChatPresentation-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let metric = MetricDefinition(name: "合成項目", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        context.insert(exercise)
        try context.save()

        let provider = SyntheticProvider(replies: [.question, .proposal])
        let coordinator = AIWorkoutChatCoordinator(provider: provider)
        let presentation = AIWorkoutChatPresentation(coordinator: coordinator, context: context, calendar: Self.calendar)
        return Fixture(container: container, context: context, exercise: exercise, metric: metric, presentation: presentation, provider: provider)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        return calendar
    }

    private func count(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<Workout>())
    }

    func testInitialSubmitDisplaysQuestionAsConversationAndClearsInput() async throws {
        let fixture = try makeFixture()
        fixture.presentation.inputText = "合成の依頼"

        await fixture.presentation.submit()

        XCTAssertEqual(fixture.presentation.pendingQuestion, "何セットですか？")
        XCTAssertEqual(fixture.presentation.inputText, "")
        XCTAssertEqual(fixture.presentation.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(fixture.presentation.messages.map(\.text), ["合成の依頼", "何セットですか？"])
        XCTAssertNil(fixture.presentation.reviewSession)
        XCTAssertEqual(try count(fixture.container), 0)
        XCTAssertFalse(fixture.context.hasChanges)

        fixture.presentation.inputText = "2セット"
        await fixture.presentation.submit()
        let session = try XCTUnwrap(fixture.presentation.reviewSession)
        XCTAssertEqual(session.status, .reviewing)
        XCTAssertNil(fixture.presentation.pendingQuestion)
        XCTAssertEqual(fixture.presentation.inputText, "")
        XCTAssertEqual(fixture.provider.requests.map(\.message), ["合成の依頼", "2セット"])
        XCTAssertEqual(try count(fixture.container), 0)

        let set = try XCTUnwrap(session.review.entries.first?.sets.first)
        try session.review.setValue("9", exerciseID: fixture.exercise.id, setID: set.id, metricID: fixture.metric.id)
        guard case .saved = fixture.presentation.approveReview() else { return XCTFail("明示承認で保存できること") }
        XCTAssertEqual(try count(fixture.container), 1)
        let workout = try XCTUnwrap(ModelContext(fixture.container).fetch(FetchDescriptor<Workout>()).first)
        XCTAssertEqual(workout.records.first?.sets.first?.values.first?.scaledValue, 9_000)
    }

    func testProviderErrorKeepsInputAndCancelingReviewSavesNothing() async throws {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("AIWorkoutChatPresentationFailure-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let provider = SyntheticProvider(failingWith: SyntheticFailure())
        let presentation = AIWorkoutChatPresentation(coordinator: AIWorkoutChatCoordinator(provider: provider), context: context, calendar: Self.calendar)
        presentation.inputText = "合成の依頼"

        await presentation.submit()

        XCTAssertEqual(presentation.inputText, "合成の依頼")
        XCTAssertTrue(presentation.messages.isEmpty)
        XCTAssertNotNil(presentation.errorMessage)
        XCTAssertEqual(try count(container), 0)

        let fixture = try makeFixture()
        fixture.presentation.inputText = "合成の依頼"
        await fixture.presentation.submit()
        fixture.presentation.inputText = "2セット"
        await fixture.presentation.submit()
        XCTAssertNotNil(fixture.presentation.reviewSession)
        fixture.presentation.cancel()
        XCTAssertEqual(try count(fixture.container), 0)
    }

    func testExternalReviewDismissKeepsSessionEditableAndExplicitApprovalSaves() async throws {
        let fixture = try makeFixture()
        fixture.presentation.inputText = "合成の依頼"
        await fixture.presentation.submit()
        fixture.presentation.inputText = "2セット"
        await fixture.presentation.submit()

        let session = try XCTUnwrap(fixture.presentation.reviewSession)
        XCTAssertEqual(session.status, .reviewing)
        XCTAssertEqual(try count(fixture.container), 0)

        // sheetの外部dismiss後に呼ばれるrefreshを模し、承認前のsessionが維持されることを確認する。
        fixture.presentation.refreshReviewState()
        XCTAssertEqual(fixture.presentation.reviewSession?.id, session.id)
        XCTAssertEqual(session.status, .reviewing)
        XCTAssertEqual(try count(fixture.container), 0)

        let set = try XCTUnwrap(session.review.entries.first?.sets.first)
        try session.review.setValue("9", exerciseID: fixture.exercise.id, setID: set.id, metricID: fixture.metric.id)
        XCTAssertEqual(fixture.presentation.reviewSession?.id, session.id)
        guard case .saved = fixture.presentation.approveReview() else { return XCTFail("閉じた後も明示承認で保存できること") }
        XCTAssertNil(fixture.presentation.reviewSession)
        XCTAssertEqual(try count(fixture.container), 1)
        let workout = try XCTUnwrap(ModelContext(fixture.container).fetch(FetchDescriptor<Workout>()).first)
        XCTAssertEqual(workout.records.first?.sets.first?.values.first?.scaledValue, 9_000)
    }

    func testCancelAfterReviewDismissClearsSessionWithoutSaving() async throws {
        let fixture = try makeFixture()
        fixture.presentation.inputText = "合成の依頼"
        await fixture.presentation.submit()
        fixture.presentation.inputText = "2セット"
        await fixture.presentation.submit()

        let session = try XCTUnwrap(fixture.presentation.reviewSession)
        fixture.presentation.refreshReviewState()
        XCTAssertEqual(fixture.presentation.reviewSession?.id, session.id)
        XCTAssertEqual(try count(fixture.container), 0)

        fixture.presentation.cancel()
        XCTAssertNil(fixture.presentation.reviewSession)
        fixture.presentation.refreshReviewState()
        XCTAssertNil(fixture.presentation.reviewSession)
        XCTAssertEqual(try count(fixture.container), 0)
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testRefreshReviewStateClearsSessionFinishedByReviewFormActionAndAllowsNextConversation() async throws {
        let fixture = try makeFixture()
        fixture.presentation.inputText = "合成の依頼"
        await fixture.presentation.submit()
        fixture.presentation.inputText = "2セット"
        await fixture.presentation.submit()

        let approvedSession = try XCTUnwrap(fixture.presentation.reviewSession)
        guard case .saved = AIWorkoutProposalReviewFormAction.approve(approvedSession, in: fixture.context) else {
            return XCTFail("ReviewFormActionで承認できること")
        }
        fixture.presentation.refreshReviewState()
        XCTAssertNil(fixture.presentation.reviewSession)

        fixture.provider.replies = [.question]
        fixture.presentation.inputText = "次の合成依頼"
        await fixture.presentation.submit()
        XCTAssertEqual(fixture.presentation.pendingQuestion, "何セットですか？")

        // cancel経由で終了したsessionもrefresh後に破棄し、次の会話を開始できること。
        let secondFixture = try makeFixture()
        secondFixture.presentation.inputText = "合成の依頼"
        await secondFixture.presentation.submit()
        secondFixture.presentation.inputText = "2セット"
        await secondFixture.presentation.submit()
        let cancelledSession = try XCTUnwrap(secondFixture.presentation.reviewSession)
        XCTAssertEqual(AIWorkoutProposalReviewFormAction.cancel(cancelledSession), .closed)
        secondFixture.presentation.refreshReviewState()
        XCTAssertNil(secondFixture.presentation.reviewSession)
        secondFixture.provider.replies = [.question]
        secondFixture.presentation.inputText = "次の合成依頼"
        await secondFixture.presentation.submit()
        XCTAssertEqual(secondFixture.presentation.pendingQuestion, "何セットですか？")
    }
}

// 通常画面の「チャットで記録」から開くデモを、factoryが作るmemory-only storeだけで確かめる。
// 実ストア・ネットワークには触れない（factoryは外からcontainerを受け取らない）。
@MainActor
final class AIWorkoutChatDemoTests: XCTestCase {
    private func count(_ session: AIWorkoutChatDemoSession) throws -> Int {
        try ModelContext(session.container).fetchCount(FetchDescriptor<Workout>())
    }

    // 1往復目（質問）→2往復目（候補）まで進めて、確認中のsessionを返す
    private func advanceToReview(_ demo: AIWorkoutChatDemoSession, first: String = "合成の依頼", answer: String = "合成の回答") async throws -> AIWorkoutProposalCoordinator.ReviewSession {
        demo.presentation.inputText = first
        await demo.presentation.submit()
        XCTAssertEqual(demo.presentation.pendingQuestion, AIWorkoutChatDemoSession.question)
        XCTAssertNil(demo.presentation.reviewSession)
        demo.presentation.inputText = answer
        await demo.presentation.submit()
        return try XCTUnwrap(demo.presentation.reviewSession)
    }

    func testFactoryCreatesSeparateMemoryOnlyV1StoreWithFixedSyntheticSeed() throws {
        let demo = try AIWorkoutChatDemoSession.make()
        XCTAssertFalse(demo.container.configurations.isEmpty)
        XCTAssertTrue(demo.container.configurations.allSatisfy(\.isStoredInMemoryOnly))
        XCTAssertEqual(Set(demo.container.schema.entities.map(\.name)),
                       Set(Schema(versionedSchema: MeleteSchemaV1.self).entities.map(\.name)))
        // 表示・承認に使うcontextは、modelContainer環境と同じデモcontainerのmainContext
        XCTAssertTrue(demo.context.container === demo.container)
        XCTAssertTrue(demo.context === demo.container.mainContext)
        XCTAssertFalse(demo.context.hasChanges)

        let exercises = try ModelContext(demo.container).fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(exercises.map(\.id), [demo.exerciseID])
        XCTAssertEqual(exercises.first?.name, AIWorkoutChatDemoSession.exerciseName)
        let metrics = try XCTUnwrap(exercises.first).metrics.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(metrics.map(\.unit), ["kg", "回"])
        XCTAssertEqual(try count(demo), 0)

        // 開くたびに別のmemory storeになり、前のデモの内容を共有しない
        let other = try AIWorkoutChatDemoSession.make()
        XCTAssertFalse(other.container === demo.container)
        XCTAssertNotEqual(other.exerciseID, demo.exerciseID)
    }

    func testScriptAsksQuestionThenProposesFixedValuesIgnoringInputAndSavesNothingBeforeApproval() async throws {
        let calendar = WorkoutCalendarLogic.calendar(timeZone: .current)
        let demo = try AIWorkoutChatDemoSession.make(calendar: calendar)
        let session = try await advanceToReview(demo, first: "合成の依頼A", answer: "99セット 123kg")
        XCTAssertEqual(try count(demo), 0)
        XCTAssertFalse(demo.context.hasChanges)

        let entry = try XCTUnwrap(session.review.entries.first)
        XCTAssertEqual(session.review.entries.count, 1)
        XCTAssertEqual(entry.exerciseID, demo.exerciseID)
        // 入力の数値は解釈せず、固定の合成値だけを候補にする
        XCTAssertEqual(entry.sets.count, AIWorkoutChatDemoSession.setCount)
        for set in entry.sets {
            XCTAssertEqual(set.values[demo.weightMetricID], AIWorkoutChatDemoSession.weightValue)
            XCTAssertEqual(set.values[demo.repsMetricID], AIWorkoutChatDemoSession.repsValue)
        }
        XCTAssertLessThanOrEqual(calendar.startOfDay(for: session.review.day), calendar.startOfDay(for: .now))

        // 別の入力でも同じ候補になる（入力内容が候補に反映されたと誤認させない）
        let other = try AIWorkoutChatDemoSession.make(calendar: calendar)
        let otherSession = try await advanceToReview(other, first: "全く別の依頼", answer: "1セット")
        XCTAssertEqual(otherSession.review.entries.first?.sets.map { $0.values[other.weightMetricID] },
                       entry.sets.map { $0.values[demo.weightMetricID] })
    }

    func testCancelledReviewSavesNothingAndConversationCanBeRestarted() async throws {
        let demo = try AIWorkoutChatDemoSession.make()
        let session = try await advanceToReview(demo)

        // シートを外から閉じた場合は確認中のまま残り、再表示できる
        demo.presentation.refreshReviewState()
        XCTAssertEqual(demo.presentation.reviewSession?.id, session.id)

        XCTAssertEqual(AIWorkoutProposalReviewFormAction.cancel(session), .closed)
        demo.presentation.refreshReviewState()
        XCTAssertNil(demo.presentation.reviewSession)
        XCTAssertEqual(try count(demo), 0)
        XCTAssertFalse(demo.context.hasChanges)

        // 取消後も同じデモで再送でき、台本は質問から始まる
        let next = try await advanceToReview(demo)
        XCTAssertNotEqual(next.id, session.id)
        XCTAssertEqual(try count(demo), 0)
    }

    func testExplicitApprovalSavesOnlyIntoDemoStore() async throws {
        let demo = try AIWorkoutChatDemoSession.make()
        let unrelated = try AIWorkoutChatDemoSession.make()
        let session = try await advanceToReview(demo)

        // 別のstoreのcontextでは承認できない（デモの候補を他のstoreへ保存しない）
        guard case .failed = AIWorkoutProposalReviewFormAction.approve(session, in: unrelated.context) else {
            return XCTFail("別storeでの承認は拒否されること")
        }
        XCTAssertEqual(try count(unrelated), 0)
        XCTAssertEqual(try count(demo), 0)

        guard case let .saved(workoutID) = AIWorkoutProposalReviewFormAction.approve(session, in: demo.context) else {
            return XCTFail("デモcontextでの明示承認で保存できること")
        }
        demo.presentation.refreshReviewState()
        XCTAssertNil(demo.presentation.reviewSession)
        XCTAssertEqual(try count(demo), 1)
        XCTAssertEqual(try count(unrelated), 0)
        XCTAssertFalse(demo.context.hasChanges)
        let workout = try XCTUnwrap(ModelContext(demo.container).fetch(FetchDescriptor<Workout>()).first)
        XCTAssertEqual(workout.id, workoutID)
        XCTAssertEqual(workout.records.first?.sets.count, AIWorkoutChatDemoSession.setCount)

        // 保存後に同じsessionを再承認しても二重に保存しない
        _ = AIWorkoutProposalReviewFormAction.approve(session, in: demo.context)
        XCTAssertEqual(try count(demo), 1)

        // 保存後も次の会話を始められる
        _ = try await advanceToReview(demo)
        XCTAssertEqual(try count(demo), 1)
    }

    func testPreparationFailsClosedWithFixedMessage() {
        struct SyntheticFailure: LocalizedError { var errorDescription: String? { "内部の詳細" } }
        guard case let .failed(message) = AIWorkoutChatDemoSession.prepare(using: { throw SyntheticFailure() }) else {
            return XCTFail("初期化失敗はfailedになること")
        }
        XCTAssertEqual(message, AIWorkoutChatDemoSession.unavailableMessage)
        XCTAssertFalse(message.contains("内部の詳細"))

        guard case .ready = AIWorkoutChatDemoSession.prepare() else { return XCTFail("通常はデモを準備できること") }
    }
}
