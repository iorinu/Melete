import CryptoKit
import Foundation
import Security

// ChatGPT OAuth初回登録用のauthorization request URLを組み立てるだけの純粋な処理。
// 段階2の下準備で、ネットワーク通信・ブラウザ起動・callback解析・token交換・保存は行わない。
// アプリ本体からはまだ呼び出さない。信頼できる認証機能としては扱わない。
// パラメータは2026-11-26にOpenAIの公式ドキュメントを確認した値に基づく。

// 1回の認可試行で使う乱数値。値はdescriptionやdumpに出さない。
struct ChatGPTOAuthAuthorizationSecrets {
    let state: String
    let nonce: String
    let codeVerifier: String

    // 本番用: 暗号論的乱数32バイト（256bit）をbase64url（paddingなし・43文字）にする
    static func generateRandom() throws -> ChatGPTOAuthAuthorizationSecrets {
        ChatGPTOAuthAuthorizationSecrets(
            state: try randomBase64URL(byteCount: 32),
            nonce: try randomBase64URL(byteCount: 32),
            codeVerifier: try randomBase64URL(byteCount: 32)
        )
    }

    private static func randomBase64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        // SecRandomCopyBytesはOSの暗号論的乱数源を使う。失敗時は弱い乱数へfallbackせずエラーにする
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw ChatGPTOAuthAuthorizationRequestError.randomGenerationFailed
        }
        return ChatGPTOAuthAuthorizationRequestBuilder.base64URLEncodedWithoutPadding(Data(bytes))
    }
}

// 秘密値を含むため、print・dump・デバッガ表示では伏せ字にする
extension ChatGPTOAuthAuthorizationSecrets: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ChatGPTOAuthAuthorizationSecrets(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

// 組み立て結果。後段のtoken exchangeで同じredirect URIとverifierを使うため値を保持する
struct ChatGPTOAuthAuthorizationRequest {
    let authorizationURL: URL
    let redirectURI: URL
    let state: String
    let nonce: String
    let codeVerifier: String
}

// URL自体にもstate・nonce・code_challengeが含まれるので、表示は伏せ字にする
extension ChatGPTOAuthAuthorizationRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ChatGPTOAuthAuthorizationRequest(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

struct ChatGPTOAuthAuthorizationRequestBuilder {
    // 固定値（外部から差し替えない）
    private static let authorizeEndpoint = "https://auth.openai.com/api/accounts/authorize"
    private static let clientID = "dynamic_agent_client"
    private static let agentNameHint = "Melete"
    private static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    private static let resource = "https://api.openai.com/v1"
    private static let loopbackHost = "127.0.0.1"
    private static let callbackPath = "/auth/callback"

    private let makeSecrets: () throws -> ChatGPTOAuthAuthorizationSecrets

    // テストでは合成の固定値を返すクロージャを明示的に渡す。既定は毎回新しい暗号論的乱数
    init(makeSecrets: @escaping () throws -> ChatGPTOAuthAuthorizationSecrets = ChatGPTOAuthAuthorizationSecrets.generateRandom) {
        self.makeSecrets = makeSecrets
    }

    /// - Parameters:
    ///   - agentHostID: 永続化済みの `urn:uuid:` 形式UUIDv4（小文字の正規形）
    ///   - redirectURI: `http://127.0.0.1:<port>/auth/callback` と完全一致するURL
    func build(agentHostID: String, redirectURI: URL) throws -> ChatGPTOAuthAuthorizationRequest {
        guard Self.isValidAgentHostID(agentHostID) else {
            throw ChatGPTOAuthAuthorizationRequestError.invalidAgentHostID
        }
        guard Self.isValidRedirectURI(redirectURI) else {
            throw ChatGPTOAuthAuthorizationRequestError.invalidRedirectURI
        }

        // 乱数はURL構築の試行ごとに1回だけ取得する（使い回さない）
        let secrets = try makeSecrets()
        guard Self.isValidRandomToken(secrets.state) else {
            throw ChatGPTOAuthAuthorizationRequestError.invalidState
        }
        guard Self.isValidRandomToken(secrets.nonce) else {
            throw ChatGPTOAuthAuthorizationRequestError.invalidNonce
        }
        guard Self.isValidCodeVerifier(secrets.codeVerifier) else {
            throw ChatGPTOAuthAuthorizationRequestError.invalidCodeVerifier
        }
        // 3つは独立した乱数のはずなので、同じ値の使い回しは誤った注入として拒否する
        guard Set([secrets.state, secrets.nonce, secrets.codeVerifier]).count == 3 else {
            throw ChatGPTOAuthAuthorizationRequestError.reusedRandomValue
        }

        // 順序を固定したいので辞書ではなく配列で持つ
        let parameters: [(String, String)] = [
            ("client_id", Self.clientID),
            ("agent_name_hint", Self.agentNameHint),
            ("ext_agent_host_id", agentHostID),
            ("response_type", "code"),
            ("redirect_uri", redirectURI.absoluteString),
            ("scope", Self.scope),
            ("resource", Self.resource),
            ("state", secrets.state),
            ("nonce", secrets.nonce),
            ("code_challenge", Self.codeChallenge(for: secrets.codeVerifier)),
            ("code_challenge_method", "S256"),
        ]
        let query = parameters
            .map { "\(Self.percentEncode($0.0))=\(Self.percentEncode($0.1))" }
            .joined(separator: "&")
        guard let url = URL(string: "\(Self.authorizeEndpoint)?\(query)") else {
            throw ChatGPTOAuthAuthorizationRequestError.urlConstructionFailed
        }

        return ChatGPTOAuthAuthorizationRequest(
            authorizationURL: url,
            redirectURI: redirectURI,
            state: secrets.state,
            nonce: secrets.nonce,
            codeVerifier: secrets.codeVerifier
        )
    }

    // RFC 7636 S256: BASE64URL(SHA256(ASCII(code_verifier)))、paddingなし
    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncodedWithoutPadding(Data(digest))
    }

    static func base64URLEncodedWithoutPadding(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - 検証

    // RFC 3986のunreserved文字（A-Z a-z 0-9 - . _ ~）
    private static let unreservedCharacters: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    private static func consistsOfUnreserved(_ value: String) -> Bool {
        // unicodeScalarsで1文字ずつ判定する（日本語などの非ASCII文字はここで弾かれる）
        value.unicodeScalars.allSatisfy { unreservedCharacters.contains($0) }
    }

    // RFC 7636: 43〜128文字のunreserved文字
    private static func isValidCodeVerifier(_ value: String) -> Bool {
        (43...128).contains(value.unicodeScalars.count) && consistsOfUnreserved(value)
    }

    // state/nonce: Melete側の制約として、256bit乱数相当（43文字）以上・128文字以下のunreserved文字に限る
    private static func isValidRandomToken(_ value: String) -> Bool {
        (43...128).contains(value.unicodeScalars.count) && consistsOfUnreserved(value)
    }

    // 小文字の正規形 `urn:uuid:xxxxxxxx-xxxx-4xxx-[89ab]xxx-xxxxxxxxxxxx` だけを受け付ける
    private static func isValidAgentHostID(_ value: String) -> Bool {
        // "$"は末尾改行の直前にもマッチするため、入力全体の先頭・末尾を表す\A・\zを使う
        let pattern = #"\Aurn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    // scheme・host・port・pathを個別に確認したうえで、正規形の文字列と完全一致することも確認する。
    // 完全一致によりuserinfo・query・fragment・末尾スラッシュ・"049152"のような非正規表記も弾く
    private static func isValidRedirectURI(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http",
              components.host == loopbackHost,
              let port = components.port,
              (1...65535).contains(port),
              components.path == callbackPath else {
            return false
        }
        return url.absoluteString == "http://\(loopbackHost):\(port)\(callbackPath)"
    }

    // MARK: - エンコード

    // unreserved文字以外はすべてpercent-encodeする（スペースは%20、":"や"/"も符号化）
    private static func percentEncode(_ value: String) -> String {
        // 有効なUTF-8文字列ではnilにならない。万一nilでも未エンコードの値は出さず空文字にする
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? ""
    }
}

// エラーには入力値や秘密値を含めない（関連値を持たせない）
enum ChatGPTOAuthAuthorizationRequestError: LocalizedError, Equatable {
    case invalidAgentHostID
    case invalidRedirectURI
    case invalidState
    case invalidNonce
    case invalidCodeVerifier
    case reusedRandomValue
    case randomGenerationFailed
    case urlConstructionFailed

    var errorDescription: String? {
        switch self {
        case .invalidAgentHostID:
            return "エージェントホストIDの形式が無効です。"
        case .invalidRedirectURI:
            return "リダイレクトURIが無効です。"
        case .invalidState:
            return "stateの形式が無効です。"
        case .invalidNonce:
            return "nonceの形式が無効です。"
        case .invalidCodeVerifier:
            return "code verifierの形式が無効です。"
        case .reusedRandomValue:
            return "認可リクエスト用の乱数値が重複しています。"
        case .randomGenerationFailed:
            return "乱数の生成に失敗しました。"
        case .urlConstructionFailed:
            return "認可URLを構築できませんでした。"
        }
    }
}
