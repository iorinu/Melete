import Foundation

// Responses APIへのHTTP transport。
// receiveはURLSessionのdelegateでSSEを逐次受け取り、onChunkへ順に渡す。
// エラーには関連値を持たせず、ヘッダー・認証情報・URL・本文を外へ出さない。ログも出力しない。
// notImplementedは現在使っていないが、既存テストが列挙しているため残している。
enum AIResponsesHTTPTransportError: Error, Equatable {
    case notImplemented
    case invalidCredential
    case invalidTestingEndpoint
    case invalidTestingCredential
    // test-only初期化に、正の有限値で本番値以下ではない応答ヘッダー待ちdeadlineが渡された
    case invalidTestingResponseHeaderDeadline
    case transportFailed
}

enum AIResponsesHTTPRequestFactory {
    // productionのendpointは固定し、引数や設定から置き換える経路を作らない。
    static let productionEndpoint = URL(string: "https://api.openai.com/v1/responses")!

    // URLSessionを使わない純粋なrequest生成。標準設定のURLRequestを返す。
    static func makeProductionRequest(credential: String, body: Data) throws -> URLRequest {
        try makeRequest(url: productionEndpoint, credential: credential, body: body)
    }

    #if DEBUG
    // test-only。URLは固定の合成endpointだけで、引数から差し替えられない。
    static func makeSyntheticTestingRequest(credential: String, body: Data) throws -> URLRequest {
        try makeRequest(url: AIResponsesHTTPTransport.syntheticEndpoint, credential: credential, body: body)
    }
    #endif

    // URLを受け取る組み立て処理はこのファイル内だけに閉じ、外からendpointを注入できないようにする。
    fileprivate static func makeRequest(url: URL, credential: String, body: Data) throws -> URLRequest {
        guard isValidCredential(credential) else {
            // 値はエラーに含めず、固定のcaseだけを返す。
            throw AIResponsesHTTPTransportError.invalidCredential
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // 圧縮を要求しない。URLSessionの自動展開に頼らず、圧縮された応答は受信側で拒否する。
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // credentialはtrim等で変形せず、検証を通った値をそのまま使う。
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    // 空の値と、空白・改行(CR/LF含む)・制御文字を一つでも含む値を拒否する。
    // 前後や途中の空白もtrimで救済せず、そのまま不正として扱う。改行や制御文字はヘッダー注入につながる。
    private static func isValidCredential(_ credential: String) -> Bool {
        guard !credential.isEmpty else {
            return false
        }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        return !credential.unicodeScalars.contains { forbidden.contains($0) }
    }
}

@MainActor final class AIResponsesHTTPTransport: AIResponsesChunkTransport {
    private let credential: String
    // productionではendpointを持たず、常にAIResponsesHTTPRequestFactory.productionEndpointを使う。
    // test-only初期化のときだけ合成endpointとtest専用URLProtocolを保持する。
    private let syntheticTesting: SyntheticTesting?

    private struct SyntheticTesting {
        let endpoint: URL
        let protocolClasses: [AnyClass]
        #if DEBUG
        let controlHook: @MainActor (SyntheticTestingControlPoint) -> Void
        // test-only。応答ヘッダー待ちdeadline(秒)。nilなら本番値を使う。init時に検証済み。
        let responseHeaderDeadline: TimeInterval?
        let beforeDeadlineExpirationForTesting: (@Sendable () -> Void)?
        #endif
    }

    // I/O開始から妥当な応答ヘッダーを受け入れるまでの制限時間(秒)。暫定値。
    // ヘッダー受け入れ後の本文(SSE)の長さには効かない。
    nonisolated static let productionResponseHeaderDeadline: TimeInterval = 15

    init(credential: String) {
        self.credential = credential
        self.syntheticTesting = nil
    }

    #if DEBUG
    // DEBUG構成（Debug/WindowProbe/ScratchProbe）だけでコンパイルされる。Releaseには含まれない。
    // URLProtocolはMainActor外で動くため、Sendableな定数はnonisolatedにして参照できるようにする。
    nonisolated static let syntheticScheme = "melete-synthetic"
    nonisolated static let syntheticEndpoint = URL(string: "melete-synthetic://responses")!
    // test-only初期化で受け付ける唯一の認証情報。実credentialではない固定ダミー。
    nonisolated static let syntheticTestCredential = "melete-synthetic-dummy-credential"

    // test-onlyの制御点。receive内でMainActorから同期的に呼ぶ。syntheticTestingがある時だけ呼ばれる。
    // - beforeSessionStart: 開始前の取消判定の後、取消ハンドラの登録とstate.startより前
    // - afterSessionStart: state.startの後、受信ループに入る前
    // - beforeChunkDelivery: nextEventが.dataを返した直後、取消・停止の判定とonChunkより前
    //   （ここで取消・停止が確定したら、そのdataはonChunkへ渡さない）
    enum SyntheticTestingControlPoint: Equatable {
        case beforeSessionStart
        case afterSessionStart
        case beforeChunkDelivery
    }

    // テスト専用の初期化。独自スキームのendpointと固定ダミー認証情報以外は受け付けない。
    // protocolClassesは既定のプロトコル群に追加せず置き換える（receiveで設定）。
    // controlHookは既定で何もしない。production初期化には存在しない。
    // beforeDeadlineExpirationForTestingは期限sleep成功後・期限状態を確定する前のsynthetic専用制御点。
    // responseHeaderDeadlineForTestingはnilなら本番値。値を渡すなら0より大きく本番値以下の有限値だけを受け付け、
    // 負数・0・NaN・無限大・本番値超えは丸めずに拒否する（Task.sleepへ渡す値を安全な範囲に限るため）。
    init(testingSyntheticEndpoint endpoint: URL, credential: String, protocolClasses: [AnyClass],
         responseHeaderDeadlineForTesting: TimeInterval? = nil,
         controlHook: @escaping @MainActor (SyntheticTestingControlPoint) -> Void = { _ in },
         beforeDeadlineExpirationForTesting: (@Sendable () -> Void)? = nil) throws {
        guard endpoint == Self.syntheticEndpoint,
              endpoint.scheme == Self.syntheticScheme,
              !protocolClasses.isEmpty else {
            throw AIResponsesHTTPTransportError.invalidTestingEndpoint
        }
        guard credential == Self.syntheticTestCredential else {
            throw AIResponsesHTTPTransportError.invalidTestingCredential
        }
        if let deadline = responseHeaderDeadlineForTesting {
            // isFiniteはNaNと無限大のどちらもfalseになる
            guard deadline.isFinite, deadline > 0, deadline <= Self.productionResponseHeaderDeadline else {
                throw AIResponsesHTTPTransportError.invalidTestingResponseHeaderDeadline
            }
        }
        self.credential = credential
        self.syntheticTesting = SyntheticTesting(endpoint: endpoint, protocolClasses: protocolClasses,
                                                 controlHook: controlHook,
                                                 responseHeaderDeadline: responseHeaderDeadlineForTesting,
                                                 beforeDeadlineExpirationForTesting: beforeDeadlineExpirationForTesting)
    }
    #endif

    // AIResponsesChunkTransportの契約: return/throwは、URLSessionのtask完了とsession無効化を待ってから行う。
    func receive(body: Data, onChunk: @MainActor (Data) throws -> Void) async throws {
        let configuration = Self.makeSessionConfiguration()
        let request: URLRequest
        #if DEBUG
        if let syntheticTesting {
            // 既定のプロトコル群に追加せず置き換え、test専用URLProtocol以外へ流れないようにする。
            configuration.protocolClasses = syntheticTesting.protocolClasses
            request = try AIResponsesHTTPRequestFactory.makeSyntheticTestingRequest(credential: credential, body: body)
        } else {
            request = try AIResponsesHTTPRequestFactory.makeProductionRequest(credential: credential, body: body)
        }
        #else
        request = try AIResponsesHTTPRequestFactory.makeProductionRequest(credential: credential, body: body)
        #endif
        guard let expectedURL = request.url else {
            throw AIResponsesHTTPTransportError.transportFailed
        }

        // 取消済みならsessionを作らず、どこにも接続しない。
        if Task.isCancelled {
            throw CancellationError()
        }

        let state = AIResponsesHTTPStreamState(expectedURL: expectedURL)
        #if DEBUG
        let responseHeaderDeadline = syntheticTesting?.responseHeaderDeadline
            ?? Self.productionResponseHeaderDeadline
        let beforeDeadlineExpirationForTesting = syntheticTesting?.beforeDeadlineExpirationForTesting
        #else
        let responseHeaderDeadline = Self.productionResponseHeaderDeadline
        let beforeDeadlineExpirationForTesting: (@Sendable () -> Void)? = nil
        #endif
        // delegateの呼び出しを直列にするため、同時実行数1の専用queueを使う。
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration,
                                 delegate: AIResponsesHTTPSessionDelegate(state: state),
                                 delegateQueue: delegateQueue)
        #if DEBUG
        syntheticTesting?.controlHook(.beforeSessionStart)
        #endif
        // 取消ハンドラをstartより前に登録する。登録時点で取消済みならonCancelが先に呼ばれ、
        // stopRequestedが立つのでstartはtaskを作らない。start中の取消もonCancelでstateへ伝わる。
        // operationではSendableなstateの同期処理だけを行い、MainActorの処理は外に置く。
        // state.startがlock内でdeadlineを確定し、その直後にtaskをresumeする。
        var responseHeaderDeadlineInstant: ContinuousClock.Instant?
        await withTaskCancellationHandler {
            responseHeaderDeadlineInstant = state.start(
                session: session, request: request, timeout: .seconds(responseHeaderDeadline)
            )
        } onCancel: {
            state.requestCancel()
        }
        // MainActorを継承しないtaskで監視する。起点はstart直前なので、taskの実行開始遅延も含めて測る。
        // deadline超過時はstate lock内で応答受理との競合を確定し、本文(SSE)受信時間には適用しない。
        let deadlineInstant = responseHeaderDeadlineInstant
        let deadlineTask = Task.detached {
            guard let deadlineInstant else {
                return
            }
            do {
                try await ContinuousClock().sleep(
                    until: deadlineInstant
                )
            } catch {
                return
            }
            beforeDeadlineExpirationForTesting?()
            state.responseHeaderDeadlineReached()
        }
        #if DEBUG
        syntheticTesting?.controlHook(.afterSessionStart)
        #endif
        // 実行中のtaskが終わったら無効化する。didBecomeInvalidWithErrorが「本当に終わった」合図になる。
        // （取消でtaskを作らなかった場合も、すぐ無効化されて合図が届く）
        session.finishTasksAndInvalidate()

        // 受信ループ全体に取消ハンドラを1つだけ掛ける。待機中・hook中・onChunk中のどこで取消されても、
        // onCancelがすぐstateへ停止を要求する（登録時点で取消済みなら登録時に呼ばれる）。
        // onCancelはlockで守られたstateの操作だけを行い、onChunkやcontinuationには触れない。
        // onChunkとhookはlockの外で、このMainActorの処理として呼ぶ。
        // ループ自体は取消で抜けず、I/Oの停止とsessionの無効化(.finished)まで必ず待つ。
        //
        // 取消の判定と並行して取消が起きた場合、取り出し済みのchunkの処理が最大1回生じ得るが、
        // その結果は下の判定で取消を優先して破棄する。実行中の同期的なonChunkは途中で中断できない。
        // receiveが戻った・投げた後にonChunkが呼ばれることはない。
        let chunkError: (any Error)? = await withTaskCancellationHandler {
            var chunkError: (any Error)?
            while true {
                let event = await state.nextEvent()
                guard case .data(let chunk) = event else {
                    break
                }
                #if DEBUG
                syntheticTesting?.controlHook(.beforeChunkDelivery)
                #endif
                // 配信直前に、停止・失敗と取消を確かめる。この判定からonChunkまでの間にawaitを入れない。
                // 確定した後は、取り出し済みのdataでもonChunkへ渡さず捨て、完了の合図(.finished)まで待つ。
                guard chunkError == nil, !state.isStopped, !Task.isCancelled else {
                    continue
                }
                do {
                    try onChunk(chunk)
                } catch {
                    // 停止を要求し、ループを続けて完了の合図(.finished)まで待ってから投げる。
                    chunkError = error
                    state.requestStop()
                }
            }
            return chunkError
        } onCancel: {
            state.requestCancel()
        }
        deadlineTask.cancel()
        await deadlineTask.value

        // 取消をonChunkのエラー(parser失敗等)より優先する。取消がなければ既存のエラーをそのまま投げる。
        let outcome = state.outcome
        if outcome.cancellationRequested || Task.isCancelled {
            throw CancellationError()
        }
        if let chunkError {
            throw chunkError
        }
        guard outcome.succeeded else {
            // HTTP・URLSession由来の詳細は捨て、固定エラーだけを返す。
            throw AIResponsesHTTPTransportError.transportFailed
        }
    }

    private static func makeSessionConfiguration() -> URLSessionConfiguration {
        // ephemeralに加えて、cookie・cache・credentialの保存先を明示的に外す。
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }
}

// 受信バッファの上限。未処理chunkを無制限に溜めない。
enum AIResponsesHTTPTransportLimits {
    // 未処理のバイトがこれ以上になったらURLSession taskを一時停止(suspend)する
    static let pendingHighWaterBytes = 64 * 1024
    // suspend後も届き続けてこの量を超えたら失敗にする
    static let maxPendingBytes = 1024 * 1024
    // 受信の累計上限。parserの上限(maxInputBytes)を先に効かせるため、それより少し大きくする
    static let maxTotalBytes = AIResponsesStreamLimits.default.maxInputBytes + maxPendingBytes
}

// URLSession delegate(専用queue)と、receive(MainActor)の間で共有する状態。
// すべての状態はlockで守り、continuationはlockの外で一度だけresumeする。
private final class AIResponsesHTTPStreamState: @unchecked Sendable {
    enum Event: Sendable {
        case data(Data)
        // taskが完了し、sessionの無効化まで終わった
        case finished
    }

    struct Outcome {
        let cancellationRequested: Bool
        let succeeded: Bool
    }

    private let lock = NSLock()
    private let expectedURL: URL
    private var task: URLSessionDataTask?
    private var pending = Data()
    private var totalBytes = 0
    private var isSuspendedForBackpressure = false
    private var waiter: CheckedContinuation<Event, Never>?
    // 呼び出し側が停止を要求した（取消・onChunkのthrow）
    private var stopRequested = false
    private var cancellationRequested = false
    // 応答の拒否・redirect・上限超過・通信エラー
    private var failed = false
    private var responseAccepted = false
    private var responseHeaderDeadline: ContinuousClock.Instant?
    private var completedWithoutError = false
    private var sessionInvalidated = false

    init(expectedURL: URL) {
        self.expectedURL = expectedURL
    }

    // 停止要求が先に来ていたらtaskを作らず、I/Oを始めない。
    func start(session: URLSession, request: URLRequest,
               timeout: Duration) -> ContinuousClock.Instant? {
        lock.withLock {
            guard !stopRequested else {
                return nil
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            responseHeaderDeadline = deadline
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
            return deadline
        }
    }

    func requestCancel() {
        lock.withLock {
            cancellationRequested = true
            stopLocked()
        }
    }

    func requestStop() {
        lock.withLock {
            stopLocked()
        }
    }

    // 妥当な応答受理・終了・他の停止がdeadlineより先なら何もしない。
    func responseHeaderDeadlineReached() {
        lock.withLock {
            guard !responseAccepted, !sessionInvalidated, !stopRequested, !failed else {
                return
            }
            failLocked()
        }
    }

    // URLSessionからの応答を検査する。HTTP 200・text/event-stream・非圧縮・想定URLのときだけ受け入れる。
    func acceptResponse(_ response: URLResponse) -> Bool {
        let isValid = Self.isAcceptable(response, expectedURL: expectedURL)
        return lock.withLock {
            // 取消・停止は期限切れより優先し、期限判定とresponseAcceptedを同じlockで直列化する。
            guard !stopRequested, !failed, !sessionInvalidated else {
                return false
            }
            if let deadline = responseHeaderDeadline, ContinuousClock.now >= deadline {
                failLocked()
                return false
            }
            guard isValid else {
                failLocked()
                return false
            }
            responseAccepted = true
            return true
        }
    }

    func rejectRedirect() {
        lock.withLock {
            failLocked()
        }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        let resumption: (CheckedContinuation<Event, Never>, Event)? = lock.withLock {
            guard responseAccepted, !stopRequested, !failed else {
                // 停止後・拒否後に届いたデータは捨てる
                return nil
            }
            totalBytes += data.count
            guard totalBytes <= AIResponsesHTTPTransportLimits.maxTotalBytes,
                  pending.count + data.count <= AIResponsesHTTPTransportLimits.maxPendingBytes else {
                failLocked()
                return nil
            }
            pending.append(data)
            if let waiter {
                // 待っている受信側へすぐ渡す
                self.waiter = nil
                return (waiter, .data(takePendingLocked()))
            }
            if pending.count >= AIResponsesHTTPTransportLimits.pendingHighWaterBytes, !isSuspendedForBackpressure {
                // 受信側が追いつくまで読み込みを止める
                task?.suspend()
                isSuspendedForBackpressure = true
            }
            return nil
        }
        if case let (continuation, event)? = resumption {
            continuation.resume(returning: event)
        }
    }

    func complete(withError hasError: Bool) {
        lock.withLock {
            if hasError || !responseAccepted {
                failed = true
                pending = Data()
            } else {
                completedWithoutError = true
            }
            task = nil
        }
    }

    // didBecomeInvalidWithError。これ以降delegateは呼ばれず、I/Oは終わっている。
    func invalidated() {
        let continuation: CheckedContinuation<Event, Never>? = lock.withLock {
            sessionInvalidated = true
            task = nil
            // waiterがいるのはpendingが空のときだけなので、そのまま終了を渡せる
            let waiter = self.waiter
            self.waiter = nil
            return waiter
        }
        continuation?.resume(returning: .finished)
    }

    // 受信側は常に1つだけ待つ。停止後はデータを返さず、無効化の合図まで待つ。
    func nextEvent() async -> Event {
        await withCheckedContinuation { (continuation: CheckedContinuation<Event, Never>) in
            let event: Event? = lock.withLock {
                if !pending.isEmpty {
                    return .data(takePendingLocked())
                }
                if sessionInvalidated {
                    return .finished
                }
                precondition(waiter == nil, "nextEventを並行して呼ばない")
                waiter = continuation
                return nil
            }
            if let event {
                continuation.resume(returning: event)
            }
        }
    }

    // 停止要求（取消・onChunkのthrow）か失敗が確定しているか。確定後のdataは配信しない。
    var isStopped: Bool {
        lock.withLock {
            stopRequested || failed
        }
    }

    var outcome: Outcome {
        lock.withLock {
            Outcome(cancellationRequested: cancellationRequested,
                    succeeded: sessionInvalidated && completedWithoutError && responseAccepted
                        && !failed && !stopRequested)
        }
    }

    private func stopLocked() {
        stopRequested = true
        pending = Data()
        // suspend中のtaskもcancelでき、didCompleteWithErrorが届く
        task?.cancel()
    }

    private func failLocked() {
        failed = true
        pending = Data()
        task?.cancel()
    }

    private func takePendingLocked() -> Data {
        let data = pending
        pending = Data()
        if isSuspendedForBackpressure {
            task?.resume()
            isSuspendedForBackpressure = false
        }
        return data
    }

    private static func isAcceptable(_ response: URLResponse, expectedURL: URL) -> Bool {
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.url == expectedURL else {
            return false
        }
        // charset等のパラメータは許し、media typeだけを比べる
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let mediaType = contentType.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard mediaType == "text/event-stream" else {
            return false
        }
        // Accept-Encoding: identity を送っているので、圧縮された応答は想定外として拒否する
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding") {
            guard encoding.trimmingCharacters(in: .whitespaces).lowercased() == "identity" else {
                return false
            }
        }
        return true
    }
}

// URLSessionのdelegate。sessionが無効化されるまでsessionに強参照される。
// 内容（ヘッダー・本文・認証情報・エラー詳細）はログせず、stateへ必要な事実だけを伝える。
private final class AIResponsesHTTPSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let state: AIResponsesHTTPStreamState

    init(state: AIResponsesHTTPStreamState) {
        self.state = state
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        state.acceptResponse(response) ? .allow : .cancel
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.append(data)
    }

    // redirectは必ず拒否する。Authorizationを別URLへ送らない。
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

    // cacheには保存しない
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse) async -> CachedURLResponse? {
        nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // エラーの中身は保持せず、有無だけを伝える
        state.complete(withError: error != nil)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        state.invalidated()
    }

    // TLSのサーバー検証はOS標準に任せ、それ以外の認証要求(Basic等)には資格情報を出さず中止する。
    private static func disposition(for challenge: URLAuthenticationChallenge)
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return (.performDefaultHandling, nil)
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
