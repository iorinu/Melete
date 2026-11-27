import XCTest
@testable import Melete

// ChatGPT OAuth loopback listenerが受け取るHTTP request headの純粋な検査だけを検証する。
// ソケット・ネットワーク・listener・ブラウザ・Keychain・保存には一切触れない。値はすべてテスト専用の合成固定値。
// 判定順: bound port → 全体の長さ → 文字・改行 → head終端 → 終端後の余剰バイト
//        → request line（形 → method → request target → path → version） → header構文 → Host → body関連header
final class ChatGPTOAuthLoopbackHTTPTests: XCTestCase {
    // 合成の固定値（実際の認証には使われない）
    private let syntheticPort = 49152
    private let syntheticQuery = "code=SyntheticLoopbackCode-0123&state=SyntheticLoopbackState-0123&client_id=synthetic_loopback_client"
    private var callbackTarget: String { "/auth/callback?\(syntheticQuery)" }
    private var hostHeader: String { "Host: 127.0.0.1:\(syntheticPort)" }

    // 行をCRLFで繋ぎ、最後にheadの終端（空行）を付ける
    private func head(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func request(
        _ requestLine: String? = nil,
        headers: [String]? = nil
    ) -> Data {
        head([requestLine ?? "GET \(callbackTarget) HTTP/1.1"] + (headers ?? [hostHeader]))
    }

    private var validRequest: Data { request() }

    private func parse(_ data: Data, boundPort: Int? = nil) throws -> ChatGPTOAuthLoopbackCallbackRequest {
        try ChatGPTOAuthLoopbackHTTPRequestParser.parse(data, boundPort: boundPort ?? syntheticPort)
    }

    // 「何かthrowすればよい」ではなく、期待した理由で拒否されたことまで確認する。
    // あわせて、errorの表示に入力（queryの値）が漏れていないことも確認する
    private func assertRejects(
        _ data: Data,
        as expected: ChatGPTOAuthLoopbackHTTPError,
        boundPort: Int? = nil,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try parse(data, boundPort: boundPort), label, file: file, line: line) { error in
            XCTAssertEqual(error as? ChatGPTOAuthLoopbackHTTPError, expected, label, file: file, line: line)
            let shown = String(describing: error) + String(reflecting: error)
            XCTAssertFalse(shown.contains("Synthetic"), label, file: file, line: line)
        }
    }

    // MARK: - positive control

    func testAcceptsMinimalCallbackRequestAndRebuildsCallback() throws {
        let result = try parse(validRequest)
        // queryは加工せず、bound portで組み立て直したcallback URL文字列にする
        XCTAssertEqual(result.callback, "http://127.0.0.1:\(syntheticPort)\(callbackTarget)")
    }

    func testAcceptsCaseInsensitiveHostNameAndOptionalWhitespace() throws {
        // field-nameは大文字小文字を区別しない。値の前後のOWS（SP・HTAB）は取り除く
        let result = try parse(request(headers: ["host:\t127.0.0.1:\(syntheticPort) "]))
        XCTAssertEqual(result.callback, "http://127.0.0.1:\(syntheticPort)\(callbackTarget)")
    }

    func testAcceptsZeroContentLengthAndUnrelatedHeaders() throws {
        let result = try parse(request(headers: [
            hostHeader,
            "User-Agent: SyntheticAgent/1.0",
            "Connection: close",
            "Content-Length: 0",
        ]))
        XCTAssertEqual(result.callback, "http://127.0.0.1:\(syntheticPort)\(callbackTarget)")
    }

    func testAcceptsRequestOfExactlyMaxLength() throws {
        let data = paddedRequest(totalLength: ChatGPTOAuthLoopbackHTTPRequestParser.maxRequestHeadLength)
        XCTAssertEqual(data.count, ChatGPTOAuthLoopbackHTTPRequestParser.maxRequestHeadLength)
        XCTAssertNoThrow(try parse(data))
    }

    func testResultDescriptionIsRedacted() throws {
        let result = try parse(validRequest)
        for shown in [String(describing: result), String(reflecting: result)] {
            XCTAssertFalse(shown.contains("Synthetic"))
            XCTAssertFalse(shown.contains("/auth/callback"))
        }
        var dumped = ""
        dump(result, to: &dumped)
        XCTAssertFalse(dumped.contains("Synthetic"))
    }

    // MARK: - bound port

    func testRejectsBoundPortOutOfRange() {
        for port in [0, -1, 65536] {
            assertRejects(validRequest, as: .invalidBoundPort, boundPort: port, "port \(port)")
        }
    }

    // MARK: - 長さ・終端・余剰バイト

    func testRejectsRequestLongerThanMaxLength() {
        let data = paddedRequest(totalLength: ChatGPTOAuthLoopbackHTTPRequestParser.maxRequestHeadLength + 1)
        assertRejects(data, as: .requestTooLarge, "8193 bytes")
    }

    func testRejectsIncompleteRequestHead() {
        let data = Data("GET \(callbackTarget) HTTP/1.1\r\n\(hostHeader)\r\n".utf8)
        assertRejects(data, as: .incompleteRequestHead, "missing empty line")
        assertRejects(Data(), as: .incompleteRequestHead, "empty input")
    }

    func testRejectsBodyBytesAfterHead() {
        var data = request(headers: [hostHeader, "Content-Length: 0"])
        data.append(Data("x".utf8))
        assertRejects(data, as: .unexpectedTrailingData, "trailing body byte")
    }

    func testRejectsPipelinedSecondRequest() {
        var data = validRequest
        data.append(head(["GET /favicon.ico HTTP/1.1", hostHeader]))
        assertRejects(data, as: .unexpectedTrailingData, "pipelined request")
    }

    // MARK: - 文字・改行

    func testRejectsBareLineFeedAndBareCarriageReturn() {
        let bareLF = Data("GET \(callbackTarget) HTTP/1.1\n\(hostHeader)\r\n\r\n".utf8)
        assertRejects(bareLF, as: .invalidLineEnding, "bare LF")
        let lfOnly = Data("GET \(callbackTarget) HTTP/1.1\n\(hostHeader)\n\n".utf8)
        assertRejects(lfOnly, as: .invalidLineEnding, "LF only")
        let bareCR = Data("GET \(callbackTarget) HTTP/1.1\r\(hostHeader)\r\n\r\n".utf8)
        assertRejects(bareCR, as: .invalidLineEnding, "bare CR")
    }

    func testRejectsNonASCIIAndControlBytes() {
        // 非ASCII（UTF-8の "é"）をrequest targetとheader値に生で入れる
        let nonASCIITarget = request("GET /auth/callback?code=caf\u{00E9} HTTP/1.1")
        assertRejects(nonASCIITarget, as: .invalidByte, "non-ASCII in target")
        let nonASCIIHeader = request(headers: [hostHeader, "User-Agent: caf\u{00E9}"])
        assertRejects(nonASCIIHeader, as: .invalidByte, "non-ASCII in header")
        let nul = request(headers: [hostHeader, "User-Agent: a\u{0000}b"])
        assertRejects(nul, as: .invalidByte, "NUL in header")
    }

    // MARK: - request line

    func testRejectsMalformedRequestLine() {
        let cases = [
            "GET  \(callbackTarget) HTTP/1.1",     // 空白2個
            "GET \(callbackTarget)  HTTP/1.1",
            " GET \(callbackTarget) HTTP/1.1",     // 先頭の空白
            "GET \(callbackTarget) HTTP/1.1 ",     // 末尾の空白
            "GET\t\(callbackTarget) HTTP/1.1",     // HTABの区切り
            "GET \(callbackTarget)",               // versionなし
        ]
        for line in cases {
            assertRejects(request(line), as: .malformedRequestLine, line)
        }
        // 先頭の空行（RFC 9112では無視してよいが、ここではfail closedにする）
        assertRejects(head(["", "GET \(callbackTarget) HTTP/1.1", hostHeader]), as: .malformedRequestLine, "leading empty line")
    }

    func testRejectsNonGETMethod() {
        for method in ["POST", "HEAD", "PUT", "get", "Get"] {
            assertRejects(request("\(method) \(callbackTarget) HTTP/1.1"), as: .unsupportedMethod, method)
        }
    }

    func testRejectsNonOriginFormTarget() {
        let cases = [
            "http://127.0.0.1:\(syntheticPort)\(callbackTarget)",  // absolute-form
            "127.0.0.1:\(syntheticPort)",                           // authority-form
            "*",                                                    // asterisk-form
            "\(callbackTarget)#fragment",                           // fragment付き
        ]
        for target in cases {
            assertRejects(request("GET \(target) HTTP/1.1"), as: .invalidRequestTarget, target)
        }
    }

    func testRejectsFaviconAndOtherPathsWithoutPassingThem() {
        let cases = [
            "/favicon.ico",
            "/",
            "/auth/callback",              // queryなし
            "/auth/callback?",             // 空のquery
            "/auth/callback/?\(syntheticQuery)",
            "/AUTH/callback?\(syntheticQuery)",
            "/auth/%63allback?\(syntheticQuery)",
            "//auth/callback?\(syntheticQuery)",
            "/auth/callback/../callback?\(syntheticQuery)",
        ]
        for target in cases {
            assertRejects(request("GET \(target) HTTP/1.1"), as: .unexpectedPath, target)
        }
    }

    func testRejectsNonHTTP11Version() {
        for version in ["HTTP/1.0", "HTTP/2", "HTTP/2.0", "http/1.1", "HTTP/1.10"] {
            assertRejects(request("GET \(callbackTarget) \(version)"), as: .unsupportedHTTPVersion, version)
        }
    }

    // MARK: - header構文

    func testRejectsMalformedHeaderLines() {
        let cases = [
            "Host 127.0.0.1:\(syntheticPort)",      // ":" なし
            "Host : 127.0.0.1:\(syntheticPort)",    // 名前とコロンの間の空白
            " Host: 127.0.0.1:\(syntheticPort)",    // 先頭の空白
            ": empty-name",                         // 空の名前
            "Bad(Name): value",                     // tokenでない名前
        ]
        for header in cases {
            assertRejects(request(headers: [header]), as: .malformedHeader, header)
        }
        // obs-fold（継続行）
        assertRejects(request(headers: [hostHeader, "User-Agent: a", " folded"]), as: .malformedHeader, "obs-fold")
    }

    // MARK: - Host

    func testRejectsMissingDuplicateOrMismatchedHost() {
        let cases: [(String, [String])] = [
            ("missing", ["User-Agent: SyntheticAgent/1.0"]),
            ("duplicate", [hostHeader, hostHeader]),
            ("duplicate different case", [hostHeader, "host: 127.0.0.1:\(syntheticPort)"]),
            ("other port", ["Host: 127.0.0.1:49153"]),
            ("no port", ["Host: 127.0.0.1"]),
            ("leading zero port", ["Host: 127.0.0.1:0\(syntheticPort)"]),
            ("localhost", ["Host: localhost:\(syntheticPort)"]),
            ("ipv6 loopback", ["Host: [::1]:\(syntheticPort)"]),
            ("userinfo", ["Host: user@127.0.0.1:\(syntheticPort)"]),
            ("empty", ["Host: "]),
        ]
        for (label, headers) in cases {
            assertRejects(request(headers: headers), as: .invalidHost, label)
        }
    }

    // MARK: - body関連header

    func testRejectsNonZeroOrDuplicateContentLengthAndTransferEncoding() {
        let cases: [(String, [String])] = [
            ("non-zero", [hostHeader, "Content-Length: 1"]),
            ("leading zero", [hostHeader, "Content-Length: 00"]),
            ("negative", [hostHeader, "Content-Length: -0"]),
            ("duplicate zero", [hostHeader, "Content-Length: 0", "Content-Length: 0"]),
            ("transfer-encoding", [hostHeader, "Transfer-Encoding: chunked"]),
            ("transfer-encoding with zero length", [hostHeader, "Content-Length: 0", "Transfer-Encoding: identity"]),
        ]
        for (label, headers) in cases {
            assertRejects(request(headers: headers), as: .unexpectedBody, label)
        }
    }

    // MARK: - helper

    // 合成のpadding headerを加えて、全体をちょうどtotalLengthバイトにした正しいrequestを作る
    private func paddedRequest(totalLength: Int) -> Data {
        let prefix = "X-Synthetic-Padding: "
        let baseLength = validRequest.count + prefix.utf8.count + 2   // padding行のCRLF分
        let padding = String(repeating: "a", count: totalLength - baseLength)
        return request(headers: [hostHeader, prefix + padding])
    }
}
