import XCTest
@testable import Melete

// ChatGPT OAuth loopback listenerがブラウザへ返す固定文HTTP responseの組み立てだけを検証する。
// ソケット・ネットワーク・listener・ブラウザ・Keychain・保存・UIには一切触れない。
// builderは関連値のないenumしか受け取らないため、callbackのcode・state等をテストから渡す手段自体がない。
final class ChatGPTOAuthLoopbackResponseTests: XCTestCase {
    private typealias Kind = ChatGPTOAuthLoopbackResponseKind

    // 種類ごとに期待するstatus line
    private let expectedStatusLines: [Kind: String] = [
        .callbackReceived: "HTTP/1.1 200 OK",
        .callbackFailed: "HTTP/1.1 400 Bad Request",
        .notFound: "HTTP/1.1 404 Not Found",
        .methodNotAllowed: "HTTP/1.1 405 Method Not Allowed",
        .requestHeadTooLarge: "HTTP/1.1 431 Request Header Fields Too Large",
    ]

    // すべてのresponseに付ける固定header（Content-Lengthは本文から計算するので別に確認する）
    private let commonHeaders: [String: String] = [
        "Content-Type": "text/plain; charset=utf-8",
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'none'",
        "Connection": "close",
    ]

    // 本文に「サインインが終わった」と読める語を含めない
    private let completionWords = ["完了", "成功", "サインインしました", "ログインしました", "認証しました"]

    // 分解したresponse。header名は出現順・重複を確認できるよう配列で持つ
    private struct ParsedResponse {
        let statusLine: String
        let headers: [(name: String, value: String)]
        let body: Data
        let raw: Data

        func values(named name: String) -> [String] {
            headers.filter { $0.name.lowercased() == name.lowercased() }.map(\.value)
        }
    }

    private func build(_ kind: Kind) throws -> Data {
        try ChatGPTOAuthLoopbackResponseBuilder.response(for: kind)
    }

    // 最初のCRLF CRLFでheadと本文に分け、headをCRLFで行に分ける。形が崩れていたらテスト失敗としてthrowする
    private func parse(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> ParsedResponse {
        let bytes = [UInt8](data)
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let terminatorStart = firstIndex(of: terminator, in: bytes) else {
            XCTFail("headの終端（CRLF CRLF）がない", file: file, line: line)
            throw ParseFailure()
        }
        let headBytes = Array(bytes[..<terminatorStart])
        let body = Data(bytes[(terminatorStart + 4)...])
        // headはASCIIだけのはずなので、ASCIIとして読めなければ失敗にする
        guard let head = String(bytes: headBytes, encoding: .ascii) else {
            XCTFail("headがASCIIではない", file: file, line: line)
            throw ParseFailure()
        }
        let lines = head.components(separatedBy: "\r\n")
        var headers: [(name: String, value: String)] = []
        for headerLine in lines.dropFirst() {
            // "Name: value" の形（コロンの直後に空白1個）で書かれていること
            guard let range = headerLine.range(of: ": ") else {
                XCTFail("header行の形が不正", file: file, line: line)
                throw ParseFailure()
            }
            headers.append((String(headerLine[..<range.lowerBound]), String(headerLine[range.upperBound...])))
        }
        return ParsedResponse(statusLine: lines[0], headers: headers, body: body, raw: data)
    }

    private struct ParseFailure: Error {}

    private func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        for index in 0...(bytes.count - pattern.count) where Array(bytes[index..<(index + pattern.count)]) == pattern {
            return index
        }
        return nil
    }

    private func bodyText(_ parsed: ParsedResponse, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let text = try XCTUnwrap(String(data: parsed.body, encoding: .utf8), "本文がUTF-8ではない", file: file, line: line)
        return text
    }

    // MARK: - 入力を受け取らない設計

    func testKindsAreFixedAndCarryNoInput() {
        // CaseIterableは関連値を持つenumには合成できないので、これがコンパイルできること自体が
        // 「code・state等の任意文字列を渡す経路がない」ことの確認になる
        XCTAssertEqual(Kind.allCases.count, 5)
        XCTAssertEqual(Set(expectedStatusLines.keys.map { "\($0)" }), Set(Kind.allCases.map { "\($0)" }))
    }

    func testMaxResponseLengthIsFixed() {
        XCTAssertEqual(ChatGPTOAuthLoopbackResponseBuilder.maxResponseLength, 1024)
    }

    func testResponseIsDeterministic() throws {
        for kind in Kind.allCases {
            XCTAssertEqual(try build(kind), try build(kind), "\(kind)")
        }
    }

    func testBuilderIsNoLongerStub() {
        for kind in Kind.allCases {
            XCTAssertNoThrow(try build(kind), "\(kind)")
            do {
                _ = try build(kind)
            } catch {
                XCTAssertNotEqual(error as? ChatGPTOAuthLoopbackResponseError, .notImplemented, "stubのままではない")
            }
        }
    }

    // MARK: - status line

    func testStatusLineMatchesKind() throws {
        for kind in Kind.allCases {
            let parsed = try parse(try build(kind))
            XCTAssertEqual(parsed.statusLine, expectedStatusLines[kind], "\(kind)")
        }
    }

    func testNeverReturnsRedirect() throws {
        for kind in Kind.allCases {
            let parsed = try parse(try build(kind))
            XCTAssertFalse(parsed.statusLine.hasPrefix("HTTP/1.1 3"), "\(kind)")
            XCTAssertTrue(parsed.values(named: "Location").isEmpty, "\(kind)")
            XCTAssertTrue(parsed.values(named: "Refresh").isEmpty, "\(kind)")
            XCTAssertTrue(parsed.values(named: "Set-Cookie").isEmpty, "\(kind)")
        }
    }

    func testOnlyCallbackReceivedIsSuccessStatus() throws {
        for kind in Kind.allCases {
            let parsed = try parse(try build(kind))
            XCTAssertEqual(parsed.statusLine.hasPrefix("HTTP/1.1 2"), kind == .callbackReceived, "\(kind)")
        }
    }

    // MARK: - header

    func testHasExactlyTheExpectedHeaders() throws {
        for kind in Kind.allCases {
            let parsed = try parse(try build(kind))
            var expected = commonHeaders
            expected["Content-Length"] = String(parsed.body.count)
            // 405ではRFC 9110に従い、受け付けるmethodをAllowで示す
            if kind == .methodNotAllowed {
                expected["Allow"] = "GET"
            }
            let names = parsed.headers.map { $0.name.lowercased() }
            XCTAssertEqual(names.count, Set(names).count, "header名が重複している: \(kind)")
            XCTAssertEqual(
                // uniqueKeysWithValuesは重複でクラッシュするため、重複は上の行で検出し、ここでは先勝ちにする
                Dictionary(parsed.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }),
                expected,
                "\(kind)"
            )
        }
    }

    func testContentLengthMatchesUTF8BodyBytes() throws {
        for kind in Kind.allCases {
            let parsed = try parse(try build(kind))
            let text = try bodyText(parsed)
            XCTAssertEqual(parsed.values(named: "Content-Length"), [String(text.utf8.count)], "\(kind)")
            XCTAssertEqual(parsed.body.count, text.utf8.count, "\(kind)")
        }
    }

    // MARK: - CRLF・長さ

    func testHeadUsesOnlyCRLFAndPrintableASCII() throws {
        for kind in Kind.allCases {
            let data = try build(kind)
            let bytes = [UInt8](data)
            let terminatorStart = try XCTUnwrap(firstIndex(of: [0x0D, 0x0A, 0x0D, 0x0A], in: bytes), "\(kind)")
            // 終端のCRLF CRLFまでを含めたheadを検査する
            let head = Array(bytes[..<(terminatorStart + 4)])
            for (index, byte) in head.enumerated() {
                switch byte {
                case 0x0D:
                    XCTAssertTrue(index + 1 < head.count && head[index + 1] == 0x0A, "単独のCR: \(kind)")
                case 0x0A:
                    XCTAssertTrue(index > 0 && head[index - 1] == 0x0D, "単独のLF: \(kind)")
                default:
                    XCTAssertTrue((0x20...0x7E).contains(byte), "headに印字可能ASCII以外: \(kind)")
                }
            }
        }
    }

    func testBodyHasNoLineBreaksOrControlCharacters() throws {
        for kind in Kind.allCases {
            let parsed = try parse(try build(kind))
            let text = try bodyText(parsed)
            XCTAssertFalse(text.isEmpty, "\(kind)")
            // 本文にCR・LFが無ければ、2個目のCRLF CRLFが紛れ込んでheadと誤読されることもない
            for scalar in text.unicodeScalars {
                XCTAssertFalse(scalar.properties.generalCategory == .control, "本文に制御文字: \(kind)")
            }
        }
    }

    func testResponseFitsWithinMaxLength() throws {
        for kind in Kind.allCases {
            let data = try build(kind)
            XCTAssertLessThanOrEqual(data.count, ChatGPTOAuthLoopbackResponseBuilder.maxResponseLength, "\(kind)")
        }
    }

    func testResponseByteLengthIsHeadPlusContentLength() throws {
        for kind in Kind.allCases {
            let data = try build(kind)
            let parsed = try parse(data)
            let contentLength = try XCTUnwrap(Int(try XCTUnwrap(parsed.values(named: "Content-Length").first)))
            let bytes = [UInt8](data)
            let terminatorStart = try XCTUnwrap(firstIndex(of: [0x0D, 0x0A, 0x0D, 0x0A], in: bytes))
            // 本文の後ろに余分なバイトが無いこと
            XCTAssertEqual(data.count, terminatorStart + 4 + contentLength, "\(kind)")
        }
    }

    // MARK: - 本文

    func testBodyIsShortJapanesePlainText() throws {
        for kind in Kind.allCases {
            let text = try bodyText(try parse(try build(kind)))
            // ひらがな・カタカナを含む日本語であること
            let hasKana = text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
            XCTAssertTrue(hasKana, "\(kind)")
            // 短い固定文であること（1行・200バイト以下）
            XCTAssertLessThanOrEqual(text.utf8.count, 200, "\(kind)")
            // HTML・URL・queryのような形を含めない（プレーンテキストで、リンクや入力の反映がない）
            for forbidden in ["<", ">", "http", "://", "?", "=", "&", "%"] {
                XCTAssertFalse(text.contains(forbidden), "本文に\(forbidden): \(kind)")
            }
        }
    }

    func testBodiesAreDistinctPerKind() throws {
        let bodies = try Kind.allCases.map { try bodyText(try parse(try build($0))) }
        XCTAssertEqual(Set(bodies).count, Kind.allCases.count)
    }

    func testCallbackReceivedBodyGuidesBackToAppWithoutClaimingSignIn() throws {
        let text = try bodyText(try parse(try build(.callbackReceived)))
        // ブラウザがcallbackを受け取ったことと、アプリへ戻る案内を含む
        XCTAssertTrue(text.contains("受け取りました"))
        XCTAssertTrue(text.contains("アプリ"))
        XCTAssertTrue(text.contains("戻"))
        // サインイン完了とは書かない（token交換・検証はこの後アプリ側で行う）
        for word in completionWords {
            XCTAssertFalse(text.contains(word), "成功時の本文に\(word)")
        }
    }

    func testNonSuccessBodiesDoNotClaimCompletion() throws {
        for kind in Kind.allCases where kind != .callbackReceived {
            let text = try bodyText(try parse(try build(kind)))
            for word in completionWords {
                XCTAssertFalse(text.contains(word), "\(kind)の本文に\(word)")
            }
            XCTAssertFalse(text.contains("受け取りました"), "\(kind)")
        }
    }
}
