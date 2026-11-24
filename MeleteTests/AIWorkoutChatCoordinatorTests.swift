import XCTest
import Observation
import SwiftData
@testable import Melete

// 会話の依頼coordinator（入力文の送信→応答の検証→確認画面用の組）を、合成in-memoryデータと
// テスト内だけの擬似providerで確かめる。実データ・通常ストア・ネットワーク・外部プロセスは一切使わない
@MainActor
final class AIWorkoutChatCoordinatorTests: XCTestCase {
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let exercise: Exercise
        let weight: MetricDefinition
        let reps: MetricDefinition
        let assist: MetricDefinition
        let provider: ScriptedProvider
        let coordinator: AIWorkoutChatCoordinator
    }

    // テスト用の擬似provider。受け取った依頼を記録し、決めておいた応答を返すか、テストが返すまで応答を保留する。
    // 保留中に取り消されても応答をやめない（遅れて届く応答を再現するため）
    @MainActor private final class ScriptedProvider: AIWorkoutChatProvider {
        enum Reply {
            case data(Data)
            case failure(Error)
        }

        private(set) var received: [AIWorkoutChatRequest] = []
        // nilなら応答を保留し、reply(to:with:) で返すまで待つ
        var immediateReply: Reply?
        private var pending: [Int: CheckedContinuation<AIWorkoutChatResponse, Error>] = [:]
        private var callWaiters: [CheckedContinuation<Void, Never>] = []

        func send(_ request: AIWorkoutChatRequest) async throws -> AIWorkoutChatResponse {
            received.append(request)
            let index = received.count - 1
            let waiters = callWaiters
            callWaiters = []
            waiters.forEach { $0.resume() }
            if let immediateReply { return try Self.response(for: immediateReply) }
            return try await withCheckedThrowingContinuation { pending[index] = $0 }
        }

        // count 回目の呼び出しが届くまで待つ
        func waitForCalls(_ count: Int) async {
            while received.count < count {
                await withCheckedContinuation { callWaiters.append($0) }
            }
        }

        func reply(to index: Int, with reply: Reply, file: StaticString = #filePath, line: UInt = #line) {
            guard let continuation = pending.removeValue(forKey: index) else { return XCTFail("保留中の呼び出しがない", file: file, line: line) }
            do {
                continuation.resume(returning: try Self.response(for: reply))
            } catch {
                continuation.resume(throwing: error)
            }
        }

        // まだ応答していない（=停止を確認できていない）呼び出しの数
        var pendingCount: Int { pending.count }

        // 保留中の呼び出しをすべて合成エラーで終わらせる。テストが途中で失敗しても、
        // 応答を待ち続けるタスクを残さないために、後片付けとして呼ぶ（保留がなければ何もしない）
        func releaseAllPending() {
            let continuations = pending.values
            pending = [:]
            continuations.forEach { $0.resume(throwing: SyntheticProviderFailure()) }
        }

        private static func response(for reply: Reply) throws -> AIWorkoutChatResponse {
            switch reply {
            case let .data(data): return AIWorkoutChatResponse(json: data)
            case let .failure(error): throw error
            }
        }
    }

    // 擬似的な通信エラー。説明文に目印を入れ、表示用メッセージへ漏れないことを確かめる
    private struct SyntheticProviderFailure: LocalizedError {
        var errorDescription: String? { "SYNTHETIC-PROVIDER-DETAIL" }
    }

    private struct PersistFailure: Error {}

    // テストが自由に進められる時計。coordinatorには now クロージャとして渡す
    @MainActor private final class TestClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    // 送信JSONのトップレベルに許すキー。history は同じ会話の直前までのやりとり（新しい会話では空の配列）
    private static let payloadKeys: Set<String> = ["message", "catalog", "today", "timeZone", "history"]

    // 確認画面の組でも質問でもない結果が返ったときに投げる（テストを失敗にするため）
    private struct UnexpectedOutcome: Error {}

    // send / answer の結果を、タスクの外へ渡せる値（Sendable）にしたもの
    private enum SentOutcome: Equatable, Sendable {
        case review(requestID: UUID)
        case question(String)
    }

    // 確認画面の組が返ったときだけ取り出す。質問が返ったら UnexpectedOutcome を投げる
    private nonisolated static func reviewSession(_ outcome: AIWorkoutChatCoordinator.Outcome) throws -> AIWorkoutProposalCoordinator.ReviewSession {
        guard case let .review(session) = outcome else { throw UnexpectedOutcome() }
        return session
    }

    private nonisolated static func sent(_ outcome: AIWorkoutChatCoordinator.Outcome) -> SentOutcome {
        switch outcome {
        case let .review(session): .review(requestID: session.requestID)
        case let .question(text): .question(text)
        }
    }

    // "2026-03-14T15:00:00Z" のようなUTC表記から時刻を作る（期待値の日付は別に文字列で書き、同じ計算で導かない）
    private func instant(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text), text, file: file, line: line)
    }

    // 呼び出し元が渡すcalendar。暦の種類とタイムゾーンを指定する
    private func callerCalendar(_ identifier: Calendar.Identifier, timeZone id: String, file: StaticString = #filePath, line: UInt = #line) throws -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: id), id, file: file, line: line)
        return calendar
    }

    // providerが受け取った依頼を、外部へ送られるJSONとして読む
    private func sentJSON(_ request: AIWorkoutChatRequest, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.payloadJSON()) as? [String: Any], file: file, line: line)
    }

    // 日付の解釈を実行環境のタイムゾーンに依存させない
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        return calendar
    }

    private let message = "合成の依頼文: 種目Aを60で10回2セット"

    // clock を渡すと、依頼時刻をその時計から読むcoordinatorを作る（提案API: init(provider:now:)）
    private func makeFixture(clock: TestClock? = nil) throws -> Fixture {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("AIWorkoutChatCoordinatorMemory-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let weight = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let reps = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 1)
        let assist = MetricDefinition(name: "補助", unit: "段階", allowsDecimal: false, isRequired: false, sortOrder: 2)
        let exercise = Exercise(name: "合成種目A", metrics: [weight, reps, assist])
        context.insert(exercise)
        context.insert(Exercise(name: "合成種目B", metrics: [MetricDefinition(name: "時間", unit: "分", allowsDecimal: true, isRequired: true, sortOrder: 0)]))
        try context.save()
        let provider = ScriptedProvider()
        let coordinator = if let clock {
            AIWorkoutChatCoordinator(provider: provider, now: { clock.now })
        } else {
            AIWorkoutChatCoordinator(provider: provider)
        }
        return Fixture(container: container, context: context, exercise: exercise, weight: weight, reps: reps, assist: assist,
                       provider: provider, coordinator: coordinator)
    }

    private func proposalData(_ fixture: Fixture, weightUnit: String = "kg", includeReps: Bool = true, exerciseID: UUID? = nil) throws -> Data {
        var values: [[String: Any]] = [["metricID": fixture.weight.id.uuidString, "value": "60", "unit": weightUnit]]
        if includeReps { values.append(["metricID": fixture.reps.id.uuidString, "value": "10", "unit": "回"]) }
        let set: [String: Any] = ["values": values]
        return try JSONSerialization.data(withJSONObject: [
            "kind": "createWorkout",
            "day": "2026-01-15",
            "entries": [["exerciseID": (exerciseID ?? fixture.exercise.id).uuidString, "sets": [set, set]]],
        ])
    }

    private func workoutCount(_ fixture: Fixture) throws -> Int {
        try ModelContext(fixture.container).fetchCount(FetchDescriptor<Workout>())
    }

    // 聞き返しの質問を表す応答。question には文字列以外（数値・null など）も入れられる
    private func questionData(_ question: Any, extra: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["kind": "askQuestion", "question": question]
        object.merge(extra) { current, _ in current }
        return try JSONSerialization.data(withJSONObject: object)
    }

    // providerが受け取った依頼の history を [["role": ..., "text": ...]] として読む
    private func sentHistory(_ request: AIWorkoutChatRequest, file: StaticString = #filePath, line: UInt = #line) throws -> [[String: String]] {
        try XCTUnwrap(sentJSON(request, file: file, line: line)["history"] as? [[String: String]], "history", file: file, line: line)
    }

    private func turn(_ role: String, _ text: String) -> [String: String] {
        ["role": role, "text": text]
    }

    // send して確認画面の組を受け取る（質問が返ったら失敗にする）
    private func sendForReview(_ fixture: Fixture, _ text: String? = nil) async throws -> AIWorkoutProposalCoordinator.ReviewSession {
        let outcome = try await fixture.coordinator.send(text ?? message, in: fixture.context, calendar: calendar)
        return try Self.reviewSession(outcome)
    }

    // send が expected で失敗することを確かめる
    private func assertSendFails(_ fixture: Fixture, _ expected: AIWorkoutChatError, message text: String? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let outcome = try await fixture.coordinator.send(text ?? message, in: fixture.context, calendar: calendar)
            XCTFail("失敗するはずが \(Self.sent(outcome)) を返した", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AIWorkoutChatError, expected, "\(error)", file: file, line: line)
        }
    }

    // answer が expected で失敗することを確かめる
    private func assertAnswerFails(_ fixture: Fixture, _ expected: AIWorkoutChatError, answer text: String, in context: ModelContext? = nil,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let outcome = try await fixture.coordinator.answer(text, in: context ?? fixture.context, calendar: calendar)
            XCTFail("失敗するはずが \(Self.sent(outcome)) を返した", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AIWorkoutChatError, expected, "\(error)", file: file, line: line)
        }
    }

    // 保留中のproviderに対して send を始めるタスク。結果は requestID だけを返す（Sendableな値にするため）
    private func startSend(_ fixture: Fixture) -> Task<UUID, Error> {
        let coordinator = fixture.coordinator
        let context = fixture.context
        let calendar = self.calendar
        let message = self.message
        return Task {
            let outcome = try await coordinator.send(message, in: context, calendar: calendar)
            return try Self.reviewSession(outcome).requestID
        }
    }

    // 保留中のproviderに対して send / answer を始めるタスク。結果は質問か requestID だけを返す
    private func startSendOutcome(_ fixture: Fixture, _ text: String) -> Task<SentOutcome, Error> {
        let coordinator = fixture.coordinator
        let context = fixture.context
        let calendar = self.calendar
        return Task {
            let outcome = try await coordinator.send(text, in: context, calendar: calendar)
            return Self.sent(outcome)
        }
    }

    private func startAnswer(_ fixture: Fixture, _ text: String) -> Task<SentOutcome, Error> {
        let coordinator = fixture.coordinator
        let context = fixture.context
        let calendar = self.calendar
        return Task {
            let outcome = try await coordinator.answer(text, in: context, calendar: calendar)
            return Self.sent(outcome)
        }
    }

    private func assertCancelled<T: Sendable>(_ task: Task<T, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        switch await task.result {
        case let .success(value): XCTFail("取り消し後に結果 \(value) が返った", file: file, line: line)
        case let .failure(error): XCTAssertEqual(error as? AIWorkoutChatError, .cancelled, "\(error)", file: file, line: line)
        }
    }

    // 依頼が終了し、reviewも保存もなく、次の依頼を受け付けられる状態であることを確かめる
    private func assertEndedWithoutReview(_ fixture: Fixture, requestID: UUID?, file: StaticString = #filePath, line: UInt = #line) throws {
        if let requestID {
            XCTAssertEqual(fixture.coordinator.requestStatus(requestID), .cancelled, file: file, line: line)
        }
        XCTAssertNil(fixture.coordinator.currentReviewSession, file: file, line: line)
        XCTAssertNil(fixture.coordinator.sendingRequestID, file: file, line: line)
        XCTAssertFalse(fixture.coordinator.isBusy, file: file, line: line)
        XCTAssertFalse(fixture.context.hasChanges, file: file, line: line)
        XCTAssertEqual(try workoutCount(fixture), 0, file: file, line: line)
    }

    // MARK: - 送信内容

    func testRequestCarriesOnlyMessageAndActiveDefinitionsWithoutPastRecords() async throws {
        let fixture = try makeFixture()
        let archived = Exercise(name: "合成アーカイブ種目", metrics: [MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0)])
        archived.isArchived = true
        fixture.context.insert(archived)
        try fixture.context.save()
        // 過去の記録を1件作っておき、送信内容に含まれないことを確かめる（値は目印になる合成値）
        var entry = WorkoutEntryDraft(exercise: fixture.exercise)
        entry.sets[0].values = [fixture.weight.id: "987.125", fixture.reps.id: "77"]
        let pastWorkout = try WorkoutCreationV1.save(day: calendar.date(from: DateComponents(year: 2026, month: 1, day: 10))!, entries: [entry], in: fixture.context, calendar: calendar)
        fixture.provider.immediateReply = .data(try proposalData(fixture))

        _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)

        XCTAssertEqual(fixture.provider.received.count, 1)
        let request = try XCTUnwrap(fixture.provider.received.first)
        // 送信型が持つのは入力文・カタログ・依頼時点の日付とタイムゾーンだけ（ユーザー承認済みの範囲）
        XCTAssertEqual(Set(Mirror(reflecting: request).children.compactMap(\.label)), Self.payloadKeys)
        XCTAssertEqual(request.message, message)
        XCTAssertEqual(request.catalog, try AIWorkoutCatalog.make(in: fixture.context))
        // 有効な種目は全部（依頼文に出てこない種目Bも）送り、アーカイブ済みは送らない
        XCTAssertEqual(request.catalog.exercises.map(\.name), ["合成種目A", "合成種目B"])

        let payload = try request.payloadJSON()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Self.payloadKeys)
        // 新しい会話の最初の依頼なので、会話の履歴は空
        XCTAssertEqual(try sentHistory(request), [])
        let text = try XCTUnwrap(String(data: payload, encoding: .utf8))
        // 記録の値・ID・日付と、記録を表すキーが含まれないこと（UUIDの16進表記と偶然一致しない目印だけを使う）
        let markers = ["987.125", pastWorkout.id.uuidString, "2026-01-10", "合成アーカイブ種目",
                       "\"metricSnapshots\"", "\"records\"", "\"sets\"", "\"values\"", "\"day\""]
        for marker in markers {
            XCTAssertFalse(text.contains(marker), marker)
        }
    }

    // 依頼時点の同じ瞬間を、指定タイムゾーンの現地グレゴリオ暦の日付として送る。
    // UTC・東京・ロサンゼルスそれぞれの日付が切り替わる前後の時刻で、UTCの日付ではなく現地の日付になることを確かめる
    func testRequestCarriesLocalGregorianTodayAndTimeZoneAtRequestInstant() async throws {
        // (依頼時刻(UTC), タイムゾーン, 期待する today)。2026年3月のロサンゼルスは夏時間(UTC-7)
        let cases: [(String, String, String)] = [
            ("2026-03-14T14:59:59Z", "Asia/Tokyo", "2026-03-14"),
            ("2026-03-14T15:00:00Z", "Asia/Tokyo", "2026-03-15"),
            ("2026-03-14T23:59:59Z", "Asia/Tokyo", "2026-03-15"),
            ("2026-03-15T00:00:00Z", "Asia/Tokyo", "2026-03-15"),
            ("2026-03-14T23:59:59Z", "America/Los_Angeles", "2026-03-14"),
            ("2026-03-15T00:00:00Z", "America/Los_Angeles", "2026-03-14"),
            ("2026-03-15T06:59:59Z", "America/Los_Angeles", "2026-03-14"),
            ("2026-03-15T07:00:00Z", "America/Los_Angeles", "2026-03-15"),
            ("2026-12-31T15:00:00Z", "Asia/Tokyo", "2027-01-01"),
        ]
        for (time, zone, expectedToday) in cases {
            let label = "\(time) \(zone)"
            let fixture = try makeFixture(clock: TestClock(try instant(time)))
            fixture.provider.immediateReply = .data(try proposalData(fixture))

            _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: try callerCalendar(.gregorian, timeZone: zone))

            XCTAssertEqual(fixture.provider.received.count, 1, label)
            let request = try XCTUnwrap(fixture.provider.received.first, label)
            let json = try sentJSON(request)
            XCTAssertEqual(Set(json.keys), Self.payloadKeys, label)
            XCTAssertEqual(json["message"] as? String, message, label)
            XCTAssertEqual(json["today"] as? String, expectedToday, label)
            XCTAssertEqual(json["timeZone"] as? String, zone, label)
            // カタログは送信時点の定義そのもの
            let expectedCatalog = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AIWorkoutCatalog.make(in: fixture.context)))
            XCTAssertEqual(json["catalog"] as? NSObject, expectedCatalog as? NSObject, label)
        }
    }

    // today は送信時に1度だけ決まり、後で時計が進んでも変わらない。呼び出し元のcalendarが仏暦でも、
    // 暦の種類は使わずタイムゾーンだけを引き継いでグレゴリオ暦で送る。過去の記録は含めない
    func testTodayIsFixedGregorianAtSendEvenIfClockAdvancesOrCallerUsesBuddhistCalendar() async throws {
        // 東京で 2026-03-14 23:59:59（仏暦では2569年）
        let clock = TestClock(try instant("2026-03-14T14:59:59Z"))
        let fixture = try makeFixture(clock: clock)
        var callerBuddhist = try callerCalendar(.buddhist, timeZone: "Asia/Tokyo")
        callerBuddhist.locale = Locale(identifier: "th_TH")
        // Task へ渡すので let にしておく（var のままだと並行に動くコードからの参照になる）
        let buddhist = callerBuddhist
        // 前日の記録を作っておき、送信内容に含まれないことを確かめる（値は目印になる合成値）
        var entry = WorkoutEntryDraft(exercise: fixture.exercise)
        entry.sets[0].values = [fixture.weight.id: "987.125", fixture.reps.id: "77"]
        let pastWorkout = try WorkoutCreationV1.save(day: calendar.date(from: DateComponents(year: 2026, month: 3, day: 13))!, entries: [entry], in: fixture.context, calendar: calendar)

        // 応答を保留したまま送信させる
        let coordinator = fixture.coordinator
        let context = fixture.context
        let message = self.message
        let task = Task {
            let outcome = try await coordinator.send(message, in: context, calendar: buddhist)
            return try Self.reviewSession(outcome).requestID
        }
        await fixture.provider.waitForCalls(1)
        let request = try XCTUnwrap(fixture.provider.received.first)
        let sentPayload = try request.payloadJSON()
        let json = try sentJSON(request)
        XCTAssertEqual(Set(json.keys), Self.payloadKeys)
        // 仏暦の年(2569)ではなくグレゴリオ暦。年だけの目印はUUIDの16進表記と偶然一致しうるので、値の一致で確かめる
        XCTAssertEqual(json["today"] as? String, "2026-03-14")
        XCTAssertEqual(json["timeZone"] as? String, "Asia/Tokyo")
        let text = try XCTUnwrap(String(data: sentPayload, encoding: .utf8))
        // 過去の記録の値・ID・日付と、記録を表すキーが含まれないこと（UUIDの16進表記と偶然一致しない目印だけを使う）
        let markers = ["987.125", pastWorkout.id.uuidString, "2026-03-13",
                       "\"metricSnapshots\"", "\"records\"", "\"sets\"", "\"values\"", "\"day\""]
        for marker in markers {
            XCTAssertFalse(text.contains(marker), marker)
        }

        // 送信後に時計が翌々日（東京で 2026-03-16 00:00）へ進んでも、送った依頼の today は変わらない
        clock.now = try instant("2026-03-15T15:00:00Z")
        XCTAssertEqual(try request.payloadJSON(), sentPayload)
        fixture.provider.reply(to: 0, with: .data(try proposalData(fixture)))
        let requestID = try await task.value
        XCTAssertEqual(fixture.coordinator.currentReviewSession?.requestID, requestID)
        XCTAssertEqual(try fixture.provider.received[0].payloadJSON(), sentPayload)

        // 時計は依頼ごとに読む。次の依頼は進んだ時計の日付になる（ここでも仏暦は使わない）
        try fixture.coordinator.cancelCurrent()
        fixture.provider.immediateReply = .data(try proposalData(fixture))
        _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: buddhist)
        XCTAssertEqual(fixture.provider.received.count, 2)
        let next = try sentJSON(fixture.provider.received[1])
        XCTAssertEqual(next["today"] as? String, "2026-03-16")
        XCTAssertEqual(next["timeZone"] as? String, "Asia/Tokyo")
        XCTAssertEqual(try fixture.provider.received[0].payloadJSON(), sentPayload)
    }

    func testEmptyMessageIsRejectedWithoutSending() async throws {
        let fixture = try makeFixture()
        fixture.provider.immediateReply = .data(try proposalData(fixture))

        await assertSendFails(fixture, .emptyMessage, message: " \n\t")
        XCTAssertTrue(fixture.provider.received.isEmpty)
        try assertEndedWithoutReview(fixture, requestID: nil)
    }

    // catalog を含む送信JSON全体が応答JSONの既存上限を超える場合、providerを呼ぶ前に拒否する。
    // 上限内なら送信でき、実際に送られるJSON全体も上限内であることを確かめる。
    func testRequestJSONSizeIncludesCatalogAndIsCheckedBeforeProviderCall() async throws {
        let fixture = try makeFixture()
        fixture.provider.immediateReply = .data(try proposalData(fixture))

        _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)
        let normalRequest = try XCTUnwrap(fixture.provider.received.first)
        XCTAssertLessThanOrEqual(try normalRequest.payloadJSON().count, AIWorkoutProposalLimits.maxResponseBytes)

        try fixture.coordinator.cancelCurrent()
        for index in 0..<2 {
            let metric = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0)
            fixture.context.insert(Exercise(name: "合成サイズ確認種目-\(index)-" + String(repeating: "x", count: 600_000), metrics: [metric]))
        }
        try fixture.context.save()

        let catalog = try AIWorkoutCatalog.make(in: fixture.context)
        XCTAssertGreaterThan(try catalog.requestPayloadJSON().count, AIWorkoutProposalLimits.maxResponseBytes, "AIWorkoutCatalog.makeを通ったcatalog自体が1MiBを超えること")

        do {
            _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)
            XCTFail("catalogを含む送信JSONが上限を超えるため、providerを呼ぶ前に拒否する")
        } catch let error as AIWorkoutChatError {
            XCTAssertEqual(error, .conversationLimitExceeded, "送信JSONサイズ超過を明示的なエラーとして返す")
        }
        XCTAssertEqual(fixture.provider.received.count, 1, "サイズ超過時はproviderを呼ばない")
        XCTAssertFalse(fixture.coordinator.isBusy)
    }

    func testUnsavedChangesAreRejectedBeforeSending() async throws {
        let fixture = try makeFixture()
        fixture.provider.immediateReply = .data(try proposalData(fixture))
        // 未保存の種目名を外部へ送らないため、カタログを作る前に止める
        fixture.context.insert(Exercise(name: "合成未保存種目", metrics: []))

        await assertSendFails(fixture, .proposal(.unsavedContext))
        XCTAssertTrue(fixture.provider.received.isEmpty)
        XCTAssertNil(fixture.coordinator.sendingRequestID)
        XCTAssertFalse(fixture.coordinator.isBusy)
    }

    // MARK: - 確認画面の組と承認

    func testValidResponseOpensReviewWithoutSavingAndApprovalSavesOnce() async throws {
        let fixture = try makeFixture()
        fixture.provider.immediateReply = .data(try proposalData(fixture))

        let session = try await sendForReview(fixture)
        XCTAssertEqual(session.status, .reviewing)
        XCTAssertEqual(fixture.coordinator.currentReviewSession?.id, session.id)
        XCTAssertTrue(fixture.coordinator.isBusy)
        XCTAssertEqual(session.review.dayString, "2026-01-15")
        XCTAssertEqual(session.review.entries.first?.sets.count, 2)
        // 承認するまでは何も保存しない
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture), 0)

        // 確認画面で値を直してから承認する
        let setID = try XCTUnwrap(session.review.entries.first?.sets.first?.id)
        try session.review.setValue("62.5", exerciseID: fixture.exercise.id, setID: setID, metricID: fixture.weight.id)
        guard case let .saved(workoutID) = AIWorkoutProposalReviewFormAction.approve(session, in: fixture.context) else { return XCTFail() }
        XCTAssertEqual(AIWorkoutProposalReviewFormAction.approve(session, in: fixture.context), .saved(workoutID: workoutID))
        XCTAssertEqual(try workoutCount(fixture), 1)
        let workout = try XCTUnwrap(ModelContext(fixture.container).fetch(FetchDescriptor<Workout>()).first)
        let first = try XCTUnwrap(workout.records.first?.sets.min { $0.sortOrder < $1.sortOrder })
        XCTAssertEqual(first.values.first { $0.metricID == fixture.weight.id }?.scaledValue, 62_500)

        // 保存した依頼は終わり、次の依頼を受け付ける
        XCTAssertNil(fixture.coordinator.currentReviewSession)
        XCTAssertFalse(fixture.coordinator.isBusy)
        XCTAssertNoThrow(try fixture.coordinator.cancelCurrent())
        XCTAssertEqual(session.status, .saved(workoutID: workoutID))
    }

    func testCancelDuringReviewSavesNothingAndLaterApproveDoesNotSave() async throws {
        let fixture = try makeFixture()
        fixture.provider.immediateReply = .data(try proposalData(fixture))
        let session = try await sendForReview(fixture)

        try fixture.coordinator.cancelCurrent()
        try fixture.coordinator.cancelCurrent()
        XCTAssertEqual(session.status, .cancelled)
        XCTAssertEqual(AIWorkoutProposalReviewFormAction.approve(session, in: fixture.context), .closed)
        try assertEndedWithoutReview(fixture, requestID: session.requestID)
    }

    func testCancelFromReviewFormFreesCoordinatorForNextRequest() async throws {
        let fixture = try makeFixture()
        fixture.provider.immediateReply = .data(try proposalData(fixture))
        let first = try await sendForReview(fixture)

        // 確認中は次の依頼を送らない
        await assertSendFails(fixture, .busy)
        XCTAssertEqual(fixture.provider.received.count, 1)

        XCTAssertEqual(AIWorkoutProposalReviewFormAction.cancel(first), .closed)
        XCTAssertFalse(fixture.coordinator.isBusy)
        let second = try await sendForReview(fixture)
        XCTAssertNotEqual(second.requestID, first.requestID)
        XCTAssertEqual(first.status, .cancelled)
        XCTAssertEqual(try workoutCount(fixture), 0)
    }

    func testCancelWhileSavingIsRejectedAndKeepsReview() async throws {
        let fixture = try makeFixture()
        fixture.provider.immediateReply = .data(try proposalData(fixture))
        let session = try await sendForReview(fixture)

        // 保存処理の途中（persist の中）で取り消しを試みる
        var cancelError: Error?
        let outcome = AIWorkoutProposalReviewFormAction.approve(session, in: fixture.context) { context in
            XCTAssertThrowsError(try fixture.coordinator.cancelCurrent()) { cancelError = $0 }
            try context.save()
        }
        XCTAssertEqual(cancelError as? AIWorkoutProposalReviewError, .notEditable)
        guard case .saved = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try workoutCount(fixture), 1)
    }

    // MARK: - 拒否する応答

    func testOversizedResponseIsRejectedWithoutReview() async throws {
        let fixture = try makeFixture()
        fixture.provider.immediateReply = .data(Data(count: AIWorkoutProposalLimits.maxResponseBytes + 1))

        await assertSendFails(fixture, .proposal(.limitExceeded(.responseSize)))
        XCTAssertEqual(fixture.provider.received.count, 1)
        try assertEndedWithoutReview(fixture, requestID: nil)
    }

    func testInvalidOrIncompleteResponsesAreRejectedWithoutReview() async throws {
        let fixture = try makeFixture()
        let cases: [(String, Data, AIWorkoutChatError)] = [
            ("JSONでない", Data("合成の文章だけの応答".utf8), .proposal(.malformed)),
            ("未知のフィールド", try JSONSerialization.data(withJSONObject: ["kind": "createWorkout", "day": "2026-01-15", "entries": [], "extra": 1]), .proposal(.malformed)),
            ("送っていない種目", try proposalData(fixture, exerciseID: UUID()), .proposal(.unknownExercise)),
            ("必須値の不足", try proposalData(fixture, includeReps: false), .proposal(.missingRequiredValue)),
            ("単位の不一致", try proposalData(fixture, weightUnit: "lb"), .proposal(.unitMismatch)),
        ]
        for (label, data, expected) in cases {
            fixture.provider.immediateReply = .data(data)
            let before = fixture.provider.received.count
            await assertSendFails(fixture, expected)
            XCTAssertEqual(fixture.provider.received.count, before + 1, label)
            try assertEndedWithoutReview(fixture, requestID: nil)
        }
    }

    func testProviderFailureEndsRequestWithoutLeakingDetail() async throws {
        let fixture = try makeFixture()
        fixture.provider.immediateReply = .failure(SyntheticProviderFailure())

        await assertSendFails(fixture, .providerFailed)
        let description = AIWorkoutChatError.providerFailed.localizedDescription
        XCTAssertFalse(description.contains("SYNTHETIC"), description)
        try assertEndedWithoutReview(fixture, requestID: nil)

        // 失敗の後は新しい依頼として送り直せる
        fixture.provider.immediateReply = .data(try proposalData(fixture))
        let session = try await sendForReview(fixture)
        XCTAssertEqual(session.status, .reviewing)
        XCTAssertEqual(fixture.provider.received.count, 2)
    }

    func testDefinitionChangedWhileWaitingIsRejected() async throws {
        let fixture = try makeFixture()
        let task = startSend(fixture)
        await fixture.provider.waitForCalls(1)
        let requestID = try XCTUnwrap(fixture.coordinator.sendingRequestID)

        // 応答待ちの間に別のcontextで単位が変わった場合
        let other = ModelContext(fixture.container)
        let weightID = fixture.weight.id
        let storedWeight = try XCTUnwrap(other.fetch(FetchDescriptor<MetricDefinition>(predicate: #Predicate { $0.id == weightID })).first)
        storedWeight.unit = "lb"
        try other.save()
        fixture.provider.reply(to: 0, with: .data(try proposalData(fixture)))

        switch await task.result {
        case .success: XCTFail("定義が変わった後の候補からreviewが作られた")
        case let .failure(error): XCTAssertEqual(error as? AIWorkoutChatError, .proposal(.staleDefinition))
        }
        try assertEndedWithoutReview(fixture, requestID: requestID)
    }

    // MARK: - 取り消し・混線・遅延応答

    func testSecondSendWhileWaitingIsBusyAndNotSent() async throws {
        let fixture = try makeFixture()
        let task = startSend(fixture)
        await fixture.provider.waitForCalls(1)

        await assertSendFails(fixture, .busy)
        XCTAssertEqual(fixture.provider.received.count, 1)

        fixture.provider.reply(to: 0, with: .data(try proposalData(fixture)))
        let requestID = try await task.value
        XCTAssertEqual(fixture.coordinator.currentReviewSession?.requestID, requestID)
        XCTAssertEqual(try workoutCount(fixture), 0)
    }

    func testCancelWhileWaitingDiscardsLateResponse() async throws {
        let fixture = try makeFixture()
        defer { fixture.provider.releaseAllPending() }
        let task = startSend(fixture)
        await fixture.provider.waitForCalls(1)
        let requestID = try XCTUnwrap(fixture.coordinator.sendingRequestID)

        try fixture.coordinator.cancelCurrent()
        // 依頼はすぐキャンセル済みになるが、providerが戻るまではキャンセル中で busy のまま
        XCTAssertEqual(fixture.coordinator.requestStatus(requestID), .cancelled)
        XCTAssertEqual(fixture.coordinator.cancellingRequestID, requestID)
        XCTAssertTrue(fixture.coordinator.isCancelling)
        XCTAssertNil(fixture.coordinator.sendingRequestID)
        XCTAssertTrue(fixture.coordinator.isBusy)

        // 取り消しを無視して、正しい候補が後から届いても使わない。届いた（=停止を確認できた）時点で解放する
        fixture.provider.reply(to: 0, with: .data(try proposalData(fixture)))
        await assertCancelled(task)
        XCTAssertFalse(fixture.coordinator.isCancelling)
        try assertEndedWithoutReview(fixture, requestID: requestID)
    }

    // 取り消した依頼の遅れた応答は、停止確認前は次の依頼を止め（busy）、
    // 停止確認後は破棄されて次の依頼に混ざらない
    func testLateResponseOfCancelledRequestDoesNotLeakIntoNextRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.provider.releaseAllPending() }
        let first = startSend(fixture)
        await fixture.provider.waitForCalls(1)
        let firstID = try XCTUnwrap(fixture.coordinator.sendingRequestID)
        try fixture.coordinator.cancelCurrent()

        // 停止確認前: 2件目はproviderを呼ばずに busy で拒否する
        await assertSendFails(fixture, .busy)
        XCTAssertEqual(fixture.provider.received.count, 1)

        // 1件目の応答が遅れて届く。使わずに解放する
        fixture.provider.reply(to: 0, with: .data(try proposalData(fixture)))
        await assertCancelled(first)
        try assertEndedWithoutReview(fixture, requestID: firstID)

        // 停止確認後: 2件目は新しい依頼として送れ、1件目の応答の影響を受けない
        let second = startSend(fixture)
        await fixture.provider.waitForCalls(2)
        let secondID = try XCTUnwrap(fixture.coordinator.sendingRequestID)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(fixture.coordinator.requestStatus(firstID), .cancelled)
        XCTAssertEqual(fixture.coordinator.requestStatus(secondID), .awaitingResponse)
        XCTAssertNil(fixture.coordinator.currentReviewSession)

        fixture.provider.reply(to: 1, with: .data(try proposalData(fixture)))
        let reviewedID = try await second.value
        XCTAssertEqual(reviewedID, secondID)
        XCTAssertEqual(fixture.coordinator.currentReviewSession?.requestID, secondID)
        XCTAssertEqual(try workoutCount(fixture), 0)
    }

    func testLateFailureOfCancelledRequestDoesNotEndNextRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.provider.releaseAllPending() }
        let first = startSend(fixture)
        await fixture.provider.waitForCalls(1)
        let firstID = try XCTUnwrap(fixture.coordinator.sendingRequestID)
        try fixture.coordinator.cancelCurrent()

        // 停止確認前: 2件目は busy
        await assertSendFails(fixture, .busy)
        XCTAssertEqual(fixture.provider.received.count, 1)

        // 1件目が遅れて通信エラーで終わっても、providerFailed ではなく取り消しとして終わる
        fixture.provider.reply(to: 0, with: .failure(SyntheticProviderFailure()))
        await assertCancelled(first)
        try assertEndedWithoutReview(fixture, requestID: firstID)

        // 停止確認後: 2件目は1件目の失敗に終わらされない
        let second = startSend(fixture)
        await fixture.provider.waitForCalls(2)
        let secondID = try XCTUnwrap(fixture.coordinator.sendingRequestID)
        XCTAssertEqual(fixture.coordinator.requestStatus(secondID), .awaitingResponse)

        fixture.provider.reply(to: 1, with: .data(try proposalData(fixture)))
        let reviewedID = try await second.value
        XCTAssertEqual(reviewedID, secondID)
    }

    func testCallerTaskCancellationDiscardsResponse() async throws {
        let fixture = try makeFixture()
        defer { fixture.provider.releaseAllPending() }
        let task = startSend(fixture)
        await fixture.provider.waitForCalls(1)
        let requestID = try XCTUnwrap(fixture.coordinator.sendingRequestID)

        // 呼び出し元（将来の画面）のタスクが取り消された後に、正しい候補が届く
        task.cancel()
        XCTAssertTrue(fixture.coordinator.isBusy)
        fixture.provider.reply(to: 0, with: .data(try proposalData(fixture)))
        await assertCancelled(task)
        try assertEndedWithoutReview(fixture, requestID: requestID)
    }

    func testAlreadyCancelledCallerTaskSendsNothing() async throws {
        let fixture = try makeFixture()
        fixture.provider.immediateReply = .data(try proposalData(fixture))
        let coordinator = fixture.coordinator
        let context = fixture.context
        let calendar = self.calendar
        let message = self.message
        let task = Task {
            // 送信より前に自分自身を取り消す
            withUnsafeCurrentTask { $0?.cancel() }
            let outcome = try await coordinator.send(message, in: context, calendar: calendar)
            return try Self.reviewSession(outcome).requestID
        }
        await assertCancelled(task)
        XCTAssertTrue(fixture.provider.received.isEmpty)
        try assertEndedWithoutReview(fixture, requestID: nil)
    }

    // MARK: - 取り消しを無視するproviderの停止確認

    // Swiftのタスクの取り消しは「止まってほしい」という合図でしかなく、providerが無視すれば通信は続く。
    // そのため取り消した後も、providerの呼び出しが終わったと確認できるまでは次の依頼を受け付けない
    // （外部への送信が二重に走らないようにするため）。確認できたら解放し、遅れた応答は使わない

    // 取り消しの起こし方
    private enum CancelTrigger: String {
        // 利用者が cancelCurrent で取り消す
        case coordinator
        // 呼び出し元（将来の画面）の send タスクが取り消される
        case callerTask
        // 呼び出し元のタスクが取り消され、さらに cancelCurrent も呼ばれる
        case callerTaskThenCoordinator
    }

    // 取り消しを無視していたproviderが、最終的にどう終わるか
    private enum LateReply: String, CaseIterable {
        // 正しい候補を遅れて返す
        case validProposal
        // 通信エラーで終わる
        case providerFailure
        // 遅れて取り消しに応じ、CancellationError で終わる
        case cancellationError
    }

    // キャンセル中になるまで MainActor を譲って待つ。永久に待たないよう回数で区切り、超えたら失敗にする
    private func waitUntilCancelling(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if fixture.coordinator.isCancelling { break }
            await Task.yield()
        }
        XCTAssertTrue(fixture.coordinator.isCancelling, "キャンセル中にならなかった", file: file, line: line)
    }

    private func assertCancelledRequestKeepsBusyUntilProviderEnds(_ trigger: CancelTrigger, lateReply: LateReply,
                                                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let label = "\(trigger.rawValue) / \(lateReply.rawValue)"
        let fixture = try makeFixture()
        // 途中で失敗しても、保留中のproviderの呼び出しを必ず合成エラーで解放してから終える
        defer { fixture.provider.releaseAllPending() }

        let task = startSend(fixture)
        await fixture.provider.waitForCalls(1)
        let requestID = try XCTUnwrap(fixture.coordinator.sendingRequestID, label, file: file, line: line)

        switch trigger {
        case .coordinator:
            try fixture.coordinator.cancelCurrent()
        case .callerTask:
            task.cancel()
        case .callerTaskThenCoordinator:
            task.cancel()
            try fixture.coordinator.cancelCurrent()
        }
        if trigger != .callerTask {
            // 取り消しは何度呼んでもよいが、呼び直しても解放はされない
            XCTAssertNoThrow(try fixture.coordinator.cancelCurrent(), label, file: file, line: line)
            // 遅れた応答からreviewを作れないよう、依頼自体はすぐにキャンセル済みになる
            XCTAssertEqual(fixture.coordinator.requestStatus(requestID), .cancelled, label, file: file, line: line)
        } else {
            // 呼び出し元タスクの取り消しは MainActor へ非同期に伝わる。キャンセル中になるまで、回数を区切って待つ
            await waitUntilCancelling(fixture, file: file, line: line)
        }
        // 画面が「キャンセル中」を判別できる（応答待ちではなく、まだ解放もされていない）
        XCTAssertEqual(fixture.coordinator.cancellingRequestID, requestID, label, file: file, line: line)
        XCTAssertTrue(fixture.coordinator.isCancelling, label, file: file, line: line)
        XCTAssertNil(fixture.coordinator.sendingRequestID, label, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.requestStatus(requestID), .cancelled, label, file: file, line: line)

        // 1) providerは取り消しを無視していて、まだ停止を確認できていない。その間は busy のまま
        XCTAssertEqual(fixture.provider.pendingCount, 1, label, file: file, line: line)
        XCTAssertTrue(fixture.coordinator.isBusy, label, file: file, line: line)
        XCTAssertNil(fixture.coordinator.currentReviewSession, label, file: file, line: line)

        // 2件目の依頼は、providerを呼ぶ前に busy で拒否する。
        // 誤って呼んでしまった場合にテストが止まらないよう、新しい呼び出しには即座に失敗を返させておく
        fixture.provider.immediateReply = .failure(SyntheticProviderFailure())
        await assertSendFails(fixture, .busy, file: file, line: line)
        XCTAssertEqual(fixture.provider.received.count, 1, label, file: file, line: line)
        XCTAssertTrue(fixture.coordinator.isBusy, label, file: file, line: line)
        XCTAssertTrue(fixture.coordinator.isCancelling, label, file: file, line: line)
        XCTAssertNil(fixture.coordinator.currentReviewSession, label, file: file, line: line)
        XCTAssertEqual(try workoutCount(fixture), 0, label, file: file, line: line)

        // 3) 旧providerが遅れて終わる。成功でも失敗でも、元の send は取り消しとして終わり、応答は使わない
        let validProposal = try proposalData(fixture)
        let reply: ScriptedProvider.Reply = switch lateReply {
        case .validProposal: .data(validProposal)
        case .providerFailure: .failure(SyntheticProviderFailure())
        case .cancellationError: .failure(CancellationError())
        }
        fixture.provider.reply(to: 0, with: reply, file: file, line: line)
        await assertCancelled(task, file: file, line: line)

        // 2) 停止を確認できた（元の send が戻った）時点で解放され、reviewも保存もない
        XCTAssertEqual(fixture.provider.pendingCount, 0, label, file: file, line: line)
        XCTAssertFalse(fixture.coordinator.isCancelling, label, file: file, line: line)
        try assertEndedWithoutReview(fixture, requestID: requestID, file: file, line: line)
        XCTAssertEqual(fixture.provider.received.count, 1, label, file: file, line: line)

        // 解放後の新しい依頼は受け付け、providerをちょうど1回呼ぶ
        let before = fixture.provider.received.count
        fixture.provider.immediateReply = .data(try proposalData(fixture))
        let session = try await sendForReview(fixture)
        XCTAssertEqual(fixture.provider.received.count, before + 1, label, file: file, line: line)
        XCTAssertNotEqual(session.requestID, requestID, label, file: file, line: line)
        XCTAssertEqual(session.status, .reviewing, label, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.requestStatus(requestID), .cancelled, label, file: file, line: line)
        XCTAssertEqual(try workoutCount(fixture), 0, label, file: file, line: line)
        try fixture.coordinator.cancelCurrent()
    }

    func testCancelCurrentKeepsBusyUntilIgnoringProviderEnds() async throws {
        for lateReply in LateReply.allCases {
            try await assertCancelledRequestKeepsBusyUntilProviderEnds(.coordinator, lateReply: lateReply)
        }
    }

    // 4) 元の send タスクを取り消した場合も同じ
    func testCallerTaskCancellationKeepsBusyUntilIgnoringProviderEnds() async throws {
        for lateReply in LateReply.allCases {
            try await assertCancelledRequestKeepsBusyUntilProviderEnds(.callerTask, lateReply: lateReply)
        }
    }

    func testCallerTaskThenCancelCurrentKeepsBusyUntilIgnoringProviderEnds() async throws {
        for lateReply in LateReply.allCases {
            try await assertCancelledRequestKeepsBusyUntilProviderEnds(.callerTaskThenCoordinator, lateReply: lateReply)
        }
    }

    // MARK: - providerが戻った後・review公開直前の取り消し

    // 確認画面の公開（active を .reviewing にする代入）の直前に起きたことを記録する。
    // onChange は非隔離の @Sendable クロージャなので、MainActor隔離のクラス（=Sendable）に入れて受け渡す
    @MainActor private final class PublishCancelProbe {
        // 公開直前の通知が来たか
        var fired = false
        // 通知の時点で、まだその依頼の応答待ちだったか（=取り消しの印がまだcoordinatorに届いていない）
        var wasSendingAtFire = false
        // 通知の時点で、providerの呼び出しがもう終わっていたか（保留中の数）
        var pendingAtFire: Int?
        // 取り消す前に、既に呼び出し元タスクが取り消されていたか（されていれば窓の外で取り消したことになる）
        var callerCancelledBeforeFire = true
        // 別スレッドからの取り消しが、公開の代入が終わる前に完了したか
        var cancelledFromOtherThread = false
    }

    // 別のOSスレッドから task を取り消し、終わるまで呼び出し元（MainActor）のスレッドを止めて待つ。
    // 取り消しは印を付けるだけで MainActor を必要としない（この時点の send には取り消しハンドラもない）ので、
    // 止めて待っても行き詰まらない。永久に待たないよう時間で区切り、間に合ったかを返す
    private nonisolated static func cancelFromAnotherThread(_ task: Task<UUID, Error>) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            task.cancel()
            done.signal()
        }
        thread.start()
        return done.wait(timeout: .now() + 5) == .success
    }

    // 前回の独立レビュー指摘（P2）の再現。send の withTaskCancellationHandler が囲むのは call.value の待機だけで、
    // その後の Task.isCancelled の確認から、同期的な decode → reviewSession → active = .reviewing までの間に
    // 他のスレッドから呼び出し元タスクが取り消されると、取り消し済みなのにreviewを返し、確認中（busy）のまま残る。
    //
    // 本番コードに差し込み口を足さずに、この窓へ決定的に取り消しを入れるため、Observation を使う。
    // coordinator は @Observable なので、active を変える代入は値を書き込む直前（willSet）に
    // withObservationTracking の onChange を同じスレッドで同期的に呼ぶ。登録後に active が変わるのは、
    // providerが正しい候補を返した後の「active = .reviewing(session)」だけなので（取り消し・失敗の経路は通らない）、
    // onChange の中は「providerが戻り、Task.isCancelled の確認とreview作成が済み、公開がまだ終わっていない」時点になる。
    // そこで別スレッドから呼び出し元タスクを取り消し、完了まで待ってから公開を続けさせる。
    //
    // 期待する動作: 取り消しが公開の完了より前に起きたので、候補は公開されず（send は cancelled で終わる）、
    // 何も保存せず、busy も解除され、後の新しい依頼は通常どおり成功する
    func testCallerTaskCancelledFromAnotherThreadJustBeforeReviewIsPublishedDiscardsReview() async throws {
        let fixture = try makeFixture()
        defer { fixture.provider.releaseAllPending() }
        let task = startSend(fixture)
        await fixture.provider.waitForCalls(1)
        let requestID = try XCTUnwrap(fixture.coordinator.sendingRequestID)

        // 応答待ちの今の active を読んで、次に active が変わる直前に通知を受ける（通知は1回だけ）。
        // 応答待ちの間 currentReviewSession が読むのは active だけ（session.status は読まない）
        let probe = PublishCancelProbe()
        let coordinator = fixture.coordinator
        let provider = fixture.provider
        withObservationTracking {
            _ = coordinator.currentReviewSession
        } onChange: {
            // active の書き込みは coordinator と同じ MainActor 上で起きるので、ここも MainActor 上で動いている
            MainActor.assumeIsolated {
                probe.fired = true
                // willSet の時点なので、active はまだ前の値（応答待ち）のはず
                probe.wasSendingAtFire = coordinator.sendingRequestID == requestID
                probe.pendingAtFire = provider.pendingCount
                probe.callerCancelledBeforeFire = task.isCancelled
                probe.cancelledFromOtherThread = Self.cancelFromAnotherThread(task)
            }
        }

        // 取り消しを無視しないproviderが、正しい候補を普通に返す（通信自体は正常に終わっている）
        fixture.provider.reply(to: 0, with: .data(try proposalData(fixture)))
        await assertCancelled(task)

        // 取り消しを狙った窓（providerが戻った後・review公開の直前）で起こせたことを確かめる。
        // ここが崩れたら、再現できていないので期待動作の確認より先に失敗として分かるようにする
        XCTAssertTrue(probe.fired, "review公開直前の通知が来なかった（active の変更を観測できていない）")
        XCTAssertTrue(probe.wasSendingAtFire, "通知の時点で応答待ちではなかった（取り消し・失敗の経路を通った）")
        XCTAssertEqual(probe.pendingAtFire, 0, "通知の時点でproviderの呼び出しが終わっていなかった")
        XCTAssertFalse(probe.callerCancelledBeforeFire, "公開直前より前に呼び出し元タスクが取り消されていた")
        XCTAssertTrue(probe.cancelledFromOtherThread, "別スレッドからの取り消しが時間内に終わらなかった")
        XCTAssertTrue(task.isCancelled)

        // 候補は公開されず、依頼はキャンセル済み、保存なし、busy も解除されている
        XCTAssertFalse(fixture.coordinator.isCancelling)
        try assertEndedWithoutReview(fixture, requestID: requestID)
        XCTAssertEqual(fixture.provider.received.count, 1)

        // 後の新しい依頼は受け付け、providerをちょうど1回呼び、確認中になる（まだ何も保存しない）
        fixture.provider.immediateReply = .data(try proposalData(fixture))
        let session = try await sendForReview(fixture)
        XCTAssertEqual(fixture.provider.received.count, 2)
        XCTAssertNotEqual(session.requestID, requestID)
        XCTAssertEqual(session.status, .reviewing)
        XCTAssertEqual(fixture.coordinator.currentReviewSession?.requestID, session.requestID)
        XCTAssertEqual(fixture.coordinator.requestStatus(requestID), .cancelled)
        XCTAssertEqual(try workoutCount(fixture), 0)
        try fixture.coordinator.cancelCurrent()
    }

    // MARK: - 聞き返し（不足情報の質問と、回答による継続）

    // 応答は {"kind": "askQuestion", "question": "..."} なら質問、{"kind": "createWorkout", ...} なら記録候補として区別する。
    // 会話の履歴（利用者が入力した文とAIの質問）はcoordinatorのメモリにだけ持ち、回答の送信時に history として渡す。
    // 過去のDBの記録は履歴に含めない

    private let firstQuestion = "合成の質問: 種目Aの重量は何kgですか？"
    private let firstAnswer = "合成の回答: 60kgです"
    private let otherMessage = "合成の依頼文: 種目Bを30分"
    private let otherQuestion = "合成の質問: 種目Bは何分ですか？"

    // 質問が返ったら、保存もreviewもせず、質問だけをメモリに持って回答を待つ（busy ではない）
    func testQuestionResponseKeepsQuestionWithoutReviewOrSaving() async throws {
        let fixture = try makeFixture()
        defer { fixture.provider.releaseAllPending() }
        let task = startSendOutcome(fixture, message)
        await fixture.provider.waitForCalls(1)
        let requestID = try XCTUnwrap(fixture.coordinator.sendingRequestID)
        // 新しい会話の最初の依頼では、履歴は空
        XCTAssertEqual(try sentHistory(fixture.provider.received[0]), [])

        fixture.provider.reply(to: 0, with: .data(try questionData(firstQuestion)))
        let outcome = try await task.value
        XCTAssertEqual(outcome, .question(firstQuestion))
        XCTAssertEqual(fixture.coordinator.pendingQuestion, firstQuestion)
        // 質問を受けた依頼は終了し、同じIDから後でreviewを作れない
        XCTAssertEqual(fixture.coordinator.requestStatus(requestID), .cancelled)
        XCTAssertNil(fixture.coordinator.currentReviewSession)
        XCTAssertNil(fixture.coordinator.sendingRequestID)
        XCTAssertFalse(fixture.coordinator.isBusy)
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture), 0)
    }

    // 質問公開時の finish が active を nil にする代入を、isBusy の同期 onChange から取り消す。
    // onChange は MainActor 上の willSet 中に同期実行されるため、cancelCurrent は active がまだ
    // .sending の間に .cancelling を書く。その後の finish の nil が上書きしないことを確認する。
    func testCancelFromSynchronousIsBusyObservationWhileQuestionIsPublishedPreservesConversation() async throws {
        let fixture = try makeFixture()
        defer { fixture.provider.releaseAllPending() }

        fixture.provider.immediateReply = .data(try questionData(firstQuestion))
        _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)
        let priorQuestion = try XCTUnwrap(fixture.coordinator.pendingQuestion)

        fixture.provider.immediateReply = nil
        let task = startAnswer(fixture, firstAnswer)
        await fixture.provider.waitForCalls(2)
        let requestID = try XCTUnwrap(fixture.coordinator.sendingRequestID)
        let coordinator = fixture.coordinator
        var onChangeFired = false

        // 送信開始後に登録し、質問公開時の finish による isBusy 依存値の変更を観測する。
        withObservationTracking {
            _ = coordinator.isBusy
        } onChange: {
            MainActor.assumeIsolated {
                guard !onChangeFired else { return }
                onChangeFired = true
                try? coordinator.cancelCurrent()
            }
        }

        fixture.provider.reply(to: 1, with: .data(try questionData(otherQuestion)))
        await assertCancelled(task)

        XCTAssertTrue(onChangeFired, "質問公開時の active 変更から同期通知されていない")
        XCTAssertEqual(fixture.coordinator.requestStatus(requestID), .cancelled)
        XCTAssertEqual(fixture.coordinator.pendingQuestion, priorQuestion)
        XCTAssertEqual(try sentHistory(fixture.provider.received[1]), [
            turn("user", message), turn("assistant", firstQuestion),
        ])
        XCTAssertFalse(fixture.coordinator.isBusy)
        XCTAssertNil(fixture.coordinator.sendingRequestID)
        XCTAssertNil(fixture.coordinator.currentReviewSession)
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture), 0)
    }

    // 候補公開中の active 更新を同期観測して取り消す。willSet 中は sendingRequestID がまだ残るため、
    // 取り消しを公開後に処理し忘れて review が返る競合を再現する。
    func testCancelFromSynchronousReviewPublicationObservationDiscardsReview() async throws {
        let fixture = try makeFixture()
        defer { fixture.provider.releaseAllPending() }
        let task = startSend(fixture)
        await fixture.provider.waitForCalls(1)
        let requestID = try XCTUnwrap(fixture.coordinator.sendingRequestID)
        let coordinator = fixture.coordinator
        var onChangeFired = false

        withObservationTracking {
            _ = coordinator.currentReviewSession
        } onChange: {
            MainActor.assumeIsolated {
                guard !onChangeFired else { return }
                onChangeFired = true
                try? coordinator.cancelCurrent()
            }
        }

        fixture.provider.reply(to: 0, with: .data(try proposalData(fixture)))
        await assertCancelled(task)

        XCTAssertTrue(onChangeFired, "review公開時のactive変更から同期通知されていない")
        try assertEndedWithoutReview(fixture, requestID: requestID)
        XCTAssertEqual(fixture.provider.received.count, 1)

        fixture.provider.immediateReply = .data(try proposalData(fixture))
        let nextSession = try await sendForReview(fixture)
        XCTAssertEqual(fixture.provider.received.count, 2)
        XCTAssertNotEqual(nextSession.requestID, requestID)
        XCTAssertEqual(nextSession.status, .reviewing)
        XCTAssertEqual(fixture.coordinator.currentReviewSession?.requestID, nextSession.requestID)
        XCTAssertTrue(fixture.coordinator.isBusy)
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture), 0)
        try fixture.coordinator.cancelCurrent()
    }

    // 回答には、同じ会話の直前までのやりとり（利用者の入力とAIの質問）を順に付けて送る。
    // 完全な候補が返ったときだけ確認画面の組になり、保存は既存の確認画面の承認経路でだけ行う
    func testAnswersCarrySameConversationHistoryAndCompleteProposalOpensReview() async throws {
        let fixture = try makeFixture()
        let secondQuestion = "合成の質問: 回数は何回ですか？"
        let secondAnswer = "合成の回答: 10回です"

        fixture.provider.immediateReply = .data(try questionData(firstQuestion))
        let first = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)
        XCTAssertEqual(Self.sent(first), .question(firstQuestion))

        fixture.provider.immediateReply = .data(try questionData(secondQuestion))
        let second = try await fixture.coordinator.answer(firstAnswer, in: fixture.context, calendar: calendar)
        XCTAssertEqual(Self.sent(second), .question(secondQuestion))
        XCTAssertEqual(fixture.coordinator.pendingQuestion, secondQuestion)
        XCTAssertEqual(try workoutCount(fixture), 0)

        fixture.provider.immediateReply = .data(try proposalData(fixture))
        let third = try await fixture.coordinator.answer(secondAnswer, in: fixture.context, calendar: calendar)
        let session = try Self.reviewSession(third)

        // 回答ごとに、今回の入力は message、直前までのやりとりは history で送る
        XCTAssertEqual(fixture.provider.received.count, 3)
        let answerJSON = try sentJSON(fixture.provider.received[1])
        XCTAssertEqual(Set(answerJSON.keys), Self.payloadKeys)
        XCTAssertEqual(answerJSON["message"] as? String, firstAnswer)
        XCTAssertEqual(try sentHistory(fixture.provider.received[1]), [turn("user", message), turn("assistant", firstQuestion)])
        XCTAssertEqual(fixture.provider.received[2].message, secondAnswer)
        XCTAssertEqual(try sentHistory(fixture.provider.received[2]),
                       [turn("user", message), turn("assistant", firstQuestion), turn("user", firstAnswer), turn("assistant", secondQuestion)])
        // 回答のたびに、送信時点の有効な定義をカタログとして送る
        XCTAssertEqual(fixture.provider.received[2].catalog, try AIWorkoutCatalog.make(in: fixture.context))

        // 完全な候補でも、承認するまでは保存しない。会話は終わり、回答待ちの質問は残らない
        XCTAssertEqual(session.status, .reviewing)
        XCTAssertEqual(fixture.coordinator.currentReviewSession?.id, session.id)
        XCTAssertNil(fixture.coordinator.pendingQuestion)
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture), 0)
        // 確認中は回答を送らない
        await assertAnswerFails(fixture, .busy, answer: "合成の追加の回答")
        XCTAssertEqual(fixture.provider.received.count, 3)

        guard case .saved = AIWorkoutProposalReviewFormAction.approve(session, in: fixture.context) else { return XCTFail("承認で保存されなかった") }
        XCTAssertEqual(try workoutCount(fixture), 1)
        XCTAssertFalse(fixture.coordinator.isBusy)
        // 会話は終わっているので、続けて回答はできない
        await assertAnswerFails(fixture, .noPendingQuestion, answer: "合成の追加の回答")
        XCTAssertEqual(fixture.provider.received.count, 3)
    }

    // 前の会話を cancelCurrent で破棄してから始めた新しい依頼（send）は新しい会話になり、前の会話の入力・質問を送らない
    func testNewConversationDoesNotCarryPreviousHistory() async throws {
        let fixture = try makeFixture()
        fixture.provider.immediateReply = .data(try questionData(firstQuestion))
        _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)
        XCTAssertEqual(fixture.coordinator.pendingQuestion, firstQuestion)

        // 回答待ちの質問は、確認なしには捨てない。破棄は cancelCurrent で明示的に行う
        try fixture.coordinator.cancelCurrent()
        XCTAssertNil(fixture.coordinator.pendingQuestion)
        XCTAssertFalse(fixture.coordinator.isBusy)

        fixture.provider.immediateReply = .data(try questionData(otherQuestion))
        let outcome = try await fixture.coordinator.send(otherMessage, in: fixture.context, calendar: calendar)
        XCTAssertEqual(Self.sent(outcome), .question(otherQuestion))
        XCTAssertEqual(fixture.provider.received[1].message, otherMessage)
        XCTAssertEqual(try sentHistory(fixture.provider.received[1]), [])
        XCTAssertEqual(fixture.coordinator.pendingQuestion, otherQuestion)

        // 回答には新しい会話のやりとりだけを付ける
        fixture.provider.immediateReply = .data(try proposalData(fixture))
        let answered = try await fixture.coordinator.answer(firstAnswer, in: fixture.context, calendar: calendar)
        _ = try Self.reviewSession(answered)
        XCTAssertEqual(try sentHistory(fixture.provider.received[2]), [turn("user", otherMessage), turn("assistant", otherQuestion)])
        let text = try XCTUnwrap(String(data: fixture.provider.received[2].payloadJSON(), encoding: .utf8))
        XCTAssertFalse(text.contains(message))
        XCTAssertFalse(text.contains(firstQuestion))
        try fixture.coordinator.cancelCurrent()
    }

    func testAnswerWithoutPendingQuestionOrEmptyAnswerIsRejectedWithoutSending() async throws {
        let fixture = try makeFixture()
        fixture.provider.immediateReply = .data(try proposalData(fixture))
        await assertAnswerFails(fixture, .noPendingQuestion, answer: firstAnswer)
        XCTAssertTrue(fixture.provider.received.isEmpty)
        try assertEndedWithoutReview(fixture, requestID: nil)

        fixture.provider.immediateReply = .data(try questionData(firstQuestion))
        _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)
        // 空の回答は送らず、質問はそのまま残る
        await assertAnswerFails(fixture, .emptyMessage, answer: " \n\t")
        XCTAssertEqual(fixture.provider.received.count, 1)
        XCTAssertEqual(fixture.coordinator.pendingQuestion, firstQuestion)
        XCTAssertFalse(fixture.coordinator.isBusy)
    }

    // 質問として読めない応答（文字列でない・空・長すぎる・余分な項目・候補との混在）は拒否し、
    // 質問もreviewも残さない。上限ちょうどの長さの質問は受け付ける
    func testInvalidQuestionResponsesAreRejected() async throws {
        let fixture = try makeFixture()
        let maxBytes = AIWorkoutChatLimits.maxQuestionBytes
        // "あ" は UTF-8 で3バイト。端数はASCIIで埋めて、ちょうど上限のバイト数にする
        let atLimit = String(repeating: "あ", count: maxBytes / 3) + String(repeating: "a", count: maxBytes % 3)
        XCTAssertEqual(atLimit.utf8.count, maxBytes)
        let proposalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: proposalData(fixture)) as? [String: Any])
        let entries = try XCTUnwrap(proposalObject["entries"])
        let proposalWithQuestion = proposalObject.merging(["question": firstQuestion]) { current, _ in current }
        let cases: [(String, Data, AIWorkoutChatError)] = [
            ("空文字", try questionData(""), .invalidQuestion),
            ("空白だけ", try questionData(" \n\t"), .invalidQuestion),
            ("数値", try questionData(42), .invalidQuestion),
            ("null", try questionData(NSNull()), .invalidQuestion),
            ("配列", try questionData(["合成の質問"]), .invalidQuestion),
            ("上限を1バイト超える", try questionData(atLimit + "a"), .invalidQuestion),
            ("質問のキーがない", try JSONSerialization.data(withJSONObject: ["kind": "askQuestion"]), .invalidQuestion),
            ("未知のフィールド", try questionData(firstQuestion, extra: ["extra": 1]), .invalidQuestion),
            ("質問に候補の項目が混ざる", try questionData(firstQuestion, extra: ["day": "2026-01-15", "entries": entries]), .invalidQuestion),
            ("候補に質問が混ざる", try JSONSerialization.data(withJSONObject: proposalWithQuestion), .proposal(.malformed)),
        ]
        for (label, data, expected) in cases {
            fixture.provider.immediateReply = .data(data)
            let before = fixture.provider.received.count
            await assertSendFails(fixture, expected)
            XCTAssertEqual(fixture.provider.received.count, before + 1, label)
            XCTAssertNil(fixture.coordinator.pendingQuestion, label)
            try assertEndedWithoutReview(fixture, requestID: nil)
        }

        fixture.provider.immediateReply = .data(try questionData(atLimit))
        let outcome = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)
        XCTAssertEqual(Self.sent(outcome), .question(atLimit))
        XCTAssertEqual(fixture.coordinator.pendingQuestion, atLimit)
    }

    // 回答の送信が失敗（通信エラー・不正な応答・不完全な候補）しても、直前の質問と履歴は残り、同じ履歴で答え直せる。
    // 失敗した回答は履歴に入れない
    func testFailedAnswerKeepsPreviousQuestionAndRetrySendsSameHistory() async throws {
        let fixture = try makeFixture()
        fixture.provider.immediateReply = .data(try questionData(firstQuestion))
        _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)
        let expectedHistory = [turn("user", message), turn("assistant", firstQuestion)]

        let failures: [(String, ScriptedProvider.Reply, AIWorkoutChatError)] = [
            ("通信エラー", .failure(SyntheticProviderFailure()), .providerFailed),
            ("不正な質問", .data(try questionData("")), .invalidQuestion),
            ("不完全な候補", .data(try proposalData(fixture, includeReps: false)), .proposal(.missingRequiredValue)),
        ]
        for (index, (label, reply, expected)) in failures.enumerated() {
            fixture.provider.immediateReply = reply
            await assertAnswerFails(fixture, expected, answer: "合成の失敗する回答\(index)")
            XCTAssertEqual(fixture.provider.received.count, index + 2, label)
            XCTAssertEqual(try sentHistory(fixture.provider.received[index + 1]), expectedHistory, label)
            XCTAssertEqual(fixture.coordinator.pendingQuestion, firstQuestion, label)
            XCTAssertNil(fixture.coordinator.currentReviewSession, label)
            XCTAssertFalse(fixture.coordinator.isBusy, label)
            XCTAssertEqual(try workoutCount(fixture), 0, label)
        }

        // 答え直すと、失敗した回答を含まない同じ履歴で送る
        fixture.provider.immediateReply = .data(try proposalData(fixture))
        let outcome = try await fixture.coordinator.answer(firstAnswer, in: fixture.context, calendar: calendar)
        _ = try Self.reviewSession(outcome)
        let last = try XCTUnwrap(fixture.provider.received.last)
        XCTAssertEqual(last.message, firstAnswer)
        XCTAssertEqual(try sentHistory(last), expectedHistory)
        try fixture.coordinator.cancelCurrent()
    }

    // 回答の送信中に取り消すと、providerが戻るまではキャンセル中で busy。遅れて届いた質問は使わず、
    // 履歴にも入れない（直前の質問は残る）。その後の新しい会話には前の会話のやりとりを送らない
    func testCancelledAnswerDiscardsLateQuestionAndNewConversationIsSeparate() async throws {
        let fixture = try makeFixture()
        defer { fixture.provider.releaseAllPending() }
        let lateQuestion = "合成の遅れて届いた質問"
        fixture.provider.immediateReply = .data(try questionData(firstQuestion))
        _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)

        fixture.provider.immediateReply = nil
        let task = startAnswer(fixture, firstAnswer)
        await fixture.provider.waitForCalls(2)
        let requestID = try XCTUnwrap(fixture.coordinator.sendingRequestID)
        try fixture.coordinator.cancelCurrent()
        XCTAssertEqual(fixture.coordinator.cancellingRequestID, requestID)
        XCTAssertTrue(fixture.coordinator.isBusy)

        // 停止を確認するまでは、回答も新しい依頼も送らない
        fixture.provider.immediateReply = .failure(SyntheticProviderFailure())
        await assertAnswerFails(fixture, .busy, answer: firstAnswer)
        await assertSendFails(fixture, .busy)
        XCTAssertEqual(fixture.provider.received.count, 2)

        fixture.provider.reply(to: 1, with: .data(try questionData(lateQuestion)))
        await assertCancelled(task)
        XCTAssertFalse(fixture.coordinator.isBusy)
        XCTAssertEqual(fixture.coordinator.requestStatus(requestID), .cancelled)
        // 遅れた質問は採用せず、直前の質問が残る
        XCTAssertEqual(fixture.coordinator.pendingQuestion, firstQuestion)
        XCTAssertNil(fixture.coordinator.currentReviewSession)

        // 質問が残っている間は、新しい依頼を送らない。もう一度 cancelCurrent すると会話全体を破棄できる
        fixture.provider.immediateReply = .data(try questionData(otherQuestion))
        await assertSendFails(fixture, .questionPending, message: otherMessage)
        XCTAssertEqual(fixture.provider.received.count, 2)
        try fixture.coordinator.cancelCurrent()
        XCTAssertNil(fixture.coordinator.pendingQuestion)

        // 新しい会話は空の履歴で始まる
        let outcome = try await fixture.coordinator.send(otherMessage, in: fixture.context, calendar: calendar)
        XCTAssertEqual(Self.sent(outcome), .question(otherQuestion))
        XCTAssertEqual(try sentHistory(fixture.provider.received[2]), [])

        fixture.provider.immediateReply = .data(try proposalData(fixture))
        let answered = try await fixture.coordinator.answer("合成の回答: 30分です", in: fixture.context, calendar: calendar)
        _ = try Self.reviewSession(answered)
        XCTAssertEqual(try sentHistory(fixture.provider.received[3]), [turn("user", otherMessage), turn("assistant", otherQuestion)])
        // 新しい会話の送信内容に、前の会話の入力・質問・回答と遅れた質問が含まれない
        for request in fixture.provider.received[2...] {
            let text = try XCTUnwrap(String(data: request.payloadJSON(), encoding: .utf8))
            for marker in [message, firstQuestion, firstAnswer, lateQuestion] {
                XCTAssertFalse(text.contains(marker), marker)
            }
        }
        try fixture.coordinator.cancelCurrent()
    }

    // 回答の送信中は、2回目の回答も新しい依頼も送らない（busy）
    func testSecondAnswerOrSendWhileAnswerIsWaitingIsBusy() async throws {
        let fixture = try makeFixture()
        defer { fixture.provider.releaseAllPending() }
        fixture.provider.immediateReply = .data(try questionData(firstQuestion))
        _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)

        fixture.provider.immediateReply = nil
        let task = startAnswer(fixture, firstAnswer)
        await fixture.provider.waitForCalls(2)

        // 誤って呼んでしまった場合にテストが止まらないよう、新しい呼び出しには即座に失敗を返させておく
        fixture.provider.immediateReply = .failure(SyntheticProviderFailure())
        await assertAnswerFails(fixture, .busy, answer: "合成の二重の回答")
        await assertSendFails(fixture, .busy)
        XCTAssertEqual(fixture.provider.received.count, 2)

        fixture.provider.reply(to: 1, with: .data(try proposalData(fixture)))
        let outcome = try await task.value
        guard case let .review(requestID) = outcome else { return XCTFail("候補が返らなかった: \(outcome)") }
        XCTAssertEqual(fixture.coordinator.currentReviewSession?.requestID, requestID)
        XCTAssertNil(fixture.coordinator.pendingQuestion)
        XCTAssertEqual(try workoutCount(fixture), 0)
        try fixture.coordinator.cancelCurrent()
    }

    // 履歴の件数が上限を超える回答は、古いやりとりを捨てて送るのではなく、送らずにエラーで会話を止める。
    // 上限ちょうどの履歴は、最初の入力から順にすべて送る
    func testHistoryTurnLimitStopsConversationWithErrorWithoutDroppingTurns() async throws {
        let fixture = try makeFixture()
        let maxTurns = AIWorkoutChatLimits.maxHistoryTurns
        // 1往復で履歴は2件（回答と質問）増える。上限ちょうどまで答えられるよう、偶数であることを前提にする
        XCTAssertEqual(maxTurns % 2, 0)
        fixture.provider.immediateReply = .data(try questionData("合成の質問0"))
        _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)
        var expected = [turn("user", message), turn("assistant", "合成の質問0")]

        // 送る履歴が上限ちょうどになるまで答える（各回答にも質問が返る）
        for round in 1...(maxTurns / 2) {
            fixture.provider.immediateReply = .data(try questionData("合成の質問\(round)"))
            let outcome = try await fixture.coordinator.answer("合成の回答\(round)", in: fixture.context, calendar: calendar)
            XCTAssertEqual(Self.sent(outcome), .question("合成の質問\(round)"), "\(round)")
            XCTAssertEqual(try sentHistory(XCTUnwrap(fixture.provider.received.last)), expected, "\(round)")
            expected += [turn("user", "合成の回答\(round)"), turn("assistant", "合成の質問\(round)")]
        }
        XCTAssertEqual(expected.count, maxTurns + 2)

        // 次の回答は履歴が上限を超えるので送らない。会話は止まり、何も保存しない
        let sentCount = fixture.provider.received.count
        fixture.provider.immediateReply = .data(try proposalData(fixture))
        await assertAnswerFails(fixture, .conversationLimitExceeded, answer: "合成の上限を超える回答")
        XCTAssertEqual(fixture.provider.received.count, sentCount)
        XCTAssertNil(fixture.coordinator.pendingQuestion)
        XCTAssertNil(fixture.coordinator.currentReviewSession)
        XCTAssertFalse(fixture.coordinator.isBusy)
        XCTAssertEqual(try workoutCount(fixture), 0)
        await assertAnswerFails(fixture, .noPendingQuestion, answer: "合成の上限を超える回答")
        XCTAssertEqual(fixture.provider.received.count, sentCount)

        // 新しい会話は空の履歴で始められる
        let next = try await sendForReview(fixture)
        XCTAssertEqual(try sentHistory(XCTUnwrap(fixture.provider.received.last)), [])
        XCTAssertEqual(next.status, .reviewing)
        try fixture.coordinator.cancelCurrent()
    }

    // 会話の文（履歴＋今回の入力）の合計の長さが上限を超える送信はせず、エラーで止める。上限ちょうどは送る
    func testConversationByteLimitStopsWithErrorWithoutSending() async throws {
        let fixture = try makeFixture()
        let maxBytes = AIWorkoutChatLimits.maxConversationBytes
        fixture.provider.immediateReply = .data(try questionData(firstQuestion))
        // 最初の依頼文だけで上限を超える場合も送らない
        await assertSendFails(fixture, .conversationLimitExceeded, message: String(repeating: "a", count: maxBytes + 1))
        XCTAssertTrue(fixture.provider.received.isEmpty)
        XCTAssertFalse(fixture.coordinator.isBusy)

        _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)
        // 履歴（依頼文と質問）と合わせて、ちょうど上限になる回答は送る
        let fitting = String(repeating: "a", count: maxBytes - message.utf8.count - firstQuestion.utf8.count)
        let secondQuestion = "合成の質問: 回数は何回ですか？"
        fixture.provider.immediateReply = .data(try questionData(secondQuestion))
        let outcome = try await fixture.coordinator.answer(fitting, in: fixture.context, calendar: calendar)
        XCTAssertEqual(Self.sent(outcome), .question(secondQuestion))
        XCTAssertEqual(fixture.provider.received.count, 2)
        XCTAssertEqual(fixture.provider.received[1].message, fitting)

        // 次の回答は、どれだけ短くても合計が上限を超えるので送らず、会話を止める
        await assertAnswerFails(fixture, .conversationLimitExceeded, answer: "a")
        XCTAssertEqual(fixture.provider.received.count, 2)
        XCTAssertNil(fixture.coordinator.pendingQuestion)
        XCTAssertFalse(fixture.coordinator.isBusy)
        XCTAssertEqual(try workoutCount(fixture), 0)
    }

    // 回答は会話を始めた保存先（container）のcontextでだけ受け付ける。別の保存先なら送らず、質問は残す
    // （別の保存先の定義をカタログとして送らないため）
    func testAnswerWithContextOfAnotherStoreIsRejectedWithoutSending() async throws {
        let fixture = try makeFixture()
        let other = try makeFixture()
        fixture.provider.immediateReply = .data(try questionData(firstQuestion))
        _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)

        fixture.provider.immediateReply = .data(try proposalData(fixture))
        await assertAnswerFails(fixture, .request(.storeMismatch), answer: firstAnswer, in: other.context)
        XCTAssertEqual(fixture.provider.received.count, 1)
        XCTAssertEqual(fixture.coordinator.pendingQuestion, firstQuestion)
        XCTAssertFalse(fixture.coordinator.isBusy)
        XCTAssertEqual(try workoutCount(other), 0)
    }

    // 回答待ちの質問がある間の send は、会話を黙って捨てずに questionPending で拒否し、何も送らない。
    // 回答の失敗後も同じ。cancelCurrent で会話全体を破棄した後は、回答できず、新しい依頼を送れる
    func testSendWhileQuestionIsPendingIsRejectedAndCancelCurrentDiscardsConversation() async throws {
        let fixture = try makeFixture()
        fixture.provider.immediateReply = .data(try questionData(firstQuestion))
        _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)

        // 誤って送ってしまった場合も、候補が返って会話が終わらないよう失敗を返させておく
        fixture.provider.immediateReply = .failure(SyntheticProviderFailure())
        await assertSendFails(fixture, .questionPending, message: otherMessage)
        XCTAssertEqual(fixture.provider.received.count, 1)
        XCTAssertEqual(fixture.coordinator.pendingQuestion, firstQuestion)
        XCTAssertFalse(fixture.coordinator.isBusy)
        // 空の依頼文は、質問の有無より先に emptyMessage で拒否する
        await assertSendFails(fixture, .emptyMessage, message: " ")

        // 回答の送信が失敗しても、質問は残り、send は引き続き拒否する
        await assertAnswerFails(fixture, .providerFailed, answer: firstAnswer)
        XCTAssertEqual(fixture.provider.received.count, 2)
        XCTAssertEqual(fixture.coordinator.pendingQuestion, firstQuestion)
        await assertSendFails(fixture, .questionPending, message: otherMessage)
        XCTAssertEqual(fixture.provider.received.count, 2)

        // 会話全体の破棄は cancelCurrent で明示的に行う。何度呼んでもよく、何も送らず、何も保存しない
        try fixture.coordinator.cancelCurrent()
        try fixture.coordinator.cancelCurrent()
        XCTAssertNil(fixture.coordinator.pendingQuestion)
        try assertEndedWithoutReview(fixture, requestID: nil)
        await assertAnswerFails(fixture, .noPendingQuestion, answer: firstAnswer)
        XCTAssertEqual(fixture.provider.received.count, 2)

        // 破棄後の新しい依頼は空の履歴で送り、前の会話の文を含まない
        fixture.provider.immediateReply = .data(try proposalData(fixture))
        let session = try await sendForReview(fixture, otherMessage)
        let last = try XCTUnwrap(fixture.provider.received.last)
        XCTAssertEqual(fixture.provider.received.count, 3)
        XCTAssertEqual(try sentHistory(last), [])
        let text = try XCTUnwrap(String(data: last.payloadJSON(), encoding: .utf8))
        for marker in [message, firstQuestion, firstAnswer] {
            XCTAssertFalse(text.contains(marker), marker)
        }
        XCTAssertEqual(session.status, .reviewing)
        XCTAssertEqual(try workoutCount(fixture), 0)
        try fixture.coordinator.cancelCurrent()
    }

    // 回答を送っている呼び出し元のタスクが取り消されたら、遅れて届いた質問は使わず、直前の質問と履歴を残す。
    // 答え直すと、取り消した回答を含まない同じ履歴で送る
    func testCallerTaskCancellationOfAnswerKeepsQuestionAndRetrySendsSameHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.provider.releaseAllPending() }
        let lateQuestion = "合成の遅れて届いた質問"
        fixture.provider.immediateReply = .data(try questionData(firstQuestion))
        _ = try await fixture.coordinator.send(message, in: fixture.context, calendar: calendar)
        let expectedHistory = [turn("user", message), turn("assistant", firstQuestion)]

        fixture.provider.immediateReply = nil
        let task = startAnswer(fixture, "合成の取り消される回答")
        await fixture.provider.waitForCalls(2)
        let requestID = try XCTUnwrap(fixture.coordinator.sendingRequestID)
        task.cancel()
        await waitUntilCancelling(fixture)
        XCTAssertTrue(fixture.coordinator.isBusy)

        fixture.provider.reply(to: 1, with: .data(try questionData(lateQuestion)))
        await assertCancelled(task)
        XCTAssertFalse(fixture.coordinator.isBusy)
        XCTAssertEqual(fixture.coordinator.requestStatus(requestID), .cancelled)
        XCTAssertEqual(fixture.coordinator.pendingQuestion, firstQuestion)
        XCTAssertNil(fixture.coordinator.currentReviewSession)

        fixture.provider.immediateReply = .data(try proposalData(fixture))
        let outcome = try await fixture.coordinator.answer(firstAnswer, in: fixture.context, calendar: calendar)
        let session = try Self.reviewSession(outcome)
        let last = try XCTUnwrap(fixture.provider.received.last)
        XCTAssertEqual(fixture.provider.received.count, 3)
        XCTAssertEqual(last.message, firstAnswer)
        XCTAssertEqual(try sentHistory(last), expectedHistory)
        let text = try XCTUnwrap(String(data: last.payloadJSON(), encoding: .utf8))
        XCTAssertFalse(text.contains(lateQuestion))
        XCTAssertFalse(text.contains("合成の取り消される回答"))
        XCTAssertNil(fixture.coordinator.pendingQuestion)
        XCTAssertEqual(session.status, .reviewing)
        XCTAssertEqual(try workoutCount(fixture), 0)
        try fixture.coordinator.cancelCurrent()
    }
}
