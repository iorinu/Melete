import XCTest
@testable import Melete

// ChatGPT OAuth token exchangeのHTTP transportだけを検証する。
// 実endpoint・実credential・ネットワーク・Keychain・保存には触れない。
// 送信は独自スキームの合成endpointとtest専用URLProtocolだけで行い、本番URLはURLRequestの組み立てまでしか使わない。
// 値はすべてテスト専用の合成固定値。
final class ChatGPTOAuthTokenHTTPTransportTests: XCTestCase {
    // 合成の固定値（実際の認証には使われない）
    private let syntheticState = "SyntheticHTTPState0123456789-_abcdefghijklm"     // 43文字
    private let syntheticNonce = "SyntheticHTTPNonce0123456789-_nopqrstuvwxyz"     // 43文字
    private let syntheticVerifier = "SyntheticHTTPVerifier0123456789-._~abcdefgh"  // 43文字
    private let syntheticHostID = "urn:uuid:11111111-2222-4333-8444-555555555555"
    private let syntheticRedirect = "http://127.0.0.1:49152/auth/callback"
    private let syntheticCode = "SyntheticHTTPCode0123456789"
    private let syntheticClientID = "synthetic_issued_client_0123456789"
    // エラー文言に紛れ込んでいないかを確かめる目印（合成値）
    private let leakMarker = "melete-synthetic-leak-marker"

    private let officialTokenEndpoint = "https://auth.openai.com/api/accounts/oauth/token"

    override func setUp() {
        super.setUp()
        SyntheticTokenURLProtocol.controller.reset(script: .init())
    }

    // MARK: - test専用URLProtocol

    // 合成endpoint（melete-synthetic-oauth://token）だけに応答するtest専用URLProtocol。
    // canInitは全URLでtrueにして通常のHTTPスタックへ流さず、それ以外のURLは固定エラーで閉じる。
    private final class SyntheticTokenURLProtocol: URLProtocol {
        enum Behavior {
            // statusCode・headerFieldsの応答を返し、chunksを順に流す
            case respond
            // 指定statusでredirectを返す（Location先は合成endpoint以外）
            case redirect(statusCode: Int, location: String)
            // 応答を返さず通信失敗にする
            case fail
            // 何も返さない。取消・停止でしか終わらない
            case hang
            // テストがreleaseHeldResponseを呼ぶまで応答を保留し、その後は.respondと同じに振る舞う。
            // 解放されないまま上限時間が過ぎたら通信失敗で閉じる（テストが止まり続けないようにする）
            case respondAfterRelease
        }

        struct Script {
            var behavior: Behavior = .respond
            var statusCode = 200
            var headerFields: [String: String] = ["Content-Type": "application/json"]
            // nilなら要求URLをそのまま応答URLにする
            var responseURL: URL?
            var chunks: [Data] = []
            // falseなら最後のchunkの後も完了せず、取消・停止でしか終わらない
            var finishesAfterChunks = true
            // trueならchunkの後に通信失敗で終える
            var failsAfterChunks = false
        }

        struct Observed {
            let url: URL?
            let method: String?
            let headers: [String: String]
            let body: Data
        }

        // URLProtocolのthreadとテストの両方から触るため、すべてlockで守る
        final class Controller: @unchecked Sendable {
            private let lock = NSLock()
            private var script = Script()
            private var observed: [Observed] = []
            private var stops = 0
            private var finishes = 0
            private var nonTokenStarts = 0
            // .respondAfterRelease用。前のテストの解放が残らないよう、resetのたびに作り直す
            private var release = DispatchSemaphore(value: 0)

            func reset(script: Script) {
                lock.withLock {
                    self.script = script
                    observed = []
                    stops = 0
                    finishes = 0
                    nonTokenStarts = 0
                    release = DispatchSemaphore(value: 0)
                }
            }

            func releaseHeldResponse() {
                let release = lock.withLock { self.release }
                release.signal()
            }

            // URLProtocolのthreadで呼ぶ。待つ間はlockを持たない
            func waitForRelease(seconds: TimeInterval) -> Bool {
                let release = lock.withLock { self.release }
                return release.wait(timeout: .now() + seconds) == .success
            }

            func begin(_ observation: Observed) -> Script {
                lock.withLock {
                    observed.append(observation)
                    return script
                }
            }

            func recordNonTokenStart() { lock.withLock { nonTokenStarts += 1 } }
            func recordStop() { lock.withLock { stops += 1 } }
            func recordFinish() { lock.withLock { finishes += 1 } }

            var observedRequests: [Observed] { lock.withLock { observed } }
            var startCount: Int { lock.withLock { observed.count } }
            var stopCount: Int { lock.withLock { stops } }
            // urlProtocolDidFinishLoading（正常なHTTP完了）を送った回数
            var finishCount: Int { lock.withLock { finishes } }
            var nonTokenStartCount: Int { lock.withLock { nonTokenStarts } }
        }

        static let controller = Controller()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canInit(with task: URLSessionTask) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  url.scheme == ChatGPTOAuthTokenHTTPTransport.syntheticScheme,
                  url.host == "token" else {
                // 合成endpoint以外は応答を作らず固定エラーで閉じる。外部へは送らない
                Self.controller.recordNonTokenStart()
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let script = Self.controller.begin(Observed(
                url: url,
                method: request.httpMethod,
                headers: request.allHTTPHeaderFields ?? [:],
                body: Self.readBody(of: request)
            ))
            switch script.behavior {
            case .hang:
                return
            case .fail:
                let error = URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: "melete-synthetic-leak-marker"])
                client?.urlProtocol(self, didFailWithError: error)
                return
            case .redirect(let statusCode, let location):
                let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": location])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: location)!),
                                    redirectResponse: response)
                return
            case .respondAfterRelease:
                // client呼び出しをstartLoadingと同じthreadで行うため、ここで待ってから応答する
                guard Self.controller.waitForRelease(seconds: 5) else {
                    client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
                    return
                }
            case .respond:
                break
            }
            let response = HTTPURLResponse(url: script.responseURL ?? url, statusCode: script.statusCode,
                                           httpVersion: "HTTP/1.1", headerFields: script.headerFields)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in script.chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            if script.failsAfterChunks {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else if script.finishesAfterChunks {
                Self.controller.recordFinish()
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() {
            Self.controller.recordStop()
        }

        // URLSessionはhttpBodyをstreamへ移し替えることがあるので、両方から読む
        private static func readBody(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    // MARK: - fixture

    // 既存のauthorization/token request builderに合成値を渡して、本物の経路でrequestを作る
    private func makeTokenRequest() throws -> ChatGPTOAuthTokenRequest {
        let secrets = ChatGPTOAuthAuthorizationSecrets(
            state: syntheticState, nonce: syntheticNonce, codeVerifier: syntheticVerifier)
        let builder = ChatGPTOAuthAuthorizationRequestBuilder(makeSecrets: { secrets })
        let authorization = try builder.build(agentHostID: syntheticHostID,
                                              redirectURI: URL(string: syntheticRedirect)!)
        let callback = ChatGPTOAuthCallbackResult(code: syntheticCode, clientID: syntheticClientID)
        return try ChatGPTOAuthTokenRequestBuilder.build(authorization: authorization, callback: callback)
    }

    // 指定した項目だけ差し替えた（builderの出力ではない）requestを、DEBUG限定の偽造factoryで明示的に作る
    private func tampered(
        _ original: ChatGPTOAuthTokenRequest,
        url: URL? = nil,
        method: String? = nil,
        headers: [String: String]? = nil,
        body: Data? = nil
    ) -> ChatGPTOAuthTokenRequest {
        ChatGPTOAuthTokenRequest.forgedForTesting(url: url ?? original.url, method: method ?? original.method,
                                                  headers: headers ?? original.headers, body: body ?? original.body)
    }

    // 応答しない相手でもテストが止まらないよう、testing deadlineは常に短く指定する
    // urlLoadingTimeoutはnilならdeadlineと同じ（productionと同じ関係）。
    // 監視taskの期限処理だけを検証するときは、URL層のtimeoutが先に発火しないよう長くする
    private func makeTransport(
        deadline: TimeInterval = 3,
        urlLoadingTimeout: TimeInterval? = nil,
        testingHooks: ChatGPTOAuthTokenHTTPTransport.TestingHooks? = nil
    ) throws -> ChatGPTOAuthTokenHTTPTransport {
        try ChatGPTOAuthTokenHTTPTransport(
            testingSyntheticEndpoint: ChatGPTOAuthTokenHTTPTransport.syntheticEndpoint,
            protocolClasses: [SyntheticTokenURLProtocol.self],
            deadlineForTesting: deadline,
            urlLoadingTimeoutForTesting: urlLoadingTimeout,
            testingHooks: testingHooks)
    }

    // deadline監視taskと交換の終了の順序を記録する。hookは別taskから呼ばれるのでlockで守る
    private final class DeadlineRaceProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var monitorElapsed = 0
        private var exchangeFinished = 0
        private var finishedBeforeMonitorResumed = false
        private var summary: ChatGPTOAuthTokenHTTPTransport.TestingExchangeSummary?

        func recordMonitorElapsed() { lock.withLock { monitorElapsed += 1 } }
        func recordExchangeFinished(_ summary: ChatGPTOAuthTokenHTTPTransport.TestingExchangeSummary) {
            lock.withLock {
                exchangeFinished += 1
                self.summary = summary
            }
        }
        func recordFinishedBeforeMonitorResumed() { lock.withLock { finishedBeforeMonitorResumed = true } }

        var monitorElapsedCount: Int { lock.withLock { monitorElapsed } }
        var exchangeFinishedCount: Int { lock.withLock { exchangeFinished } }
        var exchangeFinishedBeforeMonitorResumed: Bool { lock.withLock { finishedBeforeMonitorResumed } }
        // 交換の終了時点でのURLSession側の終わり方
        var exchangeSummary: ChatGPTOAuthTokenHTTPTransport.TestingExchangeSummary? { lock.withLock { summary } }

        // 順序はhookで決まる。時間制限は、実装が壊れていたときにテストを止めないための保険
        func waitUntilExchangeFinished(seconds: TimeInterval) async -> Bool {
            let limit = Date().addingTimeInterval(seconds)
            while Date() < limit {
                if exchangeFinishedCount > 0 { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return exchangeFinishedCount > 0
        }
    }

    private func syntheticTokenJSON() -> Data {
        Data(#"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","id_token":"synthetic.id.token","token_type":"Bearer","expires_in":3600,"scope":"openid chatgpt.tokens.use.direct"}"#.utf8)
    }

    private func assertSendFails(
        _ request: ChatGPTOAuthTokenRequest,
        as expected: ChatGPTOAuthTokenHTTPTransportError,
        _ label: String,
        deadline: TimeInterval = 3,
        // nilならdeadlineから作る。hook付きなど独自のtransportを使うときだけ渡す
        transport: ChatGPTOAuthTokenHTTPTransport? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let transport = try transport ?? makeTransport(deadline: deadline)
            _ = try await transport.send(request)
            XCTFail("\(label): 成功してしまった", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ChatGPTOAuthTokenHTTPTransportError, expected, label, file: file, line: line)
        }
    }

    private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let limit = Date().addingTimeInterval(seconds)
        while Date() < limit {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    // MARK: - URLRequestの組み立て（URLSessionは使わない）

    func testProductionURLRequestTargetsFixedOfficialEndpoint() throws {
        let request = try makeTokenRequest()

        let urlRequest = try ChatGPTOAuthTokenHTTPTransport.makeProductionURLRequest(for: request)

        XCTAssertEqual(urlRequest.url?.absoluteString, officialTokenEndpoint)
        XCTAssertEqual(ChatGPTOAuthTokenHTTPTransport.productionTokenEndpoint.absoluteString, officialTokenEndpoint)
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(urlRequest.httpShouldHandleCookies)
        XCTAssertEqual(urlRequest.httpBody, request.body)
    }

    func testRejectsRequestsThatAreNotTokenRequestBuilderOutput() async throws {
        let valid = try makeTokenRequest()
        let cases: [(String, ChatGPTOAuthTokenRequest)] = [
            ("別host", tampered(valid, url: URL(string: "https://example.invalid/api/accounts/oauth/token")!)),
            ("http", tampered(valid, url: URL(string: "http://auth.openai.com/api/accounts/oauth/token")!)),
            ("query付き", tampered(valid, url: URL(string: officialTokenEndpoint + "?x=1")!)),
            ("末尾スラッシュ", tampered(valid, url: URL(string: officialTokenEndpoint + "/")!)),
            ("userinfo付き", tampered(valid, url: URL(string: "https://user@auth.openai.com/api/accounts/oauth/token")!)),
            ("合成endpointを直接指定", tampered(valid, url: ChatGPTOAuthTokenHTTPTransport.syntheticEndpoint)),
            ("GET", tampered(valid, method: "GET")),
            ("小文字post", tampered(valid, method: "post")),
            ("Authorization追加", tampered(valid, headers: [
                "Content-Type": "application/x-www-form-urlencoded", "Authorization": "Basic \(leakMarker)"])),
            ("Content-Type違い", tampered(valid, headers: ["Content-Type": "application/json"])),
            ("headerなし", tampered(valid, headers: [:])),
            ("空body", tampered(valid, body: Data())),
            ("改行入りbody", tampered(valid, body: Data("grant_type=authorization_code\r\nX: y".utf8))),
            ("非ASCII body", tampered(valid, body: Data("grant_type=é".utf8))),
            ("過大body", tampered(valid, body: Data(repeating: 0x61,
                                                    count: ChatGPTOAuthTokenHTTPTransport.maxRequestBodyLength + 1))),
        ]
        for (label, request) in cases {
            XCTAssertThrowsError(try ChatGPTOAuthTokenHTTPTransport.makeProductionURLRequest(for: request), label) { error in
                XCTAssertEqual(error as? ChatGPTOAuthTokenHTTPTransportError, .invalidRequest, label)
            }
            await assertSendFails(request, as: .invalidRequest, label)
        }
        // 検証で拒否したrequestは1件も送らない
        XCTAssertEqual(SyntheticTokenURLProtocol.controller.startCount, 0)
        XCTAssertEqual(SyntheticTokenURLProtocol.controller.nonTokenStartCount, 0)
    }

    // MARK: - test-only初期化

    func testTestingInitializerAcceptsOnlySyntheticEndpointAndProtocolClasses() {
        let endpoints = [
            URL(string: officialTokenEndpoint)!,
            URL(string: "melete-synthetic-oauth://other")!,
            URL(string: "melete-synthetic://responses")!,
            URL(string: "http://127.0.0.1:1/token")!,
        ]
        for endpoint in endpoints {
            XCTAssertThrowsError(try ChatGPTOAuthTokenHTTPTransport(
                testingSyntheticEndpoint: endpoint, protocolClasses: [SyntheticTokenURLProtocol.self])) { error in
                XCTAssertEqual(error as? ChatGPTOAuthTokenHTTPTransportError, .invalidTestingConfiguration)
            }
        }
        // test専用URLProtocolなしでは初期化させない（既定のHTTPスタックへ流さない）
        XCTAssertThrowsError(try ChatGPTOAuthTokenHTTPTransport(
            testingSyntheticEndpoint: ChatGPTOAuthTokenHTTPTransport.syntheticEndpoint, protocolClasses: [])) { error in
            XCTAssertEqual(error as? ChatGPTOAuthTokenHTTPTransportError, .invalidTestingConfiguration)
        }
        // deadlineは0より大きく本番値以下の有限値だけ
        let deadlines: [TimeInterval] = [0, -1, .nan, .infinity,
                                         ChatGPTOAuthTokenHTTPTransport.productionDeadline + 1]
        for deadline in deadlines {
            XCTAssertThrowsError(try ChatGPTOAuthTokenHTTPTransport(
                testingSyntheticEndpoint: ChatGPTOAuthTokenHTTPTransport.syntheticEndpoint,
                protocolClasses: [SyntheticTokenURLProtocol.self],
                deadlineForTesting: deadline), "\(deadline)") { error in
                XCTAssertEqual(error as? ChatGPTOAuthTokenHTTPTransportError, .invalidTestingConfiguration)
            }
        }
        // URL層のtimeoutはdeadline以上・本番値以下の有限値だけ（deadline=1のとき）
        let urlTimeouts: [TimeInterval] = [0.5, 0, -1, .nan, .infinity,
                                           ChatGPTOAuthTokenHTTPTransport.productionDeadline + 1]
        for timeout in urlTimeouts {
            XCTAssertThrowsError(try ChatGPTOAuthTokenHTTPTransport(
                testingSyntheticEndpoint: ChatGPTOAuthTokenHTTPTransport.syntheticEndpoint,
                protocolClasses: [SyntheticTokenURLProtocol.self],
                deadlineForTesting: 1, urlLoadingTimeoutForTesting: timeout), "\(timeout)") { error in
                XCTAssertEqual(error as? ChatGPTOAuthTokenHTTPTransportError, .invalidTestingConfiguration)
            }
        }
        XCTAssertNoThrow(try ChatGPTOAuthTokenHTTPTransport(
            testingSyntheticEndpoint: ChatGPTOAuthTokenHTTPTransport.syntheticEndpoint,
            protocolClasses: [SyntheticTokenURLProtocol.self],
            deadlineForTesting: 1, urlLoadingTimeoutForTesting: 1))
    }

    // MARK: - 成功

    func testSendsBuilderRequestOnceAndReturnsUnverifiedBody() async throws {
        let request = try makeTokenRequest()
        let json = syntheticTokenJSON()
        // 分割して届いても1つのbodyに連結されることを確かめる
        SyntheticTokenURLProtocol.controller.reset(script: .init(
            headerFields: ["Content-Type": "Application/JSON; charset=UTF-8"],
            chunks: [json.prefix(10), json.dropFirst(10)].map { Data($0) }))

        let response = try await makeTransport().send(request)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, json)
        let observed = SyntheticTokenURLProtocol.controller.observedRequests
        XCTAssertEqual(observed.count, 1, "1回の認可試行で送るのは1回だけ")
        XCTAssertEqual(observed.first?.url, ChatGPTOAuthTokenHTTPTransport.syntheticEndpoint)
        XCTAssertEqual(observed.first?.method, "POST")
        XCTAssertEqual(observed.first?.body, request.body, "builderのbodyを加工せずに送る")
        let headers = Dictionary(uniqueKeysWithValues: (observed.first?.headers ?? [:]).map { ($0.key.lowercased(), $0.value) })
        XCTAssertEqual(headers["content-type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(headers["accept"], "application/json")
        XCTAssertEqual(headers["accept-encoding"], "identity")
        XCTAssertNil(headers["authorization"])
        XCTAssertNil(headers["cookie"])
        XCTAssertEqual(SyntheticTokenURLProtocol.controller.nonTokenStartCount, 0)
    }

    // transportの成功は「HTTPで受け取れた」だけで、認証済みではない。
    // ID token検証に失敗すれば、parserはcandidateを作らない
    func testSuccessfulTransportIsNotTreatedAsAuthenticated() async throws {
        SyntheticTokenURLProtocol.controller.reset(script: .init(chunks: [syntheticTokenJSON()]))
        let response = try await makeTransport().send(try makeTokenRequest())

        struct SyntheticRejection: Error {}
        XCTAssertThrowsError(try ChatGPTOAuthTokenResponseParser.parseUsingSyntheticIDTokenVerifierForTesting(
            statusCode: response.statusCode, body: response.body,
            expectedClientID: syntheticClientID, expectedNonce: syntheticNonce,
            jwks: Data("{}".utf8), now: Date(timeIntervalSince1970: 1_700_000_000),
            verifyIDToken: { _, _, _, _, _ in throw SyntheticRejection() })) { error in
            XCTAssertEqual(error as? ChatGPTOAuthTokenResponseError, .idTokenRejected)
        }
    }

    func testBodyExactlyAtLimitIsAccepted() async throws {
        let limit = ChatGPTOAuthTokenHTTPTransport.maxResponseBodyLength
        XCTAssertEqual(limit, ChatGPTOAuthTokenResponseParser.maxBodyLength, "parserの上限と揃える")
        SyntheticTokenURLProtocol.controller.reset(script: .init(
            chunks: [Data(repeating: 0x20, count: limit - 1), Data([0x20])]))

        let response = try await makeTransport().send(try makeTokenRequest())

        XCTAssertEqual(response.body.count, limit)
    }

    // MARK: - 応答サイズ上限（受信時に強制）

    // 完了しない相手でも、上限を超えた時点で失敗し、URLProtocolを止めてから戻る
    func testBodyExceedingLimitFailsDuringReceiptAndStopsProtocol() async throws {
        let limit = ChatGPTOAuthTokenHTTPTransport.maxResponseBodyLength
        SyntheticTokenURLProtocol.controller.reset(script: .init(
            chunks: [Data(repeating: 0x20, count: limit), Data([0x20])],
            finishesAfterChunks: false))
        let started = Date()

        await assertSendFails(try makeTokenRequest(), as: .responseTooLarge, "上限+1バイト", deadline: 5)

        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "deadlineではなく上限超過で止まること")
        XCTAssertEqual(SyntheticTokenURLProtocol.controller.stopCount, 1, "URLProtocolを止めずに戻った")
    }

    func testDeclaredContentLengthOverLimitIsRejectedBeforeBody() async throws {
        let limit = ChatGPTOAuthTokenHTTPTransport.maxResponseBodyLength
        SyntheticTokenURLProtocol.controller.reset(script: .init(
            headerFields: ["Content-Type": "application/json", "Content-Length": "\(limit + 1)"],
            finishesAfterChunks: false))

        await assertSendFails(try makeTokenRequest(), as: .responseTooLarge, "Content-Length超過", deadline: 5)

        XCTAssertEqual(SyntheticTokenURLProtocol.controller.stopCount, 1)
    }

    // MARK: - redirect

    func testRedirectsAreRejectedAndNeverFollowed() async throws {
        let request = try makeTokenRequest()
        for status in [301, 302, 303, 307, 308] {
            SyntheticTokenURLProtocol.controller.reset(script: .init(
                behavior: .redirect(statusCode: status, location: "melete-synthetic-oauth://redirected/token")))

            await assertSendFails(request, as: .redirectRejected, "\(status)")

            XCTAssertEqual(SyntheticTokenURLProtocol.controller.startCount, 1, "\(status)")
            XCTAssertEqual(SyntheticTokenURLProtocol.controller.nonTokenStartCount, 0, "\(status): redirect先へ送った")
        }
    }

    // MARK: - HTTPエラー・応答形式

    func testNonSuccessStatusIsRejectedWithoutExposingBody() async throws {
        let request = try makeTokenRequest()
        let errorBody = Data(#"{"error":"invalid_grant","error_description":"melete-synthetic-leak-marker"}"#.utf8)
        for status in [201, 204, 400, 401, 403, 404, 429, 500, 503] {
            SyntheticTokenURLProtocol.controller.reset(script: .init(statusCode: status, chunks: [errorBody]))

            await assertSendFails(request, as: .unexpectedStatus, "\(status)")
        }
    }

    func testUnexpectedResponseFormatIsRejected() async throws {
        let request = try makeTokenRequest()
        let json = syntheticTokenJSON()
        let scripts: [(String, SyntheticTokenURLProtocol.Script)] = [
            ("Content-Typeなし", .init(headerFields: [:], chunks: [json])),
            ("text/html", .init(headerFields: ["Content-Type": "text/html"], chunks: [json])),
            ("application/jsonx", .init(headerFields: ["Content-Type": "application/jsonx"], chunks: [json])),
            ("gzip", .init(headerFields: ["Content-Type": "application/json", "Content-Encoding": "gzip"],
                           chunks: [json])),
            ("応答URL違い", .init(responseURL: URL(string: "melete-synthetic-oauth://other/token")!, chunks: [json])),
        ]
        for (label, script) in scripts {
            SyntheticTokenURLProtocol.controller.reset(script: script)

            await assertSendFails(request, as: .invalidResponse, label)
        }
    }

    func testTransportFailureIsMappedToFixedError() async throws {
        let request = try makeTokenRequest()
        SyntheticTokenURLProtocol.controller.reset(script: .init(behavior: .fail))
        await assertSendFails(request, as: .transportFailed, "接続失敗")

        // 応答ヘッダーの後、本文の途中で切れた場合も途中までのbodyは返さない
        SyntheticTokenURLProtocol.controller.reset(script: .init(
            chunks: [Data(#"{"access_token":"#.utf8)], failsAfterChunks: true))
        await assertSendFails(request, as: .transportFailed, "本文途中で切断")
    }

    // MARK: - タイムアウト・取消

    func testHangingServerTimesOutAndStopsProtocol() async throws {
        SyntheticTokenURLProtocol.controller.reset(script: .init(behavior: .hang))
        let started = Date()

        await assertSendFails(try makeTokenRequest(), as: .timedOut, "応答なし", deadline: 0.3)

        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(SyntheticTokenURLProtocol.controller.stopCount, 1, "URLProtocolを止めずに戻った")
    }

    // 本文が途中で止まった場合もdeadlineは効く（応答ヘッダーだけでなく交換全体に掛かる）
    func testStalledBodyTimesOut() async throws {
        SyntheticTokenURLProtocol.controller.reset(script: .init(
            chunks: [Data(#"{"access_token":"#.utf8)], finishesAfterChunks: false))

        await assertSendFails(try makeTokenRequest(), as: .timedOut, "本文停止", deadline: 0.3)

        XCTAssertEqual(SyntheticTokenURLProtocol.controller.stopCount, 1)
    }

    // 競合: 期限は過ぎたが、監視taskがdeadlineReachedを呼ぶより先に成功応答が完了・無効化まで進む。
    // hookで監視taskを止め、その間に応答を流して交換の終了を待ってから監視を再開させる（時間の偶然に頼らない）。
    // URL層のtimeout（URLRequest/URLSession）は監視deadlineより十分長くし、URLError(.timedOut)が
    // 先に発火して別経路でtimedOutになる偽のPASSを防ぐ。
    // 期限後に届いた成功は、監視の処理順にかかわらずtimedOutにする
    func testSuccessCompletedAfterDeadlineBeforeMonitorRunsIsTimedOut() async throws {
        SyntheticTokenURLProtocol.controller.reset(script: .init(
            behavior: .respondAfterRelease, chunks: [syntheticTokenJSON()]))
        let probe = DeadlineRaceProbe()
        let hooks = ChatGPTOAuthTokenHTTPTransport.TestingHooks(
            deadlineMonitorDidElapse: {
                probe.recordMonitorElapsed()
                // 期限到来を検知した後で、はじめて成功応答を流す
                SyntheticTokenURLProtocol.controller.releaseHeldResponse()
                // sendが交換の終了を確認するまで、監視taskのdeadlineReachedを遅らせる
                if await probe.waitUntilExchangeFinished(seconds: 5) {
                    probe.recordFinishedBeforeMonitorResumed()
                }
            },
            exchangeDidFinish: { probe.recordExchangeFinished($0) })
        // 監視deadlineは0.2秒、URL層のtimeoutは10秒。応答はhookで0.2秒過ぎに流すので、
        // URL層のtimeoutが届く前に正常完了する
        let transport = try makeTransport(deadline: 0.2, urlLoadingTimeout: 10, testingHooks: hooks)
        let started = Date()

        await assertSendFails(try makeTokenRequest(), as: .timedOut, "期限後の成功応答", transport: transport)

        // URL層のtimeoutより十分前に終わっている（URLSessionのtimeoutで終わったのではない）
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        // 想定した順序（期限到来 → 応答完了・無効化 → 監視再開）が実際に起きたことを確かめる
        XCTAssertEqual(probe.monitorElapsedCount, 1)
        XCTAssertEqual(probe.exchangeFinishedCount, 1)
        XCTAssertTrue(probe.exchangeFinishedBeforeMonitorResumed, "競合の順序を再現できていない")
        // 期限後に、HTTPとしては正常に受理・完了していた（通信エラーやURL層のtimeoutではない）
        XCTAssertEqual(SyntheticTokenURLProtocol.controller.finishCount, 1, "合成URLProtocolが正常完了を送っていない")
        XCTAssertEqual(probe.exchangeSummary,
                       ChatGPTOAuthTokenHTTPTransport.TestingExchangeSummary(
                           responseAccepted: true, completedWithoutError: true),
                       "URLSession側で正常応答の受理・完了まで進んでいない")
        XCTAssertEqual(SyntheticTokenURLProtocol.controller.startCount, 1)
        XCTAssertEqual(SyntheticTokenURLProtocol.controller.nonTokenStartCount, 0)
    }

    // 対照: 同じhookを付けても、期限前に完了した成功はそのまま成功になる。監視taskの制御点は通らない
    func testSuccessCompletedBeforeDeadlineSucceedsWithHooksInstalled() async throws {
        let json = syntheticTokenJSON()
        SyntheticTokenURLProtocol.controller.reset(script: .init(chunks: [json]))
        let probe = DeadlineRaceProbe()
        let hooks = ChatGPTOAuthTokenHTTPTransport.TestingHooks(
            deadlineMonitorDidElapse: { probe.recordMonitorElapsed() },
            exchangeDidFinish: { probe.recordExchangeFinished($0) })

        let response = try await makeTransport(deadline: 10, testingHooks: hooks).send(try makeTokenRequest())

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, json)
        // sendは監視taskの終了を待ってから戻るので、この時点の回数は確定している
        XCTAssertEqual(probe.monitorElapsedCount, 0, "期限前に終わったのに監視が期限到来を検知した")
        XCTAssertEqual(probe.exchangeFinishedCount, 1)
        XCTAssertEqual(probe.exchangeSummary, ChatGPTOAuthTokenHTTPTransport.TestingExchangeSummary(
            responseAccepted: true, completedWithoutError: true))
        XCTAssertEqual(SyntheticTokenURLProtocol.controller.finishCount, 1)
        XCTAssertEqual(SyntheticTokenURLProtocol.controller.startCount, 1)
    }

    // 取消済みなら、requestが不正でもinvalidRequestではなくCancellationErrorを優先する。どこにも接続しない
    func testCancelledBeforeSendWithInvalidRequestThrowsCancellationError() async throws {
        let transport = try makeTransport()
        let valid = try makeTokenRequest()
        let cases: [(String, ChatGPTOAuthTokenRequest)] = [
            ("別host", tampered(valid, url: URL(string: "https://example.invalid/api/accounts/oauth/token")!)),
            ("GET", tampered(valid, method: "GET")),
            ("headerなし", tampered(valid, headers: [:])),
            ("空body", tampered(valid, body: Data())),
        ]
        for (label, request) in cases {
            let task = Task { () -> ChatGPTOAuthUnverifiedTokenHTTPResponse in
                // 送信より前に自分自身を取消す
                withUnsafeCurrentTask { $0?.cancel() }
                return try await transport.send(request)
            }
            let result = await task.result

            guard case .failure(let error) = result else {
                XCTFail("\(label): 取消したのに成功した")
                continue
            }
            XCTAssertTrue(error is CancellationError, "\(label): \(type(of: error)) \(String(describing: error))")
        }
        XCTAssertEqual(SyntheticTokenURLProtocol.controller.startCount, 0)
        XCTAssertEqual(SyntheticTokenURLProtocol.controller.nonTokenStartCount, 0)
    }

    func testCancellationWhileWaitingThrowsCancellationErrorAfterProtocolStops() async throws {
        SyntheticTokenURLProtocol.controller.reset(script: .init(behavior: .hang))
        let transport = try makeTransport(deadline: 10)
        let request = try makeTokenRequest()
        let started = Date()
        let task = Task { try await transport.send(request) }

        let didStart = await waitUntil(seconds: 3) { SyntheticTokenURLProtocol.controller.startCount == 1 }
        XCTAssertTrue(didStart)
        task.cancel()
        let result = await task.result

        guard case .failure(let error) = result else { return XCTFail("取消したのに成功した") }
        XCTAssertTrue(error is CancellationError, "\(type(of: error))")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "deadlineまで待たずに戻ること")
        XCTAssertEqual(SyntheticTokenURLProtocol.controller.stopCount, 1, "URLProtocolを止めずに戻った")
    }

    func testCancelledBeforeSendNeverStartsProtocol() async throws {
        let transport = try makeTransport()
        let request = try makeTokenRequest()
        let task = Task { () -> ChatGPTOAuthUnverifiedTokenHTTPResponse in
            // 送信より前に自分自身を取消す
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(request)
        }
        let result = await task.result

        guard case .failure(let error) = result else { return XCTFail("取消したのに成功した") }
        XCTAssertTrue(error is CancellationError, "\(type(of: error))")
        XCTAssertEqual(SyntheticTokenURLProtocol.controller.startCount, 0)
    }

    // MARK: - 秘密値を表に出さない

    func testErrorsAndResponseDescriptionsDoNotExposeSecrets() async throws {
        let errors: [ChatGPTOAuthTokenHTTPTransportError] = [
            .invalidRequest, .invalidTestingConfiguration, .redirectRejected, .unexpectedStatus,
            .invalidResponse, .responseTooLarge, .timedOut, .transportFailed,
        ]
        for error in errors {
            let texts = [String(describing: error), String(reflecting: error), error.localizedDescription]
            for text in texts {
                XCTAssertFalse(text.contains(syntheticCode), "\(error)")
                XCTAssertFalse(text.contains(syntheticVerifier), "\(error)")
                XCTAssertFalse(text.contains(syntheticClientID), "\(error)")
                XCTAssertFalse(text.contains(leakMarker), "\(error)")
            }
            XCTAssertNotEqual(error.localizedDescription, "未実装です。", "\(error)")
        }

        SyntheticTokenURLProtocol.controller.reset(script: .init(chunks: [syntheticTokenJSON()]))
        let response = try await makeTransport().send(try makeTokenRequest())
        for text in [String(describing: response), String(reflecting: response)] {
            XCTAssertFalse(text.contains("synthetic-access"))
            XCTAssertFalse(text.contains("synthetic-refresh"))
        }
        XCTAssertTrue(Mirror(reflecting: response).children.isEmpty)
    }
}
