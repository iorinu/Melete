import XCTest
@testable import Melete

// ChatGPT OAuth初回登録flowの縦切りと、安全境界（期限・取消・開始中や停止後のcallback・二重待機・
// listener開始失敗・listener障害）を合成値だけで検証する。
// fake listenerの開始 → 同じstateと実際のportで認可URL生成 → callback → token requestを1回だけ返す、までを確かめる。
// 実際のsocket・ネットワーク・ブラウザ・Keychain・保存・UIには一切触れず、token requestも送信しない。
// 値はすべてテスト専用の合成固定値で、時刻は固定のモック時計を使う。
// 期限はテストが手動で進める待機だけを使い、実時間の経過では期限を来させない。
// 待ち合わせはすべて上限時間つきのgateで行い、想定どおりに進まなくてもテストがハングしないようにする。
// 「既知の未修正点」の3件と「listener障害」の4件は、修正済みの欠陥を固定する回帰テスト。
// 「HTTP応答の確定待ち」は案Bのflow側を固定する。最初の5件はRED確認済み（stub時に失敗）の後に実装で通したもの、
// 残りは通知先行・応答待ち中の期限と時計・待ち手Taskの取消を固定する追加テスト。
@MainActor
final class ChatGPTOAuthLoginFlowTests: XCTestCase {
    // 合成の固定値（実際の認証には使われない）。それぞれ43文字のunreserved文字
    private let syntheticState = "SyntheticFlowState0123456789-_abcdefghijklm"
    private let syntheticNonce = "SyntheticFlowNonce0123456789-_nopqrstuvwxyz"
    private let syntheticVerifier = "SyntheticFlowVerifier0123456789-._~abcdefgh"

    private let syntheticHostID = "urn:uuid:11111111-2222-4333-8444-555555555555"
    // fake listenerが「bindした」と報告する合成port。既定値と取り違えないよう他テストと異なる値にする
    private let syntheticPort = 51234
    private let syntheticCode = "SyntheticFlowCode0123456789"
    private let otherCode = "OtherSyntheticFlowCode0123456789"
    private let syntheticClientID = "synthetic_issued_client_flow_0123"

    private let lifetime: TimeInterval = 300
    // 固定の開始時刻・単調時計（実時刻は使わない）
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let fixedUptime: TimeInterval = 1_000

    // MARK: - fixture

    // テストが開くまで待たせる非同期のgate。上限時間を過ぎたら timedOut を投げて待ちを打ち切る。
    // 上限は安全装置で、テストの判定には使わない（打ち切りが起きたら timedOut フラグで失敗させる）
    private final class AsyncGate: @unchecked Sendable {
        enum GateError: Error { case timedOut }

        // wait()に入った時点の状態ごとの扱い
        private enum Entry { case pass, cancel, suspend }

        private let lock = NSLock()
        private let timeout: Duration
        // trueなら待っているTaskの取消で CancellationError を投げる。falseなら取消を無視して開くまで待つ
        private let honorsCancellation: Bool
        private var isOpen = false
        private var _enteredCount = 0
        private var _timedOut = false
        private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        // continuationを登録する前に取消が届いたもの（onCancelは本体より先に呼ばれることがある）
        private var cancelledBeforeRegistration: Set<UUID> = []
        private var timers: [UUID: Task<Void, Never>] = [:]

        init(timeout: Duration = .seconds(5), honorsCancellation: Bool) {
            self.timeout = timeout
            self.honorsCancellation = honorsCancellation
        }

        var enteredCount: Int { lock.withLock { _enteredCount } }
        var timedOut: Bool { lock.withLock { _timedOut } }

        func wait() async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let entry: Entry = lock.withLock {
                        _enteredCount += 1
                        if isOpen { return .pass }
                        if cancelledBeforeRegistration.remove(id) != nil { return .cancel }
                        waiters[id] = continuation
                        return .suspend
                    }
                    switch entry {
                    case .pass:
                        continuation.resume()
                    case .cancel:
                        continuation.resume(throwing: CancellationError())
                    case .suspend:
                        // 上限時間で打ち切るタイマー。開いた・取消された時はcancelされ何もしない
                        let timeout = self.timeout
                        let timer = Task { [weak self] in
                            try? await Task.sleep(for: timeout)
                            if Task.isCancelled { return }
                            self?.resume(id, with: .failure(GateError.timedOut), isTimeout: true)
                        }
                        lock.withLock { timers[id] = timer }
                    }
                }
            } onCancel: { [honorsCancellation] in
                guard honorsCancellation else { return }
                self.cancel(id)
            }
        }

        // 待っている全員を通し、以後のwait()もすぐ通す
        func open() {
            let (pending, pendingTimers) = lock.withLock {
                isOpen = true
                let pending = waiters
                let pendingTimers = timers
                waiters.removeAll()
                timers.removeAll()
                return (pending, pendingTimers)
            }
            pendingTimers.values.forEach { $0.cancel() }
            pending.values.forEach { $0.resume() }
        }

        private func cancel(_ id: UUID) {
            let registered = lock.withLock { () -> Bool in
                if waiters[id] != nil { return true }
                cancelledBeforeRegistration.insert(id)
                return false
            }
            if registered {
                resume(id, with: .failure(CancellationError()), isTimeout: false)
            }
        }

        // continuationは必ず1回だけresumeする。辞書から取り出せた側だけが再開する
        private func resume(_ id: UUID, with result: Result<Void, Error>, isTimeout: Bool) {
            let (continuation, timer) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Task<Void, Never>?) in
                guard let continuation = waiters.removeValue(forKey: id) else { return (nil, nil) }
                if isTimeout { _timedOut = true }
                return (continuation, timers.removeValue(forKey: id))
            }
            if !isTimeout { timer?.cancel() }
            continuation?.resume(with: result)
        }
    }

    // テストが fire() を呼んだ時だけ期限が来る待機。flowが期限待機を取り消したら投げて終わる
    private final class ManualDeadline: @unchecked Sendable {
        // 上限はlistener側より長くし、テストの途中で期限が勝手に来ないようにする
        let gate = AsyncGate(timeout: .seconds(10), honorsCancellation: true)
        private let lock = NSLock()
        private var _requestedSeconds: [TimeInterval] = []

        // flowが期限待機に渡した秒数（呼ばれた順）
        var requestedSeconds: [TimeInterval] { lock.withLock { _requestedSeconds } }

        var waiter: ChatGPTOAuthLoginFlow.DeadlineWaiter {
            { [self] seconds in
                self.lock.withLock { self._requestedSeconds.append(seconds) }
                try await self.gate.wait()
            }
        }

        func fire() { gate.open() }
    }

    // 合成のlistener開始エラー。flowの外へそのまま出てはいけない
    private struct SyntheticListenerError: Error {}

    // socketを開かず、flowから渡されたstateとsinkを記録するだけのlistener。
    // flowとテストの両方から触るため、記録はlockで守る。
    // start・stopは任意のgateで止められ、startは合成エラーで失敗させることもできる
    private final class FakeListener: ChatGPTOAuthLoopbackListening, @unchecked Sendable {
        private let lock = NSLock()
        private let port: Int
        // startは取消を無視して開くまで待つ（本物のlistenerがbind完了まで戻らない状況を模す）
        private let startGate: AsyncGate?
        private let stopGate: AsyncGate?
        private let failsToStart: Bool
        // start()・stop()に入った時に開くだけのgate。テストが「到達した」ことを上限時間つきで待つのに使う
        private let startEntered: AsyncGate?
        private let stopEntered: AsyncGate?
        private var _expectedState: String?
        private var _sink: ChatGPTOAuthLoopbackListener.CallbackSink?
        private var _failureHandler: ChatGPTOAuthLoginFlow.ListenerFailureHandler?
        private var _responseCompletionHandler: ChatGPTOAuthLoginFlow.ResponseCompletionHandler?
        private var _startCount = 0
        private var _stopCount = 0

        init(
            port: Int,
            startGate: AsyncGate? = nil,
            stopGate: AsyncGate? = nil,
            failsToStart: Bool = false,
            startEntered: AsyncGate? = nil,
            stopEntered: AsyncGate? = nil
        ) {
            self.port = port
            self.startGate = startGate
            self.stopGate = stopGate
            self.failsToStart = failsToStart
            self.startEntered = startEntered
            self.stopEntered = stopEntered
        }

        // factoryから1回だけ呼ばれ、flowが選んだstate・sink・障害と応答確定の受け取り先を受け取る
        func configure(
            expectedState: String,
            sink: @escaping ChatGPTOAuthLoopbackListener.CallbackSink,
            failureHandler: @escaping ChatGPTOAuthLoginFlow.ListenerFailureHandler,
            responseCompletionHandler: @escaping ChatGPTOAuthLoginFlow.ResponseCompletionHandler
        ) {
            lock.withLock {
                _expectedState = expectedState
                _sink = sink
                _failureHandler = failureHandler
                _responseCompletionHandler = responseCompletionHandler
            }
        }

        var expectedState: String? { lock.withLock { _expectedState } }
        // start()・stop()に入った回数（gateで止まっている間も数える）
        var startCount: Int { lock.withLock { _startCount } }
        var stopCount: Int { lock.withLock { _stopCount } }

        func start() async throws -> Int {
            lock.withLock { _startCount += 1 }
            startEntered?.open()
            if let startGate {
                try await startGate.wait()
            }
            if failsToStart {
                throw SyntheticListenerError()
            }
            return port
        }

        func stop() async {
            lock.withLock { _stopCount += 1 }
            stopEntered?.open()
            if let stopGate {
                // stopは投げられないので、gateの打ち切りはtimedOutフラグで検出する
                try? await stopGate.wait()
            }
        }

        // listenerが内部で壊れた状況を模す。本物のlistenerがserver channelの障害時に送るのと同じ値を、
        // factoryから受け取ったfailureHandlerへ渡す。呼ぶたびに渡すので、重複通知の検証にも使える
        func simulateRuntimeFailure() {
            let handler = lock.withLock { _failureHandler }
            handler?(.listenerFailed)
        }

        // 本物のlistenerがstate一致を確認した後にsinkへ渡すのと同じ形で、合成callbackを配送する。
        // sinkが戻った後に応答を書き終えた想定で、続けて応答確定（flush完了）も通知する
        func deliver(_ callback: String) {
            deliverWithoutResponseCompletion(callback)
            completeResponse(.flushed)
        }

        // callbackだけを配送し、応答確定の通知はテストが completeResponse を呼ぶまで保留する
        func deliverWithoutResponseCompletion(_ callback: String) {
            let sink = lock.withLock { _sink }
            sink?(ChatGPTOAuthLoopbackCallbackRequest(callback: callback))
        }

        // factoryから受け取った受け取り先へ応答確定を通知する。呼ぶたびに渡すので、重複通知の検証にも使える
        func completeResponse(_ completion: ChatGPTOAuthLoginFlow.ResponseCompletion) {
            let handler = lock.withLock { _responseCompletionHandler }
            handler?(completion)
        }
    }

    // flow・factoryから呼ばれた回数を数える
    private final class Counter {
        var value = 0
    }

    // テストが手で進める時計。now（壁時計）とuptime（単調時計）を同じだけ進める。
    // flowもテストも@MainActorから読むので、@MainActorに閉じ込める
    @MainActor
    private final class MutableClock {
        var date: Date
        var uptime: TimeInterval

        init(date: Date, uptime: TimeInterval) {
            self.date = date
            self.uptime = uptime
        }

        func advance(by seconds: TimeInterval) {
            date = date.addingTimeInterval(seconds)
            uptime += seconds
        }
    }

    private var syntheticSecrets: ChatGPTOAuthAuthorizationSecrets {
        ChatGPTOAuthAuthorizationSecrets(state: syntheticState, nonce: syntheticNonce, codeVerifier: syntheticVerifier)
    }

    private var syntheticRedirect: String { "http://127.0.0.1:\(syntheticPort)/auth/callback" }

    // 期限が来ない待機。取消されるまで戻らず、取消されたら投げる（実時間のsleepは使わない）
    private static let neverReachedDeadline: ChatGPTOAuthLoginFlow.DeadlineWaiter = { _ in
        let stream = AsyncStream<Never> { _ in }
        for await _ in stream {}
        try Task.checkCancellation()
    }

    // 非同期の呼び出し結果を受け取る箱。上限時間つきで完了を待てる
    private final class Pending<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private let done = AsyncGate(honorsCancellation: false)
        private var _result: Result<Value, Error>?

        // まだ完了していなければnil
        var result: Result<Value, Error>? { lock.withLock { _result } }

        func fulfill(_ result: Result<Value, Error>) {
            lock.withLock { _result = result }
            done.open()
        }

        // 完了を待つ。上限時間内に完了しなければnilを返す（ハングさせない）
        func value() async -> Result<Value, Error>? {
            try? await done.wait()
            return result
        }
    }

    // 呼び出しを別のTask（@MainActor）で走らせ、結果をPendingへ入れる。Taskは取消の検証に使う
    private func launch<Value>(
        _ operation: @escaping @MainActor () async throws -> Value
    ) -> (task: Task<Void, Never>, pending: Pending<Value>) {
        let pending = Pending<Value>()
        let task = Task { @MainActor in
            do {
                pending.fulfill(.success(try await operation()))
            } catch {
                pending.fulfill(.failure(error))
            }
        }
        return (task, pending)
    }

    // waitForTokenRequest()を上限時間つきで1回呼ぶ。
    // 待ち手が居ない実行中のflowへ呼ぶと待ち続けるので、直接awaitせず必ずこれを通す
    private func probeWait(_ flow: ChatGPTOAuthLoginFlow) async -> Result<ChatGPTOAuthTokenRequest, Error>? {
        let probe = launch { try await flow.waitForTokenRequest() }
        let result = await probe.pending.value()
        if result == nil {
            probe.task.cancel()
        }
        return result
    }

    // start()を上限時間つきで呼ぶ。gateを持たないfake listenerでも、awaitを無期限にしない
    private func startFlow(
        _ flow: ChatGPTOAuthLoginFlow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> URL {
        let starting = launch { try await flow.start() }
        let result = await starting.pending.value()
        if result == nil {
            starting.task.cancel()
        }
        return try successValue(result, file: file, line: line)
    }

    // @MainActorに積まれた処理（sinkから送られたcallbackの処理など）を先に走らせる。
    // Task.yield()は自分を後ろへ積み直すので、先に積まれた処理が実行される
    private func drainMainActor() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    // 条件が成り立つまで上限回数だけ待つ。成り立たなければ失敗にする（ハングさせない）
    private func eventually(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () async -> Bool
    ) async {
        for _ in 0..<500 {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("条件が成り立たなかった: \(message)", file: file, line: line)
    }

    // flowのエラーを確かめる。成功時にtoken requestの中身は出力しない
    private func assertFlowError<Value>(
        _ result: Result<Value, Error>?,
        _ expected: ChatGPTOAuthLoginFlowError,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case nil:
            XCTFail("上限時間内に完了しなかった: \(message)", file: file, line: line)
        case .success:
            XCTFail("成功してはいけない: \(message)", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error as? ChatGPTOAuthLoginFlowError, expected, message, file: file, line: line)
        }
    }

    private func successValue<Value>(
        _ result: Result<Value, Error>?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Value {
        switch result {
        case nil:
            XCTFail("上限時間内に完了しなかった", file: file, line: line)
            throw AsyncGate.GateError.timedOut
        case .success(let value):
            return value
        case .failure(let error):
            XCTFail("失敗してはいけない: \(String(describing: error as? ChatGPTOAuthLoginFlowError))", file: file, line: line)
            throw error
        }
    }

    private func makeFlow(
        listener: FakeListener,
        secretsCounter: Counter = Counter(),
        factoryCounter: Counter = Counter(),
        deadline: ChatGPTOAuthLoginFlow.DeadlineWaiter? = nil,
        responseBound: ChatGPTOAuthLoginFlow.ResponseCompletionWaiter? = nil,
        clock: MutableClock? = nil
    ) -> ChatGPTOAuthLoginFlow {
        let fixed = syntheticSecrets
        // 時計を渡さなければ、固定の開始時刻のまま進まない時計を使う
        let clock = clock ?? MutableClock(date: fixedDate, uptime: fixedUptime)
        return ChatGPTOAuthLoginFlow(
            agentHostID: syntheticHostID,
            lifetime: lifetime,
            makeSecrets: {
                secretsCounter.value += 1
                return fixed
            },
            makeListener: { expectedState, sink, failureHandler, responseCompletionHandler in
                factoryCounter.value += 1
                listener.configure(
                    expectedState: expectedState,
                    sink: sink,
                    failureHandler: failureHandler,
                    responseCompletionHandler: responseCompletionHandler
                )
                return listener
            },
            waitForDeadline: deadline ?? Self.neverReachedDeadline,
            // 上限待機の既定も「来ない待機」。上限で止まる経路は手動の待機を注入したテストだけで確かめる
            waitForResponseCompletion: responseBound ?? Self.neverReachedDeadline,
            now: { clock.date },
            uptime: { clock.uptime }
        )
    }

    // 値はすべてunreserved文字なので、percent-encodingなしでqueryに並べられる
    private func callbackURL(code: String) -> String {
        "\(syntheticRedirect)?code=\(code)&state=\(syntheticState)&client_id=\(syntheticClientID)"
    }

    // 既存の純粋なbuilderを独立に呼び、期待する認可URLとtoken requestを作る（flowを経由しない）
    private func expectedAuthorization() throws -> ChatGPTOAuthAuthorizationRequest {
        let fixed = syntheticSecrets
        return try ChatGPTOAuthAuthorizationRequestBuilder(makeSecrets: { fixed })
            .build(agentHostID: syntheticHostID, redirectURI: URL(string: syntheticRedirect)!)
    }

    private func expectedTokenRequest(code: String) throws -> ChatGPTOAuthTokenRequest {
        try ChatGPTOAuthTokenRequestBuilder.build(
            authorization: try expectedAuthorization(),
            callback: ChatGPTOAuthCallbackResult(code: code, clientID: syntheticClientID)
        )
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    // MARK: - 縦切り

    func testStartUsesSameStateAndBoundPortThenReturnsTokenRequestOnce() async throws {
        let listener = FakeListener(port: syntheticPort)
        let secretsCounter = Counter()
        let factoryCounter = Counter()
        let flow = makeFlow(listener: listener, secretsCounter: secretsCounter, factoryCounter: factoryCounter)

        // 1. 開始: listenerを1個だけ作って1回だけ開始し、乱数も1回だけ取得する
        let authorizationURL = try await startFlow(flow)
        XCTAssertEqual(secretsCounter.value, 1, "乱数の取得は1回だけ")
        XCTAssertEqual(factoryCounter.value, 1, "listenerは1個だけ作る")
        XCTAssertEqual(listener.startCount, 1, "listenerの開始は1回だけ")

        // 2. listenerが照合するstateと、認可URLに載せたstateが同じ合成値であること
        XCTAssertEqual(listener.expectedState, syntheticState)
        XCTAssertEqual(queryValue("state", in: authorizationURL), syntheticState)

        // 3. 認可URLのredirect_uriは、listenerが実際に報告したportで作られていること。
        //    URL全体も、同じ乱数・redirect URIで独立に組み立てた認可URLと一致すること
        XCTAssertEqual(queryValue("redirect_uri", in: authorizationURL), syntheticRedirect)
        XCTAssertEqual(authorizationURL.absoluteString, try expectedAuthorization().authorizationURL.absoluteString)

        // 4. callback → token request: 同じ試行のverifierとredirect URIで組み立てたrequestが返ること
        listener.deliver(callbackURL(code: syntheticCode))
        let request = try successValue(await probeWait(flow))
        let expected = try expectedTokenRequest(code: syntheticCode)
        XCTAssertEqual(request.url, expected.url)
        XCTAssertEqual(request.method, expected.method)
        XCTAssertEqual(request.headers, expected.headers)
        XCTAssertEqual(request.body, expected.body, "bodyが独立に組み立てたrequestと一致すること")

        // 5. 1回だけ: token requestを返した後はlistenerを止め、後続のcallbackから2個目のrequestを作らない
        XCTAssertEqual(listener.stopCount, 1, "token requestを返したらlistenerを止める")
        listener.deliver(callbackURL(code: otherCode))
        switch await probeWait(flow) {
        case nil:
            XCTFail("上限時間内に完了しなかった")
        case .success:
            XCTFail("2個目のtoken requestを返してはいけない")
        case .failure(let error):
            // flowのエラーであること。stubの未実装エラーのままでは合格させない
            let flowError = error as? ChatGPTOAuthLoginFlowError
            XCTAssertNotNil(flowError)
            XCTAssertNotEqual(flowError, .notImplemented)
        }
        XCTAssertEqual(factoryCounter.value, 1, "listenerを作り直さない")
        XCTAssertEqual(listener.startCount, 1, "listenerを再開始しない")
    }

    // MARK: - 期限

    func testDeadlineWhileWaitingExpiresStopsListenerAndRejectsLaterCallback() async throws {
        let listener = FakeListener(port: syntheticPort)
        let deadline = ManualDeadline()
        let flow = makeFlow(listener: listener, deadline: deadline.waiter)

        _ = try await startFlow(flow)
        let waiting = launch { try await flow.waitForTokenRequest() }
        await drainMainActor()
        XCTAssertNil(waiting.pending.result, "期限前は待ち続ける")
        XCTAssertEqual(deadline.requestedSeconds, [lifetime], "期限待機には有効期間をそのまま渡す")

        // テストから期限を進める
        deadline.fire()
        assertFlowError(await waiting.pending.value(), .expired, "期限が来たら期限切れで終わる")
        XCTAssertEqual(listener.stopCount, 1, "期限切れでlistenerを止める（結果は停止後に渡る）")

        // 期限後に正当な形のcallbackが届いても、token requestは作らない
        listener.deliver(callbackURL(code: syntheticCode))
        await drainMainActor()
        assertFlowError(await probeWait(flow), .alreadyFinished, "期限後のcallbackから結果を作らない")
        XCTAssertEqual(listener.stopCount, 1, "停止は1回だけ")
        XCTAssertFalse(deadline.gate.timedOut)
    }

    func testDeadlineBeforeWaitIsDeliveredOnceAsExpired() async throws {
        let listener = FakeListener(port: syntheticPort)
        let deadline = ManualDeadline()
        let flow = makeFlow(listener: listener, deadline: deadline.waiter)

        _ = try await startFlow(flow)
        deadline.fire()
        // 待ち手がいない間に期限切れが確定し、listenerの停止まで終わるのを待つ
        await eventually("期限切れでlistenerが止まる") { listener.stopCount == 1 }
        await drainMainActor()

        assertFlowError(await probeWait(flow), .expired, "未配送の期限切れを1回だけ渡す")
        assertFlowError(await probeWait(flow), .alreadyFinished, "2回目は渡さない")
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertFalse(deadline.gate.timedOut)
    }

    // MARK: - 開始中

    func testFlowCancelDuringStartAbortsWithoutURLAndStopsListener() async throws {
        let startGate = AsyncGate(honorsCancellation: false)
        let listener = FakeListener(port: syntheticPort, startGate: startGate)
        let flow = makeFlow(listener: listener)

        let starting = launch { try await flow.start() }
        await eventually("listenerの開始待ちに入る") { listener.startCount == 1 }

        // listenerの開始待ちの間に取り消し、その後でbindが完了したことにする
        flow.cancel()
        startGate.open()
        assertFlowError(await starting.pending.value(), .startAborted, "取消後は認可URLを返さない")
        XCTAssertEqual(listener.stopCount, 1, "開始済みのlistenerを止める")

        listener.deliver(callbackURL(code: syntheticCode))
        await drainMainActor()
        assertFlowError(await probeWait(flow), .alreadyFinished, "取消後のcallbackから結果を作らない")
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertFalse(startGate.timedOut)
    }

    func testTaskCancellationDuringStartAbortsWithoutURLAndStopsListener() async throws {
        let startGate = AsyncGate(honorsCancellation: false)
        let listener = FakeListener(port: syntheticPort, startGate: startGate)
        let flow = makeFlow(listener: listener)

        let starting = launch { try await flow.start() }
        await eventually("listenerの開始待ちに入る") { listener.startCount == 1 }

        // start()を呼んだTask自体を取り消す。listenerは取消を無視してbindを完了する
        starting.task.cancel()
        startGate.open()
        assertFlowError(await starting.pending.value(), .startAborted, "Taskの取消後は認可URLを返さない")
        XCTAssertEqual(listener.stopCount, 1, "開始済みのlistenerを止める")
        assertFlowError(await probeWait(flow), .alreadyFinished, "中止したflowは待てない")
        XCTAssertFalse(startGate.timedOut)
    }

    func testDelayedStartRejectsEarlyWaitAndSecondStartThenCompletes() async throws {
        let startGate = AsyncGate(honorsCancellation: false)
        let listener = FakeListener(port: syntheticPort, startGate: startGate)
        let factoryCounter = Counter()
        let flow = makeFlow(listener: listener, factoryCounter: factoryCounter)

        let starting = launch { try await flow.start() }
        await eventually("listenerの開始待ちに入る") { listener.startCount == 1 }

        // 開始が遅れている間の待機と二重startは拒否し、flowの状態を変えない
        assertFlowError(await probeWait(flow), .notStarted, "開始完了前の待機は拒否する")
        assertFlowError(await launch { try await flow.start() }.pending.value(), .alreadyStarted, "二重startは拒否する")
        XCTAssertEqual(factoryCounter.value, 1, "二重startでlistenerを作らない")
        XCTAssertEqual(listener.startCount, 1, "二重startでlistenerを開始しない")

        // 遅れていた開始が完了すれば、通常どおり進む
        startGate.open()
        let authorizationURL = try successValue(await starting.pending.value())
        XCTAssertEqual(queryValue("redirect_uri", in: authorizationURL), syntheticRedirect)

        listener.deliver(callbackURL(code: syntheticCode))
        let request = try successValue(await probeWait(flow))
        XCTAssertEqual(request.body, try expectedTokenRequest(code: syntheticCode).body)
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertFalse(startGate.timedOut)
    }

    func testCallbackDuringStartAbortsStartAndIsNotConsumed() async throws {
        let startGate = AsyncGate(honorsCancellation: false)
        let listener = FakeListener(port: syntheticPort, startGate: startGate)
        let flow = makeFlow(listener: listener)

        let starting = launch { try await flow.start() }
        await eventually("listenerの開始待ちに入る") { listener.startCount == 1 }

        // 認可URLを返す前に（stateが一致する）callbackが届く。想定外の順序なので開始を中止させる
        listener.deliver(callbackURL(code: syntheticCode))
        await eventually("開始中のcallbackでflowが終了状態になる") {
            // 開始中なら notStarted、終了状態なら alreadyFinished になる
            guard case .failure(let error) = await self.probeWait(flow) else { return false }
            return (error as? ChatGPTOAuthLoginFlowError) == .alreadyFinished
        }

        startGate.open()
        assertFlowError(await starting.pending.value(), .startAborted, "開始中のcallback後は認可URLを返さない")
        XCTAssertEqual(listener.stopCount, 1, "開始済みのlistenerを止める")
        assertFlowError(await probeWait(flow), .alreadyFinished, "開始中のcallbackからtoken requestを作らない")
        XCTAssertFalse(startGate.timedOut)
    }

    func testListenerStartErrorFailsClosedWithFixedErrorAndStopsListener() async throws {
        let listener = FakeListener(port: syntheticPort, failsToStart: true)
        let factoryCounter = Counter()
        let flow = makeFlow(listener: listener, factoryCounter: factoryCounter)

        // listenerのエラーはそのまま出さず、固定のエラーへ置き換える
        assertFlowError(await launch { try await flow.start() }.pending.value(), .startFailed)
        XCTAssertEqual(listener.stopCount, 1, "開始に失敗したlistenerも止める")

        // 失敗したflowは再利用しない
        assertFlowError(await probeWait(flow), .alreadyFinished)
        assertFlowError(await launch { try await flow.start() }.pending.value(), .alreadyStarted, "失敗後の再startは拒否する")
        XCTAssertEqual(factoryCounter.value, 1, "listenerを作り直さない")
        XCTAssertEqual(listener.startCount, 1, "listenerを再開始しない")
    }

    // MARK: - 待機中・停止後

    func testCancellingWaitingTaskCancelsFlowAndRejectsLaterCallback() async throws {
        let listener = FakeListener(port: syntheticPort)
        let flow = makeFlow(listener: listener)

        _ = try await startFlow(flow)
        let waiting = launch { try await flow.waitForTokenRequest() }
        await drainMainActor()
        assertFlowError(await probeWait(flow), .alreadyWaiting, "待ち手が登録済みであること")

        // 待っているTaskを取り消すと、flow全体が取り消される
        waiting.task.cancel()
        assertFlowError(await waiting.pending.value(), .cancelled)
        XCTAssertEqual(listener.stopCount, 1, "取消でlistenerを止める")

        listener.deliver(callbackURL(code: syntheticCode))
        await drainMainActor()
        assertFlowError(await probeWait(flow), .alreadyFinished, "停止後のcallbackから結果を作らない")
        XCTAssertEqual(listener.stopCount, 1)
    }

    func testFlowCancelWhileWaitingResumesWaiterOnceAndIsIdempotent() async throws {
        let listener = FakeListener(port: syntheticPort)
        let flow = makeFlow(listener: listener)

        _ = try await startFlow(flow)
        let waiting = launch { try await flow.waitForTokenRequest() }
        await drainMainActor()

        flow.cancel()
        assertFlowError(await waiting.pending.value(), .cancelled)
        XCTAssertEqual(listener.stopCount, 1)

        // 取消を繰り返しても、停止や結果は増えない
        flow.cancel()
        await drainMainActor()
        XCTAssertEqual(listener.stopCount, 1, "二重取消でlistenerを再停止しない")
        assertFlowError(await probeWait(flow), .alreadyFinished)
    }

    func testSecondConcurrentWaitIsRejectedWhileFirstReceivesResult() async throws {
        let listener = FakeListener(port: syntheticPort)
        let flow = makeFlow(listener: listener)

        _ = try await startFlow(flow)
        let first = launch { try await flow.waitForTokenRequest() }
        await drainMainActor()

        // 2つ目の待機は拒否し、1つ目の待機には影響しない
        assertFlowError(await probeWait(flow), .alreadyWaiting)
        XCTAssertNil(first.pending.result, "二重待機の拒否で1つ目の待機を終わらせない")
        XCTAssertEqual(listener.stopCount, 0)

        listener.deliver(callbackURL(code: syntheticCode))
        let request = try successValue(await first.pending.value())
        XCTAssertEqual(request.body, try expectedTokenRequest(code: syntheticCode).body)
        assertFlowError(await probeWait(flow), .alreadyFinished, "結果を渡した後は待てない")
        XCTAssertEqual(listener.stopCount, 1)
    }

    func testCallbackAndCancelDuringStopDoNotChangeFixedOutcome() async throws {
        let stopGate = AsyncGate(honorsCancellation: false)
        let listener = FakeListener(port: syntheticPort, stopGate: stopGate)
        let deadline = ManualDeadline()
        let flow = makeFlow(listener: listener, deadline: deadline.waiter)

        _ = try await startFlow(flow)
        let waiting = launch { try await flow.waitForTokenRequest() }
        await drainMainActor()

        // 期限切れで結果を確定させ、listenerの停止の途中で止めておく
        deadline.fire()
        await eventually("listenerの停止に入る") { listener.stopCount == 1 }
        XCTAssertNil(waiting.pending.result, "停止が終わるまで結果を渡さない")

        // 停止中に正当な形のcallbackと取消が届いても、確定した結果は変わらない
        listener.deliver(callbackURL(code: syntheticCode))
        flow.cancel()
        await drainMainActor()
        assertFlowError(await probeWait(flow), .alreadyWaiting, "停止中も待ち手は1つのまま")

        stopGate.open()
        assertFlowError(await waiting.pending.value(), .expired, "停止中のcallback・取消で結果を上書きしない")
        assertFlowError(await probeWait(flow), .alreadyFinished)
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertFalse(stopGate.timedOut)
        XCTAssertFalse(deadline.gate.timedOut)
    }

    // MARK: - 既知の欠陥（修正済みの回帰テスト）

    // 以下3件は静的レビューで見つかった欠陥（修正済み）を固定する回帰テスト。
    // 順序はMainActorのyield回数に頼らず、上限時間つきのgateで「到達した」ことを確かめてから進める

    // テストの前提（Taskが取消済みであること）が崩れたことを示す合成エラー
    private struct PreconditionNotMet: Error {}

    // (1) 成功結果が未配送として保存された後、取消済みTaskからのwaitForTokenRequest()はtoken requestを受け取らない
    func testUndeliveredSuccessIsNotReturnedToAlreadyCancelledTask() async throws {
        let listener = FakeListener(port: syntheticPort)
        let flow = makeFlow(listener: listener)
        let settled = AsyncGate(honorsCancellation: false)
        flow.didCompleteStopForTesting = { settled.open() }

        _ = try await startFlow(flow)
        // 待ち手が居ない間にcallbackが届き、listener停止後に成功結果が未配送として確定するまで待つ
        listener.deliver(callbackURL(code: syntheticCode))
        try? await settled.wait()
        XCTAssertFalse(settled.timedOut, "成功結果が未配送として確定するところまで到達すること")
        XCTAssertEqual(listener.stopCount, 1)

        // 呼び出す前に自分自身を取り消したTaskから受け取りに行く
        let cancelledWait = launch { () async throws -> ChatGPTOAuthTokenRequest in
            // withUnsafeCurrentTask: 実行中のTask自身への参照を得る。ここでは自分を取消済みにするだけに使う
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            guard Task.isCancelled else { throw PreconditionNotMet() }
            return try await flow.waitForTokenRequest()
        }
        assertFlowError(await cancelledWait.pending.value(), .cancelled, "取消済みTaskへtoken requestを渡さない")
        // 取消済みTaskが受け取れなかった結果を、後から別の呼び出しへ渡すこともしない（取消はflow全体の取消として扱う）
        assertFlowError(await probeWait(flow), .alreadyFinished, "取消後に結果を渡さない")
        XCTAssertEqual(listener.stopCount, 1)
    }

    // (2) 開始中（listenerのstart待ち）のflow.cancel()は、start完了を待たずにlistenerへstopを伝える
    func testFlowCancelDuringStartStopsListenerWithoutWaitingForStartCompletion() async throws {
        let startGate = AsyncGate(honorsCancellation: false)
        let startEntered = AsyncGate(honorsCancellation: false)
        // stopが届かない場合（回帰時）は、ここで上限時間まで待って打ち切られる
        let stopEntered = AsyncGate(timeout: .seconds(2), honorsCancellation: false)
        let listener = FakeListener(
            port: syntheticPort,
            startGate: startGate,
            startEntered: startEntered,
            stopEntered: stopEntered
        )
        let flow = makeFlow(listener: listener)

        let starting = launch { try await flow.start() }
        try? await startEntered.wait()
        XCTAssertFalse(startEntered.timedOut, "listenerの開始待ちに入ること")

        // bindが終わらない（startGateを開けない）まま取り消す
        flow.cancel()
        try? await stopEntered.wait()
        XCTAssertFalse(stopEntered.timedOut, "開始中の取消はstart完了を待たずにlistenerへstopを伝える")
        XCTAssertNil(starting.pending.result, "stopはstart完了より前に届いていること")

        // 後始末: bindを完了させても、認可URLは返さずに終わる
        startGate.open()
        assertFlowError(await starting.pending.value(), .startAborted, "取消後は認可URLを返さない")
        XCTAssertGreaterThanOrEqual(listener.stopCount, 1)
        assertFlowError(await probeWait(flow), .alreadyFinished)
        XCTAssertFalse(startGate.timedOut)
    }

    // (3) 本物のlistenerは開始Taskの取消でstart()自体が投げる。その場合も startFailed ではなく startAborted になる。
    //     既存の testTaskCancellationDuringStartAbortsWithoutURLAndStopsListener は取消を無視してportを返すfakeなので、この経路を通らない
    func testListenerStartThrowingOnTaskCancellationAbortsAsStartAborted() async throws {
        // 取消を尊重するgate: start()を呼んだTaskが取り消されるとCancellationErrorを投げる（本物のlistenerと同じ）
        let startGate = AsyncGate(honorsCancellation: true)
        let startEntered = AsyncGate(honorsCancellation: false)
        let listener = FakeListener(port: syntheticPort, startGate: startGate, startEntered: startEntered)
        let flow = makeFlow(listener: listener)

        let starting = launch { try await flow.start() }
        try? await startEntered.wait()
        XCTAssertFalse(startEntered.timedOut, "listenerの開始待ちに入ること")

        starting.task.cancel()
        assertFlowError(await starting.pending.value(), .startAborted, "開始Taskの取消はstartAbortedとして扱う")
        XCTAssertEqual(listener.stopCount, 1, "開始を中止したlistenerを止める")
        assertFlowError(await probeWait(flow), .alreadyFinished, "中止したflowは待てない")
        XCTAssertFalse(startGate.timedOut, "gateの打ち切りではなく取消でstartが終わること")
    }

    // MARK: - listener障害（回帰テスト）

    // fake listenerは、factoryから受け取ったfailureHandlerへ本物のlistenerと同じ .listenerFailed を送る。
    // 期待: 障害だけで（期限を進めずに）固定の listenerFailed として終わり、listenerを1回だけ止めて待機を終える。
    // 回帰して受け口が何もしなくなった場合、障害系の4件は上限時間つきのgateで打ち切られて失敗する。
    // 競合の2件（障害より先に結果が確定した場合）は保護テストで、障害が確定済みの結果を上書きしないことを固定する。
    // 回帰時に実行中のまま残るflowは、deferのcancel()で後始末する（結果が確定済みなら何もしない）

    func testListenerRuntimeFailureWhileWaitingFinishesAsListenerFailedWithoutDeadline() async throws {
        let stopEntered = AsyncGate(timeout: .seconds(2), honorsCancellation: false)
        let listener = FakeListener(port: syntheticPort, stopEntered: stopEntered)
        let deadline = ManualDeadline()
        let flow = makeFlow(listener: listener, deadline: deadline.waiter)
        defer { flow.cancel() }

        _ = try await startFlow(flow)
        let waiting = launch { try await flow.waitForTokenRequest() }
        await drainMainActor()
        XCTAssertNil(waiting.pending.result, "障害前は待ち続ける")
        XCTAssertEqual(listener.stopCount, 0)

        // 期限は進めず、障害だけを（重複して）届ける
        listener.simulateRuntimeFailure()
        listener.simulateRuntimeFailure()
        try? await stopEntered.wait()
        XCTAssertFalse(stopEntered.timedOut, "障害だけで期限を待たずにlistenerを止める")
        assertFlowError(await waiting.pending.value(), .listenerFailed, "障害は固定のlistenerFailedで待機を終える")
        await drainMainActor()
        XCTAssertEqual(listener.stopCount, 1, "重複した障害通知でも停止は1回だけ")

        // 障害後に正当な形のcallbackが届いても、token requestは作らない
        listener.deliver(callbackURL(code: syntheticCode))
        await drainMainActor()
        assertFlowError(await probeWait(flow), .alreadyFinished, "障害後のcallbackから結果を作らない")
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertEqual(deadline.requestedSeconds, [lifetime])
        XCTAssertFalse(deadline.gate.timedOut, "期限待機は打ち切りではなく取消で終わる")
    }

    func testListenerRuntimeFailureBeforeWaitIsDeliveredOnceAsListenerFailed() async throws {
        let listener = FakeListener(port: syntheticPort)
        let deadline = ManualDeadline()
        let flow = makeFlow(listener: listener, deadline: deadline.waiter)
        defer { flow.cancel() }
        let settled = AsyncGate(timeout: .seconds(2), honorsCancellation: false)
        flow.didCompleteStopForTesting = { settled.open() }

        _ = try await startFlow(flow)
        // 待ち手が居ない間に障害が届き、listener停止後に結果が未配送として確定するまで待つ
        listener.simulateRuntimeFailure()
        try? await settled.wait()
        XCTAssertFalse(settled.timedOut, "障害で結果が確定するところまで到達すること")
        XCTAssertEqual(listener.stopCount, 1, "障害でlistenerを止める")

        assertFlowError(await probeWait(flow), .listenerFailed, "未配送の障害を1回だけ渡す")
        assertFlowError(await probeWait(flow), .alreadyFinished, "2回目は渡さない")
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertFalse(deadline.gate.timedOut)
    }

    func testListenerRuntimeFailureDuringStartStopsListenerAndAbortsWithoutURL() async throws {
        let startGate = AsyncGate(honorsCancellation: false)
        let startEntered = AsyncGate(honorsCancellation: false)
        let stopEntered = AsyncGate(timeout: .seconds(2), honorsCancellation: false)
        let listener = FakeListener(
            port: syntheticPort,
            startGate: startGate,
            startEntered: startEntered,
            stopEntered: stopEntered
        )
        let flow = makeFlow(listener: listener)
        defer { flow.cancel() }

        let starting = launch { try await flow.start() }
        try? await startEntered.wait()
        XCTAssertFalse(startEntered.timedOut, "listenerの開始待ちに入ること")

        // bindが終わらない（startGateを開けない）まま障害が届く
        listener.simulateRuntimeFailure()
        try? await stopEntered.wait()
        XCTAssertFalse(stopEntered.timedOut, "開始中の障害はstart完了を待たずにlistenerへstopを伝える")
        XCTAssertNil(starting.pending.result, "stopはstart完了より前に届いていること")

        // bindを完了させても、認可URLは返さずに固定のエラーで終わる
        startGate.open()
        assertFlowError(await starting.pending.value(), .listenerFailed, "開始中の障害後は認可URLを返さない")
        XCTAssertEqual(listener.stopCount, 1, "停止は1回だけ")

        listener.deliver(callbackURL(code: syntheticCode))
        await drainMainActor()
        assertFlowError(await probeWait(flow), .alreadyFinished, "障害後のcallbackから結果を作らない")
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertFalse(startGate.timedOut)
    }

    func testListenerRuntimeFailureFixesOutcomeAgainstLaterCallbackAndCancelDuringStop() async throws {
        let stopGate = AsyncGate(honorsCancellation: false)
        let stopEntered = AsyncGate(timeout: .seconds(2), honorsCancellation: false)
        let listener = FakeListener(port: syntheticPort, stopGate: stopGate, stopEntered: stopEntered)
        let flow = makeFlow(listener: listener)
        defer { flow.cancel() }

        _ = try await startFlow(flow)
        let waiting = launch { try await flow.waitForTokenRequest() }
        await drainMainActor()

        // 障害で結果を確定させ、listenerの停止の途中で止めておく
        listener.simulateRuntimeFailure()
        try? await stopEntered.wait()
        XCTAssertFalse(stopEntered.timedOut, "障害でlistenerの停止に入る")
        XCTAssertNil(waiting.pending.result, "停止が終わるまで結果を渡さない")

        // 停止中に正当な形のcallbackと取消が届いても、確定した結果は変わらない
        listener.deliver(callbackURL(code: syntheticCode))
        flow.cancel()
        await drainMainActor()
        assertFlowError(await probeWait(flow), .alreadyWaiting, "停止中も待ち手は1つのまま")

        stopGate.open()
        assertFlowError(await waiting.pending.value(), .listenerFailed, "停止中のcallback・取消で障害の結果を上書きしない")
        assertFlowError(await probeWait(flow), .alreadyFinished)
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertFalse(stopGate.timedOut)
    }

    // 保護テスト: callbackで成功が確定した後（停止中・停止後）の障害は、成功結果を上書きしない
    func testListenerRuntimeFailureAfterCallbackDoesNotOverrideSuccess() async throws {
        let stopGate = AsyncGate(honorsCancellation: false)
        let stopEntered = AsyncGate(honorsCancellation: false)
        let listener = FakeListener(port: syntheticPort, stopGate: stopGate, stopEntered: stopEntered)
        let flow = makeFlow(listener: listener)
        defer { flow.cancel() }

        _ = try await startFlow(flow)
        let waiting = launch { try await flow.waitForTokenRequest() }
        await drainMainActor()

        listener.deliver(callbackURL(code: syntheticCode))
        try? await stopEntered.wait()
        XCTAssertFalse(stopEntered.timedOut, "callbackで成功が確定し、listenerの停止に入る")

        // 停止中の障害
        listener.simulateRuntimeFailure()
        await drainMainActor()
        XCTAssertNil(waiting.pending.result, "停止が終わるまで結果を渡さない")

        stopGate.open()
        let request = try successValue(await waiting.pending.value())
        XCTAssertEqual(request.body, try expectedTokenRequest(code: syntheticCode).body, "障害で成功結果を上書きしない")

        // 停止後の障害も何も変えない
        listener.simulateRuntimeFailure()
        await drainMainActor()
        assertFlowError(await probeWait(flow), .alreadyFinished)
        XCTAssertEqual(listener.stopCount, 1, "障害で再停止しない")
        XCTAssertFalse(stopGate.timedOut)
    }

    // 保護テスト: 取消で結果が確定した後（停止中）の障害は、取消の結果を上書きしない
    func testListenerRuntimeFailureAfterCancelDoesNotOverrideCancellation() async throws {
        let stopGate = AsyncGate(honorsCancellation: false)
        let stopEntered = AsyncGate(honorsCancellation: false)
        let listener = FakeListener(port: syntheticPort, stopGate: stopGate, stopEntered: stopEntered)
        let flow = makeFlow(listener: listener)

        _ = try await startFlow(flow)
        let waiting = launch { try await flow.waitForTokenRequest() }
        await drainMainActor()

        flow.cancel()
        try? await stopEntered.wait()
        XCTAssertFalse(stopEntered.timedOut, "取消でlistenerの停止に入る")

        listener.simulateRuntimeFailure()
        await drainMainActor()
        XCTAssertNil(waiting.pending.result, "停止が終わるまで結果を渡さない")

        stopGate.open()
        assertFlowError(await waiting.pending.value(), .cancelled, "障害で取消の結果を上書きしない")
        assertFlowError(await probeWait(flow), .alreadyFinished)
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertFalse(stopGate.timedOut)
    }

    // MARK: - HTTP応答の確定待ち（案B）

    // 正常callbackの後だけ、listenerがcallbackReceived応答を確定する（flush完了・失敗）まで停止を待つ。
    // 待ちは注入した上限待機で打ち切り、応答失敗・上限・取消・障害のどれでも速やかに1回だけ止める。
    // 結果の扱い: callbackの時点で試行は消費済みなので、応答失敗・上限・障害でもtoken requestを渡す。
    // 取消（flow.cancel()・待ち手のTaskの取消）だけは呼び出し側の明示的な中止として cancelled にし、token requestを渡さない。
    // 検証成功の後は、認可試行の期限・時計で結果を再判定しない。
    // 到達の確認はすべて上限つきのgate・eventuallyで行い、回帰時もハングさせない。
    // 残ったflowはdeferのcancel()で後始末する（結果が確定済みなら何もしない）

    // 正常callbackを処理し、応答確定を待っている状態のflow
    private struct HeldResponse {
        let listener: FakeListener
        let flow: ChatGPTOAuthLoginFlow
        let waiting: (task: Task<Void, Never>, pending: Pending<ChatGPTOAuthTokenRequest>)
        let responseBound: ManualDeadline
        // stopに入ったら開く。止まらない回帰では上限時間で打ち切られる
        let stopEntered: AsyncGate
    }

    // 待ち手を登録してから正当なcallbackを届け、応答確定の通知だけを保留した状態まで進める。
    // 「callbackを処理した」ことは、flowが上限待機を始めたことで確かめる
    private func holdResponseAfterValidCallback(
        deadline: ManualDeadline? = nil,
        clock: MutableClock? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> HeldResponse {
        let stopEntered = AsyncGate(timeout: .seconds(2), honorsCancellation: false)
        let listener = FakeListener(port: syntheticPort, stopEntered: stopEntered)
        let responseBound = ManualDeadline()
        let flow = makeFlow(
            listener: listener,
            deadline: deadline?.waiter,
            responseBound: responseBound.waiter,
            clock: clock
        )

        _ = try await startFlow(flow, file: file, line: line)
        let waiting = launch { try await flow.waitForTokenRequest() }
        await drainMainActor()

        listener.deliverWithoutResponseCompletion(callbackURL(code: syntheticCode))
        await eventually("正常callbackの処理後に応答確定の上限待機を始める", file: file, line: line) {
            responseBound.requestedSeconds.count == 1
        }
        await drainMainActor()
        XCTAssertEqual(
            responseBound.requestedSeconds, [ChatGPTOAuthLoginFlow.responseCompletionTimeout],
            "上限待機には固定の上限を1回だけ渡す", file: file, line: line
        )
        XCTAssertEqual(listener.stopCount, 0, "callback処理後でも応答確定の通知前はlistenerを止めない", file: file, line: line)
        XCTAssertNil(waiting.pending.result, "停止前はtoken requestを渡さない", file: file, line: line)
        return HeldResponse(
            listener: listener,
            flow: flow,
            waiting: waiting,
            responseBound: responseBound,
            stopEntered: stopEntered
        )
    }

    // 停止に入り、停止後に成功（token request）が渡ること。後から届いた通知・callback・障害では何も変わらないこと
    private func assertStopsOnceThenDeliversToken(
        _ held: HeldResponse,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try? await held.stopEntered.wait()
        XCTAssertFalse(held.stopEntered.timedOut, "listenerを止める: \(message)", file: file, line: line)
        let request = try successValue(await held.waiting.pending.value(), file: file, line: line)
        XCTAssertEqual(
            request.body, try expectedTokenRequest(code: syntheticCode).body,
            "停止後にtoken requestを渡す: \(message)", file: file, line: line
        )

        held.listener.completeResponse(.flushed)
        held.listener.completeResponse(.failed)
        held.listener.simulateRuntimeFailure()
        held.listener.deliver(callbackURL(code: otherCode))
        await drainMainActor()
        assertFlowError(await probeWait(held.flow), .alreadyFinished, "結果は1回だけ: \(message)", file: file, line: line)
        XCTAssertEqual(held.listener.stopCount, 1, "停止は1回だけ: \(message)", file: file, line: line)
    }

    func testValidCallbackWaitsForResponseFlushBeforeStoppingThenReturnsTokenRequest() async throws {
        let held = try await holdResponseAfterValidCallback()
        defer { held.flow.cancel() }

        held.listener.completeResponse(.flushed)
        try await assertStopsOnceThenDeliversToken(held, "応答のflush完了後")
        XCTAssertFalse(held.responseBound.gate.timedOut, "上限待機は打ち切りではなく取消で終わる")
    }

    func testResponseFailureWhileAwaitingResponseStopsPromptlyAndReturnsTokenRequest() async throws {
        let held = try await holdResponseAfterValidCallback()
        defer { held.flow.cancel() }

        // 上限は進めず、応答失敗だけを届ける
        held.listener.completeResponse(.failed)
        try await assertStopsOnceThenDeliversToken(held, "応答失敗の後")
        XCTAssertFalse(held.responseBound.gate.timedOut, "上限待機は打ち切りではなく取消で終わる")
    }

    func testResponseCompletionTimeoutStopsListenerAndReturnsTokenRequest() async throws {
        let held = try await holdResponseAfterValidCallback()
        defer { held.flow.cancel() }

        // 応答確定の通知が来ないまま、テストから上限を進める
        held.responseBound.fire()
        try await assertStopsOnceThenDeliversToken(held, "上限到来の後")
    }

    func testFlowCancelWhileAwaitingResponseStopsPromptlyAsCancelled() async throws {
        let held = try await holdResponseAfterValidCallback()
        defer { held.flow.cancel() }

        // 応答確定も上限も待たずに取り消す
        held.flow.cancel()
        try? await held.stopEntered.wait()
        XCTAssertFalse(held.stopEntered.timedOut, "応答確定を待たずにlistenerを止める")
        assertFlowError(await held.waiting.pending.value(), .cancelled, "取消ではtoken requestを渡さない")

        // 取消後に届いた応答確定では結果を作らない
        held.listener.completeResponse(.flushed)
        await drainMainActor()
        assertFlowError(await probeWait(held.flow), .alreadyFinished, "取消後に結果を渡さない")
        XCTAssertEqual(held.listener.stopCount, 1, "停止は1回だけ")
        XCTAssertFalse(held.responseBound.gate.timedOut, "上限待機は打ち切りではなく取消で終わる")
    }

    func testListenerFailureWhileAwaitingResponseStopsPromptlyAndKeepsSuccess() async throws {
        let held = try await holdResponseAfterValidCallback()
        defer { held.flow.cancel() }

        // 応答確定も上限も待たずに障害が届く。callbackで確定した成功は上書きしない
        held.listener.simulateRuntimeFailure()
        try await assertStopsOnceThenDeliversToken(held, "障害の後")
        XCTAssertFalse(held.responseBound.gate.timedOut, "上限待機は打ち切りではなく取消で終わる")
    }

    // 待ち手のTaskの取消も明示的な中止なので、応答待ち中でもtoken requestを破棄する
    func testCancellingWaitingTaskWhileAwaitingResponseDiscardsTokenRequest() async throws {
        let held = try await holdResponseAfterValidCallback()
        defer { held.flow.cancel() }

        held.waiting.task.cancel()
        try? await held.stopEntered.wait()
        XCTAssertFalse(held.stopEntered.timedOut, "応答確定を待たずにlistenerを止める")
        assertFlowError(await held.waiting.pending.value(), .cancelled, "取消されたTaskへtoken requestを渡さない")

        held.listener.completeResponse(.flushed)
        await drainMainActor()
        assertFlowError(await probeWait(held.flow), .alreadyFinished, "取消後に結果を渡さない")
        XCTAssertEqual(held.listener.stopCount, 1, "停止は1回だけ")
        XCTAssertFalse(held.responseBound.gate.timedOut, "上限待機は打ち切りではなく取消で終わる")
    }

    // 同じ@MainActorの区切りの中でcallback → 応答確定の順に届いても、listenerが出した順に処理する。
    // callbackを先に検証してから応答確定を受けるので、上限待機を1回始めた後にflush完了で止まる
    func testCallbackThenResponseCompletionInSameTurnAreHandledInEmissionOrder() async throws {
        let stopEntered = AsyncGate(timeout: .seconds(2), honorsCancellation: false)
        let listener = FakeListener(port: syntheticPort, stopEntered: stopEntered)
        let responseBound = ManualDeadline()
        let flow = makeFlow(listener: listener, responseBound: responseBound.waiter)
        defer { flow.cancel() }

        _ = try await startFlow(flow)
        let waiting = launch { try await flow.waitForTokenRequest() }
        await drainMainActor()

        // awaitを挟まずに続けて届ける
        listener.deliverWithoutResponseCompletion(callbackURL(code: syntheticCode))
        listener.completeResponse(.flushed)

        let held = HeldResponse(
            listener: listener,
            flow: flow,
            waiting: waiting,
            responseBound: responseBound,
            stopEntered: stopEntered
        )
        try await assertStopsOnceThenDeliversToken(held, "同じ区切りでcallback → flush完了")
        XCTAssertEqual(
            responseBound.requestedSeconds, [ChatGPTOAuthLoginFlow.responseCompletionTimeout],
            "callbackを先に処理して上限待機を始めている（通知先行として扱っていない）"
        )
        XCTAssertFalse(responseBound.gate.timedOut, "上限待機は打ち切りではなく取消で終わる")
    }

    // 通知先行: 応答確定がcallbackより先に届いたら、それだけでは止めず、検証成功の直後に上限待機なしで止める。
    // flush完了・失敗のどちらでも同じく検証済みのtoken requestを渡す
    func testResponseCompletionBeforeCallbackStopsRightAfterVerificationWithoutBound() async throws {
        for completion in [ChatGPTOAuthLoginFlow.ResponseCompletion.flushed, .failed] {
            let stopEntered = AsyncGate(timeout: .seconds(2), honorsCancellation: false)
            let listener = FakeListener(port: syntheticPort, stopEntered: stopEntered)
            let responseBound = ManualDeadline()
            let flow = makeFlow(listener: listener, responseBound: responseBound.waiter)
            defer { flow.cancel() }

            _ = try await startFlow(flow)
            let waiting = launch { try await flow.waitForTokenRequest() }
            await drainMainActor()

            // callbackより先に応答確定が（重複して）届く。検証済みの結果がないので止めない
            listener.completeResponse(completion)
            listener.completeResponse(completion)
            await drainMainActor()
            XCTAssertEqual(listener.stopCount, 0, "callback前の応答確定だけでは止めない: \(completion)")
            XCTAssertNil(waiting.pending.result, "callback前に結果を作らない: \(completion)")

            listener.deliverWithoutResponseCompletion(callbackURL(code: syntheticCode))
            let held = HeldResponse(
                listener: listener,
                flow: flow,
                waiting: waiting,
                responseBound: responseBound,
                stopEntered: stopEntered
            )
            try await assertStopsOnceThenDeliversToken(held, "通知先行: \(completion)")
            XCTAssertEqual(responseBound.requestedSeconds, [], "先行した応答確定があれば上限待機を始めない: \(completion)")
        }
    }

    // 応答待ちの間に認可試行の期限（壁時計・単調時計の両方）を過ぎ、期限待機も到来させる。
    // 結果は検証成功の時点で確定しているので、期限では止めず、結果を作り直さず、時計で再判定もしない
    func testAuthorizationDeadlineAndClockAfterVerifiedCallbackDoNotChangeOutcome() async throws {
        let deadline = ManualDeadline()
        let clock = MutableClock(date: fixedDate, uptime: fixedUptime)
        let held = try await holdResponseAfterValidCallback(deadline: deadline, clock: clock)
        defer { held.flow.cancel() }
        XCTAssertEqual(deadline.requestedSeconds, [lifetime], "期限待機は開始時の1回だけ")

        clock.advance(by: lifetime + 1)
        deadline.fire()
        await drainMainActor()
        XCTAssertEqual(held.listener.stopCount, 0, "応答待ち中の期限では止めない（停止は応答確定・上限・障害・取消で決める）")
        XCTAssertNil(held.waiting.pending.result, "期限で結果を作り直さない")
        assertFlowError(await probeWait(held.flow), .alreadyWaiting, "応答待ちのまま待ち手は1つ")

        held.listener.completeResponse(.flushed)
        try await assertStopsOnceThenDeliversToken(held, "期限・時計の経過後のflush完了")
        XCTAssertFalse(deadline.gate.timedOut, "期限待機は打ち切りではなく取消で終わる")
        XCTAssertFalse(held.responseBound.gate.timedOut, "上限待機は打ち切りではなく取消で終わる")
    }
}
