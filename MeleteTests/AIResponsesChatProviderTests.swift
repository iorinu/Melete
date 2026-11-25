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
