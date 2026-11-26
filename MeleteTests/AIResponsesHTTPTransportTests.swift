import XCTest
@testable import Melete

// 実endpoint・実credential・ネットワークには触れない。
// request生成はURLSessionを呼ばない純粋関数として検証し、
// ストリーミングは独自スキームとtest専用URLProtocolだけで検証する。
@MainActor
final class AIResponsesHTTPTransportTests: XCTestCase {
    // 実credentialではない固定ダミー。これ以外の認証情報はテストで使わない。
    private static let dummyCredential = "melete-synthetic-dummy-credential"

    func testProductionRequestUsesOfficialEndpointAndStreamingHeaders() throws {
        let body = Data(#"{"model":"synthetic-model","stream":true}"#.utf8)

        // URLRequestを組み立てるだけで、URLSessionには渡さない。
        let request = try AIResponsesHTTPRequestFactory.makeProductionRequest(
            credential: Self.dummyCredential, body: body)

        XCTAssertEqual(request.url, URL(string: "https://api.openai.com/v1/responses"))
        XCTAssertEqual(request.url, AIResponsesHTTPRequestFactory.productionEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.dummyCredential)")
        XCTAssertEqual(request.httpBody, body)
    }

    func testProductionRequestRejectsInvalidCredential() {
        let body = Data("{}".utf8)
        // 空白・タブを含む値は黙ってtrimせず、すべて拒否する(合成ダミーのみ)。
        let invalidCredentials = [
            "", "   ", "dummy\nInjected: value", "dummy\r\n",
            " melete-synthetic-dummy", "melete-synthetic-dummy ",
            "melete-synthetic dummy", "melete-synthetic\tdummy",
        ]
        for credential in invalidCredentials {
            XCTAssertThrowsError(try AIResponsesHTTPRequestFactory.makeProductionRequest(
                credential: credential, body: body)) { error in
                XCTAssertEqual(error as? AIResponsesHTTPTransportError, .invalidCredential)
            }
        }
    }

    func testErrorsDoNotExposeHeadersOrCredential() {
        let errors: [AIResponsesHTTPTransportError] = [
            .notImplemented, .invalidCredential, .invalidTestingEndpoint, .invalidTestingCredential, .transportFailed
        ]
        for error in errors {
            let texts = [String(describing: error), String(reflecting: error), error.localizedDescription]
            for text in texts {
                XCTAssertFalse(text.contains(Self.dummyCredential))
                XCTAssertFalse(text.localizedCaseInsensitiveContains("Bearer"))
                XCTAssertFalse(text.localizedCaseInsensitiveContains("Authorization"))
            }
        }
    }

    #if DEBUG
    // 独自スキームのリクエストだけに合成SSE chunkを返すtest専用URLProtocol。
    // canInitは全URLでtrueにして通常のHTTPスタックへ流さず、独自スキーム以外は固定エラーで閉じる。
    private final class SyntheticResponsesURLProtocol: URLProtocol {
        // 複数スレッドから触られるため、記録はlockで守る。ヘッダーは記録・出力しない。
        final class Recorder {
            private let lock = NSLock()
            private var chunks: [Data] = []
            private var urls: [URL?] = []
            private var methods: [String?] = []

            func reset(chunks: [Data]) {
                lock.lock(); defer { lock.unlock() }
                self.chunks = chunks
                urls = []
                methods = []
            }

            func record(_ request: URLRequest) -> [Data] {
                lock.lock(); defer { lock.unlock() }
                urls.append(request.url)
                methods.append(request.httpMethod)
                return chunks
            }

            var observedURLs: [URL?] {
                lock.lock(); defer { lock.unlock() }
                return urls
            }

            var observedMethods: [String?] {
                lock.lock(); defer { lock.unlock() }
                return methods
            }
        }

        static let recorder = Recorder()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canInit(with task: URLSessionTask) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  url.scheme == AIResponsesHTTPTransport.syntheticScheme,
                  url.host == "responses" else {
                // 独自スキーム以外は応答を作らず固定エラーで閉じる。外部へは送らない。
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let chunks = Self.recorder.record(request)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // 応答内容をテストごとに切り替えられるtest専用URLProtocol。
    // 開始・停止の回数を記録し、開始をsemaphoreで知らせる。ヘッダーや本文は記録・出力しない。
    private final class ControlledResponsesURLProtocol: URLProtocol {
        struct Script {
            var statusCode = 200
            var headerFields = ["Content-Type": "text/event-stream"]
            var chunks: [Data] = []
            // falseなら最後のchunkの後も完了せず、取消・停止でしか終わらない
            var finishesAfterChunks = true
        }

        // URLProtocolのthreadとMainActorの両方から触るため、すべてlockで守る。
        final class Controller: @unchecked Sendable {
            private let lock = NSLock()
            private var script = Script()
            private var starts = 0
            private var stops = 0
            private var startSignal = DispatchSemaphore(value: 0)
            // 回収できなかったreceiveが残ると、reset後の遅延stopLoadingを区別できない。
            private var leakedRuns = 0

            func reset(script: Script) {
                lock.lock(); defer { lock.unlock() }
                self.script = script
                starts = 0
                stops = 0
                startSignal = DispatchSemaphore(value: 0)
            }

            func markLeakedRun() {
                lock.lock(); defer { lock.unlock() }
                leakedRuns += 1
            }

            var hasLeakedRun: Bool {
                lock.lock(); defer { lock.unlock() }
                return leakedRuns > 0
            }

            func beginLoading() -> Script {
                lock.lock()
                starts += 1
                let script = self.script
                let signal = startSignal
                lock.unlock()
                signal.signal()
                return script
            }

            func recordStop() {
                lock.lock(); defer { lock.unlock() }
                stops += 1
            }

            // startLoadingを時間制限付きで待つ。開始されなければfalse。
            func waitForStart(timeout: TimeInterval) -> Bool {
                lock.lock()
                let signal = startSignal
                lock.unlock()
                return signal.wait(timeout: .now() + timeout) == .success
            }

            var startCount: Int {
                lock.lock(); defer { lock.unlock() }
                return starts
            }

            var stopCount: Int {
                lock.lock(); defer { lock.unlock() }
                return stops
            }
        }

        static let controller = Controller()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canInit(with task: URLSessionTask) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  url.scheme == AIResponsesHTTPTransport.syntheticScheme,
                  url.host == "responses" else {
                // 独自スキーム以外は開始として数えず、固定エラーで閉じる。外部へは送らない。
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let script = Self.controller.beginLoading()
            let response = HTTPURLResponse(url: url, statusCode: script.statusCode, httpVersion: "HTTP/1.1",
                                           headerFields: script.headerFields)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in script.chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            if script.finishesAfterChunks {
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() {
            Self.controller.recordStop()
        }
    }

    // 取消とcallback errorの競合テスト専用のURLProtocol。他のテストとは状態を共有しない。
    // 開始・停止はrunの世代ごとに数え、endRun後や別世代の古いURLProtocolからの通知は数えない。
    // 応答は自分では完了せず、取消・停止でしか終わらない。ヘッダーや本文は記録・出力しない。
    private final class IsolatedResponsesURLProtocol: URLProtocol {
        final class Controller: @unchecked Sendable {
            private let lock = NSLock()
            private var generation = 0
            private var isRunActive = false
            private var chunks: [Data] = []
            private var starts = 0
            private var stops = 0
            // timeout後に回収できなかったreceiveの数。1以上なら以後のrunの隔離を保証できない
            private var leakedRuns = 0

            func beginRun(chunks: [Data]) {
                lock.lock(); defer { lock.unlock() }
                generation += 1
                isRunActive = true
                self.chunks = chunks
                starts = 0
                stops = 0
            }

            // 世代を進めて閉じる。これ以降に届いた古い開始・停止は無視される。
            func endRun() {
                lock.lock(); defer { lock.unlock() }
                generation += 1
                isRunActive = false
                chunks = []
            }

            // run中でなければnilを返し、開始として数えない。
            func beginLoading() -> (generation: Int, chunks: [Data])? {
                lock.lock(); defer { lock.unlock() }
                guard isRunActive else {
                    return nil
                }
                starts += 1
                return (generation, chunks)
            }

            func recordStop(generation: Int?) {
                lock.lock(); defer { lock.unlock() }
                guard isRunActive, generation == self.generation else {
                    return
                }
                stops += 1
            }

            func markLeakedRun() {
                lock.lock(); defer { lock.unlock() }
                leakedRuns += 1
            }

            var hasLeakedRun: Bool {
                lock.lock(); defer { lock.unlock() }
                return leakedRuns > 0
            }

            var startCount: Int {
                lock.lock(); defer { lock.unlock() }
                return starts
            }

            var stopCount: Int {
                lock.lock(); defer { lock.unlock() }
                return stops
            }
        }

        static let controller = Controller()

        // startLoadingで受け取った世代。stopLoadingで同じ世代のときだけ停止を数える
        private var loadingGeneration: Int?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canInit(with task: URLSessionTask) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  url.scheme == AIResponsesHTTPTransport.syntheticScheme,
                  url.host == "responses",
                  let run = Self.controller.beginLoading() else {
                // 独自スキーム以外、またはrun外の古い開始は応答を作らず固定エラーで閉じる。外部へは送らない。
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            loadingGeneration = run.generation
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in run.chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            // 完了は通知しない。停止(stopLoading)でしか終わらない
        }

        override func stopLoading() {
            Self.controller.recordStop(generation: loadingGeneration)
        }
    }

    // 応答拒否・onChunkのthrow・受信量上限の事後追加テスト専用のURLProtocol。他のテストとは状態を共有しない。
    // IsolatedResponsesURLProtocolと同じく、開始・停止はrunの世代ごとに数え、古い通知は数えない。
    // 応答は自分では完了せず、拒否・失敗・停止によるcancelでしか終わらない（stopLoadingで終了を観測する）。
    // ヘッダーや本文は記録・出力しない。
    private final class ScriptedIsolatedResponsesURLProtocol: URLProtocol {
        struct Script {
            var statusCode = 200
            var headerFields = ["Content-Type": "text/event-stream"]
            var chunks: [Data] = []
        }

        final class Controller: @unchecked Sendable {
            private let lock = NSLock()
            private var generation = 0
            private var isRunActive = false
            private var script = Script()
            private var starts = 0
            private var stops = 0
            // timeout後に回収できなかったreceiveの数。1以上なら以後のrunの隔離を保証できない
            private var leakedRuns = 0

            func beginRun(script: Script) {
                lock.lock(); defer { lock.unlock() }
                generation += 1
                isRunActive = true
                self.script = script
                starts = 0
                stops = 0
            }

            // 世代を進めて閉じる。これ以降に届いた古い開始・停止は無視される。
            func endRun() {
                lock.lock(); defer { lock.unlock() }
                generation += 1
                isRunActive = false
                script = Script()
            }

            // run中でなければnilを返し、開始として数えない。
            func beginLoading() -> (generation: Int, script: Script)? {
                lock.lock(); defer { lock.unlock() }
                guard isRunActive else {
                    return nil
                }
                starts += 1
                return (generation, script)
            }

            func recordStop(generation: Int?) {
                lock.lock(); defer { lock.unlock() }
                guard isRunActive, generation == self.generation else {
                    return
                }
                stops += 1
            }

            func markLeakedRun() {
                lock.lock(); defer { lock.unlock() }
                leakedRuns += 1
            }

            var hasLeakedRun: Bool {
                lock.lock(); defer { lock.unlock() }
                return leakedRuns > 0
            }

            var startCount: Int {
                lock.lock(); defer { lock.unlock() }
                return starts
            }

            var stopCount: Int {
                lock.lock(); defer { lock.unlock() }
                return stops
            }
        }

        static let controller = Controller()

        private var loadingGeneration: Int?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canInit(with task: URLSessionTask) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  url.scheme == AIResponsesHTTPTransport.syntheticScheme,
                  url.host == "responses",
                  let run = Self.controller.beginLoading() else {
                // 独自スキーム以外、またはrun外の古い開始は応答を作らず固定エラーで閉じる。外部へは送らない。
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            loadingGeneration = run.generation
            let response = HTTPURLResponse(url: url, statusCode: run.script.statusCode, httpVersion: "HTTP/1.1",
                                           headerFields: run.script.headerFields)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in run.script.chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            // 完了は通知しない。停止(stopLoading)でしか終わらない
        }

        override func stopLoading() {
            Self.controller.recordStop(generation: loadingGeneration)
        }
    }

    // deadlineが期限到達後の制御点で停止している間だけ、有効な応答を送る競合用protocol。
    private final class DeadlineRaceURLProtocol: URLProtocol {
        static let responseGate = DispatchSemaphore(value: 0)
        static let responseSent = DispatchSemaphore(value: 0)
        static let stopped = DispatchSemaphore(value: 0)
        private static let stateLock = NSLock()
        private static var didSendResponse = false
        private static var didStop = false
        private static var didLeakRun = false

        static var responseWasSent: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return didSendResponse
        }

        static var wasStopped: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return didStop
        }

        static var hasLeakedRun: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return didLeakRun
        }

        static func markLeakedRun() {
            stateLock.lock()
            didLeakRun = true
            stateLock.unlock()
        }

        static func resetObservations() {
            stateLock.lock()
            didSendResponse = false
            didStop = false
            // 漏出したrunは後続試験へ持ち越し、fixtureの再利用を禁止する。
            stateLock.unlock()
        }

        // 前runの異常終了処理が残したsignalを、新しいrunの応答許可に使わない。
        static func drainResponseGate() {
            while responseGate.wait(timeout: .now()) == .success {}
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canInit(with task: URLSessionTask) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  url.scheme == AIResponsesHTTPTransport.syntheticScheme,
                  url.host == "responses" else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            guard Self.responseGate.wait(timeout: .now() + 5) == .success else {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            Self.stateLock.lock()
            Self.didSendResponse = true
            Self.stateLock.unlock()
            Self.responseSent.signal()
            client?.urlProtocol(self, didLoad: Data("data: {\"synthetic\":true}\n\n".utf8))
            // stopLoadingを同じURLProtocol実行列で遅らせないよう、完了待ちせず戻る。
        }

        override func stopLoading() {
            Self.stateLock.lock()
            Self.didStop = true
            Self.stateLock.unlock()
            Self.stopped.signal()
        }
    }

    private final class DeadlineRaceSignals: @unchecked Sendable {
        let deadlineReached = DispatchSemaphore(value: 0)
        let releaseDeadline = DispatchSemaphore(value: 0)
    }

    // テスト内で観測した事実。hook・onChunk・Taskの中から触るのでMainActorに置く。
    @MainActor private final class Probe {
        var controlPoints: [AIResponsesHTTPTransport.SyntheticTestingControlPoint] = []
        var deliveredChunks: [Data] = []
        var cancelIssued = false
        var chunkDeliveredAfterCancel = false
    }

    private enum ReceiveOutcome {
        case returned
        case threw(any Error)
        case timedOut
    }

    private struct SyntheticChunkError: Error, Equatable {}

    // 値で区別できる合成エラー。固定エラーへ置き換えられず、同じ値が投げられたかを確かめる。
    private struct TaggedSyntheticChunkError: Error, Equatable {
        let tag: String
    }

    private static let syntheticBody = Data(#"{"synthetic":true}"#.utf8)
    private static let syntheticChunk = Data("event: synthetic.delta\ndata: {\"n\":1}\n\n".utf8)

    private func makeControlledTransport(
        controlHook: @escaping @MainActor (AIResponsesHTTPTransport.SyntheticTestingControlPoint) -> Void = { _ in }
    ) throws -> AIResponsesHTTPTransport {
        try AIResponsesHTTPTransport(
            testingSyntheticEndpoint: AIResponsesHTTPTransport.syntheticEndpoint,
            credential: Self.dummyCredential, protocolClasses: [ControlledResponsesURLProtocol.self],
            controlHook: controlHook)
    }

    // 既存の隔離用helperを使い、timeout後のbounded回収と回収不能時の記録を行う。
    private func runReceive(_ transport: AIResponsesHTTPTransport, timeout: TimeInterval = 5,
                            onChunk: @escaping @MainActor (Data) throws -> Void,
                            onFinish: @escaping @MainActor () -> Void = {}) async -> ReceiveOutcome {
        await runIsolatedReceive(transport, timeout: timeout,
                                 markLeaked: { ControlledResponsesURLProtocol.controller.markLeakedRun() },
                                 onChunk: onChunk, onFinish: onFinish)
    }

    // IsolatedResponsesURLProtocol用のreceive実行。制限時間内に終わらなければTaskを取消し、
    // さらに制限時間付きで終了を待って回収する。回収できなければcontrollerへ記録し、
    // 以後このURLProtocolを使うテストが共有状態の隔離を保証できないと報告できるようにする。
    // onFinishはreceiveが戻った・投げた直後に、間にawaitを挟まず同じTaskで呼ぶ。
    // markLeaked: 回収できなかったときに記録するcontroller。既定はIsolatedResponsesURLProtocol。
    private func runIsolatedReceive(_ transport: AIResponsesHTTPTransport, timeout: TimeInterval = 5,
                                    reclaimTimeout: TimeInterval = 5,
                                    markLeaked: () -> Void = { IsolatedResponsesURLProtocol.controller.markLeakedRun() },
                                    onChunk: @escaping @MainActor (Data) throws -> Void,
                                    onFinish: @escaping @MainActor () -> Void = {}) async -> ReceiveOutcome {
        @MainActor final class Box {
            var outcome: ReceiveOutcome?
        }
        let box = Box()
        let task = Task { @MainActor in
            let outcome: ReceiveOutcome
            do {
                try await transport.receive(body: Self.syntheticBody, onChunk: onChunk)
                outcome = .returned
            } catch {
                outcome = .threw(error)
            }
            onFinish()
            box.outcome = outcome
        }
        if await waitWithin(seconds: timeout, { box.outcome != nil }), let outcome = box.outcome {
            return outcome
        }
        task.cancel()
        let reclaimed = await waitWithin(seconds: reclaimTimeout) { box.outcome != nil }
        if reclaimed {
            XCTFail("receiveが制限時間内に終わらなかった（取消後に回収済み）")
        } else {
            markLeaked()
            XCTFail("receiveが制限時間内に終わらず、取消後も回収できなかった。以後の隔離は保証できない")
        }
        return .timedOut
    }

    // MainActorを手放しながら条件を待つ。制限時間を過ぎたら最後に一度だけ確かめて返す。
    private func waitWithin(seconds: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    override func tearDown() async throws {
        SyntheticResponsesURLProtocol.recorder.reset(chunks: [])
        if !ControlledResponsesURLProtocol.controller.hasLeakedRun {
            ControlledResponsesURLProtocol.controller.reset(script: .init())
        }
        try await super.tearDown()
    }

    func testTestingCredentialIsFixedDummy() {
        XCTAssertEqual(AIResponsesHTTPTransport.syntheticTestCredential, Self.dummyCredential)
        XCTAssertEqual(AIResponsesHTTPTransport.syntheticEndpoint, URL(string: "melete-synthetic://responses"))
    }

    func testTestingInitializerRejectsNonSyntheticEndpoints() {
        let rejected: [URL] = [
            AIResponsesHTTPRequestFactory.productionEndpoint,
            URL(string: "https://example.invalid/v1/responses")!,
            URL(string: "http://localhost/v1/responses")!,
            URL(string: "file:///tmp/responses")!,
            URL(string: "melete-synthetic://other")!
        ]
        for endpoint in rejected {
            XCTAssertThrowsError(try AIResponsesHTTPTransport(
                testingSyntheticEndpoint: endpoint, credential: Self.dummyCredential,
                protocolClasses: [SyntheticResponsesURLProtocol.self])) { error in
                XCTAssertEqual(error as? AIResponsesHTTPTransportError, .invalidTestingEndpoint)
            }
        }
        // test専用URLProtocolなしでは初期化させない。
        XCTAssertThrowsError(try AIResponsesHTTPTransport(
            testingSyntheticEndpoint: AIResponsesHTTPTransport.syntheticEndpoint,
            credential: Self.dummyCredential, protocolClasses: [])) { error in
            XCTAssertEqual(error as? AIResponsesHTTPTransportError, .invalidTestingEndpoint)
        }
    }

    func testTestingInitializerRejectsNonDummyCredential() {
        for credential in ["", "other-synthetic-value", Self.dummyCredential + " "] {
            XCTAssertThrowsError(try AIResponsesHTTPTransport(
                testingSyntheticEndpoint: AIResponsesHTTPTransport.syntheticEndpoint,
                credential: credential, protocolClasses: [SyntheticResponsesURLProtocol.self])) { error in
                XCTAssertEqual(error as? AIResponsesHTTPTransportError, .invalidTestingCredential)
            }
        }
    }

    func testSyntheticStreamDeliversChunksInOrderAndFinishes() async throws {
        // 合成SSE。chunk境界はURLSession側で結合され得るため、連結結果で順序を確認する。
        let chunks = [
            Data("event: synthetic.first\ndata: {\"n\":1}\n\n".utf8),
            Data("event: synthetic.second\ndata: {\"n\":2}\n\n".utf8),
            Data("event: synthetic.third\ndata: {\"n\":3}\n\n".utf8)
        ]
        SyntheticResponsesURLProtocol.recorder.reset(chunks: chunks)
        let transport = try AIResponsesHTTPTransport(
            testingSyntheticEndpoint: AIResponsesHTTPTransport.syntheticEndpoint,
            credential: Self.dummyCredential, protocolClasses: [SyntheticResponsesURLProtocol.self])

        var received: [Data] = []
        try await transport.receive(body: Data(#"{"synthetic":true}"#.utf8)) { chunk in
            received.append(chunk)
        }
        // receiveから戻った時点でストリームは終了しており、以後chunkは届かない。
        let countAtReturn = received.count

        XCTAssertFalse(received.isEmpty)
        XCTAssertFalse(received.contains(where: \.isEmpty))
        XCTAssertEqual(received.reduce(Data(), +), chunks.reduce(Data(), +))
        XCTAssertEqual(SyntheticResponsesURLProtocol.recorder.observedURLs, [AIResponsesHTTPTransport.syntheticEndpoint])
        XCTAssertEqual(SyntheticResponsesURLProtocol.recorder.observedMethods, ["POST"])
        await Task.yield()
        XCTAssertEqual(received.count, countAtReturn)
    }

    // (a) 開始前の取消判定を通った後、session開始より前に取消が確定したら、URLProtocolを開始させない。
    func testCancellationConfirmedBeforeSessionStartNeverStartsProtocol() async throws {
        let controller = ControlledResponsesURLProtocol.controller
        guard !controller.hasLeakedRun else {
            return XCTFail("以前のtimeoutで回収できなかったreceiveが残っており、共有状態の隔離を保証できない")
        }
        controller.reset(script: .init(chunks: [Self.syntheticChunk]))
        let probe = Probe()
        var startObservedBeforeLoop = false
        let transport = try makeControlledTransport { point in
            probe.controlPoints.append(point)
            switch point {
            case .beforeSessionStart:
                // receiveを実行中のTask自身を取消す。cancel()はonCancel handlerの実行を終えてから戻る。
                withUnsafeCurrentTask { $0?.cancel() }
                probe.cancelIssued = true
            case .afterSessionStart:
                // 受信ループ（ループ内の取消でtaskが止まる）より前に、開始されるかを時間制限付きで確かめる。
                // 開始されない実装では制限時間だけ待ってから進む。
                startObservedBeforeLoop = controller.waitForStart(timeout: 2)
            case .beforeChunkDelivery:
                break
            }
        }

        let outcome = await runReceive(transport, timeout: 10) { chunk in
            probe.deliveredChunks.append(chunk)
        }

        XCTAssertEqual(probe.controlPoints.first, .beforeSessionStart, "制御点beforeSessionStartが呼ばれていない")
        XCTAssertTrue(probe.cancelIssued)
        guard case .threw(let error) = outcome else {
            return XCTFail("CancellationErrorで終わるべき: \(outcome)")
        }
        XCTAssertTrue(error is CancellationError, "CancellationErrorで終わるべき: \(error)")
        XCTAssertFalse(startObservedBeforeLoop, "取消確定後にURLProtocolが開始された")
        XCTAssertEqual(controller.startCount, 0, "取消確定後にURLProtocolが開始された")
        XCTAssertTrue(probe.deliveredChunks.isEmpty)
    }

    // (b) nextEventがdataを取り出した後に取消が確定したら、そのdataをonChunkへ渡さない。
    func testCancellationAfterDataIsTakenDoesNotDeliverChunk() async throws {
        let controller = ControlledResponsesURLProtocol.controller
        guard !controller.hasLeakedRun else {
            return XCTFail("以前のtimeoutで回収できなかったreceiveが残っており、共有状態の隔離を保証できない")
        }
        controller.reset(script: .init(chunks: [Self.syntheticChunk]))
        let probe = Probe()
        let transport = try makeControlledTransport { point in
            probe.controlPoints.append(point)
            guard point == .beforeChunkDelivery, !probe.cancelIssued else {
                return
            }
            // 取り出し済みのdataがある状態で、receiveを実行中のTask自身を取消す。
            // cancel()が戻った時点で取消通知(onCancel)は完了している。
            withUnsafeCurrentTask { $0?.cancel() }
            probe.cancelIssued = true
        }

        let outcome = await runReceive(transport) { chunk in
            if probe.cancelIssued {
                probe.chunkDeliveredAfterCancel = true
            }
            probe.deliveredChunks.append(chunk)
        }

        XCTAssertEqual(probe.controlPoints.filter { $0 == .beforeChunkDelivery }.count, 1,
                       "制御点beforeChunkDeliveryがちょうど1回呼ばれていない")
        XCTAssertTrue(probe.cancelIssued)
        XCTAssertFalse(probe.chunkDeliveredAfterCancel, "取消通知の完了後にonChunkが呼ばれた")
        XCTAssertTrue(probe.deliveredChunks.isEmpty, "取消通知の完了後にonChunkが呼ばれた")
        guard case .threw(let error) = outcome else {
            return XCTFail("CancellationErrorで終わるべき: \(outcome)")
        }
        XCTAssertTrue(error is CancellationError, "CancellationErrorで終わるべき: \(error)")
        XCTAssertEqual(controller.startCount, 1)
    }

    // (c) onChunkがthrowしたら、URLProtocolの停止とtask完了を待ってから、そのエラーを投げる。
    // 応答は自分では完了しないので、停止を要求しない限りreceiveは戻れない。
    func testChunkHandlerErrorIsThrownAfterProtocolStops() async throws {
        let controller = ControlledResponsesURLProtocol.controller
        guard !controller.hasLeakedRun else {
            return XCTFail("以前のtimeoutで回収できなかったreceiveが残っており、共有状態の隔離を保証できない")
        }
        controller.reset(script: .init(chunks: [Self.syntheticChunk], finishesAfterChunks: false))
        let probe = Probe()
        let transport = try makeControlledTransport()

        var stopCountAtThrow: Int?
        let outcome = await runReceive(transport, onChunk: { chunk in
            probe.deliveredChunks.append(chunk)
            throw SyntheticChunkError()
        }, onFinish: {
            // receiveが戻った直後（間にawaitを挟まず）の停止回数を記録する。
            stopCountAtThrow = controller.stopCount
        })

        guard case .threw(let error) = outcome else {
            return XCTFail("onChunkのエラーで終わるべき: \(outcome)")
        }
        XCTAssertEqual(error as? SyntheticChunkError, SyntheticChunkError(), "onChunkのエラーをそのまま投げるべき: \(error)")
        XCTAssertEqual(probe.deliveredChunks.count, 1, "throw後にonChunkが再び呼ばれた")
        XCTAssertEqual(controller.startCount, 1)
        XCTAssertEqual(stopCountAtThrow, 1, "URLProtocolの停止より前にthrowした")
    }

    // (c') onChunkの中で自分のTaskを取消してから合成エラーをthrowした場合は、取消を優先する。
    // callbackは1回だけ呼ばれ、URLProtocolの停止とreceiveの終了を待ってからCancellationErrorを投げる。
    // 応答は自分では完了しないので、停止を要求しない限りreceiveは戻れない（制限時間付きで待つ）。
    func testSelfCancellationInsideChunkHandlerWinsOverCallbackError() async throws {
        let controller = IsolatedResponsesURLProtocol.controller
        guard !controller.hasLeakedRun else {
            return XCTFail("以前のtimeoutで回収できなかったreceiveが残っており、共有状態の隔離を保証できない")
        }
        controller.beginRun(chunks: [Self.syntheticChunk])
        // 途中で失敗・timeoutしても世代を閉じ、古い通知が後のrunに数えられないようにする
        defer { controller.endRun() }
        let probe = Probe()
        let transport = try AIResponsesHTTPTransport(
            testingSyntheticEndpoint: AIResponsesHTTPTransport.syntheticEndpoint,
            credential: Self.dummyCredential, protocolClasses: [IsolatedResponsesURLProtocol.self])

        var startCountAtFinish: Int?
        var stopCountAtFinish: Int?
        let outcome = await runIsolatedReceive(transport, onChunk: { chunk in
            probe.deliveredChunks.append(chunk)
            // receiveを実行中のTask自身を取消し、その後にcallback errorを投げる。
            withUnsafeCurrentTask { $0?.cancel() }
            probe.cancelIssued = true
            throw SyntheticChunkError()
        }, onFinish: {
            // receiveが戻った直後（間にawaitを挟まず）の開始・停止回数を記録する。
            startCountAtFinish = controller.startCount
            stopCountAtFinish = controller.stopCount
        })

        XCTAssertTrue(probe.cancelIssued)
        XCTAssertEqual(probe.deliveredChunks.count, 1, "callbackがちょうど1回呼ばれていない")
        XCTAssertEqual(startCountAtFinish, 1)
        XCTAssertEqual(stopCountAtFinish, 1, "URLProtocolの停止より前にreceiveが終了した")
        guard case .threw(let error) = outcome else {
            return XCTFail("CancellationErrorで終わるべき: \(outcome)")
        }
        XCTAssertTrue(error is CancellationError, "取消がcallback errorより優先されるべき: \(error)")
        XCTAssertNil(error as? SyntheticChunkError, "取消済みなのにcallback errorがそのまま投げられた")
    }

    // (d) 非200やContent-Type不正の応答では、本文をonChunkへ渡さず固定エラーで終わる。
    func testRejectedResponsesNeverDeliverBody() async throws {
        let controller = ControlledResponsesURLProtocol.controller
        let rejectedBody = Data("data: {\"synthetic\":\"rejected\"}\n\n".utf8)
        let scripts: [(label: String, script: ControlledResponsesURLProtocol.Script)] = [
            ("status 500", .init(statusCode: 500, headerFields: ["Content-Type": "text/event-stream"],
                                 chunks: [rejectedBody])),
            ("status 201", .init(statusCode: 201, headerFields: ["Content-Type": "text/event-stream"],
                                 chunks: [rejectedBody])),
            ("application/json", .init(statusCode: 200, headerFields: ["Content-Type": "application/json"],
                                       chunks: [rejectedBody])),
            ("Content-Typeなし", .init(statusCode: 200, headerFields: [:], chunks: [rejectedBody]))
        ]
        for (label, script) in scripts {
            guard !controller.hasLeakedRun else {
                return XCTFail("以前のtimeoutで回収できなかったreceiveが残っており、共有状態の隔離を保証できない")
            }
            controller.reset(script: script)
            let probe = Probe()
            let transport = try makeControlledTransport()

            let outcome = await runReceive(transport) { chunk in
                probe.deliveredChunks.append(chunk)
            }

            XCTAssertEqual(controller.startCount, 1, "\(label): 合成応答が開始されていない")
            XCTAssertTrue(probe.deliveredChunks.isEmpty, "\(label): 拒否した応答の本文がonChunkへ渡った")
            guard case .threw(let error) = outcome else {
                XCTFail("\(label): transportFailedで終わるべき: \(outcome)")
                continue
            }
            XCTAssertEqual(error as? AIResponsesHTTPTransportError, .transportFailed, "\(label): \(error)")
        }
    }

    private func makeScriptedIsolatedTransport() throws -> AIResponsesHTTPTransport {
        try AIResponsesHTTPTransport(
            testingSyntheticEndpoint: AIResponsesHTTPTransport.syntheticEndpoint,
            credential: Self.dummyCredential, protocolClasses: [ScriptedIsolatedResponsesURLProtocol.self],
            responseHeaderDeadlineForTesting: 0.2)
    }

    func testResponseHeaderArrivingAfterAbsoluteDeadlineIsRejected() async throws {
        guard !DeadlineRaceURLProtocol.hasLeakedRun else {
            return XCTFail("以前のtimeoutで回収できなかったreceiveが残っており、共有fixtureを再利用できない")
        }
        DeadlineRaceURLProtocol.drainResponseGate()
        DeadlineRaceURLProtocol.resetObservations()
        let signals = DeadlineRaceSignals()
        let protocolType = DeadlineRaceURLProtocol.self
        let probe = Probe()
        var receiveFinished = false
        let transport = try AIResponsesHTTPTransport(
            testingSyntheticEndpoint: AIResponsesHTTPTransport.syntheticEndpoint,
            credential: Self.dummyCredential, protocolClasses: [protocolType],
            responseHeaderDeadlineForTesting: 0.2,
            controlHook: { point in probe.controlPoints.append(point) },
            beforeDeadlineExpirationForTesting: {
                signals.deadlineReached.signal()
                // bounded wait。assertion失敗などで解放されなくても監視taskを永久停止させない。
                _ = signals.releaseDeadline.wait(timeout: .now() + 5)
            })
        let task = Task { @MainActor () -> ReceiveOutcome in
            defer { receiveFinished = true }
            do {
                try await transport.receive(body: Self.syntheticBody) { chunk in
                    probe.deliveredChunks.append(chunk)
                }
                return .returned
            } catch {
                return .threw(error)
            }
        }

        let deadlineWasReached = await waitWithin(seconds: 3) {
            signals.deadlineReached.wait(timeout: .now()) == .success
        }
        if deadlineWasReached {
            // 期限sleepが成功したのをsignalで確認済み。期限処理はhookで止まったまま応答を届ける。
            DeadlineRaceURLProtocol.responseGate.signal()
        } else {
            // 失敗時にもprotocolを解放し、receive/sessionを回収する。
            task.cancel()
            DeadlineRaceURLProtocol.responseGate.signal()
            signals.releaseDeadline.signal()
            let reclaimed = await waitWithin(seconds: 5) { receiveFinished }
            if reclaimed { _ = await task.value } else { DeadlineRaceURLProtocol.markLeakedRun() }
            return XCTFail("期限監視の停止点に到達しなかった")
        }

        let responseWasSent = await waitWithin(seconds: 3) { DeadlineRaceURLProtocol.responseWasSent }
        guard responseWasSent else {
            task.cancel()
            DeadlineRaceURLProtocol.responseGate.signal()
            signals.releaseDeadline.signal()
            let reclaimed = await waitWithin(seconds: 5) { receiveFinished }
            if reclaimed { _ = await task.value } else { DeadlineRaceURLProtocol.markLeakedRun() }
            _ = await waitWithin(seconds: 3) { DeadlineRaceURLProtocol.wasStopped }
            return XCTFail("期限停止中に有効ヘッダーを送れなかった")
        }

        let observedDeadlineRace = await waitWithin(seconds: 3) {
            DeadlineRaceURLProtocol.wasStopped || probe.controlPoints.contains(.beforeChunkDelivery)
        }
        let chunkReachedDeliveryPoint = probe.controlPoints.contains(.beforeChunkDelivery)
        let stoppedBeforeRelease = DeadlineRaceURLProtocol.wasStopped
        guard observedDeadlineRace else {
            task.cancel()
            DeadlineRaceURLProtocol.responseGate.signal()
            signals.releaseDeadline.signal()
            let reclaimed = await waitWithin(seconds: 5) { receiveFinished }
            if reclaimed { _ = await task.value } else { DeadlineRaceURLProtocol.markLeakedRun() }
            _ = await waitWithin(seconds: 3) { DeadlineRaceURLProtocol.wasStopped }
            return XCTFail("期限停止中にURLProtocol stop/chunk deliveryのいずれも観測できなかった")
        }

        // REDではchunk到達を見てから解放し、回帰を明示的に失敗させる。
        // GREENでは期限処理によるstopを見てから解放し、正常な拒否を検証する。
        signals.releaseDeadline.signal()
        if chunkReachedDeliveryPoint && !stoppedBeforeRelease {
            task.cancel()
            let reclaimed = await waitWithin(seconds: 5) { receiveFinished }
            if reclaimed { _ = await task.value } else { DeadlineRaceURLProtocol.markLeakedRun() }
            _ = await waitWithin(seconds: 3) { DeadlineRaceURLProtocol.wasStopped }
            XCTFail("期限停止中にchunk deliveryへ到達したため、期限超過後の応答を拒否できていない")
            return
        }

        let stopped = await waitWithin(seconds: 3) { DeadlineRaceURLProtocol.wasStopped }
        let receiveWasReclaimed = await waitWithin(seconds: 5) { receiveFinished }
        guard receiveWasReclaimed else {
            task.cancel()
            let reclaimed = await waitWithin(seconds: 5) { receiveFinished }
            if reclaimed { _ = await task.value } else { DeadlineRaceURLProtocol.markLeakedRun() }
            XCTFail("receiveを制限時間内に回収できなかった")
            return
        }
        let outcome = await task.value
        XCTAssertTrue(deadlineWasReached, "絶対期限のsleep成功を観測できなかった")
        XCTAssertTrue(responseWasSent, "期限停止中に有効ヘッダーが送られなかった")
        XCTAssertFalse(chunkReachedDeliveryPoint, "期限超過後のchunk処理へ進んだ")
        XCTAssertEqual(probe.deliveredChunks.count, 0, "期限超過後のchunkがcallbackへ渡った")
        guard case .threw(let error) = outcome else {
            return XCTFail("期限超過後のヘッダーはtransportFailedになるべき: \(outcome)")
        }
        XCTAssertEqual(error as? AIResponsesHTTPTransportError, .transportFailed)
        XCTAssertTrue(stopped, "失敗を返す前にURLProtocol taskが停止していない")
    }

    // (e) 非200・text/event-stream以外・圧縮(gzip等)の応答は、本文をonChunkへ渡さず、
    // URLProtocolの停止を待ってから固定エラーで終わる。応答は自分では完了しないので、拒否しない限り戻れない。
    func testRejectedStatusMediaTypeAndEncodingNeverDeliverBodyAndStopProtocol() async throws {
        let controller = ScriptedIsolatedResponsesURLProtocol.controller
        let rejectedBody = Data("data: {\"synthetic\":\"rejected\"}\n\n".utf8)
        let scripts: [(label: String, script: ScriptedIsolatedResponsesURLProtocol.Script)] = [
            ("status 404", .init(statusCode: 404, headerFields: ["Content-Type": "text/event-stream"],
                                 chunks: [rejectedBody])),
            ("status 204", .init(statusCode: 204, headerFields: ["Content-Type": "text/event-stream"],
                                 chunks: [rejectedBody])),
            ("text/plain", .init(statusCode: 200, headerFields: ["Content-Type": "text/plain"],
                                 chunks: [rejectedBody])),
            ("text/event-stream接頭辞違い", .init(statusCode: 200,
                                              headerFields: ["Content-Type": "text/event-streamx"],
                                              chunks: [rejectedBody])),
            ("Content-Encoding gzip", .init(statusCode: 200,
                                            headerFields: ["Content-Type": "text/event-stream",
                                                           "Content-Encoding": "gzip"],
                                            chunks: [rejectedBody])),
            ("Content-Encoding GZIP", .init(statusCode: 200,
                                            headerFields: ["Content-Type": "text/event-stream; charset=utf-8",
                                                           "Content-Encoding": " GZIP "],
                                            chunks: [rejectedBody])),
            ("Content-Encoding br", .init(statusCode: 200,
                                          headerFields: ["Content-Type": "text/event-stream",
                                                         "Content-Encoding": "br"],
                                          chunks: [rejectedBody]))
        ]
        for (label, script) in scripts {
            guard !controller.hasLeakedRun else {
                return XCTFail("以前のtimeoutで回収できなかったreceiveが残っており、共有状態の隔離を保証できない")
            }
            controller.beginRun(script: script)
            // 途中で失敗・timeoutしても世代を閉じる（deferはループ1回ごとに実行される）
            defer { controller.endRun() }
            let probe = Probe()
            let transport = try makeScriptedIsolatedTransport()

            var startCountAtFinish: Int?
            var stopCountAtFinish: Int?
            let outcome = await runIsolatedReceive(transport, markLeaked: { controller.markLeakedRun() }, onChunk: { chunk in
                probe.deliveredChunks.append(chunk)
            }, onFinish: {
                startCountAtFinish = controller.startCount
                stopCountAtFinish = controller.stopCount
            })

            XCTAssertEqual(startCountAtFinish, 1, "\(label): 合成応答が開始されていない")
            XCTAssertEqual(stopCountAtFinish, 1, "\(label): URLProtocolの停止より前にreceiveが終了した")
            XCTAssertTrue(probe.deliveredChunks.isEmpty, "\(label): 拒否した応答の本文がonChunkへ渡った")
            guard case .threw(let error) = outcome else {
                XCTFail("\(label): transportFailedで終わるべき: \(outcome)")
                continue
            }
            XCTAssertEqual(error as? AIResponsesHTTPTransportError, .transportFailed, "\(label): \(error)")
        }
    }

    // (f) 受信中(応答が未完了で、後続chunkも届いている状態)にonChunkがthrowしたら、
    // transportFailed等の固定エラーに置き換えず、そのエラー値を投げる。URLProtocolの停止を待ってから戻る。
    func testChunkHandlerErrorDuringStreamingIsRethrownAsIsAfterProtocolStops() async throws {
        let controller = ScriptedIsolatedResponsesURLProtocol.controller
        guard !controller.hasLeakedRun else {
            return XCTFail("以前のtimeoutで回収できなかったreceiveが残っており、共有状態の隔離を保証できない")
        }
        let chunks = (1...8).map { Data("event: synthetic.delta\ndata: {\"n\":\($0)}\n\n".utf8) }
        controller.beginRun(script: .init(chunks: chunks))
        defer { controller.endRun() }
        let probe = Probe()
        let transport = try makeScriptedIsolatedTransport()
        let thrown = TaggedSyntheticChunkError(tag: "synthetic-streaming-failure")

        var startCountAtFinish: Int?
        var stopCountAtFinish: Int?
        let outcome = await runIsolatedReceive(transport, markLeaked: { controller.markLeakedRun() }, onChunk: { chunk in
            probe.deliveredChunks.append(chunk)
            throw thrown
        }, onFinish: {
            startCountAtFinish = controller.startCount
            stopCountAtFinish = controller.stopCount
        })

        XCTAssertEqual(probe.deliveredChunks.count, 1, "throw後にonChunkが再び呼ばれた")
        XCTAssertEqual(startCountAtFinish, 1)
        XCTAssertEqual(stopCountAtFinish, 1, "URLProtocolの停止より前にreceiveが終了した")
        guard case .threw(let error) = outcome else {
            return XCTFail("onChunkのエラーで終わるべき: \(outcome)")
        }
        XCTAssertEqual(error as? TaggedSyntheticChunkError, thrown, "onChunkのエラー値をそのまま投げるべき: \(error)")
        XCTAssertNil(error as? AIResponsesHTTPTransportError, "onChunkのエラーが固定エラーに置き換えられた")
        XCTAssertFalse(error is CancellationError, "取消していないのにCancellationErrorになった")
    }

    // (g) 受信量の上限(maxTotalBytes)を超える合成データを送ると、onChunkが受け取った累計に関わらず失敗し、
    // URLProtocolの停止を待ってから固定エラーで終わる。
    // 未処理量の上限(maxPendingBytes)と累計上限のどちらが先に効くかは、配信の速さ次第なので区別しない。
    func testExceedingReceiveLimitFailsRegardlessOfDeliveredBytesAfterProtocolStops() async throws {
        let controller = ScriptedIsolatedResponsesURLProtocol.controller
        guard !controller.hasLeakedRun else {
            return XCTFail("以前のtimeoutで回収できなかったreceiveが残っており、共有状態の隔離を保証できない")
        }
        // 64KiBの合成chunkを、累計上限を確実に超える数だけ並べる。同じDataを共有するのでメモリは増えにくい。
        let chunkSize = 64 * 1024
        let chunk = Data(repeating: UInt8(ascii: "x"), count: chunkSize)
        let chunkCount = AIResponsesHTTPTransportLimits.maxTotalBytes / chunkSize + 2
        let sentBytes = chunkSize * chunkCount
        XCTAssertGreaterThan(sentBytes, AIResponsesHTTPTransportLimits.maxTotalBytes)
        controller.beginRun(script: .init(chunks: Array(repeating: chunk, count: chunkCount)))
        defer { controller.endRun() }
        let transport = try makeScriptedIsolatedTransport()

        var deliveredBytes = 0
        var startCountAtFinish: Int?
        var stopCountAtFinish: Int?
        // 数MBを処理するので、他のテストより長めの制限時間にする
        let outcome = await runIsolatedReceive(transport, timeout: 30, reclaimTimeout: 10,
                                               markLeaked: { controller.markLeakedRun() }, onChunk: { chunk in
            deliveredBytes += chunk.count
        }, onFinish: {
            startCountAtFinish = controller.startCount
            stopCountAtFinish = controller.stopCount
        })

        XCTAssertEqual(startCountAtFinish, 1)
        XCTAssertEqual(stopCountAtFinish, 1, "URLProtocolの停止より前にreceiveが終了した")
        XCTAssertLessThanOrEqual(deliveredBytes, AIResponsesHTTPTransportLimits.maxTotalBytes,
                                 "上限を超えた分までonChunkへ渡った")
        guard case .threw(let error) = outcome else {
            return XCTFail("上限超過でtransportFailedになるべき: \(outcome)")
        }
        XCTAssertEqual(error as? AIResponsesHTTPTransportError, .transportFailed, "\(error)")
    }

    // MARK: - 診断: text/plain(status 200)の拒否が本文の量・完了の有無で変わるか

    // 診断専用のURLProtocol。他のテストとは状態を共有せず、runの世代ごとに開始・停止を数える。
    // text/plain・status 200の応答に、固定の合成本文(同じ1バイトの繰り返し)を1回だけ渡す。
    // 完了するかどうかはScriptで切り替える。ヘッダーや本文は記録・出力しない。
    //
    // 仮説(未検証): Foundationが応答通知(delegateのdidReceive response)を、本文がある程度届くか
    // 完了するまで遅らせる場合、少量・未完了の(A)だけtransportが拒否できずtimeoutする。
    // 通知の順序や条件は確かめていないので、ここでは観測値を並べて比較するだけにする。
    private final class TextPlainDiagnosticURLProtocol: URLProtocol {
        struct Script {
            let bodyByteCount: Int
            // trueならbodyを渡した後にurlProtocolDidFinishLoadingを呼ぶ
            let finishesAfterBody: Bool
        }

        // 1回のrunで観測した値。時刻は開始・最初の停止の差だけを使う
        struct Observation {
            let startCount: Int
            let stopCount: Int
            let startToFirstStop: Duration?
        }

        final class Controller: @unchecked Sendable {
            private let lock = NSLock()
            private var generation = 0
            private var isRunActive = false
            private var script: Script?
            private var starts = 0
            private var stops = 0
            private var firstStart: ContinuousClock.Instant?
            private var firstStop: ContinuousClock.Instant?
            // timeout後に回収できなかったreceiveの数。1以上なら以後のrunの隔離を保証できない
            private var leakedRuns = 0

            func beginRun(script: Script) {
                lock.lock(); defer { lock.unlock() }
                generation += 1
                isRunActive = true
                self.script = script
                starts = 0
                stops = 0
                firstStart = nil
                firstStop = nil
            }

            // 世代を進めて閉じる。これ以降に届いた古い開始・停止は無視される。
            func endRun() {
                lock.lock(); defer { lock.unlock() }
                generation += 1
                isRunActive = false
                script = nil
            }

            // run中でなければnilを返し、開始として数えない。
            func beginLoading() -> (generation: Int, script: Script)? {
                lock.lock(); defer { lock.unlock() }
                guard isRunActive, let script else {
                    return nil
                }
                starts += 1
                if firstStart == nil {
                    firstStart = .now
                }
                return (generation, script)
            }

            func recordStop(generation: Int?) {
                lock.lock(); defer { lock.unlock() }
                guard isRunActive, generation == self.generation else {
                    return
                }
                stops += 1
                if firstStop == nil {
                    firstStop = .now
                }
            }

            func markLeakedRun() {
                lock.lock(); defer { lock.unlock() }
                leakedRuns += 1
            }

            var hasLeakedRun: Bool {
                lock.lock(); defer { lock.unlock() }
                return leakedRuns > 0
            }

            var startCount: Int {
                lock.lock(); defer { lock.unlock() }
                return starts
            }

            var stopCount: Int {
                lock.lock(); defer { lock.unlock() }
                return stops
            }

            var observation: Observation {
                lock.lock(); defer { lock.unlock() }
                let startToFirstStop: Duration?
                if let firstStart, let firstStop {
                    startToFirstStop = firstStop - firstStart
                } else {
                    startToFirstStop = nil
                }
                return Observation(startCount: starts, stopCount: stops, startToFirstStop: startToFirstStop)
            }
        }

        static let controller = Controller()

        private var loadingGeneration: Int?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canInit(with task: URLSessionTask) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  url.scheme == AIResponsesHTTPTransport.syntheticScheme,
                  url.host == "responses",
                  let run = Self.controller.beginLoading() else {
                // 独自スキーム以外、またはrun外の古い開始は応答を作らず固定エラーで閉じる。外部へは送らない。
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            loadingGeneration = run.generation
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/plain"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // 固定の合成本文。SSEの形にはしない
            client?.urlProtocol(self, didLoad: Data(repeating: UInt8(ascii: "p"), count: run.script.bodyByteCount))
            if run.script.finishesAfterBody {
                client?.urlProtocolDidFinishLoading(self)
            }
            // finishesAfterBodyがfalseなら完了を通知せず、停止(stopLoading)でしか終わらない
        }

        override func stopLoading() {
            Self.controller.recordStop(generation: loadingGeneration)
        }
    }

    // 診断1回分の観測値。ケース間で同じ項目を並べて比較できるよう、summaryを1行にまとめる。
    // 件数・バイト数・時間・エラーの種類だけを持ち、本文・ヘッダー・認証情報は含めない。
    private struct TextPlainDiagnosticResult {
        let label: String
        // returned / threw(...) / timedOut(reclaimed|leaked)
        let outcome: String
        let elapsed: Duration
        // onChunkが呼ばれた回数と、渡されたバイト数
        let callbackCount: Int
        let deliveredBytes: Int
        // nextEventがdataを返した回数(onChunkへ渡さなかった分も含む)
        let chunkDeliveryPoints: Int
        // receiveが戻った・投げた直後の値。timeout時はnil
        let startCountAtFinish: Int?
        let stopCountAtFinish: Int?
        // run終了時(timeout時は取消・回収の後)の値
        let startCountAfterRun: Int
        let stopCountAfterRun: Int
        let startToFirstStop: Duration?

        var summary: String {
            func describeCount(_ value: Int?) -> String { value.map(String.init) ?? "nil" }
            func describeMilliseconds(_ duration: Duration?) -> String {
                guard let duration else { return "nil" }
                // components.attosecondsは1秒未満の端数。1ミリ秒 = 10^15アト秒
                let (seconds, attoseconds) = duration.components
                return String(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
            }
            return [
                "case=\(label)",
                "receive=\(outcome)",
                "elapsedMs=\(describeMilliseconds(elapsed))",
                "callbacks=\(callbackCount)",
                "deliveredBytes=\(deliveredBytes)",
                "beforeChunkDelivery=\(chunkDeliveryPoints)",
                "startAtFinish=\(describeCount(startCountAtFinish))",
                "stopAtFinish=\(describeCount(stopCountAtFinish))",
                "startAfterRun=\(startCountAfterRun)",
                "stopAfterRun=\(stopCountAfterRun)",
                "startToFirstStopMs=\(describeMilliseconds(startToFirstStop))"
            ].joined(separator: " ")
        }
    }

    // 1ケースを専用の世代で実行し、観測値をattachmentとして残して返す。
    // timeout時はrunIsolatedReceiveが取消して回収を試み、回収できなければ以後の診断runを止める。
    // 隔離を保証できないときはnilを返す（その場合は失敗として記録済み）。
    private func runTextPlainDiagnostic(label: String, script: TextPlainDiagnosticURLProtocol.Script)
        async throws -> (outcome: ReceiveOutcome, result: TextPlainDiagnosticResult)? {
        let controller = TextPlainDiagnosticURLProtocol.controller
        guard !controller.hasLeakedRun else {
            XCTFail("\(label): 以前のtimeoutで回収できなかったreceiveが残っており、共有状態の隔離を保証できない")
            return nil
        }
        controller.beginRun(script: script)
        // 途中で失敗・timeoutしても世代を閉じ、古い通知が後のrunに数えられないようにする
        defer { controller.endRun() }
        let probe = Probe()
        let transport = try AIResponsesHTTPTransport(
            testingSyntheticEndpoint: AIResponsesHTTPTransport.syntheticEndpoint,
            credential: Self.dummyCredential, protocolClasses: [TextPlainDiagnosticURLProtocol.self],
            responseHeaderDeadlineForTesting: 0.2,
            controlHook: { point in probe.controlPoints.append(point) })

        var leaked = false
        var startCountAtFinish: Int?
        var stopCountAtFinish: Int?
        let began = ContinuousClock.now
        let outcome = await runIsolatedReceive(transport, markLeaked: {
            leaked = true
            controller.markLeakedRun()
        }, onChunk: { chunk in
            probe.deliveredChunks.append(chunk)
        }, onFinish: {
            // receiveが戻った直後（間にawaitを挟まず）の開始・停止回数を記録する。
            startCountAtFinish = controller.startCount
            stopCountAtFinish = controller.stopCount
        })
        let elapsed = ContinuousClock.now - began
        // endRunより前に読む（timeout時は取消・回収を経た後の値になる）
        let observation = controller.observation

        let outcomeText: String
        switch outcome {
        case .returned:
            outcomeText = "returned"
        case .threw(let error):
            if let transportError = error as? AIResponsesHTTPTransportError {
                outcomeText = "threw(\(transportError))"
            } else if error is CancellationError {
                outcomeText = "threw(CancellationError)"
            } else {
                // 想定外のエラーは型名だけを残し、中身は出さない
                outcomeText = "threw(other:\(String(describing: type(of: error))))"
            }
        case .timedOut:
            outcomeText = leaked ? "timedOut(leaked)" : "timedOut(reclaimed)"
        }
        let result = TextPlainDiagnosticResult(
            label: label, outcome: outcomeText, elapsed: elapsed,
            callbackCount: probe.deliveredChunks.count,
            deliveredBytes: probe.deliveredChunks.reduce(0) { $0 + $1.count },
            chunkDeliveryPoints: probe.controlPoints.filter { $0 == .beforeChunkDelivery }.count,
            startCountAtFinish: startCountAtFinish, stopCountAtFinish: stopCountAtFinish,
            startCountAfterRun: observation.startCount, stopCountAfterRun: observation.stopCount,
            startToFirstStop: observation.startToFirstStop)

        // 成功・失敗に関わらず観測値を残し、3ケースを並べて比べられるようにする
        let attachment = XCTAttachment(string: result.summary)
        attachment.name = "text-plain-diagnostic-\(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return (outcome, result)
    }

    // 3ケース共通の期待: 本文をonChunkへ渡さず、URLProtocolを1回だけ開始し、transportFailedで終わる。
    // stopAtFinishの扱いだけはケースで変える（requiresStopBeforeFinish）。
    private func assertTextPlainRejected(_ run: (outcome: ReceiveOutcome, result: TextPlainDiagnosticResult),
                                         requiresStopBeforeFinish: Bool) {
        let result = run.result
        let summary = result.summary
        XCTAssertEqual(result.callbackCount, 0, "拒否すべき本文がonChunkへ渡った: \(summary)")
        XCTAssertEqual(result.chunkDeliveryPoints, 0, "拒否すべき本文がnextEventから取り出された: \(summary)")
        XCTAssertEqual(result.startCountAtFinish, 1, "合成応答の開始回数が想定と違う: \(summary)")
        if requiresStopBeforeFinish {
            // 完了しない応答は停止でしか終わらないので、receiveが戻る前に1回だけ停止しているはず
            XCTAssertEqual(result.stopCountAtFinish, 1, "URLProtocolの停止より前にreceiveが終了した: \(summary)")
        } else if let stopCountAtFinish = result.stopCountAtFinish {
            // 完了を通知した後にstopLoadingが呼ばれるかはFoundation次第(仮説)なので、重複だけを確かめる
            XCTAssertLessThanOrEqual(stopCountAtFinish, 1, "URLProtocolが複数回停止された: \(summary)")
        }
        guard case .threw(let error) = run.outcome else {
            return XCTFail("transportFailedで終わるべき: \(summary)")
        }
        XCTAssertEqual(error as? AIResponsesHTTPTransportError, .transportFailed, "\(summary)")
    }

    // 診断(A): text/plain・30バイト・完了しない。timeoutが再現するかを見る。
    // 再現しても許容せず失敗として扱う（取消して回収した上で、観測値をattachmentに残す）。
    func testDiagnosticTextPlainSmallBodyWithoutFinishing() async throws {
        guard let run = try await runTextPlainDiagnostic(
            label: "A-30B-unfinished", script: .init(bodyByteCount: 30, finishesAfterBody: false)) else {
            return
        }
        assertTextPlainRejected(run, requiresStopBeforeFinish: true)
    }

    // 診断(B): text/plain・2KiB・完了しない。(A)との違いは本文の量だけ。
    func testDiagnosticTextPlainLargerBodyWithoutFinishing() async throws {
        guard let run = try await runTextPlainDiagnostic(
            label: "B-2KiB-unfinished", script: .init(bodyByteCount: 2 * 1024, finishesAfterBody: false)) else {
            return
        }
        assertTextPlainRejected(run, requiresStopBeforeFinish: true)
    }

    // 診断(C): text/plain・30バイト・URLProtocolがdidFinishLoadingする。(A)との違いは完了の有無だけ。
    func testDiagnosticTextPlainSmallBodyThenProtocolFinishes() async throws {
        guard let run = try await runTextPlainDiagnostic(
            label: "C-30B-finished", script: .init(bodyByteCount: 30, finishesAfterBody: true)) else {
            return
        }
        assertTextPlainRejected(run, requiresStopBeforeFinish: false)
    }

    // MARK: - 応答ヘッダー待ちdeadline（回帰テスト）

    // 応答ヘッダー待ちdeadlineのテスト専用URLProtocol。他のテストとは状態を共有せず、runの世代ごとに開始・停止を数える。
    // status 200で、Scriptのヘッダー・本文を渡す。完了するかどうかはScriptで切り替える。
    // 完了しない場合は、取消・停止(stopLoading)でしか終わらない。ヘッダーや本文は記録・出力しない。
    //
    // 観測済み: text/plain・合成30B・未完了では、5秒待ってもURLSessionの応答通知が来なかった。
    // 理由(MIME sniffing等)は仮説で確かめていないので、このテストは理由に依存しない。
    private final class ResponseHeaderDeadlineURLProtocol: URLProtocol {
        struct Script {
            var headerFields: [String: String]
            var chunks: [Data]
            // trueなら最後のchunkの後にurlProtocolDidFinishLoadingを呼ぶ
            var finishesAfterChunks: Bool
        }

        final class Controller: @unchecked Sendable {
            private let lock = NSLock()
            private var generation = 0
            private var isRunActive = false
            private var script: Script?
            private var starts = 0
            private var stops = 0
            // timeout後に回収できなかったreceiveの数。1以上なら以後のrunの隔離を保証できない
            private var leakedRuns = 0

            func beginRun(script: Script) {
                lock.lock(); defer { lock.unlock() }
                generation += 1
                isRunActive = true
                self.script = script
                starts = 0
                stops = 0
            }

            // 世代を進めて閉じる。これ以降に届いた古い開始・停止は無視される。
            func endRun() {
                lock.lock(); defer { lock.unlock() }
                generation += 1
                isRunActive = false
                script = nil
            }

            // run中でなければnilを返し、開始として数えない。
            func beginLoading() -> (generation: Int, script: Script)? {
                lock.lock(); defer { lock.unlock() }
                guard isRunActive, let script else {
                    return nil
                }
                starts += 1
                return (generation, script)
            }

            func recordStop(generation: Int?) {
                lock.lock(); defer { lock.unlock() }
                guard isRunActive, generation == self.generation else {
                    return
                }
                stops += 1
            }

            func markLeakedRun() {
                lock.lock(); defer { lock.unlock() }
                leakedRuns += 1
            }

            var hasLeakedRun: Bool {
                lock.lock(); defer { lock.unlock() }
                return leakedRuns > 0
            }

            var startCount: Int {
                lock.lock(); defer { lock.unlock() }
                return starts
            }

            var stopCount: Int {
                lock.lock(); defer { lock.unlock() }
                return stops
            }
        }

        static let controller = Controller()

        private var loadingGeneration: Int?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canInit(with task: URLSessionTask) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  url.scheme == AIResponsesHTTPTransport.syntheticScheme,
                  url.host == "responses",
                  let run = Self.controller.beginLoading() else {
                // 独自スキーム以外、またはrun外の古い開始は応答を作らず固定エラーで閉じる。外部へは送らない。
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            loadingGeneration = run.generation
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: run.script.headerFields)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in run.script.chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            if run.script.finishesAfterChunks {
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() {
            Self.controller.recordStop(generation: loadingGeneration)
        }
    }

    // deadlineテスト1回分の観測値。件数とエラーの種類だけを持ち、ヘッダー・認証情報は含めない。
    private struct ResponseHeaderDeadlineRun {
        let outcome: ReceiveOutcome
        let deliveredChunks: [Data]
        // nextEventがdataを返した回数(onChunkへ渡さなかった分も含む)
        let chunkDeliveryPoints: Int
        // receiveが戻った・投げた直後の値。回収できなかったtimeout時はnil
        let startCountAtFinish: Int?
        let stopCountAtFinish: Int?
    }

    // 試験用の短いdeadline(秒)。本番のdeadlineとは別の値で、test-only初期化にだけ渡す。
    private static let testResponseHeaderDeadline: TimeInterval = 0.2

    // 応答通知・本文・完了を一切送らない、完全無応答ケース専用の独立URLProtocol。
    private final class SilentResponsesURLProtocol: URLProtocol {
        final class Controller: @unchecked Sendable {
            private let lock = NSLock()
            private var generation = 0
            private var active = false
            private var starts = 0
            private var stops = 0
            private var leakedRuns = false
            private var stopSignal = DispatchSemaphore(value: 0)

            func beginRun() {
                lock.lock(); defer { lock.unlock() }
                generation += 1
                active = true
                starts = 0
                stops = 0
                stopSignal = DispatchSemaphore(value: 0)
            }
            func endRun() {
                lock.lock(); defer { lock.unlock() }
                generation += 1
                active = false
            }
            func beginLoading() -> Int? {
                lock.lock(); defer { lock.unlock() }
                guard active else { return nil }
                starts += 1
                return generation
            }
            func recordStop(_ run: Int?) {
                lock.lock(); defer { lock.unlock() }
                guard active, run == generation else { return }
                stops += 1
                stopSignal.signal()
            }
            func waitForStop(timeout: TimeInterval) -> Bool {
                lock.lock()
                let signal = stopSignal
                lock.unlock()
                return signal.wait(timeout: .now() + timeout) == .success
            }
            func markLeaked() {
                lock.lock(); defer { lock.unlock() }
                leakedRuns = true
            }
            var hasLeakedRun: Bool {
                lock.lock(); defer { lock.unlock() }
                return leakedRuns
            }
            var counts: (starts: Int, stops: Int) {
                lock.lock(); defer { lock.unlock() }
                return (starts, stops)
            }
        }

        static let controller = Controller()
        private var loadingGeneration: Int?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canInit(with task: URLSessionTask) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  url == AIResponsesHTTPTransport.syntheticEndpoint,
                  let generation = Self.controller.beginLoading() else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            loadingGeneration = generation
            // 意図的にresponse/data/finish/errorを一切通知しない。
        }

        override func stopLoading() {
            Self.controller.recordStop(loadingGeneration)
        }
    }

    func testCompletelySilentProtocolExpiresHeaderDeadlineAndStopsBeforeReturn() async throws {
        let controller = SilentResponsesURLProtocol.controller
        guard !controller.hasLeakedRun else {
            return XCTFail("以前のtimeoutでreceiveを回収できず、隔離を保証できない")
        }
        controller.beginRun()
        defer { controller.endRun() }
        let transport = try AIResponsesHTTPTransport(
            testingSyntheticEndpoint: URL(string: "melete-synthetic://responses")!,
            credential: Self.dummyCredential, protocolClasses: [SilentResponsesURLProtocol.self],
            responseHeaderDeadlineForTesting: 0.2)
        var callbackCount = 0
        var countsAtFinish: (starts: Int, stops: Int)?
        let outcome = await runIsolatedReceive(transport, timeout: 3, reclaimTimeout: 3,
                                               markLeaked: { controller.markLeaked() }, onChunk: { _ in
            callbackCount += 1
        }, onFinish: {
            countsAtFinish = controller.counts
        })

        XCTAssertEqual(callbackCount, 0)
        XCTAssertEqual(countsAtFinish?.starts, 1)
        XCTAssertEqual(countsAtFinish?.stops, 1, "URLProtocol停止より前にreceiveが終了した")
        guard case .threw(let error) = outcome else {
            return XCTFail("完全無応答はdeadlineでtransportFailedになるべき: \(outcome)")
        }
        XCTAssertEqual(error as? AIResponsesHTTPTransportError, .transportFailed)
    }

    // afterSessionStartでMainActorを短時間塞いでも、0.15秒deadlineによるstopLoadingが別threadから届く。
    func testSilentProtocolDeadlineStopsWhileMainActorIsBoundedlyBlocked() async throws {
        let controller = SilentResponsesURLProtocol.controller
        guard !controller.hasLeakedRun else {
            return XCTFail("以前のtimeoutでreceiveを回収できず、隔離を保証できない")
        }
        controller.beginRun()
        defer { controller.endRun() }
        var protocolStartedBeforeBlocking = false
        var stopObservedWhileBlocked = false
        let transport = try AIResponsesHTTPTransport(
            testingSyntheticEndpoint: AIResponsesHTTPTransport.syntheticEndpoint,
            credential: Self.dummyCredential, protocolClasses: [SilentResponsesURLProtocol.self],
            responseHeaderDeadlineForTesting: 0.15,
            controlHook: { point in
                guard point == .afterSessionStart else { return }
                // startLoadingを確認してから、deadline発火を待つ間MainActorを合計最大0.95秒塞ぐ。
                let started = ContinuousClock.now
                while controller.counts.starts == 0 && ContinuousClock.now - started < .seconds(0.15) {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                protocolStartedBeforeBlocking = controller.counts.starts == 1
                stopObservedWhileBlocked = controller.waitForStop(timeout: 0.8)
            })

        let outcome = await runIsolatedReceive(transport, timeout: 1, reclaimTimeout: 1,
                                               markLeaked: { controller.markLeaked() }, onChunk: { _ in
            XCTFail("無応答protocolから本文は届かない")
        })

        XCTAssertTrue(protocolStartedBeforeBlocking, "MainActorを塞ぐ前にURLProtocol開始を確認できなかった")
        XCTAssertTrue(stopObservedWhileBlocked, "MainActorを塞いでいる間にdeadline起因のstopLoadingを確認できなかった")
        guard case .threw(let error) = outcome else {
            return XCTFail("deadline超過でtransportFailedになるべき: \(outcome)")
        }
        XCTAssertEqual(error as? AIResponsesHTTPTransportError, .transportFailed)
        XCTAssertEqual(controller.counts.stops, 1)
    }

    func testTestingInitializerRejectsInvalidResponseHeaderDeadlines() {
        let invalidDeadlines: [TimeInterval] = [0, -0.1, .infinity, -.infinity, .nan,
                                                AIResponsesHTTPTransport.productionResponseHeaderDeadline + 1]
        for deadline in invalidDeadlines {
            XCTAssertThrowsError(try AIResponsesHTTPTransport(
                testingSyntheticEndpoint: URL(string: "melete-synthetic://responses")!,
                credential: Self.dummyCredential, protocolClasses: [SilentResponsesURLProtocol.self],
                responseHeaderDeadlineForTesting: deadline), "deadline \(deadline) を拒否すべき") { error in
                XCTAssertEqual(error as? AIResponsesHTTPTransportError, .invalidTestingResponseHeaderDeadline)
            }
        }
    }

    // 1ケースを専用の世代で実行する。制限時間内に終わらなければrunIsolatedReceiveがTaskを取消して回収を試み、
    // 回収できなければ以後のrunを止める。隔離を保証できないときはnilを返す（その場合は失敗として記録済み）。
    private func runResponseHeaderDeadlineCase(script: ResponseHeaderDeadlineURLProtocol.Script,
                                               timeout: TimeInterval) async throws -> ResponseHeaderDeadlineRun? {
        let controller = ResponseHeaderDeadlineURLProtocol.controller
        guard !controller.hasLeakedRun else {
            XCTFail("以前のtimeoutで回収できなかったreceiveが残っており、共有状態の隔離を保証できない")
            return nil
        }
        controller.beginRun(script: script)
        // 途中で失敗・timeoutしても世代を閉じ、古い通知が後のrunに数えられないようにする
        defer { controller.endRun() }
        let probe = Probe()
        let transport = try AIResponsesHTTPTransport(
            testingSyntheticEndpoint: AIResponsesHTTPTransport.syntheticEndpoint,
            credential: Self.dummyCredential, protocolClasses: [ResponseHeaderDeadlineURLProtocol.self],
            responseHeaderDeadlineForTesting: Self.testResponseHeaderDeadline,
            controlHook: { point in probe.controlPoints.append(point) })

        var startCountAtFinish: Int?
        var stopCountAtFinish: Int?
        let outcome = await runIsolatedReceive(transport, timeout: timeout,
                                               markLeaked: { controller.markLeakedRun() }, onChunk: { chunk in
            probe.deliveredChunks.append(chunk)
        }, onFinish: {
            // receiveが戻った直後（間にawaitを挟まず）の開始・停止回数を記録する。
            startCountAtFinish = controller.startCount
            stopCountAtFinish = controller.stopCount
        })
        return ResponseHeaderDeadlineRun(
            outcome: outcome, deliveredChunks: probe.deliveredChunks,
            chunkDeliveryPoints: probe.controlPoints.filter { $0 == .beforeChunkDelivery }.count,
            startCountAtFinish: startCountAtFinish, stopCountAtFinish: stopCountAtFinish)
    }

    // 応答通知が来ないtext/plain・合成30B・未完了の応答は、試験用deadline(0.2秒)を過ぎたら
    // taskを取消し、URLProtocolの停止を待ってからtransportFailedで終わる。本文はonChunkへ渡さない。
    // deadlineがなければ取消されるまで終わらないので、制限時間(3秒)を超えたら取消・回収して失敗にする。
    func testResponseHeaderDeadlineFailsUnfinishedTextPlainWithoutResponseNotification() async throws {
        let script = ResponseHeaderDeadlineURLProtocol.Script(
            headerFields: ["Content-Type": "text/plain"],
            chunks: [Data(repeating: UInt8(ascii: "p"), count: 30)],
            finishesAfterChunks: false)
        guard let run = try await runResponseHeaderDeadlineCase(script: script, timeout: 3) else {
            return
        }

        XCTAssertTrue(run.deliveredChunks.isEmpty, "拒否すべき本文がonChunkへ渡った")
        XCTAssertEqual(run.chunkDeliveryPoints, 0, "拒否すべき本文がnextEventから取り出された")
        XCTAssertEqual(run.startCountAtFinish, 1, "合成応答の開始回数が想定と違う")
        XCTAssertEqual(run.stopCountAtFinish, 1, "deadline超過後、URLProtocolの停止より前にreceiveが終了した")
        guard case .threw(let error) = run.outcome else {
            return XCTFail("deadline超過でtransportFailedになるべき: \(run.outcome)")
        }
        XCTAssertEqual(error as? AIResponsesHTTPTransportError, .transportFailed, "\(error)")
        XCTAssertFalse(error is CancellationError, "取消していないのにCancellationErrorになった")
    }

    // 対照: 妥当なSSE(text/event-stream)がdeadlineより前に届いて完了する応答は、同じ試験用deadlineでも
    // 失敗せず、本文をそのままonChunkへ渡して正常に戻る。
    func testValidStreamArrivingBeforeResponseHeaderDeadlineIsDelivered() async throws {
        let chunks = [
            Data("event: synthetic.first\ndata: {\"n\":1}\n\n".utf8),
            Data("event: synthetic.second\ndata: {\"n\":2}\n\n".utf8)
        ]
        let script = ResponseHeaderDeadlineURLProtocol.Script(
            headerFields: ["Content-Type": "text/event-stream"],
            chunks: chunks,
            finishesAfterChunks: true)
        guard let run = try await runResponseHeaderDeadlineCase(script: script, timeout: 3) else {
            return
        }

        guard case .returned = run.outcome else {
            return XCTFail("deadline前に届いた妥当なSSEは正常に戻るべき: \(run.outcome)")
        }
        XCTAssertFalse(run.deliveredChunks.isEmpty)
        // chunk境界はURLSession側で結合され得るため、連結結果で比べる
        XCTAssertEqual(run.deliveredChunks.reduce(Data(), +), chunks.reduce(Data(), +))
        XCTAssertEqual(run.startCountAtFinish, 1)
        // 完了を通知した後にstopLoadingが呼ばれるかはFoundation次第なので、重複だけを確かめる
        if let stopCountAtFinish = run.stopCountAtFinish {
            XCTAssertLessThanOrEqual(stopCountAtFinish, 1, "URLProtocolが複数回停止された")
        }
    }

    // 対照(遅い後続chunk)専用のURLProtocol。他のテストとは状態を共有せず、runの世代ごとに開始・停止を数える。
    // 応答内容は固定: 妥当なSSEヘッダー(status 200・text/event-stream)と1つ目のchunkをすぐ渡し、
    // 試験用deadlineより長いsecondChunkDelay秒だけ完了しない状態を保ってから、2つ目のchunkと完了を渡す。
    // 遅延はstartLoadingを呼んだthreadのrun loopで行い、停止(stopLoading)されたら予約を取り消す。
    // ヘッダーや本文は記録・出力しない。
    private final class DelayedSecondChunkURLProtocol: URLProtocol {
        static let firstChunk = Data("event: synthetic.first\ndata: {\"n\":1}\n\n".utf8)
        static let secondChunk = Data("event: synthetic.second\ndata: {\"n\":2}\n\n".utf8)
        // 試験用deadline(0.2秒)を確実に超える固定の遅延(秒)
        static let secondChunkDelay: TimeInterval = 0.5

        final class Controller: @unchecked Sendable {
            private let lock = NSLock()
            private var generation = 0
            private var isRunActive = false
            private var starts = 0
            private var stops = 0
            private var secondChunksSent = 0
            // timeout後に回収できなかったreceiveの数。1以上なら以後のrunの隔離を保証できない
            private var leakedRuns = 0

            func beginRun() {
                lock.lock(); defer { lock.unlock() }
                generation += 1
                isRunActive = true
                starts = 0
                stops = 0
                secondChunksSent = 0
            }

            // 世代を進めて閉じる。これ以降に届いた古い開始・停止・送信は無視される。
            func endRun() {
                lock.lock(); defer { lock.unlock() }
                generation += 1
                isRunActive = false
            }

            // run中でなければnilを返し、開始として数えない。
            func beginLoading() -> Int? {
                lock.lock(); defer { lock.unlock() }
                guard isRunActive else {
                    return nil
                }
                starts += 1
                return generation
            }

            // 同じ世代のrun中なら2つ目のchunkを送ってよいと答え、送信として数える。
            func beginSecondChunk(generation: Int?) -> Bool {
                lock.lock(); defer { lock.unlock() }
                guard isRunActive, generation == self.generation else {
                    return false
                }
                secondChunksSent += 1
                return true
            }

            func recordStop(generation: Int?) {
                lock.lock(); defer { lock.unlock() }
                guard isRunActive, generation == self.generation else {
                    return
                }
                stops += 1
            }

            func markLeakedRun() {
                lock.lock(); defer { lock.unlock() }
                leakedRuns += 1
            }

            var hasLeakedRun: Bool {
                lock.lock(); defer { lock.unlock() }
                return leakedRuns > 0
            }

            var startCount: Int {
                lock.lock(); defer { lock.unlock() }
                return starts
            }

            var stopCount: Int {
                lock.lock(); defer { lock.unlock() }
                return stops
            }

            var secondChunkSentCount: Int {
                lock.lock(); defer { lock.unlock() }
                return secondChunksSent
            }
        }

        static let controller = Controller()

        private var loadingGeneration: Int?
        // startLoading・遅延送信・stopLoadingはすべて同じclient threadで動くので、lockなしで読み書きする
        private var isStopped = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canInit(with task: URLSessionTask) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  url.scheme == AIResponsesHTTPTransport.syntheticScheme,
                  url.host == "responses",
                  let generation = Self.controller.beginLoading() else {
                // 独自スキーム以外、またはrun外の古い開始は応答を作らず固定エラーで閉じる。外部へは送らない。
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            loadingGeneration = generation
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.firstChunk)
            // 完了を通知せずに戻り、このthreadのrun loopで遅延送信を予約する。
            // 現在のmodeでも確実に動くよう、defaultと現在のmodeの両方に登録する。
            var modes: [RunLoop.Mode] = [.default]
            if let currentMode = RunLoop.current.currentMode, currentMode != .default {
                modes.append(currentMode)
            }
            perform(#selector(deliverSecondChunkAndFinish), with: nil,
                    afterDelay: Self.secondChunkDelay, inModes: modes)
        }

        @objc private func deliverSecondChunkAndFinish() {
            // 停止後や別世代になった後は送らない
            guard !isStopped, Self.controller.beginSecondChunk(generation: loadingGeneration) else {
                return
            }
            client?.urlProtocol(self, didLoad: Self.secondChunk)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {
            isStopped = true
            // 予約した遅延送信を取り消す（予約と同じthreadで呼ばれる）
            NSObject.cancelPreviousPerformRequests(withTarget: self,
                                                   selector: #selector(deliverSecondChunkAndFinish), object: nil)
            Self.controller.recordStop(generation: loadingGeneration)
        }
    }

    // 対照: 妥当なSSEヘッダーと1つ目のchunkが届いた後、試験用deadline(0.2秒)を超えて完了しない状態が続いても、
    // deadlineは応答ヘッダー待ちだけに効くので失敗しない。0.5秒後の2つ目のchunkと完了まで待ち、
    // 両chunkを順にonChunkへ渡して正常に戻る。deadlineを「応答全体」へ誤適用するとこのテストは失敗する。
    // 制限時間(3秒)を超えたらrunIsolatedReceiveがTaskを取消・回収して失敗にする。
    func testValidStreamStayingOpenPastResponseHeaderDeadlineDeliversBothChunksInOrder() async throws {
        let controller = DelayedSecondChunkURLProtocol.controller
        XCTAssertGreaterThan(DelayedSecondChunkURLProtocol.secondChunkDelay, Self.testResponseHeaderDeadline,
                             "遅延が試験用deadlineを超えていない")
        guard !controller.hasLeakedRun else {
            return XCTFail("以前のtimeoutで回収できなかったreceiveが残っており、共有状態の隔離を保証できない")
        }
        controller.beginRun()
        // 途中で失敗・timeoutしても世代を閉じ、古い通知が後のrunに数えられないようにする
        defer { controller.endRun() }
        let probe = Probe()
        let transport = try AIResponsesHTTPTransport(
            testingSyntheticEndpoint: AIResponsesHTTPTransport.syntheticEndpoint,
            credential: Self.dummyCredential, protocolClasses: [DelayedSecondChunkURLProtocol.self],
            responseHeaderDeadlineForTesting: Self.testResponseHeaderDeadline,
            controlHook: { point in probe.controlPoints.append(point) })

        // onChunkが呼ばれた時点で、2つ目のchunkが送信済みだったか（1回目はfalseのはず）
        var secondChunkSentAtDelivery: [Bool] = []
        var startCountAtFinish: Int?
        var stopCountAtFinish: Int?
        var secondChunkSentCountAtFinish: Int?
        let began = ContinuousClock.now
        let outcome = await runIsolatedReceive(transport, timeout: 3,
                                               markLeaked: { controller.markLeakedRun() }, onChunk: { chunk in
            secondChunkSentAtDelivery.append(controller.secondChunkSentCount > 0)
            probe.deliveredChunks.append(chunk)
        }, onFinish: {
            // receiveが戻った直後（間にawaitを挟まず）の値を記録する。
            startCountAtFinish = controller.startCount
            stopCountAtFinish = controller.stopCount
            secondChunkSentCountAtFinish = controller.secondChunkSentCount
        })
        let elapsed = ContinuousClock.now - began

        guard case .returned = outcome else {
            return XCTFail("deadline後も続く妥当なSSEは正常に戻るべき: \(outcome)")
        }
        XCTAssertEqual(startCountAtFinish, 1)
        XCTAssertEqual(secondChunkSentCountAtFinish, 1, "2つ目のchunkと完了が送られる前にreceiveが戻った")
        // 1つ目のchunkは、2つ目が送られる前（deadlineを超えて待っている間）に単独で届いているはず
        XCTAssertEqual(probe.deliveredChunks.first, DelayedSecondChunkURLProtocol.firstChunk,
                       "1つ目のchunkが単独で先に届いていない")
        XCTAssertEqual(secondChunkSentAtDelivery.first, false, "1つ目のchunkが2つ目の送信後まで届かなかった")
        // chunk境界はURLSession側で結合され得るため、順序は連結結果で比べる
        XCTAssertEqual(probe.deliveredChunks.reduce(Data(), +),
                       DelayedSecondChunkURLProtocol.firstChunk + DelayedSecondChunkURLProtocol.secondChunk,
                       "両chunkが順に届いていない")
        XCTAssertEqual(probe.controlPoints.filter { $0 == .beforeChunkDelivery }.count, probe.deliveredChunks.count,
                       "取り出したdataの一部がonChunkへ渡らなかった")
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(Self.testResponseHeaderDeadline),
                                    "試験用deadlineを超える前に終わっており、対照になっていない")
        // 完了を通知した後にstopLoadingが呼ばれるかはFoundation次第なので、重複だけを確かめる
        if let stopCountAtFinish {
            XCTAssertLessThanOrEqual(stopCountAtFinish, 1, "URLProtocolが複数回停止された")
        }
    }
    #endif
}
