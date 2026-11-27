import Foundation

// ChatGPT OAuth初回登録のloopback listenerが受け取るHTTP request headを、純粋に検査するためのAPI。
// ソケット・ネットワーク通信・listener・レスポンス生成・ブラウザ・Keychain・保存は行わず、アプリ本体からもまだ呼び出さない。
// 合格したrequestだけを callback URL 文字列（http://127.0.0.1:<port>/auth/callback?...）に組み立て直し、
// 後段の ChatGPTOAuthAttempt.consumeCallback に渡せる形にする。stateはこのparserに渡さず、検証は試行側に任せる。
//
// 受理する形（これ以外はすべてfail closedで拒否する）:
// - 入力全体が maxRequestHeadLength バイト以下で、request headの終端（CRLF CRLF）でちょうど終わる
// - 改行はすべてCRLF。単独のCR・LF、非ASCII、HTAB以外の制御文字を含まない
// - request lineは "GET" SP origin-form SP "HTTP/1.1" の完全一致（空白はちょうど1個ずつ）
// - request targetのpathは "/auth/callback" とバイト単位で完全一致し、空でないqueryを持つ（fragmentは不可）
// - header行は field-name ":" OWS field-value OWS の形。obs-fold・名前の前後の空白は不可
// - Hostはちょうど1個で、値は "127.0.0.1:<bound port>" とバイト単位で完全一致
// - Content-Lengthは付いていなければ可、付いていればちょうど1個で値は "0"。Transfer-Encodingは付いていたら拒否
//
// 判定順: bound port → 全体の長さ → 文字・改行 → head終端 → 終端後の余剰バイト
//        → request line（形 → method → request target → path → version） → header構文 → Host → body関連header
//
// request targetとheaderの内容は、error・description・ログのどこにも含めない。

// 検査に合格したrequestから組み立てたcallback。queryは加工せずそのまま含める
struct ChatGPTOAuthLoopbackCallbackRequest {
    let callback: String
}

// callbackにはstate・codeが含まれるため、print・dump・デバッガ表示では伏せ字にする
extension ChatGPTOAuthLoopbackCallbackRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ChatGPTOAuthLoopbackCallbackRequest(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["callback": "<redacted>"], displayStyle: .struct)
    }
}

enum ChatGPTOAuthLoopbackHTTPRequestParser {
    // request head全体（CRLF CRLFを含む）の上限バイト数
    static let maxRequestHeadLength = 8192

    private static let callbackPath = "/auth/callback"

    // 判定に使うASCIIのバイト値
    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A
    private static let htab: UInt8 = 0x09
    private static let sp: UInt8 = 0x20

    /// - Parameters:
    ///   - data: socketから受け取ったバイト列（加工せずそのまま渡す）
    ///   - boundPort: listenerがbind済みのloopback port（1...65535）
    /// - Returns: 検査に合格したときだけcallbackを返す。それ以外はすべてthrowする
    static func parse(_ data: Data, boundPort: Int) throws -> ChatGPTOAuthLoopbackCallbackRequest {
        guard (1...65535).contains(boundPort) else {
            throw ChatGPTOAuthLoopbackHTTPError.invalidBoundPort
        }
        // 巨大な入力を配列へコピーする前に、長さだけで弾く
        guard data.count <= maxRequestHeadLength else {
            throw ChatGPTOAuthLoopbackHTTPError.requestTooLarge
        }
        // Dataはsliceだと先頭indexが0でないことがあるため、0始まりの配列にしてから扱う
        let bytes = [UInt8](data)

        try validateBytes(bytes)
        try validateLineEndings(bytes)

        // 最初に現れるCRLF CRLFをheadの終端とする
        guard let terminatorStart = firstHeadTerminator(in: bytes) else {
            throw ChatGPTOAuthLoopbackHTTPError.incompleteRequestHead
        }
        // 終端の後ろにbodyや次のrequestが続いていたら、まとめて拒否する
        guard terminatorStart + 4 == bytes.count else {
            throw ChatGPTOAuthLoopbackHTTPError.unexpectedTrailingData
        }

        // ここまでで全バイトがASCIIかつ改行がCRLFのみと確定しているので、CRLFで行に分けても取りこぼしがない
        let lines = splitLines(bytes[0..<terminatorStart])
        let target = try parseRequestLine(lines[0])
        let headers = try parseHeaders(lines.dropFirst())
        try validateHost(headers, boundPort: boundPort)
        try validateBodyHeaders(headers)

        return ChatGPTOAuthLoopbackCallbackRequest(callback: "http://127.0.0.1:\(boundPort)\(target)")
    }

    // MARK: - 文字・改行

    // 印字可能ASCII（SP〜"~"）・HTAB・CR・LFだけを許可する。DEL・NUL・非ASCIIはここで拒否する
    private static func validateBytes(_ bytes: [UInt8]) throws {
        for byte in bytes {
            let allowed = (0x20...0x7E).contains(byte) || byte == htab || byte == cr || byte == lf
            guard allowed else { throw ChatGPTOAuthLoopbackHTTPError.invalidByte }
        }
    }

    // CRの直後は必ずLF、LFの直前は必ずCRであること（単独のCR・LFによるheader injectionを防ぐ）
    private static func validateLineEndings(_ bytes: [UInt8]) throws {
        for (index, byte) in bytes.enumerated() {
            if byte == cr {
                guard index + 1 < bytes.count, bytes[index + 1] == lf else {
                    throw ChatGPTOAuthLoopbackHTTPError.invalidLineEnding
                }
            } else if byte == lf {
                guard index > 0, bytes[index - 1] == cr else {
                    throw ChatGPTOAuthLoopbackHTTPError.invalidLineEnding
                }
            }
        }
    }

    private static func firstHeadTerminator(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4)
        where bytes[index] == cr && bytes[index + 1] == lf && bytes[index + 2] == cr && bytes[index + 3] == lf {
            return index
        }
        return nil
    }

    // CRLFで区切った各行を文字列にする。全バイトがASCIIなので、UTF-8として読んでも内容は変わらない
    private static func splitLines(_ head: ArraySlice<UInt8>) -> [String] {
        var lines: [String] = []
        var lineStart = head.startIndex
        var index = head.startIndex
        while index < head.endIndex {
            if head[index] == cr {
                lines.append(String(decoding: head[lineStart..<index], as: UTF8.self))
                index += 2   // CRの直後は必ずLFなので、CRLFの2バイトを飛ばす
                lineStart = index
            } else {
                index += 1
            }
        }
        lines.append(String(decoding: head[lineStart..<head.endIndex], as: UTF8.self))
        return lines
    }

    // MARK: - request line

    // 合格したらrequest target（origin-form）を返す
    private static func parseRequestLine(_ line: String) throws -> String {
        // omittingEmptySubsequences: false にすると、空白の連続・先頭末尾の空白が空要素として残り、要素数で検出できる
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }), !line.utf8.contains(htab) else {
            throw ChatGPTOAuthLoopbackHTTPError.malformedRequestLine
        }
        let method = parts[0]
        let target = String(parts[1])
        let version = parts[2]

        guard method == "GET" else {
            throw ChatGPTOAuthLoopbackHTTPError.unsupportedMethod
        }
        try validateOriginForm(target)

        // 最初の "?" でpathとqueryに分ける。pathは正規化（%デコード・".."解決）せずバイト単位で比較する
        guard let questionMark = target.firstIndex(of: "?"),
              target[..<questionMark] == callbackPath,
              target.index(after: questionMark) < target.endIndex
        else {
            throw ChatGPTOAuthLoopbackHTTPError.unexpectedPath
        }

        guard version == "HTTP/1.1" else {
            throw ChatGPTOAuthLoopbackHTTPError.unsupportedHTTPVersion
        }
        return target
    }

    // origin-form = absolute-path [ "?" query ]（RFC 9112）。"/" で始まり、URIで許される文字だけからなること。
    // "#"（fragment）・"<" ">" などURIに生で書けない文字・壊れた%エンコードは拒否する
    private static func validateOriginForm(_ target: String) throws {
        let bytes = Array(target.utf8)
        guard bytes.first == UInt8(ascii: "/") else {
            throw ChatGPTOAuthLoopbackHTTPError.invalidRequestTarget
        }
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%") {
                guard index + 2 < bytes.count, isHexDigit(bytes[index + 1]), isHexDigit(bytes[index + 2]) else {
                    throw ChatGPTOAuthLoopbackHTTPError.invalidRequestTarget
                }
                index += 3
                continue
            }
            guard isOriginFormByte(byte) else {
                throw ChatGPTOAuthLoopbackHTTPError.invalidRequestTarget
            }
            index += 1
        }
    }

    // pchar（unreserved / sub-delims / ":" / "@"）と、path・queryの区切りに使う "/" "?"
    private static func isOriginFormByte(_ byte: UInt8) -> Bool {
        if isAlphaNumeric(byte) { return true }
        return "-._~!$&'()*+,;=:@/?".utf8.contains(byte)
    }

    // MARK: - header

    private struct Header {
        // ASCIIの小文字に揃えた名前。field-nameは大文字小文字を区別しないため
        let lowercasedName: String
        // 前後のOWS（SP・HTAB）を取り除いた値
        let value: String
    }

    private static func parseHeaders(_ lines: ArraySlice<String>) throws -> [Header] {
        try lines.map { line in
            let bytes = Array(line.utf8)
            guard let colon = bytes.firstIndex(of: UInt8(ascii: ":")) else {
                throw ChatGPTOAuthLoopbackHTTPError.malformedHeader
            }
            let name = bytes[..<colon]
            // field-nameはtokenなので、空白や "(" などを含む名前はここで弾かれる。
            // 空白で始まる行（obs-foldの継続行・名前の前の空白）も、名前に空白が入るためここで拒否される
            guard !name.isEmpty, name.allSatisfy(isTokenByte) else {
                throw ChatGPTOAuthLoopbackHTTPError.malformedHeader
            }
            let value = trimmingOWS(bytes[(colon + 1)...])
            return Header(
                lowercasedName: String(decoding: name.map(asciiLowercased), as: UTF8.self),
                value: String(decoding: value, as: UTF8.self)
            )
        }
    }

    private static func validateHost(_ headers: [Header], boundPort: Int) throws {
        let hosts = headers.filter { $0.lowercasedName == "host" }
        guard hosts.count == 1, hosts[0].value == "127.0.0.1:\(boundPort)" else {
            throw ChatGPTOAuthLoopbackHTTPError.invalidHost
        }
    }

    // bodyを受け取らないので、bodyがあり得ることを示すheaderは拒否する
    private static func validateBodyHeaders(_ headers: [Header]) throws {
        guard !headers.contains(where: { $0.lowercasedName == "transfer-encoding" }) else {
            throw ChatGPTOAuthLoopbackHTTPError.unexpectedBody
        }
        let contentLengths = headers.filter { $0.lowercasedName == "content-length" }
        guard contentLengths.isEmpty || (contentLengths.count == 1 && contentLengths[0].value == "0") else {
            throw ChatGPTOAuthLoopbackHTTPError.unexpectedBody
        }
    }

    // MARK: - ASCII helper

    private static func trimmingOWS(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var slice = bytes
        while let first = slice.first, first == sp || first == htab { slice = slice.dropFirst() }
        while let last = slice.last, last == sp || last == htab { slice = slice.dropLast() }
        return slice
    }

    // tchar（RFC 9110）
    private static func isTokenByte(_ byte: UInt8) -> Bool {
        if isAlphaNumeric(byte) { return true }
        return "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    // localeやUnicodeの規則に依存しないよう、A〜Zだけを小文字にする
    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 0x20 : byte
    }
}

// エラーには入力値を含めない（関連値を持たせない）
enum ChatGPTOAuthLoopbackHTTPError: Error, Equatable {
    // bound portが1...65535の範囲外
    case invalidBoundPort
    // 入力全体が上限を超えている
    case requestTooLarge
    // 非ASCII・NULなど、request headに許可されないバイトを含む
    case invalidByte
    // 単独のCRまたはLFを含む
    case invalidLineEnding
    // request headの終端（CRLF CRLF）が見つからない
    case incompleteRequestHead
    // headの終端の後ろにバイトが続いている（body・パイプラインされた次のrequest）
    case unexpectedTrailingData
    // request lineの形が不正（空白の数・空行で始まる等）
    case malformedRequestLine
    // GET以外のmethod（大文字小文字違いを含む）
    case unsupportedMethod
    // origin-formでないrequest target、またはfragment付き
    case invalidRequestTarget
    // callback path以外（/favicon.icoを含む）、またはqueryが無い・空。試行には渡さない
    case unexpectedPath
    // HTTP/1.1以外
    case unsupportedHTTPVersion
    // header行の構文が不正
    case malformedHeader
    // Hostの欠落・重複・不一致
    case invalidHost
    // 0以外・重複したContent-Length、またはTransfer-Encodingが付いている
    case unexpectedBody
}
