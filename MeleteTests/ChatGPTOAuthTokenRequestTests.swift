import XCTest
@testable import Melete

// ChatGPT OAuth初回登録のtoken exchange requestの純粋な構築だけを検証する（テストファーストのRED）。
// ネットワーク・URLSession・Keychain・保存・ログには一切触れない。値はすべてテスト専用の合成固定値。
// 判定順（予定）: redirect URI → code verifier → 認可URLとの紐付け → code → client_id
final class ChatGPTOAuthTokenRequestTests: XCTestCase {
    // 合成の固定値（実際の認証には使われない）
    private let syntheticState = "SyntheticTokenState0123456789-_abcdefghijkl"      // 43文字
    private let syntheticNonce = "SyntheticTokenNonce0123456789-_mnopqrstuvwx"      // 43文字
    private let syntheticVerifier = "SyntheticTokenVerifier0123456789-._~abcdefg"   // 43文字
    private let otherVerifier = "OtherSyntheticVerifier0123456789-._~abcdefgh"      // 44文字
    private let syntheticHostID = "urn:uuid:11111111-2222-4333-8444-555555555555"
    private let syntheticRedirect = "http://127.0.0.1:49152/auth/callback"
    private let otherRedirect = "http://127.0.0.1:50000/auth/callback"
    // form内でescapeが必要な文字（+ & = % / ? # :）をわざと含めた合成code。すべて可視ASCII
    private let syntheticCode = "SyntheticTokenCode+With&Reserved=Chars%2F/?#:~_.-"
    private let encodedSyntheticCode = "SyntheticTokenCode%2BWith%26Reserved%3DChars%252F%2F%3F%23%3A~_.-"
    // callbackで発行された（という想定の）合成client_id
    private let syntheticClientID = "synthetic_issued_client_0123456789"
    private let registrationPlaceholderClientID = "dynamic_agent_client"

    private let expectedTokenEndpoint = "https://auth.openai.com/api/accounts/oauth/token"
    private let encodedSyntheticRedirect = "http%3A%2F%2F127.0.0.1%3A49152%2Fauth%2Fcallback"
    private let encodedResource = "https%3A%2F%2Fapi.openai.com%2Fv1"

    // MARK: - fixtureの組み立て

    // 本物のauthorization request builderに合成の固定乱数を注入して組み立てる（純粋な処理のみ）
    private func makeAuthorization(
        redirect: String? = nil,
        verifier: String? = nil
    ) throws -> ChatGPTOAuthAuthorizationRequest {
        let secrets = ChatGPTOAuthAuthorizationSecrets(
            state: syntheticState,
            nonce: syntheticNonce,
            codeVerifier: verifier ?? syntheticVerifier
        )
        let builder = ChatGPTOAuthAuthorizationRequestBuilder(makeSecrets: { secrets })
        return try builder.build(agentHostID: syntheticHostID, redirectURI: URL(string: redirect ?? syntheticRedirect)!)
    }

    // 認可URL・redirect URI・verifierのうち指定したものだけを差し替えた（紐付けの壊れた）requestを作る
    private func tampered(
        _ original: ChatGPTOAuthAuthorizationRequest,
        authorizationURL: URL? = nil,
        redirectURI: URL? = nil,
        codeVerifier: String? = nil
    ) -> ChatGPTOAuthAuthorizationRequest {
        ChatGPTOAuthAuthorizationRequest(
            authorizationURL: authorizationURL ?? original.authorizationURL,
            redirectURI: redirectURI ?? original.redirectURI,
            state: original.state,
            nonce: original.nonce,
            codeVerifier: codeVerifier ?? original.codeVerifier
        )
    }

    private func makeCallback(code: String? = nil, clientID: String? = nil) -> ChatGPTOAuthCallbackResult {
        ChatGPTOAuthCallbackResult(code: code ?? syntheticCode, clientID: clientID ?? syntheticClientID)
    }

    private func build(
        authorization: ChatGPTOAuthAuthorizationRequest? = nil,
        callback: ChatGPTOAuthCallbackResult? = nil
    ) throws -> ChatGPTOAuthTokenRequest {
        try ChatGPTOAuthTokenRequestBuilder.build(
            authorization: authorization ?? makeAuthorization(),
            callback: callback ?? makeCallback()
        )
    }

    // 「何かthrowすればよい」ではなく、期待した理由で拒否されたことまで確認する
    private func assertRejects(
        authorization: ChatGPTOAuthAuthorizationRequest? = nil,
        callback: ChatGPTOAuthCallbackResult? = nil,
        as expected: ChatGPTOAuthTokenRequestError,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try build(authorization: authorization, callback: callback), label, file: file, line: line) { error in
            XCTAssertEqual(error as? ChatGPTOAuthTokenRequestError, expected, label, file: file, line: line)
        }
    }

    // bodyをテスト側で独立にform-decodeし、(key, value) を出現順に返す。構造が壊れていたらnil
    private func decodeForm(_ body: Data) -> [(key: String, value: String)]? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        var pairs: [(key: String, value: String)] = []
        for segment in text.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let key = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
                return nil
            }
            pairs.append((key: key, value: value))
        }
        return pairs
    }

    // decodeした値をkeyで引けるようにする。重複keyがあってもクラッシュさせず最初の値を使う（重複自体は別テストで検出）
    private func formValues(_ body: Data) throws -> [String: String] {
        let pairs = try XCTUnwrap(decodeForm(body), "bodyがform形式として壊れている")
        return Dictionary(pairs.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private func bodyString(_ request: ChatGPTOAuthTokenRequest) -> String {
        String(decoding: request.body, as: UTF8.self)
    }

    // print・dump・デバッガ表示で出る文字列をまとめて返す
    private func renderedForms(of value: Any) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), dumped]
    }

    // MARK: - fixtureの前提

    func testSyntheticFixturesHaveExpectedShape() throws {
        XCTAssertEqual(syntheticState.count, 43)
        XCTAssertEqual(syntheticNonce.count, 43)
        XCTAssertEqual(syntheticVerifier.count, 43)
        XCTAssertEqual(otherVerifier.count, 44)
        XCTAssertNotEqual(syntheticVerifier, otherVerifier)
        XCTAssertNotEqual(syntheticRedirect, otherRedirect)
        // codeとclient_idはcallback validatorが受け付ける形式（可視ASCII・上限以内）
        for value in [syntheticCode, syntheticClientID] {
            XCTAssertTrue(value.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) })
        }
        XCTAssertLessThanOrEqual(syntheticCode.count, ChatGPTOAuthCallbackValidator.maxCodeLength)
        XCTAssertLessThanOrEqual(syntheticClientID.count, ChatGPTOAuthCallbackValidator.maxClientIDLength)
        // 合成の認可requestが組み立てられること（このテスト自体はstubに依存しない）
        let authorization = try makeAuthorization()
        XCTAssertEqual(authorization.redirectURI.absoluteString, syntheticRedirect)
        XCTAssertEqual(authorization.codeVerifier, syntheticVerifier)
    }

    // MARK: - URL・method・headers

    func testUsesExactTokenEndpointWithPOST() throws {
        let request = try build()
        XCTAssertEqual(request.url.absoluteString, expectedTokenEndpoint)
        XCTAssertNil(request.url.query, "token endpointのURLに値を載せない")
        XCTAssertNil(request.url.fragment)
        XCTAssertEqual(request.method, "POST")
    }

    func testHeadersAreExactlyFormContentTypeWithoutCredentials() throws {
        let request = try build()
        // client secretは不要なのでAuthorizationヘッダ（Basic認証など）は付けない
        XCTAssertEqual(request.headers, ["Content-Type": "application/x-www-form-urlencoded"])
        let lowercasedNames = Set(request.headers.keys.map { $0.lowercased() })
        XCTAssertFalse(lowercasedNames.contains("authorization"))
        XCTAssertFalse(lowercasedNames.contains("cookie"))
    }

    // MARK: - body

    func testBuildsExactFormBodyWithStrictEncodingAndFixedOrder() throws {
        let request = try build()
        let expected = "grant_type=authorization_code"
            + "&client_id=\(syntheticClientID)"
            + "&code=\(encodedSyntheticCode)"
            + "&code_verifier=\(syntheticVerifier)"
            + "&redirect_uri=\(encodedSyntheticRedirect)"
            + "&resource=\(encodedResource)"
        XCTAssertEqual(bodyString(request), expected)
    }

    func testBodyHasExactlySixParametersWithoutDuplicatesOrSecret() throws {
        let pairs = try XCTUnwrap(decodeForm(try build().body))
        let keys = pairs.map { $0.key }
        XCTAssertEqual(keys, ["grant_type", "client_id", "code", "code_verifier", "redirect_uri", "resource"])
        XCTAssertEqual(Set(keys).count, 6, "同じkeyを重複させない")
        XCTAssertFalse(pairs.contains { $0.key == "client_secret" })
        XCTAssertFalse(pairs.contains { $0.key == "scope" || $0.key == "state" || $0.key == "nonce" })
    }

    func testBodyRoundTripsToOriginalValues() throws {
        let values = try formValues(try build().body)
        XCTAssertEqual(values["grant_type"], "authorization_code")
        XCTAssertEqual(values["client_id"], syntheticClientID)
        XCTAssertEqual(values["code"], syntheticCode)
        XCTAssertEqual(values["code_verifier"], syntheticVerifier)
        XCTAssertEqual(values["redirect_uri"], syntheticRedirect)
        XCTAssertEqual(values["resource"], "https://api.openai.com/v1")
    }

    func testReservedCharactersInCodeAndClientIDAreEscapedInsideForm() throws {
        // "+" をspaceに、"&" "=" を区切りに誤解されないよう、すべてpercent-encodeされている必要がある
        let code = "a+b&c=d%20e"
        let clientID = "issued:client/id+1&x=y"
        let request = try build(callback: makeCallback(code: code, clientID: clientID))
        let body = bodyString(request)
        XCTAssertTrue(body.contains("&code=a%2Bb%26c%3Dd%2520e&"))
        XCTAssertTrue(body.contains("&client_id=issued%3Aclient%2Fid%2B1%26x%3Dy&"))

        let pairs = try XCTUnwrap(decodeForm(request.body))
        XCTAssertEqual(pairs.count, 6, "escape漏れでパラメータが増えていない")
        let values = try formValues(request.body)
        XCTAssertEqual(values["code"], code)
        XCTAssertEqual(values["client_id"], clientID)
    }

    func testBodyContainsOnlyUnreservedBytesAndUppercasePercentEscapes() throws {
        let body = Array(try build().body)
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        let separators = Set("=&".utf8)
        let upperHex = Set("0123456789ABCDEF".utf8)
        var index = 0
        while index < body.count {
            let byte = body[index]
            if byte == UInt8(ascii: "%") {
                XCTAssertLessThan(index + 2, body.count, "%の後ろに2桁が必要")
                guard index + 2 < body.count else { return }
                XCTAssertTrue(upperHex.contains(body[index + 1]) && upperHex.contains(body[index + 2]))
                index += 3
            } else {
                // "+"（space表現）や生の予約文字は出さない
                XCTAssertTrue(unreserved.contains(byte) || separators.contains(byte), "許可外のbyte: \(byte)")
                index += 1
            }
        }
    }

    // MARK: - client_id（callbackで発行されたものだけを使う）

    func testUsesClientIDIssuedInCallbackNotRegistrationPlaceholder() throws {
        let authorization = try makeAuthorization()
        // 前提: 認可URL側には初回登録用のプレースホルダが入っている
        XCTAssertTrue(authorization.authorizationURL.absoluteString.contains("client_id=\(registrationPlaceholderClientID)"))

        let request = try build(authorization: authorization)
        let values = try formValues(request.body)
        XCTAssertEqual(values["client_id"], syntheticClientID)
        XCTAssertFalse(bodyString(request).contains(registrationPlaceholderClientID))
    }

    func testRejectsRegistrationPlaceholderAsClientID() {
        assertRejects(
            callback: makeCallback(clientID: registrationPlaceholderClientID),
            as: .invalidClientID,
            "初回登録用のプレースホルダは発行済みclient_idではない"
        )
    }

    // MARK: - redirect URIとcode verifierの紐付け

    func testUsesRedirectURIAndVerifierFromAuthorizationRequest() throws {
        let other = try makeAuthorization(redirect: otherRedirect, verifier: otherVerifier)
        let values = try formValues(try build(authorization: other).body)
        // 認可時と完全に同じ文字列（正規化・末尾スラッシュ追加などをしない）
        XCTAssertEqual(values["redirect_uri"], otherRedirect)
        XCTAssertEqual(values["code_verifier"], otherVerifier)
    }

    func testRejectsRedirectURIThatDiffersFromAuthorizationURL() throws {
        let original = try makeAuthorization()
        assertRejects(
            authorization: tampered(original, redirectURI: URL(string: otherRedirect)!),
            as: .mismatchedAuthorization,
            "認可URLのredirect_uriと異なるredirect URI"
        )
    }

    func testRejectsVerifierThatDoesNotMatchCodeChallenge() throws {
        let original = try makeAuthorization()
        assertRejects(
            authorization: tampered(original, codeVerifier: otherVerifier),
            as: .mismatchedAuthorization,
            "認可URLのcode_challengeに対応しないverifier"
        )
    }

    // MARK: - 認可URLそのものの偽造（正規builderの出力以外を通さない）

    // 正規builderが出す認可URLの「scheme://host/path」部分。偽造URLはここだけを差し替えて作る
    private let canonicalAuthorizeBase = "https://auth.openai.com/api/accounts/authorize"

    // 正規の認可URLを「base」と「?以降のquery」に分ける。
    // queryは正規のまま使うので、偽造ケースではredirect_uri・code_challengeの照合には合格する
    // （＝拒否されるならURLの他の部分を見て拒否したことになる）
    private func splitCanonicalAuthorizationURL(
        _ authorization: ChatGPTOAuthAuthorizationRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let raw = authorization.authorizationURL.absoluteString
        // 前提: 正規builderの出力は想定どおりの形。違えばfixtureの前提が崩れているので、
        // skipではなく失敗としてテストを止める（XCTUnwrapはnilのとき失敗を記録してthrowする）
        let absolute = try XCTUnwrap(
            raw.hasPrefix(canonicalAuthorizeBase + "?") ? raw : nil,
            "正規の認可URLの形が想定と違う",
            file: file,
            line: line
        )
        XCTAssertNil(authorization.authorizationURL.fragment, file: file, line: line)
        XCTAssertNil(authorization.authorizationURL.user, file: file, line: line)
        XCTAssertNil(authorization.authorizationURL.password, file: file, line: line)
        // "?"を含めたquery部分（例: "?response_type=code&..."）を返す
        return String(absolute.dropFirst(canonicalAuthorizeBase.count))
    }

    func testAcceptsCanonicalAuthorizationURLRebuiltFromParts() throws {
        // positive対照: 偽造ケースと同じ組み立て方（base + query）で正規URLを作り直しても通ること。
        // これが通らないと、下の拒否テストが「組み立て方のせいで落ちた」のか区別できない
        let original = try makeAuthorization()
        let query = try splitCanonicalAuthorizationURL(original)
        let rebuilt = try XCTUnwrap(URL(string: canonicalAuthorizeBase + query))
        XCTAssertEqual(rebuilt.absoluteString, original.authorizationURL.absoluteString)

        let values = try formValues(try build(authorization: tampered(original, authorizationURL: rebuilt)).body)
        XCTAssertEqual(values["redirect_uri"], syntheticRedirect)
        XCTAssertEqual(values["code_verifier"], syntheticVerifier)
    }

    func testRejectsForgedAuthorizationURLs() throws {
        let original = try makeAuthorization()
        let query = try splitCanonicalAuthorizationURL(original)
        // (説明ラベル, 偽造URL文字列)。queryは正規のままで、scheme・userinfo・host・path・fragmentだけを変える。
        // ホスト名は実在しない予約ドメイン（.invalid / .example）だけを使う
        let forged: [(String, String)] = [
            // userinfo
            ("userあり", "https://user@auth.openai.com/api/accounts/authorize" + query),
            ("空のuserinfo", "https://@auth.openai.com/api/accounts/authorize" + query),
            ("user+password", "https://user:pass@auth.openai.com/api/accounts/authorize" + query),
            ("passwordのみ", "https://:pass@auth.openai.com/api/accounts/authorize" + query),
            // fragment
            ("fragmentあり", "https://auth.openai.com/api/accounts/authorize" + query + "#frag"),
            ("空のfragment", "https://auth.openai.com/api/accounts/authorize" + query + "#"),
            // host拡張
            ("hostの後ろに追加", "https://auth.openai.com.example.invalid/api/accounts/authorize" + query),
            ("hostの前に追加", "https://evil.auth.openai.com/api/accounts/authorize" + query),
            ("host末尾のドット", "https://auth.openai.com./api/accounts/authorize" + query),
            ("別host", "https://auth.example.invalid/api/accounts/authorize" + query),
            // scheme違い
            ("http", "http://auth.openai.com/api/accounts/authorize" + query),
            ("ftp", "ftp://auth.openai.com/api/accounts/authorize" + query),
            // path違い
            ("path末尾スラッシュ", "https://auth.openai.com/api/accounts/authorize/" + query),
            ("pathの後ろに追加", "https://auth.openai.com/api/accounts/authorize2" + query),
            ("path下位階層", "https://auth.openai.com/api/accounts/authorize/extra" + query),
            ("pathの大文字", "https://auth.openai.com/API/accounts/authorize" + query),
            ("dot segment", "https://auth.openai.com/api/accounts/../accounts/authorize" + query),
            ("pathなし", "https://auth.openai.com" + query),
        ]
        for (label, string) in forged {
            // URL(string:)が受け付けない文字列だとテストの意図を満たせないので、unwrap失敗として明示する
            let url = try XCTUnwrap(URL(string: string), "URLとして解釈できない: \(label)")
            assertRejects(
                authorization: tampered(original, authorizationURL: url),
                as: .mismatchedAuthorization,
                label
            )
        }
    }

    func testRejectsNonCanonicalRedirectURI() throws {
        let original = try makeAuthorization()
        let invalid = [
            "http://localhost:49152/auth/callback",
            "https://127.0.0.1:49152/auth/callback",
            "http://127.0.0.1/auth/callback",
            "http://127.0.0.1:49152/auth/callback/",
            "http://127.0.0.1:049152/auth/callback",
            "http://127.0.0.1:49152/auth/callback?x=1",
            "http://127.0.0.1:49152/auth/callback#frag",
            "http://user@127.0.0.1:49152/auth/callback",
        ]
        for value in invalid {
            assertRejects(
                authorization: tampered(original, redirectURI: URL(string: value)!),
                as: .invalidRedirectURI,
                value
            )
        }
    }

    func testRejectsMalformedCodeVerifier() throws {
        let original = try makeAuthorization()
        // dropLast()はSubstringを返すので、Stringに戻してから連結する（配列の要素型をStringにそろえるため）
        let base = String(syntheticVerifier.dropLast())
        let invalid = [
            "",
            String(repeating: "a", count: 42),
            String(repeating: "a", count: 129),
            base + " ",
            base + "+",
            base + "\n",
            base + "あ",
        ]
        for value in invalid {
            assertRejects(
                authorization: tampered(original, codeVerifier: value),
                as: .invalidCodeVerifier,
                "長さ\(value.count)の不正なverifier"
            )
        }
    }

    // MARK: - code・client_idの欠落と不正文字（fail closed）

    func testRejectsMalformedCode() {
        let maxLength = ChatGPTOAuthCallbackValidator.maxCodeLength
        let invalid = [
            "",
            " ",
            "with space",
            "line\nbreak",
            "carriage\rreturn",
            "tab\tchar",
            "nul\u{0}char",
            "del\u{7F}char",
            "非ASCII",
            String(repeating: "a", count: maxLength + 1),
        ]
        for value in invalid {
            assertRejects(callback: makeCallback(code: value), as: .invalidCode, "長さ\(value.count)の不正なcode")
        }
    }

    func testAcceptsCodeAtMaximumLength() throws {
        let code = String(repeating: "a", count: ChatGPTOAuthCallbackValidator.maxCodeLength)
        let values = try formValues(try build(callback: makeCallback(code: code)).body)
        XCTAssertEqual(values["code"], code)
    }

    func testRejectsMalformedClientID() {
        let maxLength = ChatGPTOAuthCallbackValidator.maxClientIDLength
        let invalid = [
            "",
            " ",
            "with space",
            "line\nbreak",
            "nul\u{0}char",
            "非ASCII",
            registrationPlaceholderClientID + "\n",
            String(repeating: "a", count: maxLength + 1),
        ]
        for value in invalid {
            assertRejects(callback: makeCallback(clientID: value), as: .invalidClientID, "長さ\(value.count)の不正なclient_id")
        }
    }

    func testAcceptsClientIDAtMaximumLength() throws {
        let clientID = String(repeating: "a", count: ChatGPTOAuthCallbackValidator.maxClientIDLength)
        let values = try formValues(try build(callback: makeCallback(clientID: clientID)).body)
        XCTAssertEqual(values["client_id"], clientID)
    }

    // MARK: - 秘密値を表示・エラーに出さない

    func testRequestDescriptionAndDumpDoNotRevealSecrets() throws {
        let request = try build()
        let secrets = [syntheticCode, encodedSyntheticCode, syntheticClientID, syntheticVerifier, bodyString(request)]
        for rendered in renderedForms(of: request) {
            for secret in secrets {
                XCTAssertFalse(rendered.contains(secret), "表示に秘密値が含まれている")
            }
            XCTAssertTrue(rendered.contains("redacted"), "伏せ字であることが分かる表示にする")
        }
    }

    func testErrorsDoNotRevealInputValues() throws {
        // 失敗の原因になった入力にも、正常な側の入力にも目印を入れておく
        let leakCode = "LeakMarkerCode 0001"
        let leakClientID = "LeakMarkerClient\n0002"
        let original = try makeAuthorization()
        let cases: [(ChatGPTOAuthAuthorizationRequest, ChatGPTOAuthCallbackResult)] = [
            (original, makeCallback(code: leakCode)),
            (original, makeCallback(clientID: leakClientID)),
            (tampered(original, codeVerifier: otherVerifier), makeCallback()),
            (tampered(original, redirectURI: URL(string: "http://localhost:49152/auth/callback")!), makeCallback()),
        ]
        let secrets = [leakCode, leakClientID, syntheticCode, syntheticClientID, syntheticVerifier, otherVerifier, "localhost"]
        for (authorization, callback) in cases {
            XCTAssertThrowsError(try ChatGPTOAuthTokenRequestBuilder.build(authorization: authorization, callback: callback)) { error in
                XCTAssertNotEqual(error as? ChatGPTOAuthTokenRequestError, .notImplemented, "stubのままではない")
                for rendered in renderedForms(of: error) + [error.localizedDescription] {
                    for secret in secrets {
                        XCTAssertFalse(rendered.contains(secret), "エラー表示に入力値が含まれている")
                    }
                }
            }
        }
    }
}
