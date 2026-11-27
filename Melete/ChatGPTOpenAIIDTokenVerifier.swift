import Foundation
import JOSESwift
import Security

// OpenAI（Sign in with ChatGPT）のID token（RS256のcompact JWT）を、渡されたJWKSで検証するためのAPI。
// 署名の検証そのものはJOSESwift（JWS + RSAPublicKey + Verifier）に任せ、
// その前後の形式・鍵・claimsの検証をここで厳格に行う。
// ネットワーク通信（JWKSの取得）・Keychain・保存・ログ出力は行わず、他の認証処理からもまだ呼び出さない。
//
// 注意: この関数が成功しても「ChatGPTのtokenを使ってよい」ことまでは保証しない。
// 初回sign-inで利用する前に、呼び出し側が別途token responseのauthorized scopeに
// `chatgpt.tokens.use.direct` が含まれることを確認する責務を負う。

// 検証に合格したID tokenから取り出す値。アカウントの識別に必要なsubだけを返す
struct ChatGPTOpenAIIDTokenVerificationResult {
    let subject: String
}

// subはアカウント識別子なので、print・dump・デバッガ表示では伏せ字にする
extension ChatGPTOpenAIIDTokenVerificationResult: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ChatGPTOpenAIIDTokenVerificationResult(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["subject": "<redacted>"], displayStyle: .struct)
    }
}

enum ChatGPTOpenAIIDTokenVerifier {
    // OpenAIのdiscovery（issuer・id_token_signing_alg_values_supported=[RS256]）に合わせた固定値
    private static let expectedIssuer = "https://auth.openai.com"
    private static let expectedAlgorithm = "RS256"

    // 端末とサーバーの時計のずれとして許容する幅（秒）。小さい固定値にしておく
    private static let clockSkew: TimeInterval = 5

    // 解析する入力の上限。巨大な入力でメモリや時間を使い切らないようにする
    private static let maxTokenLength = 16 * 1024
    private static let maxJWKSLength = 64 * 1024
    private static let maxKeyCount = 16
    private static let maxKeyIDLength = 256
    private static let maxSubjectLength = 255
    private static let maxInputLength = 512

    // RSA鍵の強度の範囲（bit）。下限未満は弱すぎ、上限超えは想定外として拒否する
    private static let minimumModulusBits = 2048
    private static let maximumModulusBits = 8192

    // 公開鍵の集合に入っていてはいけない秘密鍵・共有鍵の要素（RFC 7518 §6.3.2, §6.4）
    private static let privateKeyMembers: Set<String> = ["d", "p", "q", "dp", "dq", "qi", "oth", "k"]

    /// - Parameters:
    ///   - token: token responseで受け取ったID token（compact JWT）
    ///   - jwks: 信頼する公開鍵の集合（JWKSのJSON）
    ///   - clientID: 今回発行されたclient_id（audと照合する）
    ///   - nonce: authorization requestで送ったnonce
    ///   - now: 期限の判定に使う現在時刻（テストで固定できるよう外から渡す）
    /// - Returns: 検証に合格したときだけ結果を返す。それ以外はすべてthrowする
    /// - Important: 成功しても利用許可済みとは扱わない。`chatgpt.tokens.use.direct` のscope確認は呼び出し側で別途行う
    static func verify(
        token: String,
        jwks: Data,
        clientID: String,
        nonce: String,
        now: Date
    ) throws -> ChatGPTOpenAIIDTokenVerificationResult {
        // 照合に使う側の値が空・巨大なら、どのtokenとも一致させない
        guard !clientID.isEmpty, clientID.utf8.count <= maxInputLength else {
            throw ChatGPTOpenAIIDTokenError.invalidAudience
        }
        guard !nonce.isEmpty, nonce.utf8.count <= maxInputLength else {
            throw ChatGPTOpenAIIDTokenError.invalidNonce
        }

        // 1. compact JWTの形（header.payload.signature）だけを確認する
        let segments = try splitCompactJWT(token)

        // 2. headerを読み、alg=RS256固定・kid必須を確認する（この時点のheaderはまだ信頼しない）
        let keyID = try validatedKeyID(fromHeaderSegment: segments.header)

        // 3. JWKSからkidが一致する鍵をちょうど1件選び、署名検証用の安全なRSA公開鍵か確認する
        let publicKey = try trustedPublicKey(keyID: keyID, jwks: jwks)

        // 4. 署名の検証はJOSESwiftに任せる。ここを通過するまでpayloadは一切読まない
        try verifySignature(token: token, publicKey: publicKey)

        // 5. 署名が正しいと分かった後に限り、claimsを読んで検証する
        let claims = try decodeJSONObject(segments.payload)
        return try validatedResult(claims: claims, clientID: clientID, nonce: nonce, now: now)
    }

    // MARK: - JWTの形式

    private static func splitCompactJWT(_ token: String) throws -> (header: Data, payload: Data) {
        guard token.utf8.count <= maxTokenLength else { throw ChatGPTOpenAIIDTokenError.malformedToken }
        // omittingEmptySubsequences: false にしないと、空のセグメントが消えて数え間違える
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let header = base64URLDecode(parts[0]),
              let payload = base64URLDecode(parts[1]),
              !header.isEmpty, !payload.isEmpty else {
            throw ChatGPTOpenAIIDTokenError.malformedToken
        }
        // 署名セグメントは空でも形式上はここを通す（alg=noneを「未対応alg」として拒否するため）。
        // 中身の検証はJOSESwiftで行う
        guard parts[2].allSatisfy(isBase64URLCharacter) else {
            throw ChatGPTOpenAIIDTokenError.malformedToken
        }
        return (header, payload)
    }

    private static func validatedKeyID(fromHeaderSegment data: Data) throws -> String {
        let header = try decodeJSONObject(data)
        // alg=none・HS256などはここで拒否する。公開鍵をHMACの鍵として使うalgorithm confusionを防ぐ
        guard let algorithm = header["alg"] as? String, constantTimeEquals(algorithm, expectedAlgorithm) else {
            throw ChatGPTOpenAIIDTokenError.unsupportedAlgorithm
        }
        // critは「理解できない拡張があれば拒否せよ」という指定。対応している拡張は無いので拒否する
        guard header["crit"] == nil else { throw ChatGPTOpenAIIDTokenError.malformedToken }
        // jku・x5u・jwkなどheader内の鍵情報は使わない。信頼する鍵は引数のJWKSだけ
        guard let keyID = header["kid"] as? String,
              !keyID.isEmpty, keyID.utf8.count <= maxKeyIDLength else {
            throw ChatGPTOpenAIIDTokenError.untrustedKey
        }
        return keyID
    }

    // MARK: - JWKSと鍵

    private static func trustedPublicKey(keyID: String, jwks: Data) throws -> SecKey {
        guard !jwks.isEmpty, jwks.count <= maxJWKSLength,
              let object = try? JSONSerialization.jsonObject(with: jwks),
              let set = object as? [String: Any],
              let keys = set["keys"] as? [[String: Any]],
              !keys.isEmpty, keys.count <= maxKeyCount else {
            throw ChatGPTOpenAIIDTokenError.untrustedKey
        }
        // 公開鍵の集合に秘密鍵・共有鍵の要素が混ざっているJWKSは、作り方がおかしいので全体を信頼しない
        // メンバー名もUTF-8のバイト列で照合する（Stringの==やSetは正規等価な別表記も同一視するため）
        let privateKeyMemberBytes = Set(privateKeyMembers.map { Array($0.utf8) })
        guard keys.allSatisfy({ jwk in
            jwk.keys.allSatisfy { !privateKeyMemberBytes.contains(Array($0.utf8)) }
        }) else {
            throw ChatGPTOpenAIIDTokenError.untrustedKey
        }
        // 同じkidが複数あると、どの鍵で検証したのかが曖昧になるので拒否する。
        // kidはRFC 7515 §4.1.4により完全一致で照合するので、Unicode正規化はせずバイト列で比べる
        let matches = keys.filter { jwk in
            guard let candidate = jwk["kid"] as? String else { return false }
            return constantTimeEquals(candidate, keyID)
        }
        guard matches.count == 1, let jwk = matches.first else {
            throw ChatGPTOpenAIIDTokenError.untrustedKey
        }
        try validateKeyUsage(jwk)
        return try rsaPublicKey(from: jwk)
    }

    // 鍵の種類・用途の指定が「RS256の署名検証用」と矛盾しないことを確認する
    private static func validateKeyUsage(_ jwk: [String: Any]) throws {
        guard let keyType = jwk["kty"] as? String, constantTimeEquals(keyType, "RSA") else {
            throw ChatGPTOpenAIIDTokenError.untrustedKey
        }
        // alg・use・key_opsは省略可能。ただし書かれているなら署名検証用でなければならない
        if let algorithm = jwk["alg"] {
            guard let value = algorithm as? String, constantTimeEquals(value, expectedAlgorithm) else {
                throw ChatGPTOpenAIIDTokenError.untrustedKey
            }
        }
        if let use = jwk["use"] {
            guard let value = use as? String, constantTimeEquals(value, "sig") else {
                throw ChatGPTOpenAIIDTokenError.untrustedKey
            }
        }
        // JOSESwiftはkey_opsを見ないので、ここで確認する。
        // 公開鍵でできる署名関連の操作はverifyだけなので、それ以外（sign・encrypt・wrapKeyなど）が混ざっていたら拒否する
        if let operations = jwk["key_ops"] {
            guard let list = operations as? [String],
                  !list.isEmpty,
                  // 重複の判定もバイト列で行う（Set<String>は正規等価な別表記を同じ要素とみなすため）
                  Set(list.map { Array($0.utf8) }).count == list.count,
                  list.allSatisfy({ constantTimeEquals($0, "verify") }) else {
                throw ChatGPTOpenAIIDTokenError.untrustedKey
            }
        }
    }

    private static func rsaPublicKey(from jwk: [String: Any]) throws -> SecKey {
        guard let modulusString = jwk["n"] as? String,
              let exponentString = jwk["e"] as? String,
              let modulus = base64URLDecode(Substring(modulusString)),
              let exponent = base64URLDecode(Substring(exponentString)),
              isAcceptableModulus(modulus),
              isAcceptableExponent(exponent) else {
            throw ChatGPTOpenAIIDTokenError.untrustedKey
        }
        do {
            // 検証済みのn・eだけでJWKを組み立て直し、それ以外のメンバーはJOSESwiftに渡さない
            let key = RSAPublicKey(modulus: modulusString, exponent: exponentString)
            return try key.converted(to: SecKey.self)
        } catch {
            // ライブラリのエラー内容には鍵の情報が含まれうるので、表に出さない
            throw ChatGPTOpenAIIDTokenError.untrustedKey
        }
    }

    // nは符号なし整数のbig-endian表現。RFC 7518 §6.3.1.1により先頭に0x00を付けてはいけない
    private static func isAcceptableModulus(_ modulus: Data) -> Bool {
        guard let first = modulus.first, first != 0 else { return false }
        // 先頭バイトの使われているbit数 + 残りのバイト数×8 が鍵長
        let bits = (modulus.count - 1) * 8 + (8 - first.leadingZeroBitCount)
        return (minimumModulusBits...maximumModulusBits).contains(bits)
    }

    // eは奇数で3以上、4バイト以下（一般的な65537など）に限る
    private static func isAcceptableExponent(_ exponent: Data) -> Bool {
        guard let first = exponent.first, first != 0, exponent.count <= 4 else { return false }
        let value = exponent.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return value >= 3 && value % 2 == 1
    }

    // MARK: - 署名

    private static func verifySignature(token: String, publicKey: SecKey) throws {
        // 失敗の理由（形式・鍵・署名の不一致）はどれも「署名を確認できなかった」として同じ扱いにする
        guard let jws = try? JWS(compactSerialization: token),
              let verifier = Verifier(signatureAlgorithm: .RS256, key: publicKey),
              jws.isValid(for: verifier) else {
            throw ChatGPTOpenAIIDTokenError.invalidSignature
        }
    }

    // MARK: - claims（署名検証の後でだけ呼ぶ）

    private static func validatedResult(
        claims: [String: Any],
        clientID: String,
        nonce: String,
        now: Date
    ) throws -> ChatGPTOpenAIIDTokenVerificationResult {
        guard let issuer = claims["iss"] as? String, constantTimeEquals(issuer, expectedIssuer) else {
            throw ChatGPTOpenAIIDTokenError.invalidIssuer
        }
        try validateAudience(claims, clientID: clientID)

        let current = now.timeIntervalSince1970
        // exp: 期限を過ぎていたら拒否する。許容幅の分だけ猶予する
        guard let expiration = numericDate(claims["exp"]) else { throw ChatGPTOpenAIIDTokenError.invalidClaims }
        guard current < expiration + clockSkew else { throw ChatGPTOpenAIIDTokenError.expired }
        // iat: 未来に発行されたtokenや、期限より後に発行されたtokenは不自然なので拒否する
        guard let issuedAt = numericDate(claims["iat"]) else { throw ChatGPTOpenAIIDTokenError.invalidClaims }
        guard issuedAt <= current + clockSkew, issuedAt <= expiration else {
            throw ChatGPTOpenAIIDTokenError.invalidIssuedAt
        }
        // nbfは任意。あるなら、その時刻より前は無効
        if let notBeforeValue = claims["nbf"] {
            guard let notBefore = numericDate(notBeforeValue) else { throw ChatGPTOpenAIIDTokenError.invalidClaims }
            guard current + clockSkew >= notBefore else { throw ChatGPTOpenAIIDTokenError.invalidIssuedAt }
        }

        guard let tokenNonce = claims["nonce"] as? String,
              constantTimeEquals(tokenNonce, nonce) else {
            throw ChatGPTOpenAIIDTokenError.invalidNonce
        }

        // sub: 空・255 byte超え・可視ASCII（0x21...0x7e）以外を含むものは拒否する。
        // OIDCのsubは255 ASCII文字以内と定められているので非ASCIIの拒否はそれと整合する。
        // 空白や制御文字も識別子として扱うと危ないので、ここでは保守的に明示的に拒否する。
        // これはこのアプリ独自の局所的な制約で、現行のOpenAIの仕様を保証するものではない
        guard let subject = claims["sub"] as? String,
              !subject.isEmpty, subject.utf8.count <= maxSubjectLength,
              subject.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw ChatGPTOpenAIIDTokenError.invalidClaims
        }
        return ChatGPTOpenAIIDTokenVerificationResult(subject: subject)
    }

    // audは文字列か文字列の配列（OIDC Core §2, §3.1.3.7）
    private static func validateAudience(_ claims: [String: Any], clientID: String) throws {
        let audiences: [String]
        if let single = claims["aud"] as? String {
            audiences = [single]
        } else if let list = claims["aud"] as? [String], !list.isEmpty {
            audiences = list
        } else {
            throw ChatGPTOpenAIIDTokenError.invalidAudience
        }
        // aud・azpは識別子なので、Unicode正規化はせずバイト列の完全一致で照合する
        guard audiences.contains(where: { constantTimeEquals($0, clientID) }) else {
            throw ChatGPTOpenAIIDTokenError.invalidAudience
        }
        // 複数のaudienceがあるときは、azpで「誰に向けて発行したか」が自分であることも確認する
        if let authorizedParty = claims["azp"] {
            guard let value = authorizedParty as? String, constantTimeEquals(value, clientID) else {
                throw ChatGPTOpenAIIDTokenError.invalidAudience
            }
        } else if audiences.count > 1 {
            throw ChatGPTOpenAIIDTokenError.invalidAudience
        }
    }

    // NumericDate（1970年からの秒数）。JSONSerializationではtrue/falseもNSNumberになるので除外する
    private static func numericDate(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    // セキュリティ上の識別子（kid・aud・azp・iss・alg・nonceなど）の比較に使う。
    // Stringの==はUnicodeの正規等価（NFC/NFDの違いなど）を同一視するので使わず、
    // 正規化せずにUTF-8のバイト列が完全に一致するときだけtrueを返す。
    // 一致しない位置によって処理時間が変わらないよう、最後まで比較する
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    // MARK: - base64url・JSON

    private static func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw ChatGPTOpenAIIDTokenError.malformedToken
        }
        return dictionary
    }

    private static func isBase64URLCharacter(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        switch ascii {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }

    // base64url（RFC 4648 §5）をpaddingなしで厳格に読む。
    // 同じバイト列に複数の書き方ができないよう、再エンコードして元の文字列と一致するものだけ受け付ける
    private static func base64URLDecode(_ string: Substring) -> Data? {
        guard !string.isEmpty, string.allSatisfy(isBase64URLCharacter), string.count % 4 != 1 else {
            return nil
        }
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        let canonical = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return canonical == string ? data : nil
    }
}

// エラーには入力値や秘密値を含めない（関連値を持たせない）
enum ChatGPTOpenAIIDTokenError: Error, Equatable {
    // compact JWTやheader・payloadのJSONとして読めない
    case malformedToken
    // RS256以外のalg（none・HS256など）
    case unsupportedAlgorithm
    // headerのkidに対応する鍵がJWKSに無い、または署名検証用として安全な鍵ではない
    case untrustedKey
    // 署名が鍵と一致しない
    case invalidSignature
    // issがOpenAIのissuerと一致しない
    case invalidIssuer
    // audが今回のclient_idと一致しない
    case invalidAudience
    // nonceがauthorization requestで送った値と一致しない
    case invalidNonce
    // expを過ぎている
    case expired
    // iat・nbfが現在時刻やexpと矛盾する
    case invalidIssuedAt
    // 必須のclaims（exp・iat・sub）が無い、型が違う、またはsubの形式が不正
    case invalidClaims
}
