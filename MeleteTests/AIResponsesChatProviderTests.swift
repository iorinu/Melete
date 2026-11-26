import XCTest
import SwiftData
@testable import Melete

// すべて合成のSSE chunkとmemory-only storeを使う。ネットワーク・認証・実データには触れない。
@MainActor
final class AIResponsesChatProviderTests: XCTestCase {
    private final class SyntheticTransport: AIResponsesChunkTransport {
        private(set) var receivedBody: Data?
        private let chunksToReturn: [Data]

        init(chunks: [Data]) { chunksToReturn = chunks }

        func receive(body: Data, onChunk: @MainActor (Data) throws -> Void) async throws {
            receivedBody = body
            for chunk in chunksToReturn { try onChunk(chunk) }
        }
    }

    private final class ThrowingTransport: AIResponsesChunkTransport {
        private let chunks: [Data]
        private let failure: any Error

        init(chunks: [Data] = [], failure: any Error) {
            self.chunks = chunks
            self.failure = failure
        }

        func receive(body: Data, onChunk: @MainActor (Data) throws -> Void) async throws {
            for chunk in chunks { try onChunk(chunk) }
            throw failure
        }
    }

    private final class ReleaseGatedTransport: AIResponsesChunkTransport {
        private(set) var receiveCount = 0
        private(set) var cancellationObserved = false
        private(set) var deliveredChunkCount = 0
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func receive(body: Data, onChunk: @MainActor (Data) throws -> Void) async throws {
            receiveCount += 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    releaseContinuation = continuation
                }
            } onCancel: {
                Task { @MainActor in self.cancellationObserved = true }
            }
            let answer = #"{"kind":"askQuestion","question":"遅延した質問"}"#
            try onChunk(try AIResponsesChatProviderTests.makeDeltaEvent(answer))
            deliveredChunkCount += 1
            try onChunk(Data("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n".utf8))
            deliveredChunkCount += 1
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    // 不正な合成SSEを1回だけcallbackへ渡し、callbackのthrowをそのまま投げ直す合成transport。
    // cancelsCurrentTaskがtrueなら、callbackより前にreceiveを実行中のTask自身を取消す。
    // 状態はインスタンスごとに持ち、テスト間で共有しない。
    private final class InvalidSSECallbackTransport: AIResponsesChunkTransport {
        // JSONとして解釈できないdata行。parserはmalformedEventで失敗する
        static let invalidChunk = Data("data: {synthetic-invalid-json\n\n".utf8)

        private let cancelsCurrentTask: Bool
        private(set) var receiveCount = 0
        private(set) var callbackCount = 0
        private(set) var cancelledBeforeCallback = false
        private(set) var callbackError: (any Error)?

        init(cancelsCurrentTask: Bool) { self.cancelsCurrentTask = cancelsCurrentTask }

        func receive(body: Data, onChunk: @MainActor (Data) throws -> Void) async throws {
            receiveCount += 1
            if cancelsCurrentTask {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            cancelledBeforeCallback = Task.isCancelled
            callbackCount += 1
            do {
                try onChunk(Self.invalidChunk)
            } catch {
                callbackError = error
                throw error
            }
        }
    }

    // provider.sendを別Taskで動かし、制限時間付きで終了を待つ。取消するTaskをテスト本体と分けるため。
    // 制限を超えたらTaskを取消し、さらに制限時間付きで終了を待って回収する。回収できなければ明示的に失敗させる。
    // 合成transportの状態はテストごとのインスタンスなので、回収できなくても他のテストの状態は汚さない。
    private func runProviderSend(_ provider: AIResponsesChatProvider, request: AIWorkoutChatRequest,
                                 timeout: TimeInterval = 5,
                                 reclaimTimeout: TimeInterval = 5) async -> Result<AIWorkoutChatResponse, any Error>? {
        @MainActor final class Box {
            var result: Result<AIWorkoutChatResponse, any Error>?
        }
        let box = Box()
        let task = Task { @MainActor in
            do {
                box.result = .success(try await provider.send(request))
            } catch {
                box.result = .failure(error)
            }
        }
        if await waitWithin(seconds: timeout, { box.result != nil }) {
            return box.result
        }
        task.cancel()
        if await waitWithin(seconds: reclaimTimeout, { box.result != nil }) {
            XCTFail("provider.sendが制限時間内に終わらなかった（取消後に回収済み）")
        } else {
            XCTFail("provider.sendが制限時間内に終わらず、取消後も回収できなかった")
        }
        return nil
    }

    // 取消済みのTaskで、transportが不正SSEをcallbackへ渡してparser failureを返しても、
    // provider.sendはparserの失敗ではなくCancellationErrorで終わる。
    func testCancellationWinsOverParserFailureReturnedFromCallback() async throws {
        let request = try await captureValidChatRequest()
        let transport = InvalidSSECallbackTransport(cancelsCurrentTask: true)
        let provider = AIResponsesChatProvider(model: "synthetic-model", transport: transport)

        let result = await runProviderSend(provider, request: request)

        XCTAssertEqual(transport.receiveCount, 1)
        XCTAssertTrue(transport.cancelledBeforeCallback, "callbackより前に同じTaskが取消されていない")
        XCTAssertEqual(transport.callbackCount, 1)
        XCTAssertEqual(transport.callbackError as? AIResponsesStreamFailure, .malformedEvent,
                       "callbackがparser failureを返していない")
        guard case .failure(let error)? = result else {
            return XCTFail("CancellationErrorで終わるべき: \(String(describing: result))")
        }
        XCTAssertTrue(error is CancellationError, "取消がparser failureより優先されるべき: \(error)")
        XCTAssertNil(error as? AIResponsesStreamFailure, "取消済みなのにparser failureがそのまま投げられた")
    }

    // 対照: 取消がなければ、callbackが返したparser failureをそのまま投げる。
    func testParserFailureFromCallbackIsKeptWithoutCancellation() async throws {
        let request = try await captureValidChatRequest()
        let transport = InvalidSSECallbackTransport(cancelsCurrentTask: false)
        let provider = AIResponsesChatProvider(model: "synthetic-model", transport: transport)

        let result = await runProviderSend(provider, request: request)

        XCTAssertEqual(transport.receiveCount, 1)
        XCTAssertFalse(transport.cancelledBeforeCallback)
        XCTAssertEqual(transport.callbackCount, 1)
        XCTAssertEqual(transport.callbackError as? AIResponsesStreamFailure, .malformedEvent)
        guard case .failure(let error)? = result else {
            return XCTFail("parser failureで終わるべき: \(String(describing: result))")
        }
        XCTAssertEqual(error as? AIResponsesStreamFailure, .malformedEvent, "parser failureをそのまま投げるべき: \(error)")
    }

    func testSyntheticChunksReturnQuestionWithoutSavingWorkout() async throws {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("AIResponsesChatProviderMemory-\(UUID())", schema: schema,
                                                isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        context.insert(Exercise(name: "合成スクワット", metrics: [metric]))
        try context.save()

        let answer = #"{"kind":"askQuestion","question":"何回行いましたか？"}"#
        let first = try Self.makeDeltaEvent(String(answer.prefix(17)))
        let remainder = String(answer.dropFirst(17))
        let second = try Self.makeDeltaEvent(remainder)
        let completed = Data("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n".utf8)
        let transport = SyntheticTransport(chunks: [first, second, completed])
        let provider = AIResponsesChatProvider(model: "synthetic-model", transport: transport)
        let instant = ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z")!
        let coordinator = AIWorkoutChatCoordinator(provider: provider, now: { instant })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        let outcome = try await coordinator.send("合成の質問依頼", in: context, calendar: calendar)

        guard case let .question(question) = outcome else { return XCTFail("質問が返ること") }
        XCTAssertEqual(question, "何回行いましたか？")
        let receivedBody = transport.receivedBody
        let body = try XCTUnwrap(receivedBody)
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(bodyJSON["store"] as? Bool, false)
        XCTAssertEqual(bodyJSON["stream"] as? Bool, true)
        XCTAssertNil(bodyJSON["tools"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Workout>()), 0)
        XCTAssertFalse(context.hasChanges)
    }

    func testIncompleteAndFailedStreamsNeverReturnPartialOutput() async throws {
        let partial = try Self.makeDeltaEvent(#"{"kind":"askQuestion","question":"途中の内容"}"#)
        let cases: [(String, [Data])] = [
            ("incomplete EOF", [partial]),
            ("response.failed", [partial, Data("event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{}}\n\n".utf8)]),
        ]

        for (label, chunks) in cases {
            let provider = AIResponsesChatProvider(model: "synthetic-model", transport: SyntheticTransport(chunks: chunks))
            let coordinator = AIWorkoutChatCoordinator(provider: provider)
            do {
                _ = try await coordinator.send("合成依頼", in: makeMemoryContext(), calendar: Calendar(identifier: .gregorian))
                XCTFail("\(label) は失敗すること")
            } catch let error as AIWorkoutChatError {
                XCTAssertEqual(error, .providerFailed)
                XCTAssertFalse(String(describing: error).contains("途中の内容"))
            }
        }
    }

    func testUnknownTransportErrorDoesNotLeakThroughProviderOrCoordinator() async throws {
        struct MarkerError: Error { let message = "synthetic-transport-secret-marker" }
        let partial = try Self.makeDeltaEvent(#"{"kind":"askQuestion","question":"synthetic partial"}"#)
        let provider = AIResponsesChatProvider(model: "synthetic-model", transport: ThrowingTransport(chunks: [partial], failure: MarkerError()))
        let context = try makeMemoryContext()
        let coordinator = AIWorkoutChatCoordinator(provider: provider)
        do {
            _ = try await coordinator.send("合成依頼", in: context, calendar: Calendar(identifier: .gregorian))
            XCTFail("provider errorはUI向けの固定エラーになること")
        } catch let error as AIWorkoutChatError {
            XCTAssertEqual(error, .providerFailed)
            XCTAssertFalse(String(describing: error).contains("synthetic-transport-secret-marker"))
        }
    }

    func testProviderSendItselfDoesNotLeakUnknownTransportErrorMarker() async throws {
        // coordinator側の固定エラー化だけでは、provider自身がマーカーを漏らしても検出できない。
        // AIWorkoutChatRequest.init は fileprivate なので、実coordinatorで作られたrequestを捕捉して使う。
        struct MarkerError: Error, CustomStringConvertible, LocalizedError {
            static var marker: String { "synthetic-provider-direct-secret-marker" }
            var description: String { Self.marker }
            var errorDescription: String? { Self.marker }
        }
        let request = try await captureValidChatRequest()
        let partial = try Self.makeDeltaEvent(#"{"kind":"askQuestion","question":"synthetic partial"}"#)
        let provider = AIResponsesChatProvider(model: "synthetic-model",
                                               transport: ThrowingTransport(chunks: [partial], failure: MarkerError()))

        do {
            _ = try await provider.send(request)
            XCTFail("未知のtransport errorは失敗として返ること")
        } catch {
            XCTAssertEqual(error as? AIResponsesChatProviderError, .transportFailed)
            XCTAssertFalse(String(describing: error).contains(MarkerError.marker))
            XCTAssertFalse(error.localizedDescription.contains(MarkerError.marker))
        }
    }

    func testCancellationKeepsCoordinatorBusyUntilTransportReleaseAndDiscardsLateReply() async throws {
        let transport = ReleaseGatedTransport()
        defer { transport.release() }
        let provider = AIResponsesChatProvider(model: "synthetic-model", transport: transport)
        let context = try makeMemoryContext()
        let coordinator = AIWorkoutChatCoordinator(provider: provider)
        let first = Task { try await coordinator.send("最初の依頼", in: context, calendar: Calendar(identifier: .gregorian)) }

        let started = await waitUntil { transport.receiveCount == 1 }
        guard started else { return XCTFail("transport開始をbounded waitで確認") }
        try coordinator.cancelCurrent()
        let cancellationObserved = await waitUntil { transport.cancellationObserved }
        guard cancellationObserved else { return XCTFail("transportがキャンセル指示を観測すること") }
        XCTAssertTrue(coordinator.isBusy)
        do {
            _ = try await coordinator.send("二つ目", in: context, calendar: Calendar(identifier: .gregorian))
            XCTFail("release前は新規送信を拒否すること")
        } catch let error as AIWorkoutChatError {
            XCTAssertEqual(error, .busy)
        }

        transport.release()
        let firstFinished = await waitUntil { !coordinator.isBusy }
        guard firstFinished else { return XCTFail("release後に bounded wait で依頼終了を確認") }
        XCTAssertEqual(transport.deliveredChunkCount, 2, "cancel済みでも正常SSE chunkが実際にcallbackへ渡ること")
        do {
            _ = try await first.value
            XCTFail("取り消し済みの遅延応答は破棄されること")
        } catch let error as AIWorkoutChatError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(coordinator.isBusy)
        // 次の依頼が受理されることを確認し、transportは即時にキャンセル扱いで終了させる。
        let next = Task { try await coordinator.send("release後の依頼", in: context, calendar: Calendar(identifier: .gregorian)) }
        let nextStarted = await waitUntil { transport.receiveCount == 2 }
        guard nextStarted else { return XCTFail("次のtransport開始をbounded waitで確認") }
        next.cancel()
        transport.release()
        let nextFinished = await waitUntil { !coordinator.isBusy }
        guard nextFinished else { return XCTFail("次の依頼も bounded wait で終了を確認") }
        _ = try? await next.value
        XCTAssertNil(coordinator.pendingQuestion)
    }

    // 実coordinatorが作ったrequestを記録し、合成の質問を返すだけの擬似provider。通信はしない
    private final class RequestCapturingProvider: AIWorkoutChatProvider {
        private(set) var capturedRequest: AIWorkoutChatRequest?

        func send(_ request: AIWorkoutChatRequest) async throws -> AIWorkoutChatResponse {
            capturedRequest = request
            return AIWorkoutChatResponse(json: Data(#"{"kind":"askQuestion","question":"合成の質問"}"#.utf8))
        }
    }

    // memory-only の合成storeで実coordinator.sendを通し、有効なAIWorkoutChatRequestを得る
    private func captureValidChatRequest() async throws -> AIWorkoutChatRequest {
        let context = try makeMemoryContext()
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        context.insert(Exercise(name: "合成スクワット", metrics: [metric]))
        try context.save()
        let capturing = RequestCapturingProvider()
        let coordinator = AIWorkoutChatCoordinator(provider: capturing)
        _ = try await coordinator.send("合成依頼", in: context, calendar: Calendar(identifier: .gregorian))
        let captured = capturing.capturedRequest
        return try XCTUnwrap(captured, "coordinatorがproviderへrequestを渡すこと")
    }

    private func makeMemoryContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("AIResponsesChatProviderTest-\(UUID())", schema: schema,
                                                isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MainActorを手放しながら条件を待つ。制限時間を過ぎたら最後に一度だけ確かめて返す。
    private func waitWithin(seconds: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static func makeDeltaEvent(_ delta: String) throws -> Data {
        let event: [String: Any] = [
            "type": "response.output_text.delta",
            "item_id": "msg_synthetic",
            "output_index": 0,
            "content_index": 0,
            "delta": delta,
        ]
        let json = try JSONSerialization.data(withJSONObject: event)
        let data = String(decoding: json, as: UTF8.self)
        return Data("event: response.output_text.delta\ndata: \(data)\n\n".utf8)
    }
}
