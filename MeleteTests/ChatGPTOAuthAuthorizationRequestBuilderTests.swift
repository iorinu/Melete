import XCTest
@testable import Melete

// ChatGPT OAuth初回登録用authorization requestの純粋な構築だけを検証する。
// ネットワーク・ブラウザ・保存には一切触れない。値はすべて合成の固定値。
final class ChatGPTOAuthAuthorizationRequestBuilderTests: XCTestCase {
    // RFC 7636 Appendix B の公開テストベクタ（実際の認証には使われない合成値）
    private let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    private let rfcChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    // 合成のstate/nonce（43文字・base64url文字のみ）
    private let syntheticState = "SyntheticStateValue0123456789-_abcdefghijkl"
    private let syntheticNonce = "SyntheticNonceValue0123456789-_mnopqrstuvwx"
    // 合成のUUIDv4（version=4, variant=8）
    private let syntheticHostID = "urn:uuid:11111111-2222-4333-8444-555555555555"
    private let syntheticRedirect = URL(string: "http://127.0.0.1:49152/auth/callback")!

    private func makeSecrets(
        state: String? = nil,
        nonce: String? = nil,
        verifier: String? = nil
    ) -> ChatGPTOAuthAuthorizationSecrets {
        ChatGPTOAuthAuthorizationSecrets(
            state: state ?? syntheticState,
            nonce: nonce ?? syntheticNonce,
            codeVerifier: verifier ?? rfcVerifier
        )
    }

    private func makeBuilder(secrets: ChatGPTOAuthAuthorizationSecrets? = nil) -> ChatGPTOAuthAuthorizationRequestBuilder {
        let fixed = secrets ?? makeSecrets()
        return ChatGPTOAuthAuthorizationRequestBuilder(makeSecrets: { fixed })
    }

    // MARK: - PKCE

    func testCodeChallengeMatchesRFC7636AppendixB() {
        XCTAssertEqual(ChatGPTOAuthAuthorizationRequestBuilder.codeChallenge(for: rfcVerifier), rfcChallenge)
    }

    // MARK: - URL全体

    func testBuildsExactAuthorizationURLWithStrictPercentEncoding() throws {
        let request = try makeBuilder().build(agentHostID: syntheticHostID, redirectURI: syntheticRedirect)

        let expected = "https://auth.openai.com/api/accounts/authorize"
            + "?client_id=dynamic_agent_client"
            + "&agent_name_hint=Melete"
            + "&ext_agent_host_id=urn%3Auuid%3A11111111-2222-4333-8444-555555555555"
            + "&response_type=code"
            + "&redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Fauth%2Fcallback"
            + "&scope=openid%20profile%20email%20offline_access%20resource.invoke%20chatgpt.tokens.use.direct"
            + "&resource=https%3A%2F%2Fapi.openai.com%2Fv1"
            + "&state=\(syntheticState)"
            + "&nonce=\(syntheticNonce)"
            + "&code_challenge=\(rfcChallenge)"
            + "&code_challenge_method=S256"
        XCTAssertEqual(request.authorizationURL.absoluteString, expected)
    }

    func testDecodedQueryItemsMatchSpecifiedValues() throws {
        let request = try makeBuilder().build(agentHostID: syntheticHostID, redirectURI: syntheticRedirect)
        let components = try XCTUnwrap(URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertNil(components.port)
        XCTAssertEqual(components.path, "/api/accounts/authorize")
        XCTAssertNil(components.fragment)

        let items = try XCTUnwrap(components.queryItems)
        // 同名パラメータの重複がないこと
        XCTAssertEqual(items.count, Set(items.map(\.name)).count)
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        XCTAssertEqual(dict["client_id"], "dynamic_agent_client")
        XCTAssertEqual(dict["agent_name_hint"], "Melete")
        XCTAssertEqual(dict["ext_agent_host_id"], syntheticHostID)
        XCTAssertEqual(dict["response_type"], "code")
        XCTAssertEqual(dict["redirect_uri"], "http://127.0.0.1:49152/auth/callback")
        XCTAssertEqual(dict["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        XCTAssertEqual(dict["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(dict["state"], syntheticState)
        XCTAssertEqual(dict["nonce"], syntheticNonce)
        XCTAssertEqual(dict["code_challenge"], rfcChallenge)
        XCTAssertEqual(dict["code_challenge_method"], "S256")
        XCTAssertEqual(Set(dict.keys).count, 11)
    }

    func testKeepsValuesNeededForLaterTokenExchange() throws {
        let request = try makeBuilder().build(agentHostID: syntheticHostID, redirectURI: syntheticRedirect)
        // token exchangeでredirect_uri・verifierを一致させるため、構築に使った値を保持する
        XCTAssertEqual(request.redirectURI.absoluteString, "http://127.0.0.1:49152/auth/callback")
        XCTAssertEqual(request.state, syntheticState)
        XCTAssertEqual(request.nonce, syntheticNonce)
        XCTAssertEqual(request.codeVerifier, rfcVerifier)
    }

    // MARK: - 秘密値を表示しない

    func testDescriptionsDoNotRevealSecrets() throws {
        let request = try makeBuilder().build(agentHostID: syntheticHostID, redirectURI: syntheticRedirect)
        var dumped = ""
        dump(request, to: &dumped)
        let secrets = makeSecrets()
        var dumpedSecrets = ""
        dump(secrets, to: &dumpedSecrets)
        let outputs = [
            String(describing: request), String(reflecting: request), "\(request)", dumped,
            String(describing: secrets), String(reflecting: secrets), "\(secrets)", dumpedSecrets
        ]
        for output in outputs {
            XCTAssertFalse(output.contains(syntheticState))
            XCTAssertFalse(output.contains(syntheticNonce))
            XCTAssertFalse(output.contains(rfcVerifier))
            XCTAssertFalse(output.contains(rfcChallenge))
        }
    }

    // MARK: - 乱数生成（本番用の既定ジェネレータ）

    func testDefaultGeneratorProducesFreshValidValuesEachTime() throws {
        let builder = ChatGPTOAuthAuthorizationRequestBuilder()
        let first = try builder.build(agentHostID: syntheticHostID, redirectURI: syntheticRedirect)
        let second = try builder.build(agentHostID: syntheticHostID, redirectURI: syntheticRedirect)

        for request in [first, second] {
            for value in [request.state, request.nonce, request.codeVerifier] {
                XCTAssertEqual(value.count, 43)
                XCTAssertNotNil(value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression))
            }
        }
        // 毎回新しい値であること（state・nonce・verifierは互いにも異なる）
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotEqual(first.codeVerifier, second.codeVerifier)
        XCTAssertNotEqual(first.state, first.nonce)
        XCTAssertNotEqual(first.state, first.codeVerifier)
    }

    // MARK: - 不正なredirect URI

    func testRejectsInvalidRedirectURIs() {
        let invalid = [
            "https://127.0.0.1:49152/auth/callback",     // scheme違い
            "http://localhost:49152/auth/callback",      // host違い
            "http://127.0.0.2:49152/auth/callback",
            "http://[::1]:49152/auth/callback",
            "http://127.0.0.1/auth/callback",            // port省略
            "http://127.0.0.1:0/auth/callback",          // port 0
            "http://127.0.0.1:65536/auth/callback",      // 範囲外
            "http://127.0.0.1:49152/auth/callback/",     // path違い
            "http://127.0.0.1:49152/auth/Callback",
            "http://127.0.0.1:49152/",
            "http://127.0.0.1:49152/auth/callback?x=1",  // query付き
            "http://127.0.0.1:49152/auth/callback#frag", // fragment付き
            "http://user@127.0.0.1:49152/auth/callback", // userinfo付き
            "http://127.0.0.1:049152/auth/callback",     // 非正規のport表記
        ]
        for string in invalid {
            guard let url = URL(string: string) else { continue }
            XCTAssertThrowsError(
                try makeBuilder().build(agentHostID: syntheticHostID, redirectURI: url),
                string
            )
        }
    }

    func testAcceptsPortBoundaries() throws {
        for port in [1, 65535] {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/auth/callback"))
            XCTAssertNoThrow(try makeBuilder().build(agentHostID: syntheticHostID, redirectURI: url))
        }
    }

    // MARK: - 不正なext_agent_host_id

    func testRejectsInvalidAgentHostIDs() {
        let invalid = [
            "11111111-2222-4333-8444-555555555555",                // 接頭辞なし
            "urn:uuid:11111111-2222-1333-8444-555555555555",       // version 1
            "urn:uuid:11111111-2222-4333-c444-555555555555",       // variant違い
            "urn:uuid:11111111-2222-4333-8444-55555555555",        // 桁不足
            "urn:uuid:11111111-2222-4333-8444-5555555555555",      // 桁超過
            "urn:uuid:AAAAAAAA-2222-4333-8444-555555555555",       // 大文字（正規形ではない）
            "URN:UUID:11111111-2222-4333-8444-555555555555",
            "urn:uuid:11111111222243338444555555555555",           // ハイフンなし
            " urn:uuid:11111111-2222-4333-8444-555555555555",      // 前後空白
            "urn:uuid:11111111-2222-4333-8444-555555555555\n",     // 末尾改行
            "urn:uuid:00000000-0000-0000-0000-000000000000",
            "",
        ]
        for value in invalid {
            XCTAssertThrowsError(
                try makeBuilder().build(agentHostID: value, redirectURI: syntheticRedirect),
                value
            )
        }
    }

    // MARK: - 不正な注入値

    func testRejectsInvalidCodeVerifiers() {
        let invalid = [
            String(repeating: "a", count: 42),   // RFC 7636の最小43文字未満
            String(repeating: "a", count: 129),  // 最大128文字超過
            String(repeating: "a", count: 42) + "+",
            String(repeating: "a", count: 42) + "=",
            String(repeating: "a", count: 42) + " ",
            String(repeating: "a", count: 42) + "あ",
        ]
        for verifier in invalid {
            XCTAssertThrowsError(
                try makeBuilder(secrets: makeSecrets(verifier: verifier))
                    .build(agentHostID: syntheticHostID, redirectURI: syntheticRedirect)
            )
        }
    }

    func testAcceptsCodeVerifierLengthBoundaries() {
        for length in [43, 128] {
            let verifier = String(repeating: "a", count: length - 4) + "-._~"
            XCTAssertNoThrow(
                try makeBuilder(secrets: makeSecrets(verifier: verifier))
                    .build(agentHostID: syntheticHostID, redirectURI: syntheticRedirect)
            )
        }
    }

    func testRejectsInvalidStateAndNonce() {
        let invalid = [
            "",
            String(repeating: "a", count: 42),   // 256bit相当（43文字）未満
            String(repeating: "a", count: 129),
            String(repeating: "a", count: 42) + "&",
            String(repeating: "a", count: 42) + "=",
            String(repeating: "a", count: 42) + "%",
            String(repeating: "a", count: 42) + "\n",
        ]
        for value in invalid {
            XCTAssertThrowsError(
                try makeBuilder(secrets: makeSecrets(state: value))
                    .build(agentHostID: syntheticHostID, redirectURI: syntheticRedirect),
                "state"
            )
            XCTAssertThrowsError(
                try makeBuilder(secrets: makeSecrets(nonce: value))
                    .build(agentHostID: syntheticHostID, redirectURI: syntheticRedirect),
                "nonce"
            )
        }
    }

    func testRejectsReusedValuesAcrossStateNonceAndVerifier() {
        // 同じ乱数を使い回した注入は拒否する
        let same = syntheticState
        XCTAssertThrowsError(try makeBuilder(secrets: makeSecrets(state: same, nonce: same))
            .build(agentHostID: syntheticHostID, redirectURI: syntheticRedirect))
        XCTAssertThrowsError(try makeBuilder(secrets: makeSecrets(state: same, verifier: same))
            .build(agentHostID: syntheticHostID, redirectURI: syntheticRedirect))
        XCTAssertThrowsError(try makeBuilder(secrets: makeSecrets(nonce: same, verifier: same))
            .build(agentHostID: syntheticHostID, redirectURI: syntheticRedirect))
    }

    func testErrorDescriptionsDoNotRevealInputs() {
        let badState = String(repeating: "Z", count: 42) + "&"
        do {
            _ = try makeBuilder(secrets: makeSecrets(state: badState))
                .build(agentHostID: syntheticHostID, redirectURI: syntheticRedirect)
            XCTFail("拒否されるべき")
        } catch {
            let texts = [error.localizedDescription, String(describing: error), String(reflecting: error)]
            for text in texts {
                XCTAssertFalse(text.contains(badState))
                XCTAssertFalse(text.contains(syntheticNonce))
                XCTAssertFalse(text.contains(rfcVerifier))
            }
        }
    }
}
