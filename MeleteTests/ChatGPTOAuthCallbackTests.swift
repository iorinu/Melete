import XCTest
@testable import Melete

// ChatGPT OAuth初回登録callbackの純粋な検査だけを検証する。
// ネットワーク・listener・ブラウザ・Keychain・保存には一切触れない。値はすべてテスト専用の合成固定値。
// 判定順: expectation → 全体の長さ → redirect URI → queryの分解（encoding） → state
//         → query構造（scope等の重複） → iss → error → code → client_id
final class ChatGPTOAuthCallbackTests: XCTestCase {
    // 合成の固定値（実際の認証には使われない）
    private let syntheticBase = "http://127.0.0.1:49152/auth/callback"
    private let syntheticState = "SyntheticCallbackState0123456789-_abcdefghi"   // 43文字
    private let otherState = "OtherSyntheticStateValue0123456789-_abcdefg"        // 43文字
    private let syntheticCode = "SyntheticAuthorizationCode-0123456789_abcdef"
    private let syntheticClientID = "synthetic_client_id_0123456789"
    private let requestedScope = "openid%20profile%20email%20offline_access%20resource.invoke%20chatgpt.tokens.use.direct"
    // 公式sign-in callbackと同じ形式（application/x-www-form-urlencodedで、+がspaceを表す）
    private let officialFormScope = "chatgpt.tokens.use.direct+email+offline_access+openid+profile+resource.invoke"

    // XCTestCaseのexpectation(description:)と名前が衝突しないようsynthetic接頭辞を付ける
    private var syntheticExpectation: ChatGPTOAuthCallbackExpectation {
        ChatGPTOAuthCallbackExpectation(redirectURI: URL(string: syntheticBase)!, state: syntheticState)
    }

    private var stateItem: String { "state=\(syntheticState)" }
    private var codeItem: String { "code=\(syntheticCode)" }
    private var clientIDItem: String { "client_id=\(syntheticClientID)" }

    private func callback(_ items: [String], base: String? = nil) -> String {
        (base ?? syntheticBase) + "?" + items.joined(separator: "&")
    }

    private var validCallback: String { callback([codeItem, stateItem, clientIDItem]) }

    private func validate(
        _ callback: String,
        expecting expectation: ChatGPTOAuthCallbackExpectation? = nil
    ) throws -> ChatGPTOAuthCallbackResult {
        try ChatGPTOAuthCallbackValidator.validate(callback: callback, expecting: expectation ?? syntheticExpectation)
    }

    // 「何かthrowすればよい」ではなく、期待した理由で拒否されたことまで確認する
    private func assertRejects(
        _ callback: String,
        as expected: ChatGPTOAuthCallbackError,
        expecting expectation: ChatGPTOAuthCallbackExpectation? = nil,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try validate(callback, expecting: expectation), label, file: file, line: line) { error in
            XCTAssertEqual(error as? ChatGPTOAuthCallbackError, expected, label, file: file, line: line)
        }
    }

    // MARK: - fixtureの前提

    func testSyntheticFixturesHaveExpectedShape() {
        XCTAssertEqual(syntheticState.count, 43)
        XCTAssertEqual(otherState.count, 43)
        XCTAssertNotEqual(syntheticState, otherState)
    }

    // MARK: - positive control

    func testAcceptsValidCallbackAndReturnsCodeAndClientID() throws {
        let result = try validate(validCallback)
        XCTAssertEqual(result.code, syntheticCode)
        XCTAssertEqual(result.clientID, syntheticClientID)
    }

    func testAcceptsParametersInAnyOrder() throws {
        let result = try validate(callback([clientIDItem, stateItem, codeItem]))
        XCTAssertEqual(result.code, syntheticCode)
        XCTAssertEqual(result.clientID, syntheticClientID)
    }

    func testIgnoresWellFormedScopeThatDiffersFromRequest() throws {
        // callbackのscopeは許可判定に使わない（後段のtoken responseが正本）
        let scopes = [
            requestedScope,
            "openid",
            "openid%20profile",
            "chatgpt.tokens.use.direct%20openid",
            "",
        ]
        for scope in scopes {
            let result = try validate(callback([codeItem, stateItem, clientIDItem, "scope=\(scope)"]))
            XCTAssertEqual(result.code, syntheticCode, scope)
            XCTAssertEqual(result.clientID, syntheticClientID, scope)
        }
    }

    func testAcceptsPortBoundariesWhenExpectationMatches() throws {
        for port in [1, 65535] {
            let base = "http://127.0.0.1:\(port)/auth/callback"
            let expectation = ChatGPTOAuthCallbackExpectation(redirectURI: URL(string: base)!, state: syntheticState)
            let result = try validate(callback([codeItem, stateItem, clientIDItem], base: base), expecting: expectation)
            XCTAssertEqual(result.code, syntheticCode)
        }
    }

    // MARK: - 基準値（expectation）

    func testRejectsInvalidExpectationEvenWhenCallbackMatchesIt() {
        // 空stateどうしの一致などで通らないよう、基準値自体もデフォルト拒否する
        let invalidStates = ["", String(repeating: "a", count: 42), String(repeating: "a", count: 42) + "&"]
        for state in invalidStates {
            let expectation = ChatGPTOAuthCallbackExpectation(redirectURI: URL(string: syntheticBase)!, state: state)
            let encoded = state.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            assertRejects(
                callback([codeItem, "state=\(encoded)", clientIDItem]),
                as: .invalidExpectation,
                expecting: expectation,
                "invalid expected state"
            )
        }

        let invalidRedirects = [
            "http://localhost:49152/auth/callback",
            "https://127.0.0.1:49152/auth/callback",
            "http://127.0.0.1/auth/callback",
            "http://127.0.0.1:49152/auth/callback/",
            "http://127.0.0.1:49152/auth/callback?x=1",
        ]
        for redirect in invalidRedirects {
            let expectation = ChatGPTOAuthCallbackExpectation(redirectURI: URL(string: redirect)!, state: syntheticState)
            assertRejects(
                callback([codeItem, stateItem, clientIDItem], base: redirect),
                as: .invalidExpectation,
                expecting: expectation,
                redirect
            )
        }
    }

    // MARK: - 上限

    func testAcceptsCallbackAtMaximumLengthAndRejectsOneByteOver() throws {
        let prefix = callback([codeItem, stateItem, clientIDItem, "scope="])
        let padding = ChatGPTOAuthCallbackValidator.maxCallbackUTF8Length - prefix.utf8.count
        let exact = prefix + String(repeating: "a", count: padding)
        XCTAssertEqual(exact.utf8.count, ChatGPTOAuthCallbackValidator.maxCallbackUTF8Length)

        XCTAssertEqual(try validate(exact).code, syntheticCode)
        assertRejects(exact + "a", as: .callbackTooLong, "one byte over")
    }

    func testRejectsTooLongCallbackBeforeOtherChecks() {
        // 長すぎる入力はstate不一致などより先に拒否する
        let tooLong = callback(["code=" + String(repeating: "a", count: 5000), "state=\(otherState)"])
        assertRejects(tooLong, as: .callbackTooLong, "too long")
    }

    func testCodeAndClientIDLengthLimits() throws {
        let maxCode = String(repeating: "a", count: ChatGPTOAuthCallbackValidator.maxCodeLength)
        XCTAssertEqual(try validate(callback(["code=\(maxCode)", stateItem, clientIDItem])).code, maxCode)
        assertRejects(callback(["code=\(maxCode)a", stateItem, clientIDItem]), as: .invalidCode, "code too long")

        let maxClientID = String(repeating: "b", count: ChatGPTOAuthCallbackValidator.maxClientIDLength)
        XCTAssertEqual(try validate(callback([codeItem, stateItem, "client_id=\(maxClientID)"])).clientID, maxClientID)
        assertRejects(
            callback([codeItem, stateItem, "client_id=\(maxClientID)b"]),
            as: .invalidClientID,
            "client_id too long"
        )
    }

    // MARK: - redirect URI

    func testRejectsUnexpectedRedirectURIs() {
        let bases = [
            "https://127.0.0.1:49152/auth/callback",     // scheme違い
            "HTTP://127.0.0.1:49152/auth/callback",
            "http://localhost:49152/auth/callback",      // host違い
            "http://127.0.0.2:49152/auth/callback",
            "http://[::1]:49152/auth/callback",
            "http://127.0.0.1:49153/auth/callback",      // port違い
            "http://127.0.0.1:049152/auth/callback",     // 非正規のport表記
            "http://127.0.0.1/auth/callback",            // port省略
            "http://127.0.0.1:49152/auth/callback/",     // path違い
            "http://127.0.0.1:49152/auth/Callback",
            "http://127.0.0.1:49152/auth/callback/extra",
            "http://127.0.0.1:49152/auth/%63allback",    // percent-encodedのpath
            "http://127.0.0.1:49152/",
            "http://user@127.0.0.1:49152/auth/callback", // userinfo付き
            " http://127.0.0.1:49152/auth/callback",     // 前後空白
            "/auth/callback",                            // 相対参照
            "",
        ]
        for base in bases {
            assertRejects(callback([codeItem, stateItem, clientIDItem], base: base), as: .unexpectedRedirectURI, base)
        }
        assertRejects(validCallback + "\n", as: .malformedCallback, "trailing newline")
    }

    // MARK: - queryの構造・encoding

    func testRejectsFragment() {
        assertRejects(validCallback + "#fragment", as: .malformedCallback, "fragment")
        assertRejects(validCallback + "#", as: .malformedCallback, "empty fragment")
        assertRejects(
            syntheticBase + "#?" + [codeItem, stateItem, clientIDItem].joined(separator: "&"),
            as: .malformedCallback,
            "fragment before query"
        )
    }

    func testRejectsInvalidPercentEncoding() {
        let values = [
            "%ZZ",        // 16進数でない
            "%",          // 途中で切れている
            "%4",
            "%E3%81",     // 不完全なUTF-8
            "%FF",        // UTF-8として不正
            "%C0%AF",     // overlong encoding
        ]
        for value in values {
            assertRejects(callback(["code=abc\(value)", stateItem, clientIDItem]), as: .malformedCallback, value)
        }
        // 生の非ASCII文字や、query中で意味を持つ予約文字の生埋め込みも拒否する
        assertRejects(callback(["code=abcあ", stateItem, clientIDItem]), as: .malformedCallback, "raw non-ASCII")
        assertRejects(callback(["code=a=b", stateItem, clientIDItem]), as: .malformedCallback, "raw =")
        assertRejects(callback(["code=a?b", stateItem, clientIDItem]), as: .malformedCallback, "raw ?")
        assertRejects(callback(["code=a b", stateItem, clientIDItem]), as: .malformedCallback, "raw space")
    }

    func testRejectsMalformedQueryStructure() {
        let cases: [(String, String)] = [
            (callback([codeItem, "", stateItem, clientIDItem]), "empty segment"),
            (callback([codeItem, stateItem, clientIDItem]) + "&", "trailing &"),
            (callback(["", codeItem, stateItem, clientIDItem]), "leading &"),
            (callback(["code", stateItem, clientIDItem]), "key without ="),
            (callback(["=value", codeItem, stateItem, clientIDItem]), "empty key"),
            (syntheticBase + "??" + [codeItem, stateItem, clientIDItem].joined(separator: "&"), "double ?"),
        ]
        for (url, label) in cases {
            assertRejects(url, as: .malformedCallback, label)
        }
    }

    func testUnexpectedQueryParametersAreIgnoredOrRejectedByDecodedKey() throws {
        // 未知のkeyは無視する（RFC 6749 4.1.2）。大文字違いのkeyは既知のkeyとは別物なので、codeを上書きしない
        let ignoredExtras = [
            "extra=1",
            "Code=OtherSyntheticCode",
            "redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Fauth%2Fcallback",
        ]
        for extra in ignoredExtras {
            let result = try validate(callback([codeItem, stateItem, clientIDItem, extra]))
            XCTAssertEqual(result.code, syntheticCode, extra)
            XCTAssertEqual(result.clientID, syntheticClientID, extra)
        }
        // デコード後に既知のkeyになるものは無視せず、既知のkeyとして検査する
        assertRejects(
            callback([codeItem, stateItem, clientIDItem, "%63ode=\(syntheticCode)"]),
            as: .invalidCode,
            "%63ode duplicates code"
        )
        assertRejects(
            callback([codeItem, stateItem, clientIDItem, "iss=https%3A%2F%2Fauth.example.invalid"]),
            as: .invalidIssuer,
            "unexpected iss"
        )
    }

    func testRejectsMalformedUnrecognizedParameters() {
        // 未知のkeyでも、keyと値の構文（encoding・UTF-8・生の予約文字）が不正なら無視せず拒否する
        let extras = [
            "x_synthetic=%ZZ",       // 値の不正なencoding
            "x_synthetic=%",
            "x_synthetic=%FF",       // 値が不正なUTF-8
            "x_synthetic=%C0%AF",    // 値がoverlong encoding
            "x_synthetic=あ",         // 値に生の非ASCII
            "x_synthetic=a=b",       // 値に生の =
            "x_synthetic=a?b",       // 値に生の ?
            "x_synthetic=a b",       // 値に生のspace
            "x%ZZ=1",                // keyの不正なencoding
            "x%4=1",
            "x%FF=1",                // keyが不正なUTF-8
            "x%E3%81=1",             // keyが不完全なUTF-8
            "xあ=1",                  // keyに生の非ASCII
            "x?y=1",                 // keyに生の ?
            "x y=1",                 // keyに生のspace
            "x_synthetic",           // = が無い
        ]
        for extra in extras {
            assertRejects(callback([codeItem, stateItem, clientIDItem, extra]), as: .malformedCallback, extra)
        }
    }

    // MARK: - state

    func testRejectsMissingDuplicatedOrMismatchedState() {
        let cases: [([String], String)] = [
            ([codeItem, clientIDItem], "missing"),
            ([codeItem, stateItem, stateItem, clientIDItem], "duplicated same value"),
            ([codeItem, stateItem, "state=\(otherState)", clientIDItem], "duplicated different value"),
            ([codeItem, "state=", clientIDItem], "empty"),
            ([codeItem, "state=\(otherState)", clientIDItem], "mismatch"),
            ([codeItem, "state=\(syntheticState.uppercased())", clientIDItem], "case differs"),
            ([codeItem, "state=\(syntheticState)x", clientIDItem], "extra char"),
            ([codeItem, "state=\(syntheticState.dropLast())", clientIDItem], "prefix only"),
        ]
        for (items, label) in cases {
            assertRejects(callback(items), as: .invalidState, label)
        }
        // queryが無いcallbackもstate欠落として扱う
        assertRejects(syntheticBase, as: .invalidState, "no query")
    }

    // MARK: - OAuth error（state検証の後に判定し、codeは返さない）

    func testRejectsOAuthErrorAfterStateValidation() {
        assertRejects(callback(["error=access_denied", stateItem]), as: .authorizationFailed, "error only")
        assertRejects(
            callback(["error=access_denied", "error_description=Synthetic%20denial", "error_uri=https%3A%2F%2Ferror.example.invalid", stateItem]),
            as: .authorizationFailed,
            "error with description"
        )
        assertRejects(callback(["error=access_denied", stateItem, clientIDItem]), as: .authorizationFailed, "error with client_id")
        assertRejects(callback(["error=", stateItem]), as: .authorizationFailed, "empty error")
    }

    func testStateIsCheckedBeforeOAuthError() {
        // stateが通らない限り、errorの内容を信用して分岐しない
        let cases: [([String], String)] = [
            (["error=access_denied"], "missing state"),
            (["error=access_denied", "state=\(otherState)"], "mismatched state"),
            (["error=access_denied", stateItem, stateItem], "duplicated state"),
            (["error=access_denied", codeItem, "state=\(otherState)", clientIDItem], "mismatched state with code"),
        ]
        for (items, label) in cases {
            assertRejects(callback(items), as: .invalidState, label)
        }
    }

    func testRejectsErrorAndCodeTogether() {
        assertRejects(callback(["error=access_denied", codeItem, stateItem, clientIDItem]), as: .conflictingParameters, "error and code")
        assertRejects(callback(["error=", codeItem, stateItem, clientIDItem]), as: .conflictingParameters, "empty error and code")
        assertRejects(callback(["error=server_error", "code=", stateItem]), as: .conflictingParameters, "error and empty code")
    }

    // MARK: - code（stateが正しくても不正なら拒否）

    func testRejectsInvalidCodeEvenWithMatchingState() {
        let cases: [([String], String)] = [
            ([stateItem, clientIDItem], "missing"),
            (["code=", stateItem, clientIDItem], "empty"),
            ([codeItem, codeItem, stateItem, clientIDItem], "duplicated same value"),
            ([codeItem, "code=OtherSyntheticCode", stateItem, clientIDItem], "duplicated different value"),
            (["code=abc%00def", stateItem, clientIDItem], "NUL"),
            (["code=abc%0Adef", stateItem, clientIDItem], "newline"),
            (["code=abc%20def", stateItem, clientIDItem], "space"),
            (["code=abc%E3%81%82", stateItem, clientIDItem], "non-ASCII"),
        ]
        for (items, label) in cases {
            assertRejects(callback(items), as: .invalidCode, label)
        }
    }

    // MARK: - client_id（stateが正しくても不正なら拒否）

    func testRejectsInvalidClientIDEvenWithMatchingState() {
        let cases: [([String], String)] = [
            ([codeItem, stateItem], "missing"),
            ([codeItem, stateItem, "client_id="], "empty"),
            ([codeItem, stateItem, clientIDItem, clientIDItem], "duplicated same value"),
            ([codeItem, stateItem, clientIDItem, "client_id=other_synthetic_client"], "duplicated different value"),
            ([codeItem, stateItem, "client_id=abc%00def"], "NUL"),
            ([codeItem, stateItem, "client_id=abc%0Adef"], "newline"),
            ([codeItem, stateItem, "client_id=abc%20def"], "space"),
            ([codeItem, stateItem, "client_id=abc%E3%81%82"], "non-ASCII"),
        ]
        for (items, label) in cases {
            assertRejects(callback(items), as: .invalidClientID, label)
        }
    }

    func testRejectsDynamicAgentClientPlaceholderEvenWithMatchingStateAndCode() {
        // 回帰テスト: dynamic_agent_clientは初回登録requestで使うプレースホルダで、発行済みのclient_idではない。
        // 保存やtoken exchangeに使わせないため、stateとcodeが正しくてもinvalidClientIDで拒否する
        let cases: [([String], String)] = [
            ([codeItem, stateItem, "client_id=dynamic_agent_client"], "placeholder"),
            ([codeItem, stateItem, "client_id=dynamic%5Fagent%5Fclient"], "placeholder percent-encoded"),
            ([codeItem, "scope=\(officialFormScope)", stateItem, "client_id=dynamic_agent_client"], "placeholder in official form"),
        ]
        for (items, label) in cases {
            assertRejects(callback(items), as: .invalidClientID, label)
        }
    }

    // MARK: - 公式形式のcallback（form-urlencoded: + はspace、%2B はリテラルの +）

    func testAcceptsOfficialFormCallbackWithPlusSeparatedScope() throws {
        // 公式sign-in callbackと同じ並び・形式の合成callback
        let result = try validate(callback([codeItem, "scope=\(officialFormScope)", stateItem, clientIDItem]))
        XCTAssertEqual(result.code, syntheticCode)
        XCTAssertEqual(result.clientID, syntheticClientID)

        // 結果はcodeとclient_idだけを持ち、scopeは返さない（scopeはtoken responseを正本とする）
        let labels = Mirror(reflecting: result).children.compactMap { $0.label }
        XCTAssertEqual(labels, ["code", "clientID"])
    }

    func testAcceptsOfficialFormScopeInAnyOrderAndMixedEncoding() throws {
        let scopes = [
            officialFormScope,
            "openid+profile%20email",    // + と %20 の混在（どちらもspace）
            "openid%2Bprofile",          // %2B はリテラルの + （RFC 6749のscope-tokenに含められる文字）
        ]
        for scope in scopes {
            let result = try validate(callback(["scope=\(scope)", clientIDItem, stateItem, codeItem]))
            XCTAssertEqual(result.code, syntheticCode, scope)
            XCTAssertEqual(result.clientID, syntheticClientID, scope)
        }
    }

    func testPlusInValuesDecodesToSpace() {
        // + はspaceにデコードされるので、spaceを含む値と同じ理由で拒否される
        assertRejects(callback(["code=abc+def", stateItem, clientIDItem]), as: .invalidCode, "+ in code")
        assertRejects(callback(["code=+", stateItem, clientIDItem]), as: .invalidCode, "code is only +")
        assertRejects(callback([codeItem, stateItem, "client_id=abc+def"]), as: .invalidClientID, "+ in client_id")
        assertRejects(callback([codeItem, "state=\(syntheticState)+", clientIDItem]), as: .invalidState, "+ after state")
        assertRejects(callback([codeItem, "state=+\(syntheticState)", clientIDItem]), as: .invalidState, "+ before state")
    }

    func testPercentEncodedPlusIsLiteralPlusNotSpace() {
        // %2B はspaceではなく + 。stateは英数字と -._~ だけなので、+ が混ざれば不一致になる
        assertRejects(callback([codeItem, "state=\(syntheticState)%2B", clientIDItem]), as: .invalidState, "%2B after state")
        assertRejects(callback([codeItem, "state=%2B\(syntheticState)", clientIDItem]), as: .invalidState, "%2B before state")
    }

    func testPercentEncodedPlusIsPreservedInOpaqueCodeAndClientID() throws {
        // codeとissued client_idはopaque値として扱い、デコード後の安全な可視ASCII（0x21-0x7E）なら + も許容する
        // 生の + はspaceにデコードされるため、従来どおり拒否される（testPlusInValuesDecodesToSpace）
        let result = try validate(callback(["code=abc%2Bdef", stateItem, "client_id=oaiapp_synthetic%2Bvalue"]))
        XCTAssertEqual(result.code, "abc+def")
        XCTAssertEqual(result.clientID, "oaiapp_synthetic+value")
    }

    func testRejectsDuplicatedScope() {
        let cases: [([String], String)] = [
            ([codeItem, "scope=\(officialFormScope)", "scope=\(officialFormScope)", stateItem, clientIDItem], "same value"),
            ([codeItem, "scope=\(officialFormScope)", "scope=openid", stateItem, clientIDItem], "different value"),
            ([codeItem, "scope=openid+profile", "scope=openid%20profile", stateItem, clientIDItem], "same after decoding"),
            ([codeItem, "scope=", "scope=", stateItem, clientIDItem], "both empty"),
        ]
        for (items, label) in cases {
            assertRejects(callback(items), as: .malformedCallback, label)
        }
    }

    // MARK: - state照合とscope重複などの構造検査の順序
    //
    // scope等の重複はstate照合の後に判定する。stateが一致しない応答で malformedCallback を返すと、
    // 呼び出し側が「state一致後の拒否」と取り違えて配送枠や試行を消費してしまうため

    func testStateIsCheckedBeforeDuplicatedScope() {
        let duplicatedScope = ["scope=\(officialFormScope)", "scope=openid"]
        let cases: [([String], String)] = [
            ([codeItem, "state=\(otherState)", clientIDItem] + duplicatedScope, "wrong state + duplicated scope"),
            ([codeItem, clientIDItem] + duplicatedScope, "missing state + duplicated scope"),
            ([codeItem, stateItem, stateItem, clientIDItem] + duplicatedScope, "duplicated state + duplicated scope"),
            ([codeItem, "state=", clientIDItem] + duplicatedScope, "empty state + duplicated scope"),
            ([codeItem, "state=\(otherState)", clientIDItem, "error_description=a"], "wrong state + description without error"),
            (["error=access_denied", "error=server_error", "state=\(otherState)"], "wrong state + duplicated error"),
        ]
        for (items, label) in cases {
            assertRejects(callback(items), as: .invalidState, label)
        }
    }

    func testVerifyStateSucceedsOnlyForUniqueMatchingState() throws {
        // stateが一意に一致していれば、scopeが重複していてもverifyStateは合格し、validateResponseで拒否される
        let maliciousScope = callback([codeItem, "scope=openid", "scope=\(officialFormScope)", stateItem, clientIDItem])
        let verified = try ChatGPTOAuthCallbackValidator.verifyState(callback: maliciousScope, expecting: syntheticExpectation)
        XCTAssertThrowsError(try ChatGPTOAuthCallbackValidator.validateResponse(stateVerified: verified)) { error in
            XCTAssertEqual(error as? ChatGPTOAuthCallbackError, .malformedCallback)
        }

        // 正当なcallbackは2段階を通して validate と同じ結果になる
        let valid = try ChatGPTOAuthCallbackValidator.verifyState(callback: validCallback, expecting: syntheticExpectation)
        let result = try ChatGPTOAuthCallbackValidator.validateResponse(stateVerified: valid)
        XCTAssertEqual(result.code, syntheticCode)
        XCTAssertEqual(result.clientID, syntheticClientID)
    }

    func testVerifyStateRejectsWhenStateCannotBeConfirmed() {
        // state照合前に見つかった構文エラーは、stateが正しく見えても「一致を確認できない」として拒否する
        let cases: [(String, ChatGPTOAuthCallbackError, String)] = [
            (callback([codeItem, "state=\(otherState)", clientIDItem]), .invalidState, "mismatch"),
            (callback([codeItem, clientIDItem]), .invalidState, "missing"),
            (callback([codeItem, stateItem, stateItem, clientIDItem]), .invalidState, "duplicated"),
            (callback([codeItem, stateItem, "%73tate=\(otherState)", clientIDItem]), .invalidState, "duplicated by encoded key"),
            (callback([codeItem, "state=\(otherState)", clientIDItem, "scope=a", "scope=b"]), .invalidState, "mismatch + duplicated scope"),
            (callback([codeItem, stateItem, "", clientIDItem]), .malformedCallback, "empty segment with correct state"),
            (callback([codeItem, stateItem, clientIDItem, "x_synthetic=%FF"]), .malformedCallback, "bad encoding with correct state"),
            (validCallback + "#fragment", .malformedCallback, "fragment with correct state"),
        ]
        for (url, expected, label) in cases {
            XCTAssertThrowsError(
                try ChatGPTOAuthCallbackValidator.verifyState(callback: url, expecting: syntheticExpectation),
                label
            ) { error in
                XCTAssertEqual(error as? ChatGPTOAuthCallbackError, expected, label)
            }
        }
    }

    func testStateVerifiedCallbackDoesNotRevealValues() throws {
        let verified = try ChatGPTOAuthCallbackValidator.verifyState(
            callback: callback([codeItem, "scope=\(officialFormScope)", stateItem, clientIDItem]),
            expecting: syntheticExpectation
        )
        var dumped = ""
        dump(verified, to: &dumped)
        let outputs = [String(describing: verified), String(reflecting: verified), "\(verified)", dumped]
        for output in outputs {
            XCTAssertFalse(output.contains(syntheticCode))
            XCTAssertFalse(output.contains(syntheticState))
            XCTAssertFalse(output.contains(syntheticClientID))
            XCTAssertFalse(output.contains(syntheticBase))
            XCTAssertFalse(output.contains("openid"))
        }
        XCTAssertTrue(Mirror(reflecting: verified).children.isEmpty)
    }

    func testRejectsDuplicatedStateInOfficialFormCallback() {
        let cases: [([String], String)] = [
            ([codeItem, "scope=\(officialFormScope)", stateItem, stateItem, clientIDItem], "same value"),
            ([codeItem, "scope=\(officialFormScope)", stateItem, "state=\(otherState)", clientIDItem], "different value"),
        ]
        for (items, label) in cases {
            assertRejects(callback(items), as: .invalidState, label)
        }
    }

    func testRejectsDuplicatedKeysThatAppearOnlyAfterPercentDecoding() {
        // keyはform-decodeしてから照合する。デコード後に既知のkeyと重複すれば、そのkeyの重複として拒否する
        let cases: [([String], String, ChatGPTOAuthCallbackError)] = [
            ([codeItem, stateItem, "%73tate=\(syntheticState)", clientIDItem], "%73tate", .invalidState),
            ([codeItem, stateItem, "st%61te=\(otherState)", clientIDItem], "st%61te", .invalidState),
            ([codeItem, "%63ode=\(syntheticCode)", stateItem, clientIDItem], "%63ode", .invalidCode),
            ([codeItem, stateItem, clientIDItem, "client%5Fid=\(syntheticClientID)"], "client%5Fid", .invalidClientID),
            ([codeItem, "scope=\(officialFormScope)", "%73cope=openid", stateItem, clientIDItem], "%73cope", .malformedCallback),
            ([codeItem, "scope=\(officialFormScope)", "sc%6Fpe=openid", stateItem, clientIDItem], "sc%6Fpe", .malformedCallback),
            (["error=access_denied", "%65rror=server_error", stateItem], "%65rror", .malformedCallback),
            (["error=access_denied", "error_description=a", "error%5Fdescription=b", stateItem], "error%5Fdescription", .malformedCallback),
            (["error=access_denied", "error_uri=a", "error%5Furi=b", stateItem], "error%5Furi", .malformedCallback),
        ]
        for (items, label, expected) in cases {
            assertRejects(callback(items), as: expected, label)
        }
        // encodeされたkeyでもerror無しのerror_descriptionは構造エラー
        assertRejects(
            callback([codeItem, stateItem, clientIDItem, "error%5Fdescription=a"]),
            as: .malformedCallback,
            "error%5Fdescription without error"
        )
    }

    func testKeysContainingPlusOrEncodedPlusDoNotMatchKnownKeys() throws {
        // + はspace、%2B はリテラルの + にデコードされるため、既知のkeyとは一致しない未知のkeyとして無視される。
        // 既知のkeyの値を上書き・重複させないことを、codeとclient_idが変わらないことで確認する
        let extras = [
            "scope+=openid",
            "+scope=openid",
            "state%2B=\(otherState)",
            "code%20=OtherSyntheticCode",
            "client_id+=other_synthetic_client",
        ]
        for extra in extras {
            let result = try validate(callback([codeItem, stateItem, clientIDItem, extra]))
            XCTAssertEqual(result.code, syntheticCode, extra)
            XCTAssertEqual(result.clientID, syntheticClientID, extra)
        }
        // 既知のkey側が欠けていれば、+ 付きのkeyで代用されず欠落として拒否する
        assertRejects(callback([codeItem, "state+=\(syntheticState)", clientIDItem]), as: .invalidState, "state+ only")
        assertRejects(callback(["code+=\(syntheticCode)", stateItem, clientIDItem]), as: .invalidCode, "code+ only")
    }

    func testOfficialFormErrorFailsOnlyAfterStateValidation() {
        // 正しいstateならOAuth errorとして失敗させる（codeは返さない）
        assertRejects(
            callback(["error=access_denied", "scope=\(officialFormScope)", stateItem]),
            as: .authorizationFailed,
            "access_denied with official scope"
        )
        assertRejects(
            callback(["error=access_denied", "error_description=Synthetic+denial+message", stateItem]),
            as: .authorizationFailed,
            "access_denied with + encoded description"
        )
        // stateが通らなければerrorの内容より先にstateで拒否する
        assertRejects(
            callback(["error=access_denied", "scope=\(officialFormScope)", "state=\(otherState)"]),
            as: .invalidState,
            "access_denied with mismatched state"
        )
        assertRejects(
            callback(["error=access_denied", "state=\(syntheticState)+"]),
            as: .invalidState,
            "access_denied with + appended state"
        )
    }

    func testUnspecifiedKeysAreIgnoredInOfficialFormCallback() throws {
        // このvalidatorが扱わないkeyは、構文が正しければ公式形式に付いていても無視する（RFC 6749 4.1.2）。
        // ただし値は結果に含めず、codeとclient_idだけが返る
        let extras = [
            "session_state=synthetic",
            "nonce=synthetic",
            "prompt=login",
            "response_type=code",
            "authuser=0",
        ]
        for extra in extras {
            let result = try validate(callback([codeItem, "scope=\(officialFormScope)", stateItem, clientIDItem, extra]))
            XCTAssertEqual(result.code, syntheticCode, extra)
            XCTAssertEqual(result.clientID, syntheticClientID, extra)
            let labels = Mirror(reflecting: result).children.compactMap { $0.label }
            XCTAssertEqual(labels, ["code", "clientID"], extra)
        }
        // issは未知のkeyではなくセキュリティ上の意味を持つため、無視せず検査する
        assertRejects(
            callback([codeItem, "scope=\(officialFormScope)", stateItem, clientIDItem, "iss=https%3A%2F%2Fauth.example.invalid"]),
            as: .invalidIssuer,
            "unexpected iss in official form"
        )
    }

    // MARK: - iss（RFC 9207。付いていた場合だけ検査する）

    func testAcceptsExpectedIssuer() throws {
        let issuers = [
            "https%3A%2F%2Fauth.openai.com",   // percent-encoded
            "https://auth.openai.com",         // : と / は値に生で書いてよい
        ]
        for issuer in issuers {
            let result = try validate(callback([codeItem, stateItem, clientIDItem, "iss=\(issuer)"]))
            XCTAssertEqual(result.code, syntheticCode, issuer)
            XCTAssertEqual(result.clientID, syntheticClientID, issuer)
            // encodeされたkeyでも同じissとして扱う
            let encodedKey = try validate(callback([codeItem, stateItem, clientIDItem, "%69ss=\(issuer)"]))
            XCTAssertEqual(encodedKey.code, syntheticCode, issuer)
        }
    }

    func testRejectsUnexpectedOrDuplicatedIssuer() {
        let expectedIssuer = "https%3A%2F%2Fauth.openai.com"
        let cases: [([String], String)] = [
            (["iss="], "empty"),
            (["iss=https%3A%2F%2Fauth.example.invalid"], "other issuer"),
            (["iss=http%3A%2F%2Fauth.openai.com"], "http scheme"),
            (["iss=https%3A%2F%2Fauth.openai.com%2F"], "trailing slash"),
            (["iss=https%3A%2F%2FAUTH.openai.com"], "case differs"),
            (["iss=https%3A%2F%2Fauth.openai.com.example.invalid"], "suffix"),
            (["iss=https%3A%2F%2Fauth.openai.com%3A443"], "explicit port"),
            (["iss=https%3A%2F%2Fauth.openai.com+"], "+ decodes to trailing space"),
            (["iss=+https%3A%2F%2Fauth.openai.com"], "leading space"),
            (["iss=auth.openai.com"], "host only"),
            (["iss=\(expectedIssuer)", "iss=\(expectedIssuer)"], "duplicated same value"),
            (["iss=\(expectedIssuer)", "iss=https%3A%2F%2Fauth.example.invalid"], "duplicated different value"),
            (["iss=\(expectedIssuer)", "%69ss=\(expectedIssuer)"], "duplicated after key decoding"),
        ]
        for (extras, label) in cases {
            assertRejects(callback([codeItem, stateItem, clientIDItem] + extras), as: .invalidIssuer, label)
        }
    }

    func testIssuerIsCheckedAfterStateAndBeforeOAuthError() {
        let wrongIssuer = "iss=https%3A%2F%2Fauth.example.invalid"
        // stateが通らなければissより先にstateで拒否する
        assertRejects(callback([codeItem, "state=\(otherState)", clientIDItem, wrongIssuer]), as: .invalidState, "mismatched state")
        assertRejects(callback(["error=access_denied", wrongIssuer]), as: .invalidState, "missing state with error")
        // errorレスポンスでも、errorの内容を信用する前にissを確認する
        assertRejects(callback(["error=access_denied", stateItem, wrongIssuer]), as: .invalidIssuer, "error with wrong iss")
        assertRejects(
            callback(["error=access_denied", codeItem, stateItem, wrongIssuer]),
            as: .invalidIssuer,
            "error and code with wrong iss"
        )
        // 正しいissならerrorレスポンスは従来どおり失敗として扱う
        assertRejects(
            callback(["error=access_denied", stateItem, "iss=https%3A%2F%2Fauth.openai.com"]),
            as: .authorizationFailed,
            "error with expected iss"
        )
        // 正しいissでもcode・client_idの検査は弱めない
        assertRejects(
            callback(["code=", stateItem, clientIDItem, "iss=https%3A%2F%2Fauth.openai.com"]),
            as: .invalidCode,
            "empty code with expected iss"
        )
        assertRejects(
            callback([codeItem, stateItem, "client_id=dynamic_agent_client", "iss=https%3A%2F%2Fauth.openai.com"]),
            as: .invalidClientID,
            "placeholder client_id with expected iss"
        )
    }

    func testRejectsMalformedIssuerSyntax() {
        // issの値も他と同じく構文検査を通す
        for issuer in ["%ZZ", "%FF", "https://auth.openai.com?x", "https://auth.openai.com あ"] {
            assertRejects(callback([codeItem, stateItem, clientIDItem, "iss=\(issuer)"]), as: .malformedCallback, issuer)
        }
    }

    // MARK: - RFC 6749 4.1.2への追従
    //
    // RFC 6749 4.1.2は「クライアントは認識できない応答パラメータを無視しなければならない」と定める。
    // keyもform-decodeしてから照合し、未知のkeyは構文検査とcallback全体の長さ上限を通った上で無視する。

    func testIgnoresWellFormedUnrecognizedAuthorizationResponseParameters() throws {
        // 未知のkeyが付いていない正しいcallbackの結果を基準にする
        let baseline = try validate(validCallback)

        // 合成の拡張パラメータ。既存のOAuth/OIDCパラメータ名（iss・nonceなど）とは重ならない名前にしている
        let extraSets: [[String]] = [
            ["x_synthetic_extension=1"],
            ["synthetic_ext=abc%20def"],              // percent-encodedのspace
            ["synthetic.ext-flag=on+off"],            // form形式の + （spaceにデコードされる）
            ["x_synthetic_empty="],                   // 空の値も形式としては正しい
            ["x_synthetic_a=1", "x_synthetic_b=2"],   // 複数の異なる未知のkey
        ]
        for extras in extraSets {
            let label = extras.joined(separator: "&")
            let plain = try validate(callback([codeItem, stateItem, clientIDItem] + extras))
            XCTAssertEqual(plain.code, baseline.code, label)
            XCTAssertEqual(plain.clientID, baseline.clientID, label)

            // 公式形式（scope付き）のcallbackに混ざっていても同じ結果になる
            let official = try validate(callback([codeItem, "scope=\(officialFormScope)", stateItem, clientIDItem] + extras))
            XCTAssertEqual(official.code, baseline.code, label)
            XCTAssertEqual(official.clientID, baseline.clientID, label)
        }
    }

    func testDecodesFormKeysBeforeDetectingDuplicateCriticalParameters() throws {
        // keyも値と同じくform-decodeしてから照合する。encodeされたkeyが単独なら通常のkeyとして受理する
        let singleEncodedKeyCases: [([String], String)] = [
            ([codeItem, "%73tate=\(syntheticState)", clientIDItem], "%73tate"),
            ([codeItem, "st%61te=\(syntheticState)", clientIDItem], "st%61te"),
            (["%63ode=\(syntheticCode)", stateItem, clientIDItem], "%63ode"),
            ([codeItem, stateItem, "client%5Fid=\(syntheticClientID)"], "client%5Fid"),
        ]
        for (items, label) in singleEncodedKeyCases {
            let result = try validate(callback(items))
            XCTAssertEqual(result.code, syntheticCode, label)
            XCTAssertEqual(result.clientID, syntheticClientID, label)
        }

        // デコード後に既存のstateと重複するなら、未知のkeyとして無視せずstateの重複として拒否する
        let duplicatedStateCases: [([String], String)] = [
            ([codeItem, stateItem, "%73tate=\(syntheticState)", clientIDItem], "state + %73tate same value"),
            ([codeItem, stateItem, "st%61te=\(otherState)", clientIDItem], "state + st%61te different value"),
            ([codeItem, "%73tate=\(syntheticState)", stateItem, clientIDItem], "%73tate before state"),
        ]
        for (items, label) in duplicatedStateCases {
            assertRejects(callback(items), as: .invalidState, label)
        }
    }

    // MARK: - 秘密値を表示しない

    func testResultAndExpectationDescriptionsDoNotRevealValues() throws {
        let result = try validate(validCallback)
        let expectation = syntheticExpectation
        var dumpedResult = ""
        dump(result, to: &dumpedResult)
        var dumpedExpectation = ""
        dump(expectation, to: &dumpedExpectation)
        let outputs = [
            String(describing: result), String(reflecting: result), "\(result)", dumpedResult,
            String(describing: expectation), String(reflecting: expectation), "\(expectation)", dumpedExpectation,
        ]
        for output in outputs {
            XCTAssertFalse(output.contains(syntheticCode))
            XCTAssertFalse(output.contains(syntheticState))
            XCTAssertFalse(output.contains(syntheticClientID))
        }
    }

    func testErrorDescriptionsDoNotRevealValues() {
        let cases: [(String, ChatGPTOAuthCallbackError)] = [
            (callback([codeItem, "state=\(otherState)", clientIDItem]), .invalidState),
            (callback(["error=access_denied", codeItem, stateItem, clientIDItem]), .conflictingParameters),
            (callback([codeItem, codeItem, stateItem, clientIDItem]), .invalidCode),
            (callback([codeItem, stateItem, clientIDItem, clientIDItem]), .invalidClientID),
            (callback([codeItem, stateItem, clientIDItem]) + "#fragment", .malformedCallback),
        ]
        for (url, expected) in cases {
            do {
                _ = try validate(url)
                XCTFail("拒否されるべき")
            } catch {
                XCTAssertEqual(error as? ChatGPTOAuthCallbackError, expected)
                let texts = [error.localizedDescription, String(describing: error), String(reflecting: error)]
                for text in texts {
                    XCTAssertFalse(text.contains(syntheticCode))
                    XCTAssertFalse(text.contains(syntheticState))
                    XCTAssertFalse(text.contains(otherState))
                    XCTAssertFalse(text.contains(syntheticClientID))
                }
            }
        }
    }
}
