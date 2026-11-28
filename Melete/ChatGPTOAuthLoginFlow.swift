import Foundation

// ChatGPT OAuth初回登録の「listener開始 → 認可URL生成 → callback受信 → token request構築」を
// 1本の流れとして結び付けるflow。最小の縦切りだけを実装した未統合の基盤で、アプリ本体からはまだ呼び出さない。
// token requestの送信・ブラウザ起動・Keychain・保存・UI・ログは扱わない。信頼できる認証機能としては扱わない。
//
// 振る舞い（テストで固定済みなのは縦切りの1本だけ。それ以外は実装のみで未検証）:
// - start(): 乱数を1回だけ取得し、そのstateでlistenerを作って開始する。
//   listenerが実際にbindしたportから redirect URI を作り、同じ乱数で試行（ChatGPTOAuthAttempt）を作って認可URLを返す
// - waitForTokenRequest(): callbackを待ち、試行で検証してtoken requestを1回だけ返す。送信はしない。
//   結果が確定したらlistenerの停止を待ってから返す
// - 期限: 注入された期限待機が終わったら、期限切れとして終了する
// - 常にfail closed: 失敗・取消・期限切れ・想定外の順序のどれでも、flowは終了状態になり再利用しない。
//   開始中（認可URLを返す前）・結果確定後・取消後に届いたcallbackは試行に渡さない
//
// 未完の範囲（安全機能として未実装・未検証のもの）:
// - 縦切り以外（取消・期限切れ・開始中のcallback・callback拒否・二重待機・start失敗）はテストで固定していない
// - flowをcancel()せずに破棄した場合、listenerは止めない。呼び出し側が破棄前にcancel()を呼ぶ必要がある
// - 期限待機の既定実装はなく、正式な経路で何を注入するかは未確定。期限の厳密な判定は試行側の時計検査に任せている
// - 取り出されるまでの結果（token request）とstate・verifierはメモリ上に平文で残り、消去は保証しない
// - listenerがstate照合済みのcallbackだけを渡すことを前提に、試行での拒否は1回でもflow全体を終了させる。
//   そのため、state一致のまま不正な応答が届くと正当なcallbackを待たずに終わる（安全側だがDoSには弱い）
// - 回帰テストで固定済みの修正点: 取消済みTaskへは未配送の結果を渡さず破棄する。開始中のcancel()はstart完了を待たずに
//   listenerへstopを伝える。listener開始が取消で投げた場合はstartAbortedにする
// - listenerの停止は1つのTaskにまとめ、停止要求が重なっても停止は1回だけ。呼び出し側は全員その完了を待つ
// - listener障害: factoryへ本物のlistenerと同じ形のfailureHandlerを渡し、独立した終端原因 listenerFailed で終える。
//   開始中はstart完了を待たずに停止を伝え、start()はlistenerFailedで投げる。開始後は一度だけ停止し、停止後に固定のエラーを渡す。
//   障害より先にcallback・取消・期限で結果が確定していれば上書きしない（後から届いた側も確定済みの障害を上書きしない）。
//   障害の検証は合成のfake listenerだけで、本物のlistenerの障害経路と結び付けた検証はしていない
// - HTTP応答の確定待ち（案B・flow側のみ実装）: 試行がcallbackを検証して成功した後だけ、listenerの停止を
//   応答確定（flush完了・失敗）の通知か、注入した上限待機（waitForResponseCompletion）の到来まで遅らせる。
//   検証成功の時点で結果（token request）は確定し、以後の扱いは次のとおり:
//   - flush完了・応答失敗・上限到来・listener障害: すぐ1回だけ止め、停止後に検証済みのtoken requestを渡す
//     （応答の成否はブラウザへの表示だけの問題で、認証の結果には影響させない）
//   - 明示的な取消（cancel()・待ち手のTaskの取消）: すぐ止め、token requestは破棄して cancelled を渡す
//   - 認可試行の期限: 検証成功の時点で期限待機を取り消す。すでに期限待機が戻って処理待ちでも、結果は変えない。
//     確定後は時計（now・uptime）で期限を再判定しない（期限の判定はconsumeCallbackの1回だけ）
//   - 通知先行: 応答確定がcallbackより先に届いたら最初の1件だけ保持し、検証成功の直後に上限待機をせずに止める。
//     callbackが拒否された・届かなかった場合は保持した通知を使わずに捨てる
//   listenerからの出来事（callback・障害・応答確定）は受け箱を通し、listenerが出した順のまま@MainActorで処理する。
//   検証は合成のfake listenerだけ。本物のlistenerはまだ応答確定を通知しないので、本番では上限到来まで待つことになる
//   （本物のNIO listenerとの接続は次工程）

// flowが使うlistenerの境界。テストでは合成のfake listenerを注入する
protocol ChatGPTOAuthLoopbackListening: AnyObject, Sendable {
    /// 受付を始め、bind済みのport（1...65535）を返す
    func start() async throws -> Int
    /// 受付を止める
    func stop() async
}

// 既存のloopback listenerは同じ形のstart・stopを持つので、そのまま境界に適合させる
extension ChatGPTOAuthLoopbackListener: ChatGPTOAuthLoopbackListening {}

@MainActor
final class ChatGPTOAuthLoginFlow {
    // listener障害の受け取り先。本物のlistener（ChatGPTOAuthLoopbackListener.init）のfailureHandlerと同じ型なので、
    // 本番のfactoryはそのまま渡せる。listener側のスレッドから呼ばれる
    typealias ListenerFailureHandler = ChatGPTOAuthNIOLoopbackListener.FailureHandler

    // callbackを受理した後のHTTP応答（callbackReceived）がどう確定したか。応答の中身・失敗の理由は含めない
    enum ResponseCompletion: Equatable, Sendable {
        // 応答を書き終え（flush完了）、送信側を閉じた
        case flushed
        // 応答を書けなかった、または書く前に接続が閉じた（期限・切断・停止など）
        case failed
    }

    // 応答確定の受け取り先。listener側のスレッドから呼ばれる
    typealias ResponseCompletionHandler = @Sendable (ResponseCompletion) -> Void

    // listenerの作成方法。期待するstate・callbackの受け取り先・障害の受け取り先・応答確定の受け取り先を渡して作る
    typealias ListenerFactory = @MainActor (
        _ expectedState: String,
        _ callbackSink: @escaping ChatGPTOAuthLoopbackListener.CallbackSink,
        _ failureHandler: @escaping ListenerFailureHandler,
        _ responseCompletionHandler: @escaping ResponseCompletionHandler
    ) -> any ChatGPTOAuthLoopbackListening

    // 期限まで待つ処理。引数は待つ秒数。戻ったら期限到来、取消されたら投げる
    typealias DeadlineWaiter = @Sendable (_ seconds: TimeInterval) async throws -> Void

    // 応答確定を待つ上限の待機。形は期限待機と同じ（戻ったら上限到来、取消されたら投げる）
    typealias ResponseCompletionWaiter = @Sendable (_ seconds: TimeInterval) async throws -> Void

    // 応答確定を待つ上限（秒）。listenerの接続期限より1秒長くし、通常はlistener側の期限で .failed が先に届くようにする。
    // flow側の上限は通知が来ない場合の安全装置（仮の値で、正式な値は未確定）
    static let responseCompletionTimeout = TimeInterval(ChatGPTOAuthNIOLoopbackListener.connectionDeadlineSeconds) + 1

    private let agentHostID: String
    private let lifetime: TimeInterval
    private let makeSecrets: () throws -> ChatGPTOAuthAuthorizationSecrets
    private let makeListener: ListenerFactory
    private let waitForDeadline: DeadlineWaiter
    private let waitForResponseCompletion: ResponseCompletionWaiter
    private let now: @MainActor () -> Date
    private let uptime: @MainActor () -> TimeInterval

    // flowの進行状態。状態の検査と更新はすべて@MainActor上でawaitを挟まずに行う
    private enum Phase {
        // start()がまだ呼ばれていない
        case idle
        // start()の途中（listenerの開始待ち）。認可URLはまだ外へ出ていない。
        // listenerは作成後に入る（開始中のcancel()から停止を伝えるため）
        case starting(listener: (any ChatGPTOAuthLoopbackListening)?)
        // 認可URLを返し、callbackを待っている
        case running(attempt: ChatGPTOAuthAttempt, listener: any ChatGPTOAuthLoopbackListening)
        // 試行がcallbackを検証して成功し、ブラウザへの応答の確定を待っている。listenerはまだ止めていない。
        // 結果は検証済みのrequestで確定済み（取消だけはrequestを破棄する）。以後のcallbackは試行に渡さない
        case awaitingResponse(request: ChatGPTOAuthTokenRequest, listener: any ChatGPTOAuthLoopbackListening)
        // 結果は確定し、listenerの停止を待っている。以後のcallbackは試行に渡さない
        case stopping
        // 終了した（成功・失敗・取消・期限切れのいずれか）。再利用しない
        case finished
    }

    private var phase: Phase = .idle
    // 開始中（認可URLを返す前）にflowを終わらせた最初の原因。start()がawaitから戻った時にこの原因で投げる。
    // 最初に確定した原因だけを記録し、後から届いた取消・callback・障害では上書きしない
    private var startTerminationCause: ChatGPTOAuthLoginFlowError?
    // 確定したがまだ呼び出し側へ渡していない結果。渡したらnilに戻し、2回目は渡さない
    private var undeliveredOutcome: Result<ChatGPTOAuthTokenRequest, ChatGPTOAuthLoginFlowError>?
    // waitForTokenRequest()で待っている呼び出し。同時に1つだけ
    private var waiter: CheckedContinuation<ChatGPTOAuthTokenRequest, Error>?
    private var deadlineTask: Task<Void, Never>?
    // 応答確定を待つ上限の待機。検証成功の後だけ動き、停止を始めたら取り消す
    private var responseCompletionTask: Task<Void, Never>?
    // callbackより先に届いた応答確定（通知先行）。最初の1件だけ保持し、検証成功の直後に使うか、終了時に捨てる
    private var earlyResponseCompletion: ResponseCompletion?
    // listenerのスレッドから届く出来事を、届いた順のまま@MainActorへ渡す受け箱
    private let listenerEvents = ChatGPTOAuthLoginFlowEventInbox()
    // listenerの停止処理。最初の停止要求で1回だけ作り、以後の要求は同じTaskの完了を待つ
    private var listenerStopTask: Task<Void, Never>?

#if DEBUG
    // テスト専用の観測点。listener停止後に結果が確定（待ち手へ再開、または未配送として保存）した直後に呼ぶ。
    // flowの状態・結果には一切触れない。既定はnilでReleaseビルドには存在しない
    var didCompleteStopForTesting: (@MainActor () -> Void)?
#endif

    /// - Parameters:
    ///   - agentHostID: 永続化済みの `urn:uuid:` 形式UUIDv4
    ///   - lifetime: 試行の有効期間（秒）。`ChatGPTOAuthAttempt` と同じ制約に従う
    ///   - makeSecrets: 乱数の取得元。テストでは合成の固定値を注入する
    ///   - makeListener: listenerの作成方法。テストではfake listenerを注入する
    ///   - waitForDeadline: 期限まで待つ処理。テストでは手動で進める待機を注入する
    ///   - waitForResponseCompletion: 正常callback後に応答確定を待つ上限の待機。テストでは手動で進める待機を注入する
    ///   - now: 現在時刻（テストで固定できるよう外から渡す）
    ///   - uptime: 単調時計。テストだけが差し替える
    init(
        agentHostID: String,
        lifetime: TimeInterval,
        makeSecrets: @escaping () throws -> ChatGPTOAuthAuthorizationSecrets = ChatGPTOAuthAuthorizationSecrets.generateRandom,
        makeListener: @escaping ListenerFactory,
        waitForDeadline: @escaping DeadlineWaiter,
        waitForResponseCompletion: @escaping ResponseCompletionWaiter,
        now: @escaping @MainActor () -> Date,
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.agentHostID = agentHostID
        self.lifetime = lifetime
        self.makeSecrets = makeSecrets
        self.makeListener = makeListener
        self.waitForDeadline = waitForDeadline
        self.waitForResponseCompletion = waitForResponseCompletion
        self.now = now
        self.uptime = uptime
    }

    /// listenerを開始し、ブラウザで開く認可URLを返す。1つのflowで1回だけ呼べる
    func start() async throws -> URL {
        guard case .idle = phase else {
            throw ChatGPTOAuthLoginFlowError.alreadyStarted
        }
        // 乱数の取得やlistenerの開始より前に、試行と同じ制約で有効期間を確かめる
        guard lifetime.isFinite, lifetime > 0, lifetime <= ChatGPTOAuthAttempt.maxLifetime else {
            phase = .finished
            throw ChatGPTOAuthLoginFlowError.invalidConfiguration
        }
        phase = .starting(listener: nil)

        // 乱数はここで1回だけ取得し、listenerの照合用stateと試行の両方に同じ値を使う
        let secrets: ChatGPTOAuthAuthorizationSecrets
        do {
            secrets = try makeSecrets()
        } catch {
            // 取得元のエラーは中身に秘密値を含みうるため、固定値へ置き換える
            phase = .finished
            throw ChatGPTOAuthLoginFlowError.startFailed
        }

        // 3つの受け取り先はlistener側のスレッドから呼ばれる。Sendableな値（callback文字列・応答確定）だけを
        // 受け箱へ届いた順に積み、@MainActorでまとめて取り出して処理する。
        // 出来事ごとに別のTaskで@MainActorへ移すと実行順が保証されないため、順序は受け箱の積んだ順で決める。
        // flowを強参照しないよう弱参照にする（flowが破棄されたら出来事は捨てる）。
        // 障害の種類（listenerFailedのみ）は受け口へ渡さず、受け口は常に固定のlistenerFailedで終える
        let events = listenerEvents
        let listener = makeListener(
            secrets.state,
            { [weak self] request in
                events.append(.callback(request.callback))
                Task { @MainActor [weak self] in
                    self?.drainListenerEvents()
                }
            },
            { [weak self] _ in
                events.append(.listenerFailure)
                Task { @MainActor [weak self] in
                    self?.drainListenerEvents()
                }
            },
            { [weak self] completion in
                events.append(.responseCompletion(completion))
                Task { @MainActor [weak self] in
                    self?.drainListenerEvents()
                }
            }
        )
        // 開始待ちの間にcancel()が来たら停止を伝えられるよう、作ったlistenerを状態に持たせる。
        // 万一factoryの中で状態が変わっていたら上書きしない（await後の確認で中止する）
        if case .starting = phase {
            phase = .starting(listener: listener)
        }

        let port: Int
        do {
            port = try await listener.start()
        } catch {
            // 開始中にflowを終わらせた原因（cancel()・callback・listener障害）が先に確定していれば、それを優先する。
            // 原因がなく、開始Taskの取消で投げた場合は、失敗ではなく中止として扱う。
            // 判定は停止のawaitより前に行い、投げた時点の原因を反映させる
            let failure: ChatGPTOAuthLoginFlowError
            if let cause = startTerminationCause {
                failure = cause
            } else if error is CancellationError || Task.isCancelled {
                failure = .startAborted
            } else if case .starting = phase {
                failure = .startFailed
            } else {
                failure = .startAborted
            }
            await requestListenerStop(listener).value
            phase = .finished
            throw failure
        }

        // awaitの間に取消された・開始中にcallbackや障害が届いた場合は、認可URLを返さずに終わる。
        // 原因が記録されていればその原因（障害ならlistenerFailed）で、なければ中止として投げる。
        // cancel()や障害がすでに停止を始めていれば、同じ停止Taskの完了を待つ（二重には止めない）
        guard case .starting = phase, !Task.isCancelled else {
            let failure = startTerminationCause ?? .startAborted
            await requestListenerStop(listener).value
            phase = .finished
            throw failure
        }

        // listenerが実際にbindしたportだけからredirect URIを作る（形式の最終確認は試行側のbuilderが行う）
        guard (1...65535).contains(port),
              let redirectURI = URL(string: "http://127.0.0.1:\(port)/auth/callback") else {
            await requestListenerStop(listener).value
            phase = .finished
            throw ChatGPTOAuthLoginFlowError.startFailed
        }

        let attempt: ChatGPTOAuthAttempt
        do {
            // builderへは取得済みの乱数を返すだけのクロージャを渡し、乱数を取り直さない
            attempt = try ChatGPTOAuthAttempt(
                agentHostID: agentHostID,
                redirectURI: redirectURI,
                lifetime: lifetime,
                authorizationBuilder: ChatGPTOAuthAuthorizationRequestBuilder(makeSecrets: { secrets }),
                now: now,
                uptime: uptime
            )
        } catch {
            await requestListenerStop(listener).value
            phase = .finished
            throw ChatGPTOAuthLoginFlowError.startFailed
        }

        // ここから戻るまではawaitを挟まないので、callbackや取消が割り込むことはない
        phase = .running(attempt: attempt, listener: listener)
        startDeadline()
        return attempt.authorizationURL
    }

    /// callbackを待ち、検証に合格したtoken requestを1回だけ返す。送信はしない。
    /// 結果を一度返した（または失敗を投げた）後の呼び出しはすべて `alreadyFinished` で拒否する
    func waitForTokenRequest() async throws -> ChatGPTOAuthTokenRequest {
        switch phase {
        case .idle, .starting:
            throw ChatGPTOAuthLoginFlowError.notStarted
        case .finished:
            // 確定済みで未配送の結果があれば1回だけ渡す
            if let outcome = undeliveredOutcome {
                undeliveredOutcome = nil
                // 取消済みのTaskへは秘密を含む結果を渡さず、そのまま破棄する（後の呼び出しにも渡さない）
                if Task.isCancelled {
                    throw ChatGPTOAuthLoginFlowError.cancelled
                }
                return try outcome.get()
            }
            throw ChatGPTOAuthLoginFlowError.alreadyFinished
        case .running, .awaitingResponse, .stopping:
            break
        }
        guard waiter == nil else {
            throw ChatGPTOAuthLoginFlowError.alreadyWaiting
        }

        // withTaskCancellationHandler: 待っているTaskが取消されたらonCancelが（別スレッドから）呼ばれる。
        // onCancelからは状態に直接触れず、@MainActorへ移ってからflow全体を取り消す
        let request = try await withTaskCancellationHandler {
            // withCheckedThrowingContinuation: 結果が確定するまで中断し、後でresumeされた値で再開する
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
        // 取消と結果の確定が競合した場合も、取消された呼び出し側へはtoken requestを渡さない
        if Task.isCancelled {
            throw ChatGPTOAuthLoginFlowError.cancelled
        }
        return request
    }

    /// flowを取り消す。listenerを止め、以後のcallbackは試行に渡さない
    func cancel() {
        switch phase {
        case .idle:
            phase = .finished
        case .starting(let listener):
            terminateDuringStart(listener: listener, cause: .startAborted)
        case .running:
            finish(.failure(.cancelled))
        case .awaitingResponse:
            // 明示的な取消は、検証済みでもtoken requestを破棄する。応答確定は待たない
            finishAwaitingResponse(discardingRequest: true)
        case .stopping, .finished:
            // すでに結果が確定している場合は上書きしない
            break
        }
    }

    // MARK: - 内部処理

    // 受け箱に積まれた出来事を、積まれた順に1件ずつ処理する。
    // 出来事ごとにこのメソッドが呼ばれるが、先に呼ばれた側がまとめて処理し、後の呼び出しは空振りする
    private func drainListenerEvents() {
        while let event = listenerEvents.next() {
            switch event {
            case .callback(let callback):
                receive(callback)
            case .listenerFailure:
                handleListenerFailure()
            case .responseCompletion(let completion):
                handleResponseCompletion(completion)
            }
        }
    }

    // listenerから届いたcallbackを処理する。@MainActor上で同期的に判定するので、2つが同時に成功することはない
    private func receive(_ callback: String) {
        switch phase {
        case .starting:
            // 認可URLをまだ返していないのでstateを知る正当な相手はいない。想定外の順序として開始を中止する。
            // listenerの停止はstart()がawaitから戻った後に行う（従来どおり）
            startTerminationCause = .startAborted
            phase = .finished
        case .running(let attempt, let listener):
            let request: ChatGPTOAuthTokenRequest
            do {
                request = try attempt.consumeCallback(callback)
            } catch let error as ChatGPTOAuthAttemptError {
                finish(.failure(Self.flowError(for: error)))
                return
            } catch {
                finish(.failure(.callbackRejected))
                return
            }
            acceptVerifiedRequest(request, listener: listener)
        case .idle, .awaitingResponse, .stopping, .finished:
            // 開始前・検証成功後・結果確定後・取消後のcallbackは試行に渡さず捨てる
            break
        }
    }

    // 検証に合格した直後の処理。ここで結果は確定し、認可試行の期限はもう判定しない。
    // 通知先行で応答確定が保持されていればすぐ止め、なければ応答確定か上限まで停止を待つ
    private func acceptVerifiedRequest(
        _ request: ChatGPTOAuthTokenRequest,
        listener: any ChatGPTOAuthLoopbackListening
    ) {
        guard case .running = phase else { return }
        // 期限待機が戻って処理待ちでも、expire()は.running以外では何もしないので結果は変わらない
        deadlineTask?.cancel()
        deadlineTask = nil
        if earlyResponseCompletion != nil {
            beginStop(listener: listener, outcome: .success(request))
            return
        }
        phase = .awaitingResponse(request: request, listener: listener)
        startResponseCompletionBound()
    }

    // 結果を確定させ、listenerを止める。停止が終わってから結果を待ち手へ渡す
    private func finish(_ outcome: Result<ChatGPTOAuthTokenRequest, ChatGPTOAuthLoginFlowError>) {
        guard case .running(let attempt, let listener) = phase else { return }
        // 消費済みの試行には影響しない。取消・期限切れでは試行も取り消して以後のcallbackを拒否させる
        attempt.cancel()
        beginStop(listener: listener, outcome: outcome)
    }

    // 応答確定待ちを終え、listenerを止める。取消の時だけ検証済みのrequestを破棄する
    private func finishAwaitingResponse(discardingRequest: Bool) {
        guard case .awaitingResponse(let request, let listener) = phase else { return }
        beginStop(listener: listener, outcome: discardingRequest ? .failure(.cancelled) : .success(request))
    }

    // 停止状態へ移り、期限・上限の待機を取り消してlistenerを止める。停止が終わってから結果を待ち手へ渡す
    private func beginStop(
        listener: any ChatGPTOAuthLoopbackListening,
        outcome: Result<ChatGPTOAuthTokenRequest, ChatGPTOAuthLoginFlowError>
    ) {
        phase = .stopping
        deadlineTask?.cancel()
        deadlineTask = nil
        responseCompletionTask?.cancel()
        responseCompletionTask = nil
        earlyResponseCompletion = nil

        // 停止Taskがlistenerを強参照で持つので、flowが先に破棄されても停止は最後まで行う
        let stopTask = requestListenerStop(listener)
        Task { @MainActor [weak self] in
            await stopTask.value
            self?.completeStop(with: outcome)
        }
    }

    // listenerの停止を1つのTaskにまとめて返す。何度呼ばれても stop() は1回だけで、呼び出し側は同じ完了を待つ
    private func requestListenerStop(_ listener: any ChatGPTOAuthLoopbackListening) -> Task<Void, Never> {
        if let listenerStopTask {
            return listenerStopTask
        }
        // 構造化されていないTaskは呼び出し元の取消を引き継がないので、取消済みのstart()からでも停止は最後まで行う
        let task = Task { @MainActor in
            await listener.stop()
        }
        listenerStopTask = task
        return task
    }

    private func completeStop(with outcome: Result<ChatGPTOAuthTokenRequest, ChatGPTOAuthLoginFlowError>) {
        phase = .finished
        if let waiter {
            // continuationは必ず1回だけresumeする。先にnilへ戻してから再開する
            self.waiter = nil
            waiter.resume(with: outcome.mapError { $0 as Error })
        } else {
            undeliveredOutcome = outcome
        }
#if DEBUG
        didCompleteStopForTesting?()
#endif
    }

    // 開始中（認可URLを返す前）にflowを終える。start完了を待たずにlistenerへ停止を伝え、原因を記録する。
    // start()はawait後にこの状態を見て、同じ停止Taskの完了を待ってから記録した原因で投げる
    private func terminateDuringStart(
        listener: (any ChatGPTOAuthLoopbackListening)?,
        cause: ChatGPTOAuthLoginFlowError
    ) {
        guard case .starting = phase else { return }
        startTerminationCause = cause
        phase = .finished
        if let listener {
            _ = requestListenerStop(listener)
        }
    }

    // listener障害の受け口。factoryへ渡したfailureHandlerから@MainActor上で呼ばれる。
    // 状態の判定はcallback・取消・期限と同じく@MainActor上でawaitを挟まずに行うので、最初に確定した結果だけが残る
    private func handleListenerFailure() {
        switch phase {
        case .starting(let listener):
            // 認可URLはまだ外へ出ていない。開始を待たずに止め、start()はlistenerFailedで終える
            terminateDuringStart(listener: listener, cause: .listenerFailed)
        case .running:
            // 期限を待たずに固定のlistenerFailedで終える。停止は1回だけで、結果は停止後に渡す
            finish(.failure(.listenerFailed))
        case .awaitingResponse:
            // 通信はすぐ終えるが、検証済みの結果は保つ（応答が届かなかったかもしれないだけで、認証自体は成功している）
            finishAwaitingResponse(discardingRequest: false)
        case .idle, .stopping, .finished:
            // 開始前・結果確定後（重複した障害通知を含む）は何もしない。確定済みの結果を上書きしない
            break
        }
    }

    // 応答確定の受け口。flush完了・失敗のどちらでも、応答待ちならすぐ止めて検証済みのrequestを渡す
    private func handleResponseCompletion(_ completion: ResponseCompletion) {
        switch phase {
        case .running:
            // 通知先行: callbackの処理より先に届いた。最初の1件だけ保持し、検証成功の直後に使う
            if earlyResponseCompletion == nil {
                earlyResponseCompletion = completion
            }
        case .awaitingResponse:
            finishAwaitingResponse(discardingRequest: false)
        case .idle, .starting, .stopping, .finished:
            // 開始前・開始中・結果確定後（重複した通知を含む）は何もしない
            break
        }
    }

    // 上限待機が戻ったら、応答確定を待たずに止めて検証済みのrequestを渡す。
    // 待機自体が想定外に失敗した場合も上限到来として扱う（待ち続けない）
    private func startResponseCompletionBound() {
        let wait = waitForResponseCompletion
        let seconds = Self.responseCompletionTimeout
        responseCompletionTask = Task { [weak self] in
            do {
                try await wait(seconds)
            } catch {
                if Task.isCancelled { return }
            }
            if Task.isCancelled { return }
            self?.finishAwaitingResponse(discardingRequest: false)
        }
    }

#if DEBUG
    // テスト専用。factory経由のfailureHandlerを通さず、受け口を直接呼ぶ
    func simulateListenerFailureForTesting() {
        handleListenerFailure()
    }
#endif

    // 注入された待機が戻ったら期限切れとして終える。待機自体が想定外に失敗した場合も期限切れ扱い（fail closed）
    private func startDeadline() {
        let wait = waitForDeadline
        let seconds = lifetime
        // @MainActorのメソッド内で作ったTaskは@MainActorを引き継ぐ。waitは@Sendableなので別の場所で実行される
        deadlineTask = Task { [weak self] in
            do {
                try await wait(seconds)
            } catch {
                if Task.isCancelled { return }
            }
            if Task.isCancelled { return }
            self?.expire()
        }
    }

    // 検証成功後（.awaitingResponse）に届いた期限は無視する。確定した結果を認可時刻で再判定しない
    private func expire() {
        guard case .running = phase else { return }
        finish(.failure(.expired))
    }

    // 試行のエラーを、関連値を持たないflowのエラーへ写す
    private static func flowError(for error: ChatGPTOAuthAttemptError) -> ChatGPTOAuthLoginFlowError {
        switch error {
        case .expired:
            return .expired
        case .cancelled:
            return .cancelled
        case .invalidLifetime, .invalidClock, .alreadyConsumed, .callbackRejected,
             .tokenRequestRejected, .unexpectedFailure:
            return .callbackRejected
        }
    }
}

// state・verifierを保持するため、print・dump・デバッガ表示では伏せ字にする
extension ChatGPTOAuthLoginFlow: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "ChatGPTOAuthLoginFlow(<redacted>)" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }
}

// listenerのスレッドから届く出来事を、届いた順のまま取り出せる受け箱。
// 積む側（listenerのスレッド）と取り出す側（@MainActor）が別なので、lockで守る。
// callback文字列は秘密を含みうるので、取り出したら受け箱には残さない
final class ChatGPTOAuthLoginFlowEventInbox: @unchecked Sendable {
    enum Event: Sendable {
        case callback(String)
        case listenerFailure
        case responseCompletion(ChatGPTOAuthLoginFlow.ResponseCompletion)
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func append(_ event: Event) {
        lock.withLock { events.append(event) }
    }

    // 最も古い出来事を1件取り出す。空ならnil
    func next() -> Event? {
        lock.withLock { events.isEmpty ? nil : events.removeFirst() }
    }
}

// エラーには入力値や秘密値を含めない（関連値を持たせない）
enum ChatGPTOAuthLoginFlowError: Error, Equatable {
    // RED段階のstubで使っていた値。もう投げないが、テストが「stubのままではない」ことの確認に参照しているため残す
    case notImplemented
    // start()は1つのflowで1回だけ
    case alreadyStarted
    // 有効期間が0以下・上限超え・NaN・無限大
    case invalidConfiguration
    // 乱数の取得・listenerの開始・redirect URIや試行の作成に失敗した
    case startFailed
    // 開始中に取消された、または認可URLを返す前にcallbackが届いた（開始中のlistener障害は listenerFailed）
    case startAborted
    // start()が完了する前にwaitForTokenRequest()が呼ばれた
    case notStarted
    // 別の呼び出しがすでにwaitForTokenRequest()で待っている
    case alreadyWaiting
    // 結果はすでに渡した（またはstartに失敗した）。2個目のtoken requestは返さない
    case alreadyFinished
    // 取消された
    case cancelled
    // 期限切れ（注入された期限待機の終了、または試行側の時計検査による失効）
    case expired
    // 試行がcallbackを拒否した（OAuthのerror・code不正・token request構築の失敗など）
    case callbackRejected
    // listenerが開始中または開始後に壊れた（障害の詳細は含めない）
    case listenerFailed
}
