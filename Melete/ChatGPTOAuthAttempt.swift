import Foundation

// ChatGPT OAuth初回登録の「1回の認可試行」を表す境界。
// 1つの試行が state・nonce・code verifier・redirect URI をまとめて保持し、
// callbackの検証とtoken exchange requestの構築を同じ試行に結び付ける。
// ネットワーク通信・listener・ブラウザ・Keychain・保存・UIには繋がず、アプリ本体からもまだ呼び出さない。
// 信頼できる認証機能としては扱わない。
//
// 振る舞い:
// - 試行の生成時に乱数（state・nonce・verifier）を1回だけ取得し、使い回さない
// - 判定順: 終端状態（消費済み・キャンセル済み・期限切れ） → 時刻 → state照合 → （ここで消費） → 残りのcallback検証 → token request構築
// - stateの一意一致を確認できなかった応答（state不一致・欠落・重複、state照合前の構文エラー）は試行をpendingのまま保つ。
//   state一致を確認できた応答は、その後の検証に失敗しても消費する。時計の異常も消費する
// - @MainActorに隔離し、状態の検査から終端状態への更新までをawaitを挟まない同期処理にすることで、
//   2つのcallbackが同時に成功扱いになることを防ぐ
// - 時計が生成時刻より前に戻った・NaNや無限大になった場合は、期限切れとして拒否する（fail closed）
// - 期限は壁時計と単調時計（uptime）の両方で判定し、どちらか一方でも期限以上なら拒否する。
//   壁時計は利用者やNTPで巻き戻せ、uptimeはスリープ中に進まない環境があるため、片方だけには頼らない。
//   ただし両方が同時に遅れて見える場合（スリープ中に壁時計も巻き戻された等）まで実時間の上限を保証するものではない

@MainActor
final class ChatGPTOAuthAttempt {
    // 有効期間の上限（秒）。ブラウザでの操作に十分で、放置された試行が長く残らない長さにする
    static let maxLifetime: TimeInterval = 600

    // ブラウザで開く認可URL。state・code_challengeを含むので、ログやUIのデバッグ表示には出さない
    var authorizationURL: URL { authorization.authorizationURL }

    private let authorization: ChatGPTOAuthAuthorizationRequest
    // 時刻は1970年からの秒数（Double）で持ち、NaN・無限大を明示的に検査できるようにする
    private let startedAt: TimeInterval
    private let expiresAt: TimeInterval
    // 単調時計（起動からの経過秒）で測った開始時点と期限
    private let uptimeStartedAt: TimeInterval
    private let uptimeExpiresAt: TimeInterval
    private let now: @MainActor () -> Date
    // 単調時計（起動からの経過秒）。壁時計の巻き戻しに左右されない期限判定に使う
    private let uptime: @MainActor () -> TimeInterval
    private var phase: Phase = .pending

    private enum Phase {
        // callbackをまだ受け取っていない
        case pending
        // state一致を確認できたcallbackを1回受け取った（成功・state照合後の検証失敗）、または時計が異常だった
        case consumed
        // 利用者または呼び出し元が取り消した
        case cancelled
        // 期限を過ぎてからcallbackが届いた
        case expired
    }

    /// - Parameters:
    ///   - agentHostID: 永続化済みの `urn:uuid:` 形式UUIDv4
    ///   - redirectURI: `http://127.0.0.1:<port>/auth/callback`
    ///   - lifetime: 試行の有効期間（秒）。0より大きく `maxLifetime` 以下の有限値だけ受け付ける
    ///   - authorizationBuilder: 乱数の取得元を含むbuilder。テストでは合成の固定値を注入する
    ///   - now: 現在時刻（テストで固定できるよう外から渡す）
    ///   - uptime: 単調時計。正式な経路では既定の `systemUptime` を使い、テストだけが差し替える。
    ///     `systemUptime` はスリープ中に進まない環境があるため、壁時計と併用して判定する
    init(
        agentHostID: String,
        redirectURI: URL,
        lifetime: TimeInterval,
        authorizationBuilder: ChatGPTOAuthAuthorizationRequestBuilder,
        now: @escaping @MainActor () -> Date,
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        // NaNや無限大だと期限の比較が当てにならず、期限切れにならない試行ができてしまうため拒否する
        guard lifetime.isFinite, lifetime > 0, lifetime <= Self.maxLifetime else {
            throw ChatGPTOAuthAttemptError.invalidLifetime
        }
        // 開始時刻と期限が有限でなければ、後の比較がすべて信用できないため試行を作らない。
        // 乱数を無駄に取得しないよう、builderを呼ぶ前に検査する
        let start = now().timeIntervalSince1970
        let expiry = start + lifetime
        guard start.isFinite, expiry.isFinite else {
            throw ChatGPTOAuthAttemptError.invalidClock
        }
        // 単調時計も同様に検査する。起動からの経過秒なので負数はありえず、異常値として扱う
        let uptimeStart = uptime()
        let uptimeExpiry = uptimeStart + lifetime
        guard uptimeStart.isFinite, uptimeStart >= 0, uptimeExpiry.isFinite, uptimeExpiry >= uptimeStart else {
            throw ChatGPTOAuthAttemptError.invalidClock
        }
        // 乱数はここで1回だけ取得する（builder.buildの中でmakeSecretsが1回呼ばれる）
        do {
            self.authorization = try authorizationBuilder.build(agentHostID: agentHostID, redirectURI: redirectURI)
        } catch let error as ChatGPTOAuthAuthorizationRequestError {
            // 関連値を持たない既知の固定エラーなので、理由が分かるようそのまま投げ直す
            throw error
        } catch {
            // 乱数の取得元などが投げた想定外のエラーは中身に秘密値を含みうるため、固定値へ置き換える
            throw ChatGPTOAuthAttemptError.unexpectedFailure
        }
        self.startedAt = start
        self.expiresAt = expiry
        self.uptimeStartedAt = uptimeStart
        self.uptimeExpiresAt = uptimeExpiry
        self.now = now
        self.uptime = uptime
    }

    /// callbackを検証し、合格したときだけtoken exchange requestを1回だけ返す
    /// - Parameter callback: ブラウザから戻ってきたcallback URLの文字列（加工せずそのまま渡す）
    func consumeCallback(_ callback: String) throws -> ChatGPTOAuthTokenRequest {
        // 1. すでに終わった試行は、中身を見ずに拒否する
        switch phase {
        case .pending:
            break
        case .consumed:
            throw ChatGPTOAuthAttemptError.alreadyConsumed
        case .cancelled:
            throw ChatGPTOAuthAttemptError.cancelled
        case .expired:
            throw ChatGPTOAuthAttemptError.expired
        }

        // ここから下はawaitを挟まない同期処理なので、判定途中に別callbackが割り込むことはない

        // 2. 時刻の検査。壁時計・単調時計のどちらかがNaN・無限大・負数・生成時点より前（巻き戻り）なら
        //    信用できないので拒否する。時計が正常に戻っても再利用させないため、消費済みにする
        let current = now().timeIntervalSince1970
        let currentUptime = uptime()
        guard current.isFinite, current >= startedAt,
              currentUptime.isFinite, currentUptime >= 0, currentUptime >= uptimeStartedAt else {
            phase = .consumed
            throw ChatGPTOAuthAttemptError.expired
        }
        // 期限ちょうども失効扱い。どちらか一方の時計でも期限に達していれば失効とする。
        // 時計が進んだ結果の失効なので、以後も期限切れとして報告する
        guard current < expiresAt, currentUptime < uptimeExpiresAt else {
            phase = .expired
            throw ChatGPTOAuthAttemptError.expired
        }

        // 3. stateの一意一致だけを先に確かめる。
        //    ここで拒否された応答（state不一致・欠落・重複、state照合前に見つかった構文エラー）は、
        //    この試行の応答だと確認できていないので、試行をpendingのまま保って正当なcallbackを待つ
        let verified: ChatGPTOAuthStateVerifiedCallback
        do {
            verified = try ChatGPTOAuthCallbackValidator.verifyState(
                callback: callback,
                expecting: ChatGPTOAuthCallbackExpectation(
                    redirectURI: authorization.redirectURI,
                    state: authorization.state
                )
            )
        } catch let error as ChatGPTOAuthCallbackError {
            // 関連値は秘密値を持たないenumだけなので、そのまま包んでよい
            throw ChatGPTOAuthAttemptError.callbackRejected(error)
        } catch {
            // 想定外の型のエラーは中身に何が入っているか分からないため、外へ出さずに固定値へ置き換える
            throw ChatGPTOAuthAttemptError.unexpectedFailure
        }

        // 4. state一致を確認できたので、ここで初めて試行を消費する。
        //    以後の拒否（scope重複・認可拒否・code不正など）でも、試行は終了したままにする
        phase = .consumed
        let result: ChatGPTOAuthCallbackResult
        do {
            result = try ChatGPTOAuthCallbackValidator.validateResponse(stateVerified: verified)
        } catch let error as ChatGPTOAuthCallbackError {
            throw ChatGPTOAuthAttemptError.callbackRejected(error)
        } catch {
            throw ChatGPTOAuthAttemptError.unexpectedFailure
        }

        // 5. この試行のredirect URIとverifierだけを使ってtoken requestを組み立てる
        do {
            return try ChatGPTOAuthTokenRequestBuilder.build(authorization: authorization, callback: result)
        } catch let error as ChatGPTOAuthTokenRequestError {
            throw ChatGPTOAuthAttemptError.tokenRequestRejected(error)
        } catch {
            throw ChatGPTOAuthAttemptError.unexpectedFailure
        }
    }

    /// 試行を取り消す。取り消し後のcallbackはすべて拒否する
    func cancel() {
        // すでに終わった試行（消費済み・期限切れ）の理由は上書きしない
        if phase == .pending {
            phase = .cancelled
        }
    }
}

// state・nonce・verifierを保持するため、print・dump・デバッガ表示では伏せ字にする
extension ChatGPTOAuthAttempt: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    // CustomReflectableなどのプロトコル要件はactorに隔離されない文脈から呼ばれるため、nonisolatedにする。
    // 中身は固定文字列だけで、隔離されたプロパティには触れない
    nonisolated var description: String { "ChatGPTOAuthAttempt(<redacted>)" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }
}

// エラーには入力値や秘密値を含めない。
// 関連値は、秘密値を持たない既存のエラー型（関連値なしのenum）だけに限る
enum ChatGPTOAuthAttemptError: Error, Equatable {
    // 有効期間が0以下・上限超え・NaN・無限大
    case invalidLifetime
    // 生成時の壁時計・単調時計（またはそこから求めた期限）がNaN・無限大、または単調時計が負数
    case invalidClock
    // この試行はすでにcallbackを受け取って終了している（成功・state照合後の検証失敗・時計の異常のいずれか）
    case alreadyConsumed
    // この試行はキャンセル済み
    case cancelled
    // この試行は期限切れ、または時計が信用できない
    case expired
    // callbackの検証で拒否された（state不一致・OAuthのerror・errorとcodeの併存など）
    case callbackRejected(ChatGPTOAuthCallbackError)
    // token requestの構築で拒否された
    case tokenRequestRejected(ChatGPTOAuthTokenRequestError)
    // 想定外の型のエラー。中身は伏せて固定値だけを返す
    case unexpectedFailure
}
