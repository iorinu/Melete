import Foundation

// ChatGPT OAuth token exchange（authorization_code grant）のHTTP transport。
// ChatGPTOAuthTokenRequestBuilderの出力だけを受け付け、固定のtoken endpointへ1回だけPOSTする。
// 受け取ったbodyは「HTTPで受け取れた」だけの未検証データで、検証はChatGPTOAuthTokenResponseParserが行う。
// アプリ本体からはまだ呼び出さない。Keychain・保存・ログは扱わない。
// エラーには関連値を持たせず、URL・ヘッダー・本文・URLSession由来の詳細を外へ出さない。

// 未検証の応答。bodyにtoken（秘密値）を含み得るため、print・dump・デバッガ表示では伏せ字にする
struct ChatGPTOAuthUnverifiedTokenHTTPResponse {
    let statusCode: Int
    let body: Data

    // このファイルの外からは作れないようにし、transportを通った応答だけがこの型になるようにする
    fileprivate init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

extension ChatGPTOAuthUnverifiedTokenHTTPResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ChatGPTOAuthUnverifiedTokenHTTPResponse(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

enum ChatGPTOAuthTokenHTTPTransportError: LocalizedError, Equatable {
    // RED段階のstubで使っていた値。sendからはもう投げないが、既存の列挙と互換を保つため残している
    case notImplemented
    // requestがtoken request builderの出力の形ではない
    case invalidRequest
    // test-only初期化の引数が不正
    case invalidTestingConfiguration
    // redirectを受け取った（追従しない）
    case redirectRejected
    // HTTP 200以外
    case unexpectedStatus
    // Content-Type・Content-Encoding・応答URL・Content-Lengthの形式が想定外
    case invalidResponse
    // 宣言または受信中のbodyが上限を超えた
    case responseTooLarge
    // 交換全体のdeadlineを超えた
    case timedOut
    // 通信エラー（詳細は捨てる）
    case transportFailed

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "未実装です。"
        case .invalidRequest:
            return "token requestの形式が無効です。"
        case .invalidTestingConfiguration:
            return "テスト用の設定が無効です。"
        case .redirectRejected:
            return "token endpointからのリダイレクトは許可されていません。"
        case .unexpectedStatus:
            return "token endpointが想定外の状態を返しました。"
        case .invalidResponse:
            return "token endpointの応答形式が無効です。"
        case .responseTooLarge:
            return "token endpointの応答が大きすぎます。"
        case .timedOut:
            return "token endpointとの通信がタイムアウトしました。"
        case .transportFailed:
            return "token endpointとの通信に失敗しました。"
        }
    }
}

struct ChatGPTOAuthTokenHTTPTransport {
    // productionのendpointは固定し、引数や設定から置き換える経路を作らない
    static let productionTokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    // 送信開始から応答本文の受信完了までの交換全体に掛ける制限時間(秒)
    static let productionDeadline: TimeInterval = 30
    static let maxRequestBodyLength = 8 * 1024
    // parserより大きいbodyは受け取っても検証できないので、受信時点で同じ上限を強制する
    static var maxResponseBodyLength: Int { ChatGPTOAuthTokenResponseParser.maxBodyLength }

    // builderが付けるheaderはこれだけ。完全一致で比べる
    private static let formContentType = "application/x-www-form-urlencoded"
    // builderのbodyは必ずこの項目から始まる
    private static let bodyPrefix = Data("grant_type=authorization_code&".utf8)

    // 実際に送る先。production初期化ではproductionTokenEndpoint、test-only初期化では合成endpointだけ
    private let endpoint: URL
    private let deadline: TimeInterval
    // URLRequest・URLSession側に渡すtimeoutの基準値。production初期化では常にdeadlineと同じ値
    private let urlLoadingTimeout: TimeInterval
    // nilなら既定のプロトコル群を使う。test-only初期化のときだけ、test専用URLProtocolで置き換える
    private let protocolClasses: [AnyClass]?
    #if DEBUG
    // test-only初期化のときだけ値がある。production初期化では常にnil
    private let testingHooks: TestingHooks?
    #endif

    init() {
        self.endpoint = Self.productionTokenEndpoint
        self.deadline = Self.productionDeadline
        self.urlLoadingTimeout = Self.productionDeadline
        self.protocolClasses = nil
        #if DEBUG
        self.testingHooks = nil
        #endif
    }

    // URLSessionを使わない純粋なrequest生成。送信先はrequest.urlではなく固定endpointを使う
    static func makeProductionURLRequest(for request: ChatGPTOAuthTokenRequest) throws -> URLRequest {
        try validate(request)
        return makeURLRequest(url: productionTokenEndpoint, body: request.body, timeout: productionDeadline)
    }

    #if DEBUG
    // DEBUG構成（Debug/WindowProbe/ScratchProbe）だけでコンパイルされる。Releaseには含まれない
    static let syntheticScheme = "melete-synthetic-oauth"
    static let syntheticEndpoint = URL(string: "melete-synthetic-oauth://token")!

    // テスト専用の制御点。deadline監視taskと交換の終了の順序を、テストから決定的に作るために使う。
    // 送受信の判定そのものは変えず、決まった位置で呼ばれるだけ
    struct TestingHooks: Sendable {
        // deadline監視taskが期限到来を検知した直後、deadlineReachedを呼ぶ前にawaitされる。
        // 期限前に交換が終わって監視taskが取消された場合は呼ばれない
        var deadlineMonitorDidElapse: (@Sendable () async -> Void)?
        // sendがsession無効化（交換の終了）を確認した直後、監視taskの終了を待つ前に呼ばれる。
        // URLSession側でどう終わったかの事実だけを渡す（本文・ヘッダー・エラー詳細は渡さない）
        var exchangeDidFinish: (@Sendable (TestingExchangeSummary) -> Void)?
    }

    // exchangeDidFinishに渡す、URLSession側の終わり方の要約
    struct TestingExchangeSummary: Sendable, Equatable {
        // acceptResponseが応答を受け入れた
        let responseAccepted: Bool
        // didCompleteWithErrorがエラーなし（正常なHTTP完了）で届いた
        let completedWithoutError: Bool
    }

    // テスト専用の初期化。独自スキームの合成endpoint以外は受け付けない。
    // protocolClassesは既定のプロトコル群に追加せず置き換える（空なら既定のHTTPスタックへ流れるので拒否）。
    // deadlineForTestingはnilなら本番値。値を渡すなら0より大きく本番値以下の有限値だけを受け付け、丸めずに拒否する。
    // urlLoadingTimeoutForTestingはnilならdeadlineと同じ値（productionと同じ関係）。
    // 値を渡すならdeadline以上・本番値以下の有限値だけを受け付ける。URL層のtimeoutを監視deadlineより
    // 長くして、監視taskの期限処理だけを検証するために使う
    init(testingSyntheticEndpoint endpoint: URL, protocolClasses: [AnyClass],
         deadlineForTesting: TimeInterval? = nil, urlLoadingTimeoutForTesting: TimeInterval? = nil,
         testingHooks: TestingHooks? = nil) throws {
        guard endpoint == Self.syntheticEndpoint,
              endpoint.scheme == Self.syntheticScheme,
              !protocolClasses.isEmpty else {
            throw ChatGPTOAuthTokenHTTPTransportError.invalidTestingConfiguration
        }
        if let deadline = deadlineForTesting {
            // isFiniteはNaNと無限大のどちらもfalseになる
            guard deadline.isFinite, deadline > 0, deadline <= Self.productionDeadline else {
                throw ChatGPTOAuthTokenHTTPTransportError.invalidTestingConfiguration
            }
        }
        let deadline = deadlineForTesting ?? Self.productionDeadline
        if let timeout = urlLoadingTimeoutForTesting {
            // URL層のtimeoutは予備なので、監視deadlineより短くはさせない
            guard timeout.isFinite, timeout >= deadline, timeout <= Self.productionDeadline else {
                throw ChatGPTOAuthTokenHTTPTransportError.invalidTestingConfiguration
            }
        }
        self.endpoint = Self.syntheticEndpoint
        self.deadline = deadline
        self.urlLoadingTimeout = urlLoadingTimeoutForTesting ?? deadline
        self.protocolClasses = protocolClasses
        self.testingHooks = testingHooks
    }
    #endif

    // 契約: return/throwは、URLSessionのtask完了とsession無効化（=URLProtocolの停止）を待ってから行う。
    // 取消は他の結果より優先してCancellationErrorにする。取消済みならどこにも接続しない
    func send(_ request: ChatGPTOAuthTokenRequest) async throws -> ChatGPTOAuthUnverifiedTokenHTTPResponse {
        // 取消は検証エラーより優先する（取消済みなら不正なrequestでもCancellationError）
        if Task.isCancelled {
            throw CancellationError()
        }
        try Self.validate(request)
        let urlRequest = Self.makeURLRequest(url: endpoint, body: request.body, timeout: urlLoadingTimeout)

        let configuration = Self.makeSessionConfiguration(timeout: urlLoadingTimeout)
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        // deadlineは応答ヘッダーだけでなく交換全体に掛ける。起点はtask開始の直前。
        // 成否は監視taskの処理順ではなく、stateが成功を確定した時点の実際の時刻とこの値を比べて決める
        let deadlineInstant = ContinuousClock.now.advanced(by: .seconds(deadline))
        let state = ChatGPTOAuthTokenHTTPExchangeState(expectedURL: endpoint, maxBodyLength: Self.maxResponseBodyLength,
                                                       deadline: deadlineInstant)
        // delegateの呼び出しを直列にするため、同時実行数1の専用queueを使う
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration,
                                 delegate: ChatGPTOAuthTokenHTTPSessionDelegate(state: state),
                                 delegateQueue: delegateQueue)

        #if DEBUG
        let hooks = testingHooks
        #endif
        let deadlineTask = Task.detached {
            do {
                try await ContinuousClock().sleep(until: deadlineInstant, tolerance: nil)
            } catch {
                // 交換が先に終わってcancelされた
                return
            }
            #if DEBUG
            // テスト専用: 期限到来の検知からdeadlineReachedまでの間に、応答の処理を割り込ませる
            await hooks?.deadlineMonitorDidElapse?()
            #endif
            state.deadlineReached()
        }

        // 取消ハンドラを開始より前に登録する。登録時点で取消済みならonCancelが先に呼ばれ、startはtaskを作らない。
        // 待機中に取消されても、onCancelがtaskを止め、無効化の合図が届くまでここで待つ
        await withTaskCancellationHandler {
            state.start(session: session, request: urlRequest)
            // 実行中のtaskが終わったら無効化する。didBecomeInvalidWithErrorが「本当に終わった」合図になる
            session.finishTasksAndInvalidate()
            await state.waitUntilInvalidated()
        } onCancel: {
            state.requestCancel()
        }
        #if DEBUG
        hooks?.exchangeDidFinish?(state.testingSummary)
        #endif
        deadlineTask.cancel()
        await deadlineTask.value

        let outcome = state.outcome
        if outcome.cancellationRequested || Task.isCancelled {
            throw CancellationError()
        }
        if let failure = outcome.failure {
            throw failure
        }
        guard let body = outcome.body else {
            throw ChatGPTOAuthTokenHTTPTransportError.transportFailed
        }
        return ChatGPTOAuthUnverifiedTokenHTTPResponse(statusCode: 200, body: body)
    }

    // MARK: - request

    // builderの出力と同じ形のときだけ通す。値はエラーに含めず、固定のcaseだけを返す
    private static func validate(_ request: ChatGPTOAuthTokenRequest) throws {
        guard request.url.baseURL == nil,
              request.url.absoluteString == productionTokenEndpoint.absoluteString,
              request.method == "POST",
              request.headers == ["Content-Type": formContentType],
              isValidFormBody(request.body) else {
            throw ChatGPTOAuthTokenHTTPTransportError.invalidRequest
        }
    }

    // builderは各値をunreserved文字と "%XX" だけにform encodeし、"=" と "&" で区切る。
    // それ以外のバイト（改行・空白・非ASCIIなど）があればbuilderの出力ではないので拒否する
    private static func isValidFormBody(_ body: Data) -> Bool {
        guard (1...maxRequestBodyLength).contains(body.count),
              body.starts(with: bodyPrefix) else {
            return false
        }
        return body.allSatisfy { byte in
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39: return true   // A-Z a-z 0-9
            case 0x2D, 0x2E, 0x5F, 0x7E: return true                  // - . _ ~
            case 0x25, 0x3D, 0x26: return true                        // % = &
            default: return false
            }
        }
    }

    private static func makeURLRequest(url: URL, body: Data, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(formContentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 圧縮を要求しない。URLSessionの自動展開に頼らず、圧縮された応答は受信側で拒否する
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // client secretは使わないのでAuthorizationは付けない。cookieも送らない
        request.httpShouldHandleCookies = false
        // builderのbodyを加工せずにそのまま送る
        request.httpBody = body
        return request
    }

    private static func makeSessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        // ephemeralに加えて、cookie・cache・credentialの保存先を明示的に外す
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        // 主なdeadlineはsend内の監視taskで掛ける。URLSession側の値は、それが働かなかった時の予備
        configuration.timeoutIntervalForRequest = timeout + 1
        configuration.timeoutIntervalForResource = timeout + 1
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }
}

// URLSession delegate(専用queue)・deadline監視task・send(呼び出し側)の間で共有する状態。
// すべての状態はlockで守り、continuationはlockの外で一度だけresumeする。
// 失敗の理由は最初に確定したものを使う（後から届く取消由来のエラー等で上書きしない）
private final class ChatGPTOAuthTokenHTTPExchangeState: @unchecked Sendable {
    struct Outcome {
        let cancellationRequested: Bool
        let failure: ChatGPTOAuthTokenHTTPTransportError?
        // 成功したときだけ値がある
        let body: Data?
    }

    private let lock = NSLock()
    private let expectedURL: URL
    private let maxBodyLength: Int
    // 交換全体の期限（monotonic時刻）。成功の確定がこれ以降ならtimedOutにする
    private let deadline: ContinuousClock.Instant
    private var task: URLSessionDataTask?
    private var body = Data()
    private var cancellationRequested = false
    private var failure: ChatGPTOAuthTokenHTTPTransportError?
    private var responseAccepted = false
    // didCompleteWithErrorが届いた（成否は問わない）
    private var completed = false
    private var completedWithoutError = false
    private var sessionInvalidated = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(expectedURL: URL, maxBodyLength: Int, deadline: ContinuousClock.Instant) {
        self.expectedURL = expectedURL
        self.maxBodyLength = maxBodyLength
        self.deadline = deadline
    }

    // 取消・失敗（deadline超過）が先に来ていたらtaskを作らず、I/Oを始めない
    func start(session: URLSession, request: URLRequest) {
        lock.withLock {
            guard !cancellationRequested, failure == nil else {
                return
            }
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func requestCancel() {
        lock.withLock {
            cancellationRequested = true
            body = Data()
            task?.cancel()
        }
    }

    // 交換がすでに終わっていれば何もしない
    func deadlineReached() {
        lock.withLock {
            guard !completed, !sessionInvalidated else {
                return
            }
            failLocked(.timedOut)
        }
    }

    // HTTP 200・application/json・非圧縮・想定URL・宣言サイズが上限以内のときだけ受け入れる
    func acceptResponse(_ response: URLResponse) -> Bool {
        let rejection = Self.rejection(for: response, expectedURL: expectedURL, maxBodyLength: maxBodyLength)
        return lock.withLock {
            guard !cancellationRequested, failure == nil, !completed else {
                return false
            }
            if let rejection {
                failLocked(rejection)
                return false
            }
            responseAccepted = true
            return true
        }
    }

    // redirectには追従せず、そのまま交換を失敗で終える
    func rejectRedirect() {
        lock.withLock {
            failLocked(.redirectRejected)
        }
    }

    // 受信中に上限を強制する。完了を待たず、超えた時点でtaskを止める
    func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        lock.withLock {
            guard responseAccepted, !cancellationRequested, failure == nil else {
                // 停止後・拒否後に届いたデータは捨てる
                return
            }
            guard body.count + data.count <= maxBodyLength else {
                failLocked(.responseTooLarge)
                return
            }
            body.append(data)
        }
    }

    func complete(with error: (any Error)?) {
        // エラーの中身（userInfo等）は保持せず、種類だけを見る
        let timedOut = (error as? URLError)?.code == .timedOut
        lock.withLock {
            completed = true
            task = nil
            if error != nil {
                if failure == nil, !cancellationRequested {
                    failure = timedOut ? .timedOut : .transportFailed
                }
                // 途中までのbodyは返さない
                body = Data()
            } else if !responseAccepted {
                if failure == nil, !cancellationRequested {
                    failure = .transportFailed
                }
                body = Data()
            } else {
                // HTTPとしては正常に完了した（事実として記録する。成否の判定は下で行う）
                completedWithoutError = true
                // 成功を確定するのはこの時点。監視taskがまだdeadlineReachedを呼んでいなくても、
                // 実際の時刻が期限以降なら成功にしない。session無効化の遅れはここに影響しない
                if failure == nil, !cancellationRequested, ContinuousClock.now >= deadline {
                    failure = .timedOut
                    body = Data()
                }
            }
        }
    }

    // didBecomeInvalidWithError。これ以降delegateは呼ばれず、I/Oは終わっている
    func invalidated() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            sessionInvalidated = true
            task = nil
            let waiter = self.waiter
            self.waiter = nil
            return waiter
        }
        continuation?.resume()
    }

    func waitUntilInvalidated() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyInvalidated: Bool = lock.withLock {
                if sessionInvalidated {
                    return true
                }
                precondition(waiter == nil, "waitUntilInvalidatedを並行して呼ばない")
                waiter = continuation
                return false
            }
            if alreadyInvalidated {
                continuation.resume()
            }
        }
    }

    var outcome: Outcome {
        lock.withLock {
            let succeeded = sessionInvalidated && completedWithoutError && responseAccepted
                && failure == nil && !cancellationRequested
            return Outcome(cancellationRequested: cancellationRequested,
                           failure: failure,
                           body: succeeded ? body : nil)
        }
    }

    #if DEBUG
    // テスト専用: URLSession側の終わり方だけを返す。判定（outcome）には使わない
    var testingSummary: ChatGPTOAuthTokenHTTPTransport.TestingExchangeSummary {
        lock.withLock {
            .init(responseAccepted: responseAccepted, completedWithoutError: completedWithoutError)
        }
    }
    #endif

    private func failLocked(_ reason: ChatGPTOAuthTokenHTTPTransportError) {
        if failure == nil {
            failure = reason
        }
        body = Data()
        task?.cancel()
    }

    // 受け入れられない理由を返す。受け入れられるならnil
    private static func rejection(for response: URLResponse, expectedURL: URL,
                                  maxBodyLength: Int) -> ChatGPTOAuthTokenHTTPTransportError? {
        guard let http = response as? HTTPURLResponse, http.url == expectedURL else {
            return .invalidResponse
        }
        // redirect応答がdelegateを経由せずに届いた場合も追従しない
        if [301, 302, 303, 307, 308].contains(http.statusCode) {
            return .redirectRejected
        }
        guard http.statusCode == 200 else {
            // error bodyは受け取らない（エラー文言に紛れ込ませない）
            return .unexpectedStatus
        }
        // charset等のパラメータは許し、media typeだけを大文字小文字を区別せずに比べる
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let mediaType = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard mediaType == "application/json" else {
            return .invalidResponse
        }
        // Accept-Encoding: identity を送っているので、圧縮された応答は想定外として拒否する
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding") {
            guard encoding.trimmingCharacters(in: .whitespaces).lowercased() == "identity" else {
                return .invalidResponse
            }
        }
        // 宣言された長さが上限を超えるなら本文を待たずに拒否する
        if let declared = http.value(forHTTPHeaderField: "Content-Length") {
            let digits = declared.trimmingCharacters(in: .whitespaces)
            guard !digits.isEmpty, digits.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }) else {
                return .invalidResponse
            }
            // 桁が多すぎてIntに収まらない値も上限超過として扱う
            guard let length = Int(digits), length <= maxBodyLength else {
                return .responseTooLarge
            }
        }
        return nil
    }
}

// URLSessionのdelegate。sessionが無効化されるまでsessionに強参照される。
// 内容（ヘッダー・本文・エラー詳細）はログせず、stateへ必要な事実だけを伝える
private final class ChatGPTOAuthTokenHTTPSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let state: ChatGPTOAuthTokenHTTPExchangeState

    init(state: ChatGPTOAuthTokenHTTPExchangeState) {
        self.state = state
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        state.acceptResponse(response) ? .allow : .cancel
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.append(data)
    }

    // redirectは必ず拒否する。code・code_verifierを含むbodyを別URLへ送らない
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        state.rejectRedirect()
        return nil
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        Self.disposition(for: challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        Self.disposition(for: challenge)
    }

    // tokenを含む応答をcacheに保存しない
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse) async -> CachedURLResponse? {
        nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        state.complete(with: error)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        state.invalidated()
    }

    // TLSのサーバー検証はOS標準に任せ、それ以外の認証要求(Basic等)には資格情報を出さず中止する
    private static func disposition(for challenge: URLAuthenticationChallenge)
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return (.performDefaultHandling, nil)
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
