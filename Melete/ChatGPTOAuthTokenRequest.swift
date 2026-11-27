import Foundation

// ChatGPT OAuth初回登録のtoken exchange request（authorization_code grant）を組み立てるだけの純粋な処理。
// ネットワーク通信・URLSession・Keychain・保存・ログは行わず、アプリ本体からもまだ呼び出さない。
// 信頼できる認証機能としては扱わない。
//
// 組み立てるrequest（ユーザーが提示した公式SIWCの仕様に基づく）:
//   POST https://auth.openai.com/api/accounts/oauth/token
//   Content-Type: application/x-www-form-urlencoded（client secretは送らない）
//   body: grant_type=authorization_code, client_id（callbackで発行されたもの）, code, code_verifier,
//         redirect_uri（認可時と完全同一）, resource=https://api.openai.com/v1 の6項目だけ
// 判定順: redirect URI → code verifier → 認可URLとの紐付け → code → client_id
//
// このbuilderが保証しないこと（今後の呼び出し側の責任）:
// - `ChatGPTOAuthCallbackResult` を受け取っても、それが「この認可requestのstateで検証済み」だとは限らない。
//   型はcodeとclient_idを持つだけで、どのexpectationで検証したかの情報を持たないため、
//   callbackの検証（state照合など）とこのbuilderを同じ認可試行で結び付けるのは呼び出し側で行う
// - code・code_verifier・stateは1回の認可試行で1回だけ使う。使用済みかどうかの管理はここでは行わない
// - 送信・token responseの検証・token保存は別の段階で扱う

// 組み立て結果。body・headersに秘密値（code・code_verifier・client_id）を含む
struct ChatGPTOAuthTokenRequest {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data
}

// bodyに秘密値を含むため、print・dump・デバッガ表示では伏せ字にする
extension ChatGPTOAuthTokenRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ChatGPTOAuthTokenRequest(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

enum ChatGPTOAuthTokenRequestBuilder {
    // 固定値（外部から差し替えない）
    private static let tokenEndpoint = "https://auth.openai.com/api/accounts/oauth/token"
    private static let resource = "https://api.openai.com/v1"
    private static let loopbackHost = "127.0.0.1"
    private static let callbackPath = "/auth/callback"
    // 認可URLが公式のauthorize endpointを指していることの確認に使う
    private static let authorizeScheme = "https"
    private static let authorizeHost = "auth.openai.com"
    private static let authorizePath = "/api/accounts/authorize"
    // 認可URL全体（UTF-8バイト数）の上限。これを超える入力はquery解析の前に拒否する
    private static let maxAuthorizationURLLength = 8192
    // 初回登録requestで使うプレースホルダ。発行済みのclient_idではないので送らない
    private static let registrationPlaceholderClientID = "dynamic_agent_client"

    /// - Parameters:
    ///   - authorization: 認可時に組み立てたrequest。redirect URIとcode verifierはここからだけ取る
    ///   - callback: 検査に合格したcallbackの結果。codeと、callbackで発行されたclient_idを取る
    /// - Returns: 検査に合格したときだけrequestを返す。それ以外はすべてthrowする
    static func build(
        authorization: ChatGPTOAuthAuthorizationRequest,
        callback: ChatGPTOAuthCallbackResult
    ) throws -> ChatGPTOAuthTokenRequest {
        // 1. redirect URIは認可時と完全に同じ正規形の文字列でなければならない
        guard let redirectURI = canonicalRedirectURI(authorization.redirectURI) else {
            throw ChatGPTOAuthTokenRequestError.invalidRedirectURI
        }

        // 2. code verifierの形式（RFC 7636）
        let verifier = authorization.codeVerifier
        guard isValidCodeVerifier(verifier) else {
            throw ChatGPTOAuthTokenRequestError.invalidCodeVerifier
        }

        // 3. 認可URLに実際に載せたredirect_uri・code_challengeと対応しているか。
        //    構造体のフィールドだけ差し替えられた（紐付けの壊れた）requestをここで弾く
        guard matchesAuthorizationURL(authorization.authorizationURL, redirectURI: redirectURI, verifier: verifier) else {
            throw ChatGPTOAuthTokenRequestError.mismatchedAuthorization
        }

        // 4. code（callback validatorと同じ制約をもう一度確認する。呼び出し側を信用しきらない）
        guard isValidOpaqueValue(callback.code, maxLength: ChatGPTOAuthCallbackValidator.maxCodeLength) else {
            throw ChatGPTOAuthTokenRequestError.invalidCode
        }

        // 5. client_id（callbackで発行されたもの。初回登録用のプレースホルダは拒否）
        guard isValidOpaqueValue(callback.clientID, maxLength: ChatGPTOAuthCallbackValidator.maxClientIDLength),
              callback.clientID != registrationPlaceholderClientID else {
            throw ChatGPTOAuthTokenRequestError.invalidClientID
        }

        guard let url = URL(string: tokenEndpoint) else {
            throw ChatGPTOAuthTokenRequestError.urlConstructionFailed
        }

        // 順序を固定したいので辞書ではなく配列で持つ。stateやnonce・scopeなど余計な値は送らない
        let parameters: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("client_id", callback.clientID),
            ("code", callback.code),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI),
            ("resource", resource),
        ]
        let body = parameters
            .map { "\(formEncode($0.0))=\(formEncode($0.1))" }
            .joined(separator: "&")

        return ChatGPTOAuthTokenRequest(
            url: url,
            method: "POST",
            // client secretは使わないのでAuthorizationヘッダは付けない
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8)
        )
    }

    // MARK: - 検証

    // `http://127.0.0.1:<port>/auth/callback` の正規形と完全一致するときだけ、その文字列を返す。
    // 完全一致によりuserinfo・query・fragment・末尾スラッシュ・"049152"のような非正規表記も弾く
    private static func canonicalRedirectURI(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http",
              components.host == loopbackHost,
              let port = components.port,
              (1...65535).contains(port),
              components.path == callbackPath else {
            return nil
        }
        let canonical = "http://\(loopbackHost):\(port)\(callbackPath)"
        return url.absoluteString == canonical ? canonical : nil
    }

    // RFC 7636: 43〜128文字のunreserved文字
    private static func isValidCodeVerifier(_ value: String) -> Bool {
        (43...128).contains(value.unicodeScalars.count)
            && value.unicodeScalars.allSatisfy { isUnreserved($0.value) }
    }

    // 認可URLが公式のauthorize endpointで、redirect_uri・code_challenge・code_challenge_methodが
    // それぞれ1個だけ存在し、今回送る値と対応しているかを確認する
    private static func matchesAuthorizationURL(_ url: URL, redirectURI: String, verifier: String) -> Bool {
        // 相対URL（baseURLあり）は解決後の形が呼び出し側の基準URLに左右されるので拒否する
        guard url.baseURL == nil else { return false }
        let raw = url.absoluteString
        // 過大な入力ではqueryItemsの解析自体を避ける。正規builderの出力は1KB未満なので十分な余裕がある
        guard raw.utf8.count <= maxAuthorizationURLLength else { return false }
        // 文字列として `https://auth.openai.com/api/accounts/authorize?<query>` の形だけを許す。
        // authorityが固定文字列と一致するので、userinfo（空の "@" や ":pass@" も含む）・port・
        // host末尾のドットはここで弾ける。fragmentは空の "#" も含めて "#" 自体を許さない
        let prefix = "\(authorizeScheme)://\(authorizeHost)\(authorizePath)?"
        guard raw.hasPrefix(prefix),
              raw.utf8.count > prefix.utf8.count,
              !raw.contains("#") else {
            return false
        }
        // 文字列検査に加え、構造としても同じ結論になることを確認する（念のための二重化）
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == authorizeScheme,
              components.percentEncodedUser == nil,
              components.percentEncodedPassword == nil,
              components.host == authorizeHost,
              components.port == nil,
              components.path == authorizePath,
              components.percentEncodedFragment == nil,
              let items = components.queryItems else {
            return false
        }
        // 同じkeyが複数あると、どちらが使われたか曖昧になるので不一致として扱う
        func singleValue(_ name: String) -> String? {
            let values = items.filter { $0.name == name }
            guard values.count == 1 else { return nil }
            return values[0].value
        }
        guard let urlRedirect = singleValue("redirect_uri"),
              let urlChallenge = singleValue("code_challenge"),
              let urlMethod = singleValue("code_challenge_method") else {
            return false
        }
        return urlRedirect == redirectURI
            && urlMethod == "S256"
            && urlChallenge == ChatGPTOAuthAuthorizationRequestBuilder.codeChallenge(for: verifier)
    }

    // codeとissued client_idはopaque値として扱う。空でなく、上限以内の可視ASCII（0x21-0x7E）だけ許可する
    private static func isValidOpaqueValue(_ value: String, maxLength: Int) -> Bool {
        let scalars = value.unicodeScalars
        return (1...maxLength).contains(scalars.count)
            && scalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    // RFC 3986のunreserved文字（A-Z a-z 0-9 - . _ ~）
    private static func isUnreserved(_ value: UInt32) -> Bool {
        switch value {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39: return true
        case 0x2D, 0x2E, 0x5F, 0x7E: return true   // - . _ ~
        default: return false
        }
    }

    // MARK: - エンコード

    private static let upperHexDigits = Array("0123456789ABCDEF")

    // unreserved文字以外はすべてUTF-8のバイト単位で "%XX"（大文字16進）にする。
    // "+" をspaceとして使わず、"&" "=" "%" なども必ず符号化するので、受け側で区切りを誤解されない。
    // Foundationの関数はOptionalを返すため、失敗時の扱いを考えずに済むよう自前で1バイトずつ変換する
    private static func formEncode(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            if isUnreserved(UInt32(byte)) {
                encoded.append(Character(Unicode.Scalar(byte)))
            } else {
                // 上位4bitと下位4bitをそれぞれ16進1桁にする
                encoded.append("%")
                encoded.append(upperHexDigits[Int(byte >> 4)])
                encoded.append(upperHexDigits[Int(byte & 0x0F)])
            }
        }
        return encoded
    }
}

// エラーには入力値や秘密値を含めない（関連値を持たせない）
enum ChatGPTOAuthTokenRequestError: LocalizedError, Equatable {
    // RED段階のstubで使っていた値。buildからはもう投げないが、テストが「stubのままではない」ことの
    // 確認に参照しているため残している
    case notImplemented
    // redirect URIが `http://127.0.0.1:<port>/auth/callback` の正規形ではない
    case invalidRedirectURI
    // code verifierがRFC 7636の形式（43〜128文字のunreserved文字）ではない
    case invalidCodeVerifier
    // redirect URI・code verifierが認可URL（redirect_uri・code_challenge）と対応しない
    case mismatchedAuthorization
    // codeが空・上限超過・可視ASCII以外を含む
    case invalidCode
    // client_idが空・上限超過・可視ASCII以外を含む、または初回登録用のプレースホルダ
    case invalidClientID
    // 固定のtoken endpointからURLを作れなかった（通常は起きない）
    case urlConstructionFailed

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "token requestの構築は未実装です。"
        case .invalidRedirectURI:
            return "リダイレクトURIが無効です。"
        case .invalidCodeVerifier:
            return "code verifierの形式が無効です。"
        case .mismatchedAuthorization:
            return "認可リクエストと対応していません。"
        case .invalidCode:
            return "認可コードの形式が無効です。"
        case .invalidClientID:
            return "client_idの形式が無効です。"
        case .urlConstructionFailed:
            return "token endpointのURLを構築できませんでした。"
        }
    }
}
