import Darwin
import XCTest
@testable import Melete

#if DEBUG
// ChatGPT OAuth初回登録flowを、本物のloopback listener（facade → SwiftNIO runtime）と127.0.0.1の実socketで結合して確かめる。
// flowのfactoryから本物のlistenerへ、callback・障害・応答確定の3つの受け口をそのまま渡す。
// 値はすべて合成の固定値で、実OpenAI・ブラウザ・Keychain・保存・UIには触れず、token requestも送信しない。
//
// 現状（RED）: listenerの応答確定（flush完了・失敗）の通知はstubで、受け口を受け取るだけで一度も呼ばない。
// flowの上限待機はテストが30秒の長い待機に差し替えているので、通知が配線されるまでflowはlistenerを止めず、
// 「flush完了後にlistenerが止まる」の確認が上限時間で失敗する。通知の実装は次工程。
//
// テストが漏れて残らないよう、次を守る:
// - 接続先は127.0.0.1だけ。テスト側socketのconnect・send・recvはすべて制限時間付きで、blocking I/Oは別スレッドで行い必ずcloseする
// - flowの開始・token待ち・listenerの停止・socketの結果待ちは、すべて上限時間付きでpollingする（無期限のawaitはしない）
// - flowの期限待機・応答確定の上限待機は、取消で必ず終わる上限付きのsleepにする
// - 各テストの最後（失敗時も）にflush gateを開け、flowを取り消し、listenerの停止を上限付きで待つ
@MainActor
final class ChatGPTOAuthLoginFlowLoopbackTests: XCTestCase {
    // MARK: - tests

    // 正常callbackを実socketで送ると、固定のcallbackReceived応答の全体が届いてから接続が閉じる。
    // flush完了の後にflowがlistenerを止め、停止が終わってからtoken requestを1回渡す。停止後のportは接続を拒否する
    func testValidCallbackGetsFullFixedResponseThenTokenAfterListenerStops() async throws {
        try await withFixture(holdsFlush: false) { fixture in
            let port = try await fixture.start()
            fixture.beginTokenWait()
            fixture.beginCallbackExchange(port: port)

            // 1. 固定HTTP応答の全体が届き、相手（listener）がFINで閉じた
            let outcome = await fixture.waitForExchange()
            XCTAssertEqual(outcome, .closed(try ChatGPTOAuthLoopbackResponseBuilder.response(for: .callbackReceived)),
                           "固定のcallbackReceived応答の全体を受け取ってから閉じられていない")

            // 2〜4. flush完了 → listener停止 → token、の順に進み、停止後のportは接続を拒否する
            try await assertStopsAfterFlushThenDeliversToken(fixture, port: port)
        }
    }

    // 応答のflushをDEBUG hookで止めている間は、flowがcallbackを検証済みでもlistenerを止めない。
    // flushを再開して完了した後にだけ止め、その後にtoken requestを渡す
    func testFlowKeepsListenerRunningUntilCallbackResponseFlushCompletes() async throws {
        try await withFixture(holdsFlush: true) { fixture in
            let port = try await fixture.start()
            fixture.beginTokenWait()
            fixture.beginCallbackExchange(port: port)

            // 1. listenerがcallbackReceived応答のflush直前で止まった
            guard await waitUntil(seconds: 2, { fixture.log.contains(.flushHeld) }) else {
                XCTFail("callbackReceived応答のflush直前まで進まなかった")
                return
            }
            // 2. flowがcallbackを検証し、応答確定待ち（上限待機の開始）に入った
            guard await waitUntil(seconds: 2, { fixture.log.contains(.responseBoundEntered) }) else {
                XCTFail("flowが応答確定待ちに入らなかった")
                return
            }

            // 3. flushを止めている間は、listenerを止めず、tokenも渡さず、client側にも応答は届かない。
            //    flush完了の通知はflushを再開するまで原理的に出せないので、この観測窓の長さには依存しない
            try? await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(fixture.log.count(of: .stopEntered), 0, "flush完了前にflowがlistenerを止めた")
            XCTAssertFalse(fixture.log.contains(.flushCompleted(true)), "flushを止めている間に応答が書かれた")
            XCTAssertNil(fixture.tokenResult, "flush完了前にtoken requestが渡された")
            XCTAssertNil(fixture.exchangeOutcome, "flushを止めている間にclient側の受信が終わった")

            // 4. flushを再開する
            fixture.flushGate.release()
            let outcome = await fixture.waitForExchange()
            XCTAssertEqual(outcome, .closed(try ChatGPTOAuthLoopbackResponseBuilder.response(for: .callbackReceived)),
                           "flush再開後に固定のcallbackReceived応答の全体が届いていない")

            // 5〜7. flush完了 → listener停止 → token、の順に進み、停止後のportは接続を拒否する
            try await assertStopsAfterFlushThenDeliversToken(fixture, port: port)
        }
    }

    // callbackがflowへ配送された後、接続期限でresponse write前に切断された場合は
    // flow側の30秒上限を待たずに.failedで終了する。先行する不正接続は失敗通知を発生させない。
    func testAcceptedCallbackConnectionDeadlineFailsPromptlyAndInvalidConnectionDoesNot() async throws {
        try await withFixture(holdsFlush: true) { fixture in
            let port = try await fixture.start()
            fixture.beginTokenWait()

            // 不正stateの接続はHTTPエラー応答だけで、flowの応答完了を偽装しない。
            let invalid = await LoopbackSocket.offThread {
                LoopbackSocket.exchange(port: port, request: Synthetic.invalidCallbackRequest(port: port))
            }
            XCTAssertEqual(invalid, .closed(try ChatGPTOAuthLoopbackResponseBuilder.response(for: .callbackFailed)))
            XCTAssertEqual(fixture.log.count(of: .stopEntered), 0, "他接続の失敗がflowを終了させた")
            XCTAssertNil(fixture.tokenResult, "他接続の失敗でtoken結果が確定した")

            fixture.beginCallbackExchange(port: port)
            guard await waitUntil(seconds: 3, { fixture.log.contains(.flushHeld) && fixture.log.contains(.responseBoundEntered) }) else {
                XCTFail("callback配送後、応答flush待ちに入らなかった")
                return
            }

            // NIO listenerの実connection deadlineは5秒。flow側waiterは30秒のままなので、
            // 期限切断による.failedが届けば期限待ちを進めずに停止する。
            guard await waitUntil(seconds: 7, { fixture.log.contains(.stopReturned) }) else {
                XCTFail("受理済み接続の期限切断で.failedが届かず、flowがlistenerを止めなかった")
                return
            }
            // socket自身のtimeoutではなく、listenerが期限切断した結果を読み取り、上限付きで確認する。
            // FIN/RST以外、応答データ付きのclose、read timeout、その他のエラーはすべて失敗。
            guard let outcome = await fixture.waitForExchange() else {
                XCTFail("受理済み接続の読み取り結果が上限時間内に届かなかった")
                return
            }
            switch outcome {
            case .closed(let data), .reset(let data):
                XCTAssertTrue(data.isEmpty, "期限切断前に余計な受信データが届いた")
            case .timedOut(let data):
                XCTFail("client自身の受信timeoutで終了した（受信済み: \(data.count) bytes）")
            case .tooLarge:
                XCTFail("期限切断前に上限を超える受信データが届いた")
            case .failed(let error):
                XCTFail("期限切断のclose/reset以外のsocket error: \(error)")
            }
            XCTAssertEqual(fixture.log.count(of: .stopEntered), 1, "flowのlistener停止回数が不正")
            guard await waitUntil(seconds: 2, { fixture.tokenResult != nil }) else {
                XCTFail("listener停止後、上限時間内にtoken requestの結果が渡されなかった")
                return
            }
            guard let tokenResult = fixture.tokenResult else {
                XCTFail("listener停止後にtoken requestの結果が渡されなかった")
                return
            }
            let request: ChatGPTOAuthTokenRequest
            switch tokenResult {
            case .success(let value):
                request = value
            case .failure:
                XCTFail("検証済みcallbackのtoken requestが成功しなかった")
                return
            }
            let expected = try Synthetic.expectedTokenRequest(port: port)
            XCTAssertEqual(request.url, expected.url)
            XCTAssertEqual(request.method, expected.method)
            XCTAssertEqual(request.headers, expected.headers)
            XCTAssertEqual(request.body, expected.body, "bodyが独立に組み立てたrequestと一致しない")
            let events = fixture.log.events
            if let stopped = events.firstIndex(of: .stopReturned),
               let delivered = events.firstIndex(of: .tokenDelivered) {
                XCTAssertLessThan(stopped, delivered, "listener停止完了前にtoken requestが渡された")
            } else {
                XCTFail("listener停止完了またはtoken request配送の記録がない")
            }
            XCTAssertEqual(fixture.log.count(of: .responseBoundEntered), 1)
        }
    }


    // MARK: - 共通の検証

    // flush完了の後にlistenerの停止が始まり、停止が終わってからtokenが渡ること。
    // tokenは独立に組み立てたrequestと一致し、停止後のportは接続を拒否すること
    private func assertStopsAfterFlushThenDeliversToken(
        _ fixture: Fixture,
        port: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let log = fixture.log
        guard await waitUntil(seconds: 2, { log.contains(.flushCompleted(true)) }) else {
            XCTFail("callbackReceived応答のflush完了を観測できなかった", file: file, line: line)
            return
        }
        // stubのままではここで失敗する（応答確定の通知がflowへ届かず、flowはlistenerを止めない）
        guard await waitUntil(seconds: 3, { log.contains(.stopReturned) }) else {
            XCTFail("flush完了後、上限時間内にflowがlistenerを止めなかった（応答確定の通知が届いた証拠がない）",
                    file: file, line: line)
            return
        }
        XCTAssertEqual(log.count(of: .stopEntered), 1, "listenerの停止はちょうど1回", file: file, line: line)
        XCTAssertEqual(log.count(of: .flushCompleted(true)), 1, "flush完了はちょうど1回", file: file, line: line)
        XCTAssertFalse(log.contains(.flushCompleted(false)), "応答のflushが失敗した", file: file, line: line)

        guard await waitUntil(seconds: 2, { fixture.tokenResult != nil }) else {
            XCTFail("listener停止後、上限時間内にtoken requestが渡されなかった", file: file, line: line)
            return
        }
        // 順序: flush完了 → 停止開始 → 停止完了 → token
        let order = log.events
        if let flushed = order.firstIndex(of: .flushCompleted(true)),
           let stopEntered = order.firstIndex(of: .stopEntered),
           let stopReturned = order.firstIndex(of: .stopReturned),
           let delivered = order.firstIndex(of: .tokenDelivered) {
            XCTAssertLessThan(flushed, stopEntered, "flush完了より前にlistenerの停止が始まった", file: file, line: line)
            XCTAssertLessThan(stopReturned, delivered, "listenerの停止完了より前にtokenが渡された", file: file, line: line)
        } else {
            XCTFail("順序の証拠（flush完了・停止開始・停止完了・token）が揃っていない", file: file, line: line)
        }

        let request: ChatGPTOAuthTokenRequest
        switch fixture.tokenResult {
        case .success(let value)?:
            request = value
        case .failure(let error)?:
            // 中身に秘密を含みうる値は出さず、flowの固定エラーだけを出す
            XCTFail("token requestではなく失敗が渡された: \(String(describing: error as? ChatGPTOAuthLoginFlowError))",
                    file: file, line: line)
            return
        case nil:
            XCTFail("token requestが渡されていない", file: file, line: line)
            return
        }
        let expected = try Synthetic.expectedTokenRequest(port: port)
        XCTAssertEqual(request.url, expected.url, file: file, line: line)
        XCTAssertEqual(request.method, expected.method, file: file, line: line)
        XCTAssertEqual(request.headers, expected.headers, file: file, line: line)
        XCTAssertEqual(request.body, expected.body, "bodyが独立に組み立てたrequestと一致しない", file: file, line: line)

        let refused = await LoopbackSocket.offThread { LoopbackSocket.connectAndClose(port: port) }
        XCTAssertEqual(refused, .notConnected(errno: ECONNREFUSED), "停止後のportが接続を拒否しなかった",
                       file: file, line: line)
    }

    // MARK: - fixture

    // fixtureを作って本体を走らせ、成功・失敗のどちらでも後始末してから戻る
    private func withFixture(holdsFlush: Bool, _ body: (Fixture) async throws -> Void) async throws {
        let fixture = Fixture(holdsFlush: holdsFlush)
        do {
            try await body(fixture)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    // 1テスト分のflow・本物のlistener・観測記録・socketの結果をまとめて持つ
    @MainActor
    private final class Fixture {
        let log = LoopbackEventLog()
        let flushGate: FlushGate
        private(set) var flow: ChatGPTOAuthLoginFlow?
        private(set) var facade: ChatGPTOAuthLoopbackListener?
        private(set) var recording: RecordingLoopbackListener?
        private(set) var factoryCount = 0
        private(set) var factoryExpectedState: String?
        private(set) var tokenResult: Result<ChatGPTOAuthTokenRequest, Error>?
        private var startResult: Result<URL, Error>?
        private var startTask: Task<Void, Never>?
        private var tokenTask: Task<Void, Never>?
        private let exchange = ExchangeBox()

        init(holdsFlush: Bool) {
            flushGate = FlushGate(log: log, holds: holdsFlush)
        }

        var exchangeOutcome: LoopbackSocket.ReadOutcome? { exchange.outcome }

        // flowを作って上限時間付きで開始し、listenerが実際にbindしたportを返す
        func start(file: StaticString = #filePath, line: UInt = #line) async throws -> Int {
            let flow = makeFlow()
            self.flow = flow
            startTask = Task { @MainActor [weak self] in
                do {
                    let url = try await flow.start()
                    self?.startResult = .success(url)
                } catch {
                    self?.startResult = .failure(error)
                }
            }
            guard await waitUntil(seconds: 5, { self.startResult != nil }) else {
                startTask?.cancel()
                XCTFail("flowのstart()が上限時間内に終わらなかった", file: file, line: line)
                throw FixtureError.timedOut
            }
            let authorizationURL: URL
            switch startResult {
            case .success(let url)?:
                authorizationURL = url
            default:
                XCTFail("flowのstart()が失敗した", file: file, line: line)
                throw FixtureError.startFailed
            }

            XCTAssertEqual(factoryCount, 1, "本物のlistenerは1個だけ作る", file: file, line: line)
            XCTAssertEqual(factoryExpectedState, Synthetic.state, "listenerへ合成stateが渡っていない", file: file, line: line)
            guard let port = recording?.boundPort, (1...65535).contains(port) else {
                XCTFail("本物のlistenerがbind済みportを返していない", file: file, line: line)
                throw FixtureError.startFailed
            }
            // 認可URLのredirect_uriは、本物のlistenerがbindした127.0.0.1のportで作られている
            let redirect = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "redirect_uri" })?.value
            XCTAssertEqual(redirect, "http://127.0.0.1:\(port)/auth/callback", file: file, line: line)
            return port
        }

        // waitForTokenRequest()を別Taskで待ち始める。結果が届いたらtokenDeliveredを記録する
        func beginTokenWait() {
            guard let flow else { return }
            tokenTask = Task { @MainActor [weak self, log] in
                let result: Result<ChatGPTOAuthTokenRequest, Error>
                do {
                    result = .success(try await flow.waitForTokenRequest())
                } catch {
                    result = .failure(error)
                }
                log.record(.tokenDelivered)
                self?.tokenResult = result
            }
        }

        // 別スレッドで1回だけ接続して合成callbackを送り、相手が閉じるまで読む
        func beginCallbackExchange(port: Int) {
            let request = Synthetic.callbackRequest(port: port)
            let exchange = exchange
            exchange.markStarted()
            DispatchQueue.global().async {
                exchange.set(LoopbackSocket.exchange(port: port, request: request))
            }
        }

        // socket側の制限時間（connect・send・recv・読み取り全体）より長い上限で、client側の結果を待つ
        func waitForExchange() async -> LoopbackSocket.ReadOutcome? {
            let exchange = exchange
            _ = await waitUntil(seconds: 10, { exchange.outcome != nil })
            return exchange.outcome
        }

        // flush gateを開け、flowを取り消し、listenerの停止とclient側の終了を上限時間付きで待つ
        func cleanUp() async {
            flushGate.release()
            flow?.cancel()
            startTask?.cancel()
            tokenTask?.cancel()
            if let facade {
                let stopped = LockedFlag()
                Task.detached {
                    await facade.stop()
                    stopped.set()
                }
                if !(await waitUntil(seconds: 5, { stopped.isSet })) {
                    XCTFail("後始末でlistenerの停止が上限時間内に終わらなかった")
                }
            }
            if exchange.started {
                let exchange = exchange
                if !(await waitUntil(seconds: 10, { exchange.outcome != nil })) {
                    XCTFail("後始末でclient側socketが上限時間内に終わらなかった")
                }
            }
            flow = nil
        }

        private func makeFlow() -> ChatGPTOAuthLoginFlow {
            let log = log
            let hook = flushGate.hook
            return ChatGPTOAuthLoginFlow(
                agentHostID: Synthetic.hostID,
                lifetime: Synthetic.lifetime,
                makeSecrets: { Synthetic.secrets },
                // flowから受け取った3つの受け口を、そのまま本物のlistener（facade）へ渡す
                makeListener: { [weak self] expectedState, sink, failureHandler, responseCompletionHandler in
                    let facade = ChatGPTOAuthLoopbackListener(
                        expectedState: expectedState,
                        callbackSink: sink,
                        failureHandler: failureHandler,
                        responseCompletionHandler: responseCompletionHandler
                    )
                    facade.setResponseFlushTestHook(hook)
                    let recording = RecordingLoopbackListener(inner: facade, log: log)
                    self?.factoryCount += 1
                    self?.factoryExpectedState = expectedState
                    self?.facade = facade
                    self?.recording = recording
                    return recording
                },
                // 期限は来させない。取消で必ず終わり、取消されなくても30秒で戻る上限付きの待機
                waitForDeadline: { _ in try await Task.sleep(for: .seconds(30)) },
                // 応答確定の上限待機に入ったことだけ記録する。テストの観測時間内には上限を来させない
                waitForResponseCompletion: { _ in
                    log.record(.responseBoundEntered)
                    try await Task.sleep(for: .seconds(30))
                },
                now: { Synthetic.fixedDate },
                uptime: { Synthetic.fixedUptime }
            )
        }
    }

    private enum FixtureError: Error {
        case timedOut
        case startFailed
    }
}

// MARK: - 上限付きの待ち合わせ

// 条件が成り立つまで、上限時間付きでpollingする。@MainActorを手放しながら待つ
@MainActor
private func waitUntil(seconds: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

// MARK: - 合成値

private enum Synthetic {
    // 実際の認証には使われない合成の固定値。それぞれ43文字のunreserved文字
    static let state = "SyntheticLoopState0123456789-_abcdefghijklm"
    static let nonce = "SyntheticLoopNonce0123456789-_nopqrstuvwxyz"
    static let verifier = "SyntheticLoopVerifier0123456789-._~abcdefgh"
    static let hostID = "urn:uuid:11111111-2222-4333-8444-666666666666"
    static let code = "SyntheticLoopCode0123456789"
    static let clientID = "synthetic_issued_client_loop_0123"
    static let lifetime: TimeInterval = 300
    // 固定の時刻・単調時計（実時刻は使わない）
    static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    static let fixedUptime: TimeInterval = 1_000

    static var secrets: ChatGPTOAuthAuthorizationSecrets {
        ChatGPTOAuthAuthorizationSecrets(state: state, nonce: nonce, codeVerifier: verifier)
    }

    // Hostはbind済みportに合わせた、listenerが受理する最小のrequest head。値はすべてunreserved文字
    static func callbackRequest(port: Int) -> Data {
        let path = "/auth/callback?code=\(code)&state=\(state)&client_id=\(clientID)"
        return Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8)
    }

    static func invalidCallbackRequest(port: Int) -> Data {
        let path = "/auth/callback?code=SyntheticInvalidCode&state=SyntheticInvalidState"
        return Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8)
    }

    // flowを経由せず、既存の純粋なbuilderで期待するtoken requestを組み立てる
    static func expectedTokenRequest(port: Int) throws -> ChatGPTOAuthTokenRequest {
        let fixed = secrets
        let authorization = try ChatGPTOAuthAuthorizationRequestBuilder(makeSecrets: { fixed })
            .build(agentHostID: hostID, redirectURI: URL(string: "http://127.0.0.1:\(port)/auth/callback")!)
        return try ChatGPTOAuthTokenRequestBuilder.build(
            authorization: authorization,
            callback: ChatGPTOAuthCallbackResult(code: code, clientID: clientID)
        )
    }
}

// MARK: - 観測用のhelper型

// listener・flow・テストの各スレッドから届く出来事を、届いた順に記録する
private final class LoopbackEventLog: @unchecked Sendable {
    enum Event: Equatable {
        // callbackReceived応答のflush直前でhookが止めた
        case flushHeld
        // テストがflushを再開した
        case flushReleased
        // callbackReceived応答のwriteAndFlushが完了した（成功したか）
        case flushCompleted(Bool)
        // flowが応答確定の上限待機に入った（callbackの検証に成功した）
        case responseBoundEntered
        // flowがlistenerのstop()を呼んだ・stop()が戻った
        case stopEntered
        case stopReturned
        // waitForTokenRequest()が結果を受け取った
        case tokenDelivered
    }

    private let lock = NSLock()
    private var stored: [Event] = []

    func record(_ event: Event) {
        lock.withLock { stored.append(event) }
    }

    var events: [Event] { lock.withLock { stored } }

    func contains(_ event: Event) -> Bool { lock.withLock { stored.contains(event) } }

    func count(of event: Event) -> Int { lock.withLock { stored.filter { $0 == event }.count } }
}

// callbackReceived応答のflushを止めて観測するgate。holds=falseならすぐ通し、flush完了だけを記録する
private final class FlushGate: @unchecked Sendable {
    private let log: LoopbackEventLog
    private let holds: Bool
    private let lock = NSLock()
    private var pendingRelease: (@Sendable () -> Void)?

    init(log: LoopbackEventLog, holds: Bool) {
        self.log = log
        self.holds = holds
    }

    var hook: ChatGPTOAuthNIOLoopbackListener.ResponseFlushTestHook {
        ChatGPTOAuthNIOLoopbackListener.ResponseFlushTestHook(
            // event loop上で呼ばれるので、記録してreleaseを預かるだけですぐ戻る
            willFlushCallbackReceived: { [self] release in
                guard holds else {
                    release()
                    return
                }
                lock.withLock { pendingRelease = release }
                log.record(.flushHeld)
            },
            didFlushCallbackReceived: { [log] succeeded in
                log.record(.flushCompleted(succeeded))
            }
        )
    }

    // 止めているflushを再開する。何度呼んでもよい（止めていなければ何もしない）
    func release() {
        let release = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { pendingRelease = nil }
            return pendingRelease
        }
        guard let release else { return }
        log.record(.flushReleased)
        release()
    }
}

// 本物のlistener（facade）を包み、bind済みportとstop()の出入りだけを記録する。それ以外はそのまま委譲する
private final class RecordingLoopbackListener: ChatGPTOAuthLoopbackListening, @unchecked Sendable {
    private let inner: ChatGPTOAuthLoopbackListener
    private let log: LoopbackEventLog
    private let lock = NSLock()
    private var port: Int?

    init(inner: ChatGPTOAuthLoopbackListener, log: LoopbackEventLog) {
        self.inner = inner
        self.log = log
    }

    var boundPort: Int? { lock.withLock { port } }

    func start() async throws -> Int {
        let bound = try await inner.start()
        lock.withLock { port = bound }
        return bound
    }

    func stop() async {
        log.record(.stopEntered)
        await inner.stop()
        log.record(.stopReturned)
    }
}

// client側socketの結果を、別スレッドからテストへ渡す
private final class ExchangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LoopbackSocket.ReadOutcome?
    private var wasStarted = false

    var outcome: LoopbackSocket.ReadOutcome? { lock.withLock { stored } }
    var started: Bool { lock.withLock { wasStarted } }

    func markStarted() {
        lock.withLock { wasStarted = true }
    }

    func set(_ outcome: LoopbackSocket.ReadOutcome) {
        lock.withLock { stored = outcome }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

// MARK: - テスト側socket（127.0.0.1限定・制限時間付き）

private enum LoopbackSocket {
    static let connectTimeoutMilliseconds: Int32 = 1000
    // listener側の接続期限（5秒）より長くし、client自身のrecv timeoutによる誤成功を防ぐ
    static let ioTimeoutSeconds = 8
    // 読み取り全体もlistener側の接続期限（5秒）より十分長くし、少しずつ届くデータも制限する
    static let readDeadlineSeconds = 9
    static let maxResponseBytes = 4096

    enum ConnectOutcome: Equatable {
        case connected(Int32)
        case notConnected(errno: Int32)
    }

    enum ReadOutcome: Equatable {
        // 相手が正常に閉じた（FIN）
        case closed(Data)
        // 相手がRSTで閉じた
        case reset(Data)
        // 制限時間内に閉じられなかった
        case timedOut(Data)
        // maxResponseBytesを超えた
        case tooLarge
        case failed(errno: Int32)
    }

    // blocking I/Oをテストの実行スレッドから外す。各I/Oはsocketの制限時間で必ず戻る
    static func offThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }

    // 1回だけ接続してrequestを送り、相手が閉じるまで読む。fdは必ずcloseする
    static func exchange(port: Int, request: Data) -> ReadOutcome {
        let fd: Int32
        switch connect(port: port) {
        case .connected(let connected):
            fd = connected
        case .notConnected(let connectErrno):
            return .failed(errno: connectErrno)
        }
        defer { Darwin.close(fd) }
        guard sendAll(fd, request) else {
            return .failed(errno: EPIPE)
        }
        return readUntilClose(fd)
    }

    // 127.0.0.1へだけnon-blockingでconnectし、pollで制限時間付きに待つ。
    // 接続後はblockingに戻し、send・recvの制限時間を設定する。接続できたfdの後始末は呼び出し側が行う
    static func connect(port: Int) -> ConnectOutcome {
        guard let port16 = UInt16(exactly: port), port16 != 0 else {
            return .notConnected(errno: EINVAL)
        }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return .notConnected(errno: errno) }

        // 相手が閉じた後のsendでSIGPIPEによりテストプロセスが落ちないようにする
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: ioTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        // portはネットワークバイトオーダー（big endian）で渡す
        socketAddress.sin_port = in_port_t(port16.bigEndian)
        guard inet_pton(AF_INET, "127.0.0.1", &socketAddress.sin_addr) == 1 else {
            Darwin.close(fd)
            return .notConnected(errno: EINVAL)
        }
        let result = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result != 0 {
            let connectErrno = errno
            guard connectErrno == EINPROGRESS else {
                Darwin.close(fd)
                return .notConnected(errno: connectErrno)
            }
            var pollTarget = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollTarget, 1, connectTimeoutMilliseconds) == 1 else {
                Darwin.close(fd)
                return .notConnected(errno: ETIMEDOUT)
            }
            // 書き込み可能になっても接続失敗のことがあるので、SO_ERRORで結果を確かめる
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
            guard socketError == 0 else {
                Darwin.close(fd)
                return .notConnected(errno: socketError)
            }
        }

        _ = fcntl(fd, F_SETFL, flags)
        return .connected(fd)
    }

    // 接続できてしまった場合もfdを閉じてから結果を返す（停止後の拒否確認用）
    static func connectAndClose(port: Int) -> ConnectOutcome {
        let outcome = connect(port: port)
        if case .connected(let fd) = outcome {
            Darwin.close(fd)
        }
        return outcome
    }

    // 全バイトを送れたらtrue。各sendはSO_SNDTIMEOで制限される
    static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBufferPointer { buffer in
                Darwin.send(fd, buffer.baseAddress! + sent, buffer.count - sent, 0)
            }
            if count > 0 {
                sent += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    // 相手が閉じるまで読む。各recvはSO_RCVTIMEOで、全体はreadDeadlineSecondsで制限される
    static func readUntilClose(_ fd: Int32) -> ReadOutcome {
        let deadline = ContinuousClock.now + .seconds(readDeadlineSeconds)
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while ContinuousClock.now < deadline {
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
                if collected.count > maxResponseBytes { return .tooLarge }
            } else if count == 0 {
                return .closed(collected)
            } else {
                let readErrno = errno
                switch readErrno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    return .timedOut(collected)
                case ECONNRESET:
                    return .reset(collected)
                default:
                    return .failed(errno: readErrno)
                }
            }
        }
        return .timedOut(collected)
    }
}
#endif
