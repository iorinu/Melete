import Foundation

// ChatGPT OAuth初回登録のtoken exchange response（authorization_code grant）を検証するだけの純粋な処理。
// ネットワーク通信・URLSession・Keychain・保存・ログは行わず、アプリ本体からもまだ呼び出さない。
// 信頼できる認証機能としては扱わない。
//
// 受け取るresponse（ユーザーが提示した公式SIWC token-referenceに基づく）:
//   HTTP 200, JSON object: access_token, refresh_token, id_token, token_type, expires_in, scope
// ChatGPT planでの推論利用は、token responseのscopeに `chatgpt.tokens.use.direct` があるときだけ許可する。
// scopeの正本はtoken responseだけで、callbackや認可requestの値から補完しない（APIもそれらを受け取らない）。
//
// 返却型 `ChatGPTOAuthAuthorizedTokenCandidate` は、ID tokenの検証成功と
// `chatgpt.tokens.use.direct` scopeの存在が両方揃ったときだけ、このファイル内で生成される。
// 「candidate」は保存・利用の承認前であることを表す。保存やユーザー承認はここでは扱わない。
//
// JSONの解析はこのファイル内の厳格なparser（`StrictJSONParser`）で1回だけ行う。
// JSONSerializationは重複keyを黙って後勝ちにし、UTF-16なども受け付けてしまうため使わない。

// 検証に合格したtoken response。access_token・refresh_tokenは秘密値
struct ChatGPTOAuthAuthorizedTokenCandidate {
    let accessToken: String
    let refreshToken: String
    // ID token検証結果のsub（アカウント識別子）
    let subject: String
    // 固定時刻 now + expires_in
    let expiresAt: Date
    // token responseのscopeを出現順に分割したもの
    let grantedScopes: [String]

    // このファイルの外（テストを含む）からは作れないようにし、検証を経ずに「使える型」が出来ることを防ぐ
    fileprivate init(accessToken: String, refreshToken: String, subject: String, expiresAt: Date, grantedScopes: [String]) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.subject = subject
        self.expiresAt = expiresAt
        self.grantedScopes = grantedScopes
    }
}

// 秘密値・アカウント識別子を含むため、print・dump・デバッガ表示では伏せ字にする
extension ChatGPTOAuthAuthorizedTokenCandidate: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ChatGPTOAuthAuthorizedTokenCandidate(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

enum ChatGPTOAuthTokenResponseParser {
    // response body（UTF-8バイト数）の上限。これを超える入力はJSON解析の前に拒否する
    static let maxBodyLength = 64 * 1024
    // expires_in（秒）の上限。暫定値（30日）。これを超える値は異常として拒否する
    static let maxExpiresInSeconds = 30 * 24 * 60 * 60
    // ChatGPT planでの推論利用を許可するscope
    static let directUseScope = "chatgpt.tokens.use.direct"
    // access_token・refresh_token・id_token 1項目あたりの上限（UTF-8バイト数）
    private static let maxCredentialLength = 16 * 1024
    // scope文字列全体の上限（UTF-8バイト数）
    private static let maxScopeLength = 4096
    // 照合に使うclient_id・nonceの上限（ID token verifierの上限に合わせる）
    private static let maxExpectationLength = 512

    // ID tokenを検証する処理の形。本番では `ChatGPTOpenAIIDTokenVerifier.verify` だけを使う
    typealias IDTokenVerification = (
        _ idToken: String,
        _ jwks: Data,
        _ clientID: String,
        _ nonce: String,
        _ now: Date
    ) throws -> ChatGPTOpenAIIDTokenVerificationResult

    /// - Parameters:
    ///   - statusCode: HTTPのstatus code。200以外はすべて拒否する
    ///   - body: response body（JSON）
    ///   - expectedClientID: callbackで発行されたclient_id（ID tokenのaudと照合する）
    ///   - expectedNonce: authorization requestで送ったnonce
    ///   - jwks: 信頼する公開鍵の集合（JWKSのJSON）
    ///   - now: 期限の計算に使う現在時刻（テストで固定できるよう外から渡す）
    /// - Returns: ID token検証とdirect scopeの確認に両方合格したときだけ返す。それ以外はすべてthrowする
    static func parse(
        statusCode: Int,
        body: Data,
        expectedClientID: String,
        expectedNonce: String,
        jwks: Data,
        now: Date
    ) throws -> ChatGPTOAuthAuthorizedTokenCandidate {
        // 本番の経路では検証処理を差し替えられない
        try parse(
            statusCode: statusCode,
            body: body,
            expectedClientID: expectedClientID,
            expectedNonce: expectedNonce,
            jwks: jwks,
            now: now,
            verifyIDToken: ChatGPTOpenAIIDTokenVerifier.verify
        )
    }

    #if DEBUG
    // test-only。ID token検証を合成のclosureに差し替える。Releaseビルドには存在しない。
    // 実署名の検証は `ChatGPTOpenAIIDTokenVerifierTests` 側で扱い、ここでは接続と結果の扱いだけを確かめる
    static func parseUsingSyntheticIDTokenVerifierForTesting(
        statusCode: Int,
        body: Data,
        expectedClientID: String,
        expectedNonce: String,
        jwks: Data,
        now: Date,
        verifyIDToken: IDTokenVerification
    ) throws -> ChatGPTOAuthAuthorizedTokenCandidate {
        try parse(
            statusCode: statusCode,
            body: body,
            expectedClientID: expectedClientID,
            expectedNonce: expectedNonce,
            jwks: jwks,
            now: now,
            verifyIDToken: verifyIDToken
        )
    }
    #endif

    // 検証処理を受け取る中核はこのファイル内だけに閉じ、外から検証を差し替えられないようにする
    fileprivate static func parse(
        statusCode: Int,
        body: Data,
        expectedClientID: String,
        expectedNonce: String,
        jwks: Data,
        now: Date,
        verifyIDToken: IDTokenVerification
    ) throws -> ChatGPTOAuthAuthorizedTokenCandidate {
        // 1. 照合に使う呼び出し元の値。空・巨大ならどのtokenとも一致させない
        guard isValidExpectation(expectedClientID), isValidExpectation(expectedNonce) else {
            throw ChatGPTOAuthTokenResponseError.invalidExpectation
        }
        // 2. 成功は200だけ。OAuthのerror response（400など）はbodyを読まずに拒否する
        guard statusCode == 200 else { throw ChatGPTOAuthTokenResponseError.unexpectedStatus }
        // 3. 巨大なbodyはJSON解析の前に拒否する
        guard body.count <= maxBodyLength else { throw ChatGPTOAuthTokenResponseError.bodyTooLarge }

        // 4. 厳格なJSON解析。重複keyはescape表記違いも含めて拒否する
        let members: [String: StrictJSONValue]
        do {
            members = try StrictJSONParser.parseTopLevelObject(body)
        } catch StrictJSONParser.Failure.duplicateKey {
            throw ChatGPTOAuthTokenResponseError.duplicateField
        } catch {
            throw ChatGPTOAuthTokenResponseError.malformedBody
        }

        // 5. 各項目の型・形式・上限。ID token検証より前に、安く判定できるものはすべて済ませる
        let accessToken = try validatedCredential(members["access_token"])
        let refreshToken = try validatedCredential(members["refresh_token"])
        let idToken = try validatedCredential(members["id_token"])
        try validateTokenType(members["token_type"])
        let expiresIn = try validatedExpiresIn(members["expires_in"])
        // scopeはtoken responseの値だけを信頼する（callbackや認可requestから補完しない）
        let scopes = try validatedScopes(members["scope"])
        guard scopes.contains(directUseScope) else {
            throw ChatGPTOAuthTokenResponseError.directUseNotGranted
        }

        // 6. ID tokenの検証。元のid_token・JWKS・client_id・nonce・時刻を加工せずに渡す。
        // 検証側のerrorには秘密値が含まれうるので、内容は捨てて1種類のerrorにまとめる
        let verification: ChatGPTOpenAIIDTokenVerificationResult
        do {
            verification = try verifyIDToken(idToken, jwks, expectedClientID, expectedNonce, now)
        } catch {
            throw ChatGPTOAuthTokenResponseError.idTokenRejected
        }
        guard !verification.subject.isEmpty else { throw ChatGPTOAuthTokenResponseError.idTokenRejected }

        // 7. すべての検証に合格したときだけcandidateを作る
        return ChatGPTOAuthAuthorizedTokenCandidate(
            accessToken: accessToken,
            refreshToken: refreshToken,
            subject: verification.subject,
            expiresAt: now.addingTimeInterval(TimeInterval(expiresIn)),
            grantedScopes: scopes
        )
    }

    // MARK: - 各項目の検証

    private static func isValidExpectation(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maxExpectationLength
    }

    // tokenはopaque値として扱う。空でなく、上限以内の可視ASCII（0x21-0x7E）だけ許可する
    private static func validatedCredential(_ value: StrictJSONValue?) throws -> String {
        guard case .string(let text)? = value,
              (1...maxCredentialLength).contains(text.utf8.count),
              text.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            throw ChatGPTOAuthTokenResponseError.invalidField
        }
        return text
    }

    // RFC 6749 §5.1によりtoken_typeは大文字小文字を区別しない。
    // ASCIIの英字だけを小文字に揃えてバイト列で比べ、全角文字などは別の文字として扱う
    private static func validateTokenType(_ value: StrictJSONValue?) throws {
        guard case .string(let text)? = value else { throw ChatGPTOAuthTokenResponseError.invalidField }
        let lowered = text.utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
        guard lowered == Array("bearer".utf8) else { throw ChatGPTOAuthTokenResponseError.unsupportedTokenType }
    }

    // expires_inは整数の秒数だけ受け付ける。数値はparserが字句のまま返すので、
    // 浮動小数点に変換せずに判定でき、3600.5・1e300なども確実に区別できる
    private static func validatedExpiresIn(_ value: StrictJSONValue?) throws -> Int {
        guard case .number(let lexeme)? = value else { throw ChatGPTOAuthTokenResponseError.invalidExpiresIn }
        let isNegative = lexeme.hasPrefix("-")
        let digits = isNegative ? lexeme.dropFirst() : Substring(lexeme)
        // 小数点・指数を含むものは整数ではない
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            throw ChatGPTOAuthTokenResponseError.invalidExpiresIn
        }
        // 負の数と0（-0を含む）は受け取った時点で期限切れ。桁数に関係なく変換せずに判定する
        if isNegative || digits.utf8.allSatisfy({ $0 == 0x30 }) {
            throw ChatGPTOAuthTokenResponseError.expired
        }
        // Intに収まらない値はnilになるので、上限超過と同じく拒否する
        guard let seconds = Int(digits), seconds <= maxExpiresInSeconds else {
            throw ChatGPTOAuthTokenResponseError.invalidExpiresIn
        }
        return seconds
    }

    // scope = scope-token *( SP scope-token )、scope-token = 1*( %x21 / %x23-5B / %x5D-7E )（RFC 6749 §3.3）。
    // 区切りは半角空白1個だけ。重複は意味が曖昧になるので拒否する
    private static func validatedScopes(_ value: StrictJSONValue?) throws -> [String] {
        guard let value else { throw ChatGPTOAuthTokenResponseError.missingScope }
        guard case .string(let text) = value,
              (1...maxScopeLength).contains(text.utf8.count) else {
            throw ChatGPTOAuthTokenResponseError.invalidScope
        }
        // Characterではなくバイト単位で分割する（空白と結合文字が1文字にまとまるのを避ける）
        let parts = text.utf8.split(separator: 0x20, omittingEmptySubsequences: false)
        var scopes: [String] = []
        var seen = Set<String>()
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(isScopeTokenByte) else {
                throw ChatGPTOAuthTokenResponseError.invalidScope
            }
            // 上でASCIIだけと確認済みなので、置換文字は発生しない
            let scope = String(decoding: part, as: UTF8.self)
            guard seen.insert(scope).inserted else { throw ChatGPTOAuthTokenResponseError.invalidScope }
            scopes.append(scope)
        }
        return scopes
    }

    private static func isScopeTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x21, 0x23...0x5B, 0x5D...0x7E: return true
        default: return false
        }
    }
}

// MARK: - 厳格なJSON parser

// 解析結果。数値は丸めずに字句（例: "3600", "1e300"）のまま持つ
fileprivate enum StrictJSONValue {
    case object([String: StrictJSONValue])
    case array([StrictJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

// RFC 8259のJSONだけを受け付ける小さなparser。曖昧な入力はすべて拒否する（fail closed）:
// - bodyは先に厳格なUTF-8としてデコードする（不正なバイト・overlong・BOM付き・UTF-16は拒否）
// - 同じobject内の重複keyは、escapeを解いた後の文字列で判定する（入れ子のobjectも対象）
// - 入れ子の深さに上限を設け、再帰でstackを使い切らないようにする
// - 末尾のゴミ・余分なカンマ・先頭の0・未escapeの制御文字・対になっていないsurrogateは拒否する
fileprivate struct StrictJSONParser {
    enum Failure: Error {
        case malformed
        case duplicateKey
    }

    // token responseは平らなobjectなので、深い入れ子は想定外として拒否する
    static let maxDepth = 32

    private let scalars: [Unicode.Scalar]
    private var index = 0
    // 重複を見つけても最後まで解析し、JSONとして壊れている入力は malformed を優先する
    private var foundDuplicateKey = false

    private init(scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    static func parseTopLevelObject(_ data: Data) throws -> [String: StrictJSONValue] {
        guard let scalars = decodeUTF8Strictly(data) else { throw Failure.malformed }
        var parser = StrictJSONParser(scalars: scalars)
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        // 値の後ろに何か残っていたら（末尾のゴミ・objectの連続など）拒否する
        guard parser.index == scalars.count else { throw Failure.malformed }
        guard case .object(let members) = value else { throw Failure.malformed }
        guard !parser.foundDuplicateKey else { throw Failure.duplicateKey }
        return members
    }

    // String(decoding:as:) は不正なバイトを置換文字に変えてしまうため、1文字ずつ厳格に検査する
    private static func decodeUTF8Strictly(_ data: Data) -> [Unicode.Scalar]? {
        var result: [Unicode.Scalar] = []
        var iterator = data.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                result.append(scalar)
            case .emptyInput:
                return result
            case .error:
                return nil
            }
        }
    }

    // MARK: 値

    private mutating func parseValue(depth: Int) throws -> StrictJSONValue {
        guard index < scalars.count else { throw Failure.malformed }
        switch scalars[index] {
        case "{":
            guard depth < Self.maxDepth else { throw Failure.malformed }
            return try parseObject(depth: depth)
        case "[":
            guard depth < Self.maxDepth else { throw Failure.malformed }
            return try parseArray(depth: depth)
        case "\"":
            return .string(try parseString())
        case "t":
            try expectLiteral("true")
            return .bool(true)
        case "f":
            try expectLiteral("false")
            return .bool(false)
        case "n":
            try expectLiteral("null")
            return .null
        default:
            return .number(try parseNumber())
        }
    }

    private mutating func parseObject(depth: Int) throws -> StrictJSONValue {
        index += 1  // "{"
        var members: [String: StrictJSONValue] = [:]
        skipWhitespace()
        if consume("}") { return .object(members) }
        while true {
            guard index < scalars.count, scalars[index] == "\"" else { throw Failure.malformed }
            let key = try parseString()
            skipWhitespace()
            guard consume(":") else { throw Failure.malformed }
            skipWhitespace()
            let value = try parseValue(depth: depth + 1)
            // Dictionaryのkey比較は正規等価な別表記も同一視するので、重複の判定は広め（安全側）になる。
            // 後勝ち・先勝ちのどちらにも頼らないよう、重複があればbody全体を拒否する
            if members[key] != nil {
                foundDuplicateKey = true
            } else {
                members[key] = value
            }
            skipWhitespace()
            if consume(",") {
                skipWhitespace()
                continue
            }
            guard consume("}") else { throw Failure.malformed }
            return .object(members)
        }
    }

    private mutating func parseArray(depth: Int) throws -> StrictJSONValue {
        index += 1  // "["
        var elements: [StrictJSONValue] = []
        skipWhitespace()
        if consume("]") { return .array(elements) }
        while true {
            elements.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            if consume(",") {
                skipWhitespace()
                continue
            }
            guard consume("]") else { throw Failure.malformed }
            return .array(elements)
        }
    }

    // MARK: 文字列

    private mutating func parseString() throws -> String {
        index += 1  // 開始の "
        var result = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            switch scalar.value {
            case 0x22:  // "
                return String(result)
            case 0x5C:  // \
                result.append(try parseEscape())
            case 0x00...0x1F:
                // 制御文字はescapeしなければならない
                throw Failure.malformed
            default:
                result.append(scalar)
            }
        }
        // 閉じていない文字列
        throw Failure.malformed
    }

    private mutating func parseEscape() throws -> Unicode.Scalar {
        guard index < scalars.count else { throw Failure.malformed }
        let marker = scalars[index]
        index += 1
        switch marker {
        case "\"": return "\""
        case "\\": return "\\"
        case "/": return "/"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "u":
            let unit = try parseHex4()
            switch unit {
            case 0xD800...0xDBFF:
                // 上位surrogateは、直後に \uDC00-\uDFFF が続くときだけ1文字にまとめる
                guard consume("\\"), consume("u") else { throw Failure.malformed }
                let low = try parseHex4()
                guard (0xDC00...0xDFFF).contains(low) else { throw Failure.malformed }
                let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                guard let scalar = Unicode.Scalar(combined) else { throw Failure.malformed }
                return scalar
            case 0xDC00...0xDFFF:
                // 単独の下位surrogate
                throw Failure.malformed
            default:
                guard let scalar = Unicode.Scalar(unit) else { throw Failure.malformed }
                return scalar
            }
        default:
            throw Failure.malformed
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= scalars.count else { throw Failure.malformed }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let digit: UInt32
            switch scalars[index].value {
            case 0x30...0x39: digit = scalars[index].value - 0x30        // 0-9
            case 0x41...0x46: digit = scalars[index].value - 0x41 + 10   // A-F
            case 0x61...0x66: digit = scalars[index].value - 0x61 + 10   // a-f
            default: throw Failure.malformed
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    // MARK: 数値・リテラル

    // number = [ "-" ] int [ frac ] [ exp ]、int = "0" / ( 1-9 *DIGIT )。字句をそのまま返す
    private mutating func parseNumber() throws -> String {
        let start = index
        _ = consume("-")
        // 整数部が "0" ならそこで終わる（"0123" は後続の "1" が区切り文字でないため呼び出し側で拒否される）
        if !consume("0") {
            guard isDigit(at: index) else { throw Failure.malformed }
            skipDigits()
        }
        if consume(".") {
            guard isDigit(at: index) else { throw Failure.malformed }
            skipDigits()
        }
        let hasExponent = consume("e") ? true : consume("E")
        if hasExponent {
            if !consume("+") { _ = consume("-") }
            guard isDigit(at: index) else { throw Failure.malformed }
            skipDigits()
        }
        var lexeme = String.UnicodeScalarView()
        lexeme.append(contentsOf: scalars[start..<index])
        return String(lexeme)
    }

    private mutating func expectLiteral(_ literal: String) throws {
        for expected in literal.unicodeScalars {
            guard consume(expected) else { throw Failure.malformed }
        }
    }

    // MARK: 低レベルの読み取り

    private func isDigit(at position: Int) -> Bool {
        position < scalars.count && (0x30...0x39).contains(scalars[position].value)
    }

    private mutating func skipDigits() {
        while isDigit(at: index) { index += 1 }
    }

    // JSONの空白は space・tab・LF・CR の4種類だけ（NBSPやBOMは含まない）
    private mutating func skipWhitespace() {
        while index < scalars.count {
            switch scalars[index].value {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    // 次の文字が期待どおりなら1文字進めてtrueを返す
    private mutating func consume(_ expected: Unicode.Scalar) -> Bool {
        guard index < scalars.count, scalars[index] == expected else { return false }
        index += 1
        return true
    }
}

// エラーには入力値や秘密値を含めない（関連値を持たせない）
enum ChatGPTOAuthTokenResponseError: LocalizedError, Equatable {
    // 照合に使うclient_id・nonceが空、または上限超過
    case invalidExpectation
    // HTTP statusが200ではない
    case unexpectedStatus
    // bodyが上限を超えている
    case bodyTooLarge
    // bodyがUTF-8のJSON objectとして読めない（空・配列・末尾のゴミなどを含む）
    case malformedBody
    // 最上位に同じkeyが複数ある（escape表記違いの同じkeyを含む）
    case duplicateField
    // access_token・refresh_token・id_token・token_typeが無い、型が違う、空、上限超過、可視ASCII以外を含む
    case invalidField
    // token_typeがBearerではない
    case unsupportedTokenType
    // expires_inが無い、整数でない、真偽値・文字列、上限超過
    case invalidExpiresIn
    // expires_inが0以下（受け取った時点で期限切れ）
    case expired
    // ID tokenの検証に失敗した（検証側のエラー内容は表に出さない）
    case idTokenRejected
    // scopeが無い
    case missingScope
    // scopeの形式が不正（型違い・空・区切りの異常・使えない文字・重複）
    case invalidScope
    // scopeに `chatgpt.tokens.use.direct` が無いので、ChatGPT planでの推論利用は許可しない
    case directUseNotGranted

    var errorDescription: String? {
        switch self {
        case .invalidExpectation:
            return "照合に使う値が無効です。"
        case .unexpectedStatus:
            return "token responseのstatusが想定外です。"
        case .bodyTooLarge:
            return "token responseが大きすぎます。"
        case .malformedBody:
            return "token responseの形式が無効です。"
        case .duplicateField:
            return "token responseに重複した項目があります。"
        case .invalidField:
            return "token responseの項目が無効です。"
        case .unsupportedTokenType:
            return "token_typeが対応していない種類です。"
        case .invalidExpiresIn:
            return "expires_inが無効です。"
        case .expired:
            return "tokenの有効期限が切れています。"
        case .idTokenRejected:
            return "ID tokenを検証できませんでした。"
        case .missingScope:
            return "scopeがありません。"
        case .invalidScope:
            return "scopeの形式が無効です。"
        case .directUseNotGranted:
            return "ChatGPTプランでの利用が許可されていません。"
        }
    }
}
