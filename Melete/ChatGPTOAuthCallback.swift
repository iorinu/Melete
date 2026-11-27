import Foundation

// ChatGPT OAuth初回登録のcallback URL（http://127.0.0.1:<port>/auth/callback?...）を
// 文字列のまま受け取り、純粋に検査するためのAPI。
// ネットワーク通信・listener・ブラウザ・Keychain・保存は行わず、アプリ本体からもまだ呼び出さない。
// callbackのscopeは許可判定に使わない（後段のtoken responseのscopeを正本とする）。
// 未認識の応答パラメータは、構文検査に通った上で無視する（RFC 6749 4.1.2）。
// 判定順: expectation → 全体の長さ → redirect URI → queryの分解（encoding） → state
//         → query構造（scope等の重複） → iss → error → code → client_id
//
// 検査は2段階に分かれる:
// - verifyState: stateの一意一致までを確かめ、合格したときだけ ChatGPTOAuthStateVerifiedCallback を返す。
//   ここでthrowした場合（構文エラーを含む）は「stateが一致したと確認できていない」ことを意味し、
//   呼び出し側（listenerの配送枠・Attempt）はこの応答で何も消費してはいけない
// - validateResponse: state一致を確認済みの応答だけを受け取り、残りを検査する。
//   ここでのthrowは「正しいstateを持つ応答が不正だった」ことを意味する

// 検査の基準になる値。authorization request構築時に使ったredirect URIとstateを渡す
struct ChatGPTOAuthCallbackExpectation {
    let redirectURI: URL
    let state: String
}

// stateを含むため、print・dump・デバッガ表示では伏せ字にする
extension ChatGPTOAuthCallbackExpectation: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ChatGPTOAuthCallbackExpectation(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

// 検査に合格したcallbackから取り出す値。token exchangeに渡すcodeと、callbackで通知されたclient_id
struct ChatGPTOAuthCallbackResult {
    let code: String
    let clientID: String
}

// codeとclient_idは秘密値として扱う。項目名は残し、値だけを伏せ字にする
extension ChatGPTOAuthCallbackResult: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ChatGPTOAuthCallbackResult(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["code": "<redacted>", "clientID": "<redacted>"], displayStyle: .struct)
    }
}

// stateが期待値とちょうど1個だけ一致したことを、validatorが確認済みのcallback。
// initはこのファイル内（validator）からしか呼べないため、この型の値を持っていること自体が
// 「state照合に成功した」という証拠になる。listener・Attemptはこれを受け取ってから枠や試行を消費する
struct ChatGPTOAuthStateVerifiedCallback {
    // デコード済みのパラメータ（code・client_id等の秘密値を含む）。外からは読ませない
    fileprivate let parameters: [ChatGPTOAuthCallbackValidator.Key: [String]]

    fileprivate init(parameters: [ChatGPTOAuthCallbackValidator.Key: [String]]) {
        self.parameters = parameters
    }
}

// code・state・client_idを含むため、print・dump・デバッガ表示では伏せ字にする
extension ChatGPTOAuthStateVerifiedCallback: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ChatGPTOAuthStateVerifiedCallback(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

enum ChatGPTOAuthCallbackValidator {
    // 上限値（callback全体はUTF-8のバイト数、code・client_idはデコード後の文字数）
    static let maxCallbackUTF8Length = 4096
    static let maxCodeLength = 1024
    static let maxClientIDLength = 256

    // 固定値（外部から差し替えない）
    private static let loopbackHost = "127.0.0.1"
    private static let callbackPath = "/auth/callback"
    // 初回登録requestで使うプレースホルダ。発行済みのclient_idではないため、callbackで返ってきても受け付けない
    private static let registrationPlaceholderClientID = "dynamic_agent_client"
    // issが付いていた場合に要求するauthorization serverのissuer識別子（RFC 9207）
    private static let expectedIssuer = "https://auth.openai.com"

    // このvalidatorが扱うkey（デコード後の文字列で照合する）。
    // これ以外のkeyは構文だけ検査して無視する（RFC 6749 4.1.2）
    // ChatGPTOAuthStateVerifiedCallbackが保持するため、このファイル内だけで見えるようにする
    fileprivate enum Key: String {
        case code
        case state
        case clientID = "client_id"
        case scope
        case error
        case errorDescription = "error_description"
        case errorURI = "error_uri"
        case issuer = "iss"
    }

    /// - Parameters:
    ///   - callback: ブラウザから戻ってきたcallback URLの文字列（加工せずそのまま渡す）
    ///   - expectation: 構築時のredirect URIとstate
    /// - Returns: 検査に合格したときだけcodeとclient_idを返す。それ以外はすべてthrowする
    static func validate(
        callback: String,
        expecting expectation: ChatGPTOAuthCallbackExpectation
    ) throws -> ChatGPTOAuthCallbackResult {
        try validateResponse(stateVerified: verifyState(callback: callback, expecting: expectation))
    }

    /// stateの一意一致までを確かめる。
    /// throwしたときは、構文エラーを含めて「stateが一致したと確認できていない」ので、呼び出し側は何も消費しない。
    /// 投げうるのは invalidExpectation・callbackTooLong・unexpectedRedirectURI・malformedCallback（encoding等）・invalidState
    /// - Returns: stateがちょうど1個あり、期待値と一致したときだけ返す
    static func verifyState(
        callback: String,
        expecting expectation: ChatGPTOAuthCallbackExpectation
    ) throws -> ChatGPTOAuthStateVerifiedCallback {
        // 1. 基準値自体を検査する（空stateどうしの一致などで通さない）
        guard let expectedBase = canonicalRedirectURI(expectation.redirectURI),
              isValidExpectedState(expectation.state) else {
            throw ChatGPTOAuthCallbackError.invalidExpectation
        }

        // 2. 長すぎる入力は中身を見る前に拒否する
        //    配列化（全体のコピー）は上限以内と確認できてから行う
        guard callback.utf8.count <= maxCallbackUTF8Length else {
            throw ChatGPTOAuthCallbackError.callbackTooLong
        }
        let bytes = Array(callback.utf8)

        // 3. 最初の "?" か "#" までをredirect URI部分とみなし、正規形とバイト単位で完全一致させる。
        //    URL型に解釈させないのは、大文字小文字・非正規port・percent-encodingなどを寛容に正規化されないようにするため
        let separatorIndex = bytes.firstIndex { $0 == ascii("?") || $0 == ascii("#") } ?? bytes.endIndex
        guard Array(bytes[..<separatorIndex]) == Array(expectedBase.utf8) else {
            throw ChatGPTOAuthCallbackError.unexpectedRedirectURI
        }

        // 4. queryを key → デコード済みの値の配列 に分解する。
        //    ここではencoding等の構文だけを見る。encodeされたkey（"%73tate"）も既知のkeyとして集めないと
        //    stateの重複を見逃すため、どれか1つでも分解できなければstateの一意性を確認できず拒否する
        let parameters = try parseQuery(bytes[separatorIndex...])

        // 5. stateを確認する。stateが通らない限り、scopeの重複やerrorなど他の内容を信用して分岐しない
        guard let states = parameters[.state], states.count == 1,
              constantTimeEquals(states[0], expectation.state) else {
            throw ChatGPTOAuthCallbackError.invalidState
        }
        return ChatGPTOAuthStateVerifiedCallback(parameters: parameters)
    }

    /// state一致を確認済みの応答について、残り（query構造・iss・error・code・client_id）を検査する
    /// - Returns: 検査に合格したときだけcodeとclient_idを返す。それ以外はすべてthrowする
    static func validateResponse(
        stateVerified verified: ChatGPTOAuthStateVerifiedCallback
    ) throws -> ChatGPTOAuthCallbackResult {
        let parameters = verified.parameters

        // 6. 既知keyの重複など、query全体としての構造を確認する
        try checkQueryStructure(parameters)

        // 7. issは任意だが、付いていたら1個だけで、期待するissuerと完全一致する必要がある（RFC 9207）。
        //    mix-up攻撃を防ぐため、errorレスポンスであってもerrorの内容より先に確認する
        if let issuers = parameters[.issuer] {
            guard issuers.count == 1, issuers[0] == expectedIssuer else {
                throw ChatGPTOAuthCallbackError.invalidIssuer
            }
        }

        // 8. OAuthのerrorレスポンス。codeと併存していたら矛盾として扱う
        if parameters[.error] != nil {
            if parameters[.code] != nil {
                throw ChatGPTOAuthCallbackError.conflictingParameters
            }
            throw ChatGPTOAuthCallbackError.authorizationFailed
        }

        // 9. code（stateが正しくても形式が不正なら拒否）
        guard let codes = parameters[.code], codes.count == 1,
              isValidOpaqueValue(codes[0], maxLength: maxCodeLength) else {
            throw ChatGPTOAuthCallbackError.invalidCode
        }

        // 10. client_id（今回発行されたもの。stateが正しくても形式が不正なら拒否）。
        //    デコード後の値で比較するため、"dynamic%5Fagent%5Fclient" のようなencoding違いのプレースホルダも拒否する
        guard let clientIDs = parameters[.clientID], clientIDs.count == 1,
              isValidOpaqueValue(clientIDs[0], maxLength: maxClientIDLength),
              clientIDs[0] != registrationPlaceholderClientID else {
            throw ChatGPTOAuthCallbackError.invalidClientID
        }

        // scopeは構造検査（重複なし・正しいencoding）だけ行い、値は結果にも判定にも使わない
        return ChatGPTOAuthCallbackResult(code: codes[0], clientID: clientIDs[0])
    }

    // MARK: - 基準値の検査

    // `http://127.0.0.1:<port>/auth/callback` の正規形と完全一致するときだけ、その文字列を返す
    private static func canonicalRedirectURI(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http",
              components.host == loopbackHost,
              let port = components.port,
              (1...65535).contains(port),
              components.path == callbackPath else {
            return nil
        }
        // 完全一致によりuserinfo・query・fragment・末尾スラッシュ・"049152"のような非正規表記も弾く
        let canonical = "http://\(loopbackHost):\(port)\(callbackPath)"
        return url.absoluteString == canonical ? canonical : nil
    }

    // authorization request構築時と同じ制約（43〜128文字のunreserved文字）
    private static func isValidExpectedState(_ value: String) -> Bool {
        (43...128).contains(value.unicodeScalars.count)
            && value.unicodeScalars.allSatisfy { isUnreserved($0.value) }
    }

    // MARK: - queryの解析

    // separatorIndex以降（"?..." / "#..." / 空）を受け取る
    private static func parseQuery(_ rest: ArraySlice<UInt8>) throws -> [Key: [String]] {
        // queryが無いcallbackはパラメータ0個として扱う（後段でstate欠落になる）
        guard let first = rest.first else { return [:] }
        // fragmentは位置に関係なく拒否する（"#?..." のようにqueryより前にあっても同じ）
        guard first == ascii("?"), !rest.contains(ascii("#")) else {
            throw ChatGPTOAuthCallbackError.malformedCallback
        }

        var parameters: [Key: [String]] = [:]
        // omittingEmptySubsequences: false で、空セグメント（"&&"や先頭・末尾の"&"）も検出できるようにする
        for segment in rest.dropFirst().split(separator: ascii("&"), omittingEmptySubsequences: false) {
            guard let equalIndex = segment.firstIndex(of: ascii("=")) else {
                throw ChatGPTOAuthCallbackError.malformedCallback
            }
            // keyも値と同じく厳格にform-decodeしてから既知のkeyと照合する。
            // こうしないと "%73tate" のようなencode違いのkeyが未知のkeyとして無視され、stateの重複を見逃す
            guard let keyString = formDecode(segment[..<equalIndex]), !keyString.isEmpty else {
                throw ChatGPTOAuthCallbackError.malformedCallback
            }
            // 未知のkeyでも値の構文（encoding・UTF-8）は検査し、不正なら拒否する
            guard let value = formDecode(segment[segment.index(after: equalIndex)...]) else {
                throw ChatGPTOAuthCallbackError.malformedCallback
            }
            // 構文が正しい未知のkeyは無視する（RFC 6749 4.1.2）。値は保持もしない
            guard let key = Key(rawValue: keyString) else { continue }
            parameters[key, default: []].append(value)
        }
        return parameters
    }

    // state照合の後に呼ぶ。stateが一致していない応答では、ここの結果で分岐させない
    private static func checkQueryStructure(_ parameters: [Key: [String]]) throws {
        // state・code・client_id・issの重複はそれぞれの段階で専用のエラーにする。
        // それ以外の既知keyの重複は構造エラーにする（デコード後に同じ値でも重複は重複）
        for key in [Key.scope, .error, .errorDescription, .errorURI] {
            if let values = parameters[key], values.count > 1 {
                throw ChatGPTOAuthCallbackError.malformedCallback
            }
        }
        // error_description・error_uriはerrorの付随情報なので、error無しで来たら構造が不正
        if parameters[.error] == nil,
           parameters[.errorDescription] != nil || parameters[.errorURI] != nil {
            throw ChatGPTOAuthCallbackError.malformedCallback
        }
    }

    // application/x-www-form-urlencodedの値を1回だけデコードする。
    // "+" はspace、"%XX" はそのバイト。不正なencoding・不正なUTF-8・許可外の生文字はnil
    private static func formDecode(_ raw: ArraySlice<UInt8>) -> String? {
        var decoded: [UInt8] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let byte = raw[index]
            if byte == ascii("%") {
                // "%" の後ろにちょうど2桁の16進数が必要
                guard raw.distance(from: index, to: raw.endIndex) >= 3,
                      let high = hexValue(raw[index + 1]),
                      let low = hexValue(raw[index + 2]) else {
                    return nil
                }
                decoded.append(high << 4 | low)
                index += 3
            } else if byte == ascii("+") {
                decoded.append(ascii(" "))
                index += 1
            } else if isAllowedRawValueByte(byte) {
                decoded.append(byte)
                index += 1
            } else {
                return nil
            }
        }
        // デコードは1回だけ。結果に "%" が残っていても再デコードしない
        return decodeUTF8Strictly(decoded)
    }

    // 不完全なシーケンス・overlong encoding・UTF-8として不正なバイトがあればnilを返す。
    // String(decoding:as:) は不正なバイトを置換文字に変えてしまうため、自前で1文字ずつ検査する
    private static func decodeUTF8Strictly(_ bytes: [UInt8]) -> String? {
        var scalars = String.UnicodeScalarView()
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                scalars.append(scalar)
            case .emptyInput:
                return String(scalars)
            case .error:
                return nil
            }
        }
    }

    // MARK: - 文字の判定

    private static func ascii(_ character: Unicode.Scalar) -> UInt8 {
        UInt8(character.value)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case ascii("0")...ascii("9"): return byte - ascii("0")
        case ascii("A")...ascii("F"): return byte - ascii("A") + 10
        case ascii("a")...ascii("f"): return byte - ascii("a") + 10
        default: return nil
        }
    }

    // RFC 3986のunreserved文字（A-Z a-z 0-9 - . _ ~）
    private static func isUnreserved(_ value: UInt32) -> Bool {
        switch value {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39: return true
        case 0x2D, 0x2E, 0x5F, 0x7E: return true   // - . _ ~
        default: return false
        }
    }

    // 値の中に生で書いてよい文字: unreservedと、query中で区切りの意味を持たない記号。
    // "&" "=" "?" "#" やspace・制御文字・非ASCIIはpercent-encodeされていなければ拒否する
    private static func isAllowedRawValueByte(_ byte: UInt8) -> Bool {
        if isUnreserved(UInt32(byte)) { return true }
        return "!$'()*,;:@/".utf8.contains(byte)
    }

    // codeとissued client_idはopaque値として扱う。デコード後が空でなく、上限以内の可視ASCII（0x21-0x7E）だけ許可する
    private static func isValidOpaqueValue(_ value: String, maxLength: Int) -> Bool {
        let scalars = value.unicodeScalars
        return (1...maxLength).contains(scalars.count)
            && scalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    // 内容によって比較時間が変わらないようにする（長さが違う場合だけは即座にfalse）
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
}

// エラーには入力値や秘密値を含めない（関連値を持たせない）
enum ChatGPTOAuthCallbackError: Error, Equatable {
    // 基準値（expectation）自体が不正
    case invalidExpectation
    // callback全体が上限を超えている
    case callbackTooLong
    // scheme・host・port・pathが基準のredirect URIと一致しない
    case unexpectedRedirectURI
    // fragment付き・不正なpercent-encoding・空のkey・scope等の重複など、queryの構造が不正。
    // encoding等はstate照合の前（verifyState）、scope等の重複はstate照合の後（validateResponse）で判定する
    case malformedCallback
    // stateの欠落・重複・不一致
    case invalidState
    // issが付いているが、重複・不一致（期待するissuerと完全一致しない）
    case invalidIssuer
    // OAuthのerrorレスポンス（state検証の後に判定）
    case authorizationFailed
    // errorとcodeが併存している
    case conflictingParameters
    // codeの欠落・重複・空・形式不正
    case invalidCode
    // client_idの欠落・重複・空・形式不正
    case invalidClientID
}
