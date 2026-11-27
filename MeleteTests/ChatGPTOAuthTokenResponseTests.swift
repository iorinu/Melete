import Security
import XCTest
@testable import Melete

// ChatGPT OAuth初回登録のtoken exchange responseの純粋な検証だけを確かめる（テストファーストのRED）。
// ネットワーク・URLSession・Keychain・保存・ログには一切触れない。値はすべてテスト専用の合成固定値。
// ID tokenの実署名の検証の詳細は `ChatGPTOpenAIIDTokenVerifierTests` で扱う。ここでは主に合成closureを注入し、
// 「検証処理へ正しい値が渡ること」と「検証結果・失敗をどう扱うか」を確かめる。
// 加えて「本番の入口 + 実RS256署名」の節では、Securityでメモリ上だけに生成した鍵で署名したID tokenを
// 本番の入口へ渡し、parserと本物のverifierがつながった状態（end-to-end）で受理・拒否を確かめる。
final class ChatGPTOAuthTokenResponseTests: XCTestCase {
    // MARK: - 合成の固定値（実際の認証には使われない）

    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let syntheticClientID = "synthetic_issued_client_0123456789"
    private let syntheticNonce = "SyntheticResponseNonce0123456789-_abcdefghi"
    // 中身は検証されない合成のJWKS。closureへそのまま渡されることだけを確かめる
    private let syntheticJWKS = Data(#"{"keys":[{"kty":"RSA","kid":"synthetic-kid","n":"synthetic-n","e":"AQAB"}]}"#.utf8)
    private let syntheticAccessToken = "synthetic-access-token-0123456789.ABCdef_-"
    private let syntheticRefreshToken = "synthetic-refresh-token-9876543210.XYZuvw_-"
    private let syntheticIDToken = "c3ludGhldGlj.aWQtdG9rZW4.c2lnbmF0dXJl"
    // closureが返すsub。body内のどの値とも違うので、結果がclosure由来であることを確かめられる
    private let syntheticSubject = "synthetic-subject-from-verifier-0001"
    private let syntheticScope = "openid offline_access chatgpt.tokens.use.direct"
    private let directUseScope = "chatgpt.tokens.use.direct"

    // 実RS256署名のend-to-end用。ID tokenのissはverifierが固定で照合するOpenAIのissuer
    private let openAIIssuer = "https://auth.openai.com"
    private let realPathKeyID = "synthetic-e2e-kid-0001"
    // 実署名のID tokenに入れるsub。body・closure用の値とは別にし、結果が本物のverifier由来だと分かるようにする
    private let realPathSubject = "synthetic-subject-e2e-rs256-0001"
    private let realPathOtherNonce = "OtherSyntheticE2ENonce0123456789-_zyxwvutsr"

    // body内のkeyの並び（既定値はこの順で組み立てる）
    private let fieldOrder = ["access_token", "refresh_token", "id_token", "token_type", "expires_in", "scope"]

    // JSONのunicode escape（backslash + "u" + 4桁のhex）を作る。
    // 編集ツールや整形でescape表記が実際の文字へ化けて誤GREENにならないよう、
    // backslashはソース上に直接書かず、コード値0x5Cから組み立てる
    private static let backslash = String(Character(Unicode.Scalar(UInt8(0x5C))))
    private func unicodeEscape(_ hex: String) -> String {
        Self.backslash + "u" + hex
    }

    // escapeを解くと "access_token"（0061 = a）・"scope"（006f = o）になるkeyのJSON断片
    private var escapedAccessTokenKey: String { "\"" + unicodeEscape("0061") + "ccess_token\"" }
    private var escapedScopeKey: String { "\"sc" + unicodeEscape("006f") + "pe\"" }

    // MARK: - 合成のID token検証closure

    // 注入するclosureの呼び出し内容を記録し、固定の結果を返す（または固定のerrorを投げる）
    private final class SyntheticIDTokenVerifier {
        struct Call {
            let idToken: String
            let jwks: Data
            let clientID: String
            let nonce: String
            let now: Date
        }

        enum Outcome {
            case verified(subject: String)
            case rejected(Error)
        }

        private let outcome: Outcome
        private(set) var calls: [Call] = []

        init(_ outcome: Outcome) {
            self.outcome = outcome
        }

        func verify(
            idToken: String,
            jwks: Data,
            clientID: String,
            nonce: String,
            now: Date
        ) throws -> ChatGPTOpenAIIDTokenVerificationResult {
            calls.append(Call(idToken: idToken, jwks: jwks, clientID: clientID, nonce: nonce, now: now))
            switch outcome {
            case .verified(let subject):
                return ChatGPTOpenAIIDTokenVerificationResult(subject: subject)
            case .rejected(let error):
                throw error
            }
        }
    }

    // 検証側のerrorに秘密値が含まれていても、parserのerrorへ漏れないことを確かめるための合成error
    private struct SyntheticVerifierFailure: Error {
        let detail: String
    }

    private func verified() -> SyntheticIDTokenVerifier {
        SyntheticIDTokenVerifier(.verified(subject: syntheticSubject))
    }

    // MARK: - fixtureの組み立て

    // JSONの文字列リテラル（ASCIIの合成値専用。escapeが必要な値は呼び出し側で生のJSON断片を書く）
    private func q(_ value: String) -> String {
        "\"\(value)\""
    }

    private func defaultFragments() -> [String: String] {
        [
            "access_token": q(syntheticAccessToken),
            "refresh_token": q(syntheticRefreshToken),
            "id_token": q(syntheticIDToken),
            "token_type": q("Bearer"),
            "expires_in": "3600",
            "scope": q(syntheticScope),
        ]
    }

    // 生のJSON断片から最上位objectを組み立てる。重複keyやescape表記のkeyも作れるよう文字列で連結する
    // - set: 既定のkeyの値（JSON断片）を差し替える
    // - remove: 既定のkeyを省く
    // - extra: 末尾に追加する (keyのJSON断片, 値のJSON断片)
    private func makeBodyString(
        set: [String: String] = [:],
        remove: Set<String> = [],
        extra: [(key: String, value: String)] = []
    ) -> String {
        let defaults = defaultFragments()
        var members: [String] = []
        for key in fieldOrder where !remove.contains(key) {
            members.append("\(q(key)):\(set[key] ?? defaults[key]!)")
        }
        for pair in extra {
            members.append("\(pair.key):\(pair.value)")
        }
        return "{" + members.joined(separator: ",") + "}"
    }

    private func makeBody(
        set: [String: String] = [:],
        remove: Set<String> = [],
        extra: [(key: String, value: String)] = []
    ) -> Data {
        Data(makeBodyString(set: set, remove: remove, extra: extra).utf8)
    }

    private func parse(
        statusCode: Int = 200,
        body: Data? = nil,
        clientID: String? = nil,
        nonce: String? = nil,
        verifier: SyntheticIDTokenVerifier
    ) throws -> ChatGPTOAuthAuthorizedTokenCandidate {
        try ChatGPTOAuthTokenResponseParser.parseUsingSyntheticIDTokenVerifierForTesting(
            statusCode: statusCode,
            body: body ?? makeBody(),
            expectedClientID: clientID ?? syntheticClientID,
            expectedNonce: nonce ?? syntheticNonce,
            jwks: syntheticJWKS,
            now: fixedNow,
            verifyIDToken: verifier.verify
        )
    }

    // 「何かthrowすればよい」ではなく、期待した理由で拒否されたことまで確認する。
    // verifierCallsを指定したときは、ID token検証closureの呼び出し回数も確かめる
    @discardableResult
    private func assertRejects(
        statusCode: Int = 200,
        body: Data? = nil,
        clientID: String? = nil,
        nonce: String? = nil,
        verifier: SyntheticIDTokenVerifier? = nil,
        as expected: ChatGPTOAuthTokenResponseError,
        verifierCalls: Int? = nil,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Error? {
        let verifier = verifier ?? verified()
        var thrown: Error?
        XCTAssertThrowsError(
            try parse(statusCode: statusCode, body: body, clientID: clientID, nonce: nonce, verifier: verifier),
            label,
            file: file,
            line: line
        ) { error in
            thrown = error
            XCTAssertEqual(error as? ChatGPTOAuthTokenResponseError, expected, label, file: file, line: line)
        }
        if let verifierCalls {
            XCTAssertEqual(verifier.calls.count, verifierCalls, "\(label): ID token検証closureの呼び出し回数", file: file, line: line)
        }
        return thrown
    }

    // print・dump・デバッガ表示で出る文字列をまとめて返す
    private func renderedForms(of value: Any) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), dumped]
    }

    private func renderedErrorForms(of error: Error) -> [String] {
        let bridged = error as NSError
        return renderedForms(of: error) + [
            error.localizedDescription,
            String(describing: bridged),
            String(describing: bridged.userInfo),
        ]
    }

    // MARK: - fixtureの前提（stubに依存しない）

    func testSyntheticFixturesHaveExpectedShape() throws {
        // 公式SIWCのscope名を固定値として持っていること
        XCTAssertEqual(ChatGPTOAuthTokenResponseParser.directUseScope, "chatgpt.tokens.use.direct")
        XCTAssertTrue(syntheticScope.split(separator: " ").contains(Substring(directUseScope)))
        // 合成の秘密値はすべて可視ASCII（0x21-0x7E）で、互いに異なる
        let secrets = [syntheticAccessToken, syntheticRefreshToken, syntheticIDToken, syntheticSubject]
        for value in secrets {
            XCTAssertFalse(value.isEmpty)
            XCTAssertTrue(value.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }, value)
        }
        XCTAssertEqual(Set(secrets).count, secrets.count)
        // closureが返すsubはbody内に現れない
        XCTAssertFalse(makeBodyString().contains(syntheticSubject))
        // 既定のbodyは上限より十分小さく、JSONとして6項目を持つ
        let body = makeBody()
        XCTAssertLessThan(body.count, ChatGPTOAuthTokenResponseParser.maxBodyLength)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(fieldOrder))
        XCTAssertGreaterThan(ChatGPTOAuthTokenResponseParser.maxExpiresInSeconds, 3600)
    }

    // MARK: - 正常系（positive control）

    func testValidResponseYieldsAuthorizedCandidate() throws {
        let verifier = verified()
        let candidate = try parse(verifier: verifier)

        XCTAssertEqual(candidate.accessToken, syntheticAccessToken)
        XCTAssertEqual(candidate.refreshToken, syntheticRefreshToken)
        // subはbodyではなくID token検証の結果から取る
        XCTAssertEqual(candidate.subject, syntheticSubject)
        XCTAssertEqual(candidate.expiresAt, fixedNow.addingTimeInterval(3600))
        XCTAssertEqual(candidate.grantedScopes, ["openid", "offline_access", "chatgpt.tokens.use.direct"])
    }

    func testIDTokenVerifierIsWiredWithResponseTokenAndCallerExpectations() throws {
        let verifier = verified()
        _ = try parse(verifier: verifier)

        // 検証はちょうど1回だけ、bodyのid_tokenと呼び出し元の期待値・JWKS・固定時刻で行われる
        XCTAssertEqual(verifier.calls.count, 1)
        let call = try XCTUnwrap(verifier.calls.first)
        XCTAssertEqual(call.idToken, syntheticIDToken)
        XCTAssertEqual(call.jwks, syntheticJWKS)
        XCTAssertEqual(call.clientID, syntheticClientID)
        XCTAssertEqual(call.nonce, syntheticNonce)
        XCTAssertEqual(call.now, fixedNow)
    }

    func testCallerExpectationsArePassedThroughUnchanged() throws {
        // 別の合成client_id・nonceでも、加工せずそのままclosureへ渡す
        let otherClientID = "other_synthetic_client_abcdef"
        let otherNonce = "OtherSyntheticNonce0123456789-_zyxwvutsrqpo"
        let verifier = verified()
        _ = try parse(clientID: otherClientID, nonce: otherNonce, verifier: verifier)
        let call = try XCTUnwrap(verifier.calls.first)
        XCTAssertEqual(call.clientID, otherClientID)
        XCTAssertEqual(call.nonce, otherNonce)
    }

    func testBearerTokenTypeIsCaseInsensitive() throws {
        // RFC 6749 §5.1: token_typeは大文字小文字を区別しない
        for tokenType in ["Bearer", "bearer", "BEARER", "bEaReR"] {
            let candidate = try parse(body: makeBody(set: ["token_type": q(tokenType)]), verifier: verified())
            XCTAssertEqual(candidate.accessToken, syntheticAccessToken, tokenType)
        }
    }

    func testDirectScopeIsAcceptedAnywhereInScopeList() throws {
        let cases: [(scope: String, expected: [String])] = [
            ("chatgpt.tokens.use.direct", ["chatgpt.tokens.use.direct"]),
            ("chatgpt.tokens.use.direct openid", ["chatgpt.tokens.use.direct", "openid"]),
            ("openid chatgpt.tokens.use.direct offline_access", ["openid", "chatgpt.tokens.use.direct", "offline_access"]),
        ]
        for (scope, expected) in cases {
            let candidate = try parse(body: makeBody(set: ["scope": q(scope)]), verifier: verified())
            XCTAssertEqual(candidate.grantedScopes, expected, scope)
        }
    }

    func testUnknownExtraFieldsAreIgnored() throws {
        // RFC 6749 §5.1: 知らない項目は無視する（重複でない限り）
        let body = makeBody(extra: [(q("synthetic_extra"), q("ignored")), (q("synthetic_number"), "1")])
        let candidate = try parse(body: body, verifier: verified())
        XCTAssertEqual(candidate.accessToken, syntheticAccessToken)
    }

    func testExpiresInUpperBoundIsAccepted() throws {
        let maximum = ChatGPTOAuthTokenResponseParser.maxExpiresInSeconds
        let candidate = try parse(body: makeBody(set: ["expires_in": String(maximum)]), verifier: verified())
        XCTAssertEqual(candidate.expiresAt, fixedNow.addingTimeInterval(TimeInterval(maximum)))
        // 最小の正の値も受け付ける
        let shortLived = try parse(body: makeBody(set: ["expires_in": "1"]), verifier: verified())
        XCTAssertEqual(shortLived.expiresAt, fixedNow.addingTimeInterval(1))
    }

    func testBodyAtExactLimitIsAccepted() throws {
        // JSONの空白で埋めて、ちょうど上限バイト数のbodyを作る
        let base = makeBodyString()
        let padding = ChatGPTOAuthTokenResponseParser.maxBodyLength - base.utf8.count
        XCTAssertGreaterThan(padding, 0)
        let padded = "{" + String(repeating: " ", count: padding) + base.dropFirst()
        let body = Data(padded.utf8)
        XCTAssertEqual(body.count, ChatGPTOAuthTokenResponseParser.maxBodyLength)

        let candidate = try parse(body: body, verifier: verified())
        XCTAssertEqual(candidate.accessToken, syntheticAccessToken)
    }

    // MARK: - 本番の入口

    func testProductionEntryUsesRealIDTokenVerifier() {
        // 本番の入口は検証を差し替えられず、本物のverifierで検証する。
        // 署名の無い合成id_tokenと空のJWKSは本物のverifierが必ず拒否するので、idTokenRejectedになるはず
        let body = makeBody(set: ["id_token": q("c3ludGhldGlj.bm90LXNpZ25lZA.")])
        XCTAssertThrowsError(
            try ChatGPTOAuthTokenResponseParser.parse(
                statusCode: 200,
                body: body,
                expectedClientID: syntheticClientID,
                expectedNonce: syntheticNonce,
                jwks: Data(#"{"keys":[]}"#.utf8),
                now: fixedNow
            )
        ) { error in
            XCTAssertEqual(error as? ChatGPTOAuthTokenResponseError, .idTokenRejected)
        }
    }

    // MARK: - 本番の入口 + 実RS256署名（end-to-end）
    // 本番の入口 parse(statusCode:body:expectedClientID:expectedNonce:jwks:now:) に、
    // Securityでメモリ上だけに生成したRSA 2048鍵で実際にRS256署名したID tokenと、その公開鍵のJWKSを渡す。
    // 署名の生成には検証側と同じライブラリ（JOSESwift）を使わず、Securityだけで行う。
    // 鍵・token・JWKSはdiskにもKeychainにも保存せず、失敗メッセージやerrorの表示にも値を載せない

    // テスト中だけ使う鍵とJWKS。どれもメモリ上の値
    private struct RealRS256Fixture {
        let privateKey: SecKey
        let publicKey: SecKey
        // SecKeyが書き出した公開鍵の外部表現（PKCS#1 RSAPublicKeyのDER）
        let publicKeyDER: Data
        let jwk: [String: Any]
        let jwks: Data
    }

    // 失敗の理由だけを表す（鍵やCFErrorの内容は持たせない）
    private enum RealSignatureFixtureError: Error {
        case keyGenerationFailed
        case publicKeyExportFailed
        case signingFailed
        case malformedDER
        case malformedToken
    }

    // RSA 2048鍵ペアをメモリ上だけに生成する。kSecAttrIsPermanent=falseでKeychainに保存させない
    private func makeEphemeralRSAKey() throws -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            // エラー内容は出力せず、解放だけする
            _ = error?.takeRetainedValue()
            throw RealSignatureFixtureError.keyGenerationFailed
        }
        return privateKey
    }

    // 鍵を生成し、公開鍵のn・eを取り出してJWK（kty=RSA）1件だけのJWKSを作る
    private func makeRealRS256Fixture() throws -> RealRS256Fixture {
        let privateKey = try makeEphemeralRSAKey()
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            _ = error?.takeRetainedValue()
            throw RealSignatureFixtureError.publicKeyExportFailed
        }
        let (modulus, exponent) = try parsePKCS1RSAPublicKey(der)
        let jwk: [String: Any] = [
            "kty": "RSA",
            "kid": realPathKeyID,
            "use": "sig",
            "alg": "RS256",
            "n": base64URL(modulus),
            "e": base64URL(exponent),
        ]
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [jwk]], options: [.sortedKeys])
        return RealRS256Fixture(privateKey: privateKey, publicKey: publicKey, publicKeyDER: der, jwk: jwk, jwks: jwks)
    }

    // 本物のverifierがすべて合格とするclaims。nonceだけ差し替えられる
    private func realIDTokenClaims(nonce: String? = nil) -> [String: Any] {
        let now = Int(fixedNow.timeIntervalSince1970)
        return [
            "iss": openAIIssuer,
            "aud": syntheticClientID,
            "nonce": nonce ?? syntheticNonce,
            "sub": realPathSubject,
            "iat": now - 60,
            "exp": now + 3600,
        ]
    }

    // header.payload をSecurityのRSASSA-PKCS1-v1_5 + SHA-256（=RS256）で署名したcompact JWTを返す
    private func signRealIDToken(claims: [String: Any], fixture: RealRS256Fixture) throws -> String {
        let header: [String: Any] = ["alg": "RS256", "kid": realPathKeyID, "typ": "JWT"]
        let signingInput = try base64URLSegment(header) + "." + base64URLSegment(claims)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            fixture.privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &error
        ) as Data? else {
            _ = error?.takeRetainedValue()
            throw RealSignatureFixtureError.signingFailed
        }
        return signingInput + "." + base64URL(signature)
    }

    // compact JWTを (署名対象の "header.payload", 署名のバイト列) に分ける
    private func splitSignedToken(_ token: String) throws -> (signingInput: String, signature: Data) {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3, let signature = base64URLDecode(segments[2]) else {
            throw RealSignatureFixtureError.malformedToken
        }
        return (segments[0] + "." + segments[1], signature)
    }

    // 署名の途中の1バイトだけを変えたtoken（長さ・base64urlの形式は正しいまま）
    private func tamperingOneSignatureByte(of token: String) throws -> String {
        let parts = try splitSignedToken(token)
        var signature = parts.signature
        signature[signature.count / 2] ^= 0x01
        return parts.signingInput + "." + base64URL(signature)
    }

    // Securityだけで（verifierと独立に）署名を確かめる
    private func securityVerifiesSignature(of token: String, with publicKey: SecKey) throws -> Bool {
        let (signingInput, signature) = try splitSignedToken(token)
        return SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            signature as CFData,
            nil
        )
    }

    // 本番の入口を呼ぶ。Resultにすることで「candidateが返らなかったこと」を明示的に確かめられる
    private func parseWithProductionVerifier(
        body: Data,
        nonce: String? = nil,
        jwks: Data
    ) -> Result<ChatGPTOAuthAuthorizedTokenCandidate, Error> {
        Result {
            try ChatGPTOAuthTokenResponseParser.parse(
                statusCode: 200,
                body: body,
                expectedClientID: syntheticClientID,
                expectedNonce: nonce ?? syntheticNonce,
                jwks: jwks,
                now: fixedNow
            )
        }
    }

    // 本番の入口で受理され、subと許可scopeが本物のverifier・token responseから来ていることを確かめる。
    // 秘密値の比較はXCTAssertTrue(==)で行い、失敗メッセージに値を出さない
    @discardableResult
    private func assertProductionAccepts(
        body: Data,
        nonce: String? = nil,
        jwks: Data,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ChatGPTOAuthAuthorizedTokenCandidate? {
        switch parseWithProductionVerifier(body: body, nonce: nonce, jwks: jwks) {
        case .success(let candidate):
            XCTAssertTrue(candidate.subject == realPathSubject, "\(label): subが実署名ID tokenのsubと一致しない", file: file, line: line)
            XCTAssertTrue(candidate.accessToken == syntheticAccessToken, "\(label): access_token", file: file, line: line)
            XCTAssertTrue(candidate.refreshToken == syntheticRefreshToken, "\(label): refresh_token", file: file, line: line)
            XCTAssertEqual(candidate.grantedScopes, ["openid", "offline_access", directUseScope], label, file: file, line: line)
            XCTAssertTrue(candidate.grantedScopes.contains(directUseScope), "\(label): direct scope", file: file, line: line)
            XCTAssertEqual(candidate.expiresAt, fixedNow.addingTimeInterval(3600), label, file: file, line: line)
            return candidate
        case .failure(let error):
            // parserのerrorは関連値を持たないcaseだけなので、種類だけを表示する
            XCTFail("\(label): candidateが返らなかった（\(String(describing: error as? ChatGPTOAuthTokenResponseError))）", file: file, line: line)
            return nil
        }
    }

    // 本番の入口で期待した理由で拒否され、candidateが返らず、errorの表示に値が出ないことを確かめる
    private func assertProductionRejects(
        body: Data,
        nonce: String? = nil,
        jwks: Data,
        idToken: String,
        as expected: ChatGPTOAuthTokenResponseError,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch parseWithProductionVerifier(body: body, nonce: nonce, jwks: jwks) {
        case .success:
            // candidateの中身は表示しない
            XCTFail("\(label): candidateが返った", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error as? ChatGPTOAuthTokenResponseError, expected, label, file: file, line: line)
            let values = [
                idToken, realPathSubject, syntheticAccessToken, syntheticRefreshToken,
                syntheticClientID, syntheticNonce, realPathOtherNonce,
            ]
            for rendered in renderedErrorForms(of: error) {
                for value in values {
                    XCTAssertFalse(rendered.contains(value), "\(label): errorの表示に値が出ている", file: file, line: line)
                }
            }
        }
    }

    func testRealRS256FixtureJWKMatchesGeneratedKey() throws {
        let fixture = try makeRealRS256Fixture()

        // JWKのn・eは2048 bitの鍵とe=65537（AQAB）
        let modulus = try XCTUnwrap(base64URLDecode(try XCTUnwrap(fixture.jwk["n"] as? String)))
        let exponent = try XCTUnwrap(base64URLDecode(try XCTUnwrap(fixture.jwk["e"] as? String)))
        let firstByte = try XCTUnwrap(modulus.first)
        XCTAssertEqual((modulus.count - 1) * 8 + (8 - firstByte.leadingZeroBitCount), 2048)
        XCTAssertEqual(fixture.jwk["e"] as? String, "AQAB")
        XCTAssertEqual(SecKeyGetBlockSize(fixture.privateKey), 256)

        // JWKのn・eからPKCS#1のDERを組み立て直すと、SecKeyが書き出した公開鍵とバイト単位で一致する
        // （取り出しの途中でバイトの欠け・符号用の0x00の扱い違いなどが起きていない）
        let rebuiltDER = Data(derTLV(tag: 0x30, content: derUnsignedInteger(modulus) + derUnsignedInteger(exponent)))
        XCTAssertTrue(rebuiltDER == fixture.publicKeyDER, "JWKから組み立て直した公開鍵が実鍵と一致しない")

        // JWKだけから復元した公開鍵で、実鍵の署名がSecurity上で通る
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 2048,
        ]
        var error: Unmanaged<CFError>?
        let restoredKey = SecKeyCreateWithData(rebuiltDER as CFData, attributes as CFDictionary, &error)
        _ = error?.takeRetainedValue()
        let restored = try XCTUnwrap(restoredKey, "JWKから公開鍵を復元できない")
        let token = try signRealIDToken(claims: realIDTokenClaims(), fixture: fixture)
        XCTAssertTrue(try securityVerifiesSignature(of: token, with: restored))
        XCTAssertTrue(try securityVerifiesSignature(of: token, with: fixture.publicKey))

        // JWKSは公開鍵1件だけで、kidがheaderと一致し、秘密鍵の要素を含まない
        let set = try XCTUnwrap(try JSONSerialization.jsonObject(with: fixture.jwks) as? [String: Any])
        let keys = try XCTUnwrap(set["keys"] as? [[String: Any]])
        XCTAssertEqual(keys.count, 1)
        let key = try XCTUnwrap(keys.first)
        XCTAssertEqual(key["kid"] as? String, realPathKeyID)
        XCTAssertTrue(Set(key.keys).isDisjoint(with: ["d", "p", "q", "dp", "dq", "qi", "oth", "k"]))
        let headerSegment = try XCTUnwrap(token.split(separator: ".").first)
        let header = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(base64URLDecode(String(headerSegment)))) as? [String: Any]
        )
        XCTAssertEqual(header["kid"] as? String, realPathKeyID)
        XCTAssertEqual(header["alg"] as? String, "RS256")
    }

    func testProductionEntryAcceptsRealSignedIDTokenEndToEnd() throws {
        let fixture = try makeRealRS256Fixture()
        let token = try signRealIDToken(claims: realIDTokenClaims(), fixture: fixture)
        // 前提: bodyのid_tokenとして受け付けられる形（可視ASCII・上限以内）
        XCTAssertTrue(token.utf8.allSatisfy { (0x21...0x7E).contains($0) })
        let body = makeBody(set: ["id_token": q(token)])
        XCTAssertLessThan(body.count, ChatGPTOAuthTokenResponseParser.maxBodyLength)
        // 前提: subはbodyに平文では現れない（candidateのsubはID tokenの署名検証の結果からしか来ない）
        XCTAssertFalse(makeBodyString(set: ["id_token": q(token)]).contains(realPathSubject))

        let candidate = try XCTUnwrap(assertProductionAccepts(body: body, jwks: fixture.jwks, "実RS256署名のID token"))
        // 返されたcandidateの表示にも値が出ない
        for rendered in renderedForms(of: candidate) {
            XCTAssertFalse(rendered.contains(realPathSubject), "candidateの表示にsubが出ている")
            XCTAssertFalse(rendered.contains(token), "candidateの表示にID tokenが出ている")
        }
    }

    func testProductionEntryRejectsTamperedSignatureEndToEnd() throws {
        let fixture = try makeRealRS256Fixture()
        let token = try signRealIDToken(claims: realIDTokenClaims(), fixture: fixture)
        let tampered = try tamperingOneSignatureByte(of: token)

        // 前提: 改ざんは署名の1バイトだけで、署名対象（header.payload）と長さは同じ
        let original = try splitSignedToken(token)
        let modified = try splitSignedToken(tampered)
        XCTAssertEqual(original.signingInput, modified.signingInput)
        XCTAssertEqual(original.signature.count, modified.signature.count)
        XCTAssertEqual(zip(original.signature, modified.signature).filter { $0 != $1 }.count, 1)
        // 前提: Securityだけで見ても、元の署名は通り、改ざんした署名は通らない
        XCTAssertTrue(try securityVerifiesSignature(of: token, with: fixture.publicKey))
        XCTAssertFalse(try securityVerifiesSignature(of: tampered, with: fixture.publicKey))

        // positive control: 同じ鍵・JWKS・bodyで、改ざん前のtokenなら受理される
        assertProductionAccepts(body: makeBody(set: ["id_token": q(token)]), jwks: fixture.jwks, "control: 改ざん前の署名")

        assertProductionRejects(
            body: makeBody(set: ["id_token": q(tampered)]),
            jwks: fixture.jwks,
            idToken: tampered,
            as: .idTokenRejected,
            "署名の1バイト改ざん"
        )
    }

    func testProductionEntryRejectsNonceMismatchEndToEnd() throws {
        XCTAssertNotEqual(syntheticNonce, realPathOtherNonce)
        let fixture = try makeRealRS256Fixture()
        // 別のnonceで正しく署名したtoken（署名・鍵・他のclaimsは正しい）
        let token = try signRealIDToken(claims: realIDTokenClaims(nonce: realPathOtherNonce), fixture: fixture)
        let body = makeBody(set: ["id_token": q(token)])

        // positive control: 同じtokenでも、照合するnonceが署名されたnonceと一致すれば受理される
        // （拒否の理由がnonceの照合だけであることが分かる）
        assertProductionAccepts(body: body, nonce: realPathOtherNonce, jwks: fixture.jwks, "control: 一致するnonce")

        assertProductionRejects(
            body: body,
            nonce: syntheticNonce,
            jwks: fixture.jwks,
            idToken: token,
            as: .idTokenRejected,
            "nonce違い"
        )
    }

    func testProductionEntryRejectsMissingScopeEndToEnd() throws {
        let fixture = try makeRealRS256Fixture()
        let token = try signRealIDToken(claims: realIDTokenClaims(), fixture: fixture)

        // positive control: 同じ実署名tokenで、scopeがあれば受理される
        assertProductionAccepts(body: makeBody(set: ["id_token": q(token)]), jwks: fixture.jwks, "control: scopeあり")

        // 前提: scopeを省いたbodyは、scope以外の項目がそろったまま
        let body = makeBody(set: ["id_token": q(token)], remove: ["scope"])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(fieldOrder).subtracting(["scope"]))

        // ID tokenの署名検証に合格するtokenでも、scopeが無ければ推論利用を許可しない
        assertProductionRejects(
            body: body,
            jwks: fixture.jwks,
            idToken: token,
            as: .missingScope,
            "scopeなし"
        )
    }

    // MARK: 実RS256署名の補助（テスト専用）

    // base64url（RFC 4648 §5）、paddingなし
    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // 4文字単位になるようpaddingを補う
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private func base64URLSegment(_ object: [String: Any]) throws -> String {
        base64URL(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER } を読む。
    // JWKのn・eは符号なしの値なので、DER INTEGERの先頭に付く0x00は取り除く
    private func parsePKCS1RSAPublicKey(_ der: Data) throws -> (modulus: Data, exponent: Data) {
        let bytes = [UInt8](der)
        var index = 0
        let sequence = try readTLV(bytes, at: &index, expectedTag: 0x30)
        guard sequence.upperBound == bytes.count else { throw RealSignatureFixtureError.malformedDER }
        index = sequence.lowerBound
        let modulus = try readTLV(bytes, at: &index, expectedTag: 0x02)
        index = modulus.upperBound
        let exponent = try readTLV(bytes, at: &index, expectedTag: 0x02)
        guard exponent.upperBound == sequence.upperBound else { throw RealSignatureFixtureError.malformedDER }
        return (Data(bytes[modulus].drop { $0 == 0 }), Data(bytes[exponent].drop { $0 == 0 }))
    }

    // tagとlengthを読み、中身（value）の範囲を返す。indexはvalueの先頭に進める
    private func readTLV(_ bytes: [UInt8], at index: inout Int, expectedTag: UInt8) throws -> Range<Int> {
        guard index < bytes.count, bytes[index] == expectedTag else { throw RealSignatureFixtureError.malformedDER }
        index += 1
        guard index < bytes.count else { throw RealSignatureFixtureError.malformedDER }
        var length = Int(bytes[index])
        index += 1
        // 0x80以上は長形式。下位7bitが後続の長さバイト数
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), index + count <= bytes.count else { throw RealSignatureFixtureError.malformedDER }
            length = bytes[index..<(index + count)].reduce(0) { $0 << 8 | Int($1) }
            index += count
        }
        guard index + length <= bytes.count else { throw RealSignatureFixtureError.malformedDER }
        return index..<(index + length)
    }

    // DERのtag + length + valueを組み立てる。lengthは最短の形式（128未満は短形式、それ以外は長形式）
    private func derTLV(tag: UInt8, content: [UInt8]) -> [UInt8] {
        guard content.count >= 0x80 else { return [tag, UInt8(content.count)] + content }
        var lengthBytes: [UInt8] = []
        var remaining = content.count
        while remaining > 0 {
            lengthBytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [tag, 0x80 | UInt8(lengthBytes.count)] + lengthBytes + content
    }

    // 符号なしの値をDER INTEGERにする。最上位bitが1なら負数と区別するため先頭に0x00を付ける
    private func derUnsignedInteger(_ value: Data) -> [UInt8] {
        var bytes = [UInt8](value)
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return derTLV(tag: 0x02, content: bytes)
    }

    // MARK: - ID token検証の失敗

    func testRejectsWhenIDTokenVerifierThrows() {
        // 誤署名などverifierが投げうるerrorは、どれも必ず拒否に変わる
        let verifierErrors: [ChatGPTOpenAIIDTokenError] = [
            .invalidSignature, .malformedToken, .unsupportedAlgorithm, .untrustedKey,
            .invalidIssuer, .invalidAudience, .invalidNonce, .expired, .invalidIssuedAt, .invalidClaims,
        ]
        for verifierError in verifierErrors {
            assertRejects(
                verifier: SyntheticIDTokenVerifier(.rejected(verifierError)),
                as: .idTokenRejected,
                verifierCalls: 1,
                "verifier error: \(verifierError)"
            )
        }
        // verifier以外の型のerrorでも拒否する（そのまま外へ流さない）
        assertRejects(
            verifier: SyntheticIDTokenVerifier(.rejected(SyntheticVerifierFailure(detail: "synthetic"))),
            as: .idTokenRejected,
            verifierCalls: 1,
            "unknown verifier error"
        )
    }

    // MARK: - scope

    func testRejectsMissingScope() {
        // scopeはtoken responseだけが正本。無ければ補完せず拒否する
        assertRejects(body: makeBody(remove: ["scope"]), as: .missingScope, "scopeなし")
    }

    func testRejectsScopeWithoutDirectUse() {
        // ID token検証が成功していても、direct scopeが無ければ推論利用を許可しない
        let scopes = [
            "openid",
            "openid offline_access",
            "chatgpt.tokens.use",
            "chatgpt.tokens.use.direct.extra",
            "chatgpt.tokens.use.directx",
            "xchatgpt.tokens.use.direct",
            "CHATGPT.TOKENS.USE.DIRECT",        // scope tokenは大文字小文字を区別する（RFC 6749 §3.3）
            "Chatgpt.tokens.use.direct",
            "chatgpt.tokens.use.direct:read",
            "chatgpt_tokens_use_direct",
        ]
        for scope in scopes {
            assertRejects(body: makeBody(set: ["scope": q(scope)]), as: .directUseNotGranted, "scope: \(scope)")
        }
    }

    func testRejectsMalformedScope() {
        // 形式の壊れたscopeは、ID token検証の前に拒否する
        let fragments: [(fragment: String, label: String)] = [
            ("null", "null"),
            ("123", "数値"),
            ("true", "真偽値"),
            (#"["chatgpt.tokens.use.direct"]"#, "配列"),
            (#"{"scope":"chatgpt.tokens.use.direct"}"#, "object"),
            (q(""), "空文字列"),
            (q(" "), "空白のみ"),
            (q(" chatgpt.tokens.use.direct"), "先頭の空白"),
            (q("chatgpt.tokens.use.direct "), "末尾の空白"),
            (q("openid  chatgpt.tokens.use.direct"), "連続した空白"),
            (#""openid\tchatgpt.tokens.use.direct""#, "tab区切り"),
            (#""openid\nchatgpt.tokens.use.direct""#, "改行区切り"),
            (#""openid chatgpt.tokens.use.direct""#, "NBSP区切り"),
            (#""chatgpt.tokens.use.direct\u0000""#, "NUL"),
            (#""chatgpt.tokens.use.directé""#, "非ASCII"),
            (#""chatgpt.tokens.use.direct \"quoted\"""#, "引用符（scope-tokenに使えない文字）"),
            (#""chatgpt.tokens.use.direct back\\slash""#, "backslash（scope-tokenに使えない文字）"),
            (q("chatgpt.tokens.use.direct chatgpt.tokens.use.direct"), "同じscopeの重複"),
            (q("openid chatgpt.tokens.use.direct openid"), "別scopeの重複"),
        ]
        for (fragment, label) in fragments {
            assertRejects(
                body: makeBody(set: ["scope": fragment]),
                as: .invalidScope,
                verifierCalls: 0,
                "scope: \(label)"
            )
        }
    }

    // MARK: - token_type

    func testRejectsNonBearerTokenType() {
        let tokenTypes = ["mac", "DPoP", "Basic", "Bearer ", " Bearer", "Bearer\\t", "Bear", "Bearerx", "Ｂearer", "N_A", ""]
        for tokenType in tokenTypes {
            assertRejects(
                body: makeBody(set: ["token_type": q(tokenType)]),
                as: .unsupportedTokenType,
                verifierCalls: 0,
                "token_type: \(tokenType)"
            )
        }
    }

    func testRejectsMissingOrNonStringTokenType() {
        assertRejects(body: makeBody(remove: ["token_type"]), as: .invalidField, verifierCalls: 0, "token_typeなし")
        for fragment in ["null", "1", "true", #"["Bearer"]"#, #"{"type":"Bearer"}"#] {
            assertRejects(
                body: makeBody(set: ["token_type": fragment]),
                as: .invalidField,
                verifierCalls: 0,
                "token_type: \(fragment)"
            )
        }
    }

    // MARK: - expires_in

    func testRejectsAlreadyExpiredExpiresIn() {
        for fragment in ["0", "-1", "-3600"] {
            assertRejects(
                body: makeBody(set: ["expires_in": fragment]),
                as: .expired,
                verifierCalls: 0,
                "expires_in: \(fragment)"
            )
        }
    }

    func testRejectsInvalidExpiresIn() {
        assertRejects(body: makeBody(remove: ["expires_in"]), as: .invalidExpiresIn, verifierCalls: 0, "expires_inなし")
        let fragments = ["null", q("3600"), "true", "false", "3600.5", "0.5", "[3600]", #"{"seconds":3600}"#]
        for fragment in fragments {
            assertRejects(
                body: makeBody(set: ["expires_in": fragment]),
                as: .invalidExpiresIn,
                verifierCalls: 0,
                "expires_in: \(fragment)"
            )
        }
    }

    func testRejectsOverflowingExpiresIn() {
        let overLimit = String(ChatGPTOAuthTokenResponseParser.maxExpiresInSeconds + 1)
        let fragments = [
            overLimit,
            "2147483648",                 // Int32.max + 1
            "9223372036854775807",        // Int64.max
            "9223372036854775808",        // Int64.max + 1
            "18446744073709551616",       // UInt64.max + 1
            "1e300",
        ]
        for fragment in fragments {
            assertRejects(
                body: makeBody(set: ["expires_in": fragment]),
                as: .invalidExpiresIn,
                verifierCalls: 0,
                "expires_in: \(fragment)"
            )
        }
        // 倍精度で表せない値は、JSONとして読めない扱いでも上限超過の扱いでもよい。ただし必ず拒否する
        let verifier = verified()
        XCTAssertThrowsError(try parse(body: makeBody(set: ["expires_in": "1e400"]), verifier: verifier)) { error in
            let parsed = error as? ChatGPTOAuthTokenResponseError
            XCTAssertTrue(parsed == .invalidExpiresIn || parsed == .malformedBody, "expires_in: 1e400 → \(String(describing: parsed))")
        }
        XCTAssertEqual(verifier.calls.count, 0)
    }

    // MARK: - 秘密値の項目

    func testRejectsInvalidCredentialFields() {
        let fragments: [(fragment: String, label: String)] = [
            ("null", "null"),
            ("123", "数値"),
            ("true", "真偽値"),
            (#"["synthetic"]"#, "配列"),
            ("{}", "object"),
            (q(""), "空文字列"),
            (q("has space"), "空白を含む"),
            (#""tab\tchar""#, "tabを含む"),
            (#""line\nbreak""#, "改行を含む"),
            (#""nul\u0000char""#, "NULを含む"),
            (#""del\u007fchar""#, "DELを含む"),
            (#""café""#, "非ASCIIを含む"),
        ]
        for key in ["access_token", "refresh_token", "id_token"] {
            assertRejects(body: makeBody(remove: [key]), as: .invalidField, verifierCalls: 0, "\(key)なし")
            for (fragment, label) in fragments {
                assertRejects(
                    body: makeBody(set: [key: fragment]),
                    as: .invalidField,
                    verifierCalls: 0,
                    "\(key): \(label)"
                )
            }
        }
    }

    func testSuccessfulStatusWithErrorBodyIsRejected() {
        // 200でもOAuthのerror形式（access_tokenなど必須項目なし）は受け付けない
        let body = Data(#"{"error":"invalid_grant","error_description":"synthetic"}"#.utf8)
        assertRejects(body: body, as: .invalidField, verifierCalls: 0, "200 + error body")
        assertRejects(body: Data("{}".utf8), as: .invalidField, verifierCalls: 0, "空のobject")
    }

    // MARK: - 重複

    func testRejectsDuplicateFields() {
        let cases: [(body: Data, label: String)] = [
            (makeBody(extra: [(q("access_token"), q("other-synthetic-access"))]), "access_tokenの重複"),
            (makeBody(extra: [(q("refresh_token"), q("other-synthetic-refresh"))]), "refresh_tokenの重複"),
            (makeBody(extra: [(q("id_token"), q("b3RoZXI.aWQ.c2ln"))]), "id_tokenの重複"),
            (makeBody(extra: [(q("token_type"), q("Bearer"))]), "token_typeの同値重複"),
            (makeBody(extra: [(q("expires_in"), "3600")]), "expires_inの同値重複"),
            // 後勝ちで解釈されると、direct scopeの無い応答が許可されてしまう組み合わせ
            (makeBody(set: ["scope": q("openid")], extra: [(q("scope"), q(directUseScope))]), "scopeの重複（後ろにdirect）"),
            (makeBody(extra: [(q("scope"), q("openid"))]), "scopeの重複（前にdirect）"),
            // JSONのescape表記でも同じkeyなら重複（fixtureがescapeを含むことは別のテストで確認する）
            (makeBody(extra: [(escapedAccessTokenKey, q("other-synthetic-access"))]), "escape表記のaccess_token"),
            (makeBody(extra: [(escapedScopeKey, q("openid"))]), "escape表記のscope"),
            // 知らない項目でも、同じkeyが複数あるbodyは全体を信頼しない
            (makeBody(extra: [(q("synthetic_extra"), "1"), (q("synthetic_extra"), "2")]), "知らない項目の重複"),
        ]
        for (body, label) in cases {
            assertRejects(body: body, as: .duplicateField, verifierCalls: 0, label)
        }
    }

    func testUnicodeEscapedKeyFixturesReallyContainEscapes() throws {
        // 前提: fixtureのkeyは、backslash + "u" + hexを文字どおり含み、素のkeyとは別の文字列である
        let cases: [(fragment: String, escape: String, decoded: String)] = [
            (escapedAccessTokenKey, "0061", "access_token"),
            (escapedScopeKey, "006f", "scope"),
        ]
        for (fragment, escape, decoded) in cases {
            XCTAssertTrue(fragment.unicodeScalars.contains { $0.value == 0x5C }, "\(decoded): backslashを含む")
            XCTAssertTrue(fragment.contains(Self.backslash + "u" + escape), "\(decoded): escape表記を含む")
            XCTAssertNotEqual(fragment, q(decoded), "\(decoded): 素のkeyと同じ表記になっている")
            XCTAssertFalse(fragment.contains(decoded), "\(decoded): 素のkeyの綴りを含んでいる")
            // parserと独立にJSONSerializationでescapeを解くと、本来のkeyになる
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data("{\(fragment):1}".utf8)) as? [String: Any]
            )
            XCTAssertEqual(Array(object.keys), [decoded])
        }
    }

    func testUnicodeEscapedKeyIsDecodedBeforeLookup() throws {
        // positive control: escape表記のkeyだけなら、escapeを解いた項目として受け付ける。
        // これにより、重複の拒否が「escapeを解いた結果の一致」によるものだと分かる
        let accessVerifier = verified()
        let accessBody = makeBody(remove: ["access_token"], extra: [(escapedAccessTokenKey, q(syntheticAccessToken))])
        let accessCandidate = try parse(body: accessBody, verifier: accessVerifier)
        XCTAssertEqual(accessCandidate.accessToken, syntheticAccessToken)
        XCTAssertEqual(accessVerifier.calls.count, 1)

        let scopeVerifier = verified()
        let scopeBody = makeBody(remove: ["scope"], extra: [(escapedScopeKey, q(syntheticScope))])
        let scopeCandidate = try parse(body: scopeBody, verifier: scopeVerifier)
        XCTAssertEqual(scopeCandidate.grantedScopes, ["openid", "offline_access", "chatgpt.tokens.use.direct"])
        XCTAssertEqual(scopeVerifier.calls.count, 1)
    }

    func testRejectsDuplicateFieldsWrittenWithUnicodeEscapes() {
        // 素のkeyとescape表記のkeyが並んだら、どちらが先でも重複として拒否し、ID token検証は呼ばない
        let cases: [(body: Data, label: String)] = [
            (makeBody(extra: [(escapedAccessTokenKey, q("other-synthetic-access"))]), "素のaccess_token → escape表記"),
            (
                makeBody(remove: ["access_token"], extra: [
                    (escapedAccessTokenKey, q("other-synthetic-access")),
                    (q("access_token"), q(syntheticAccessToken)),
                ]),
                "escape表記 → 素のaccess_token"
            ),
            (makeBody(extra: [(escapedScopeKey, q("openid"))]), "素のscope → escape表記"),
            // 後勝ちで解釈されると、direct scopeの無い応答が許可されてしまう組み合わせ
            (
                makeBody(set: ["scope": q("openid")], extra: [(escapedScopeKey, q(directUseScope))]),
                "direct無しのscope → escape表記のdirect"
            ),
        ]
        for (body, label) in cases {
            assertRejects(body: body, as: .duplicateField, verifierCalls: 0, label)
        }
    }

    // MARK: - 厳格なJSON parser
    // 知らない項目は値を見ずに無視されるので、その値にだけ手を加えれば、受理・拒否はparserだけで決まる

    // 知らない項目（synthetic_note）として、値のJSON断片を1つ足したbody
    private func makeBodyWithIgnoredValue(_ fragment: String) -> Data {
        makeBody(extra: [(q("synthetic_note"), fragment)])
    }

    // 知らない項目の文字列の中身を、任意のバイト列（不正なUTF-8など）に差し替えたbody
    private func makeBodyWithIgnoredStringBytes(_ bytes: [UInt8]) throws -> Data {
        var body = makeBodyWithIgnoredValue(q("MARKER"))
        let marker = try XCTUnwrap(body.range(of: Data("MARKER".utf8)))
        body.replaceSubrange(marker, with: bytes)
        return body
    }

    // 配列をlevels段入れ子にしたJSON断片。例: levels=2 → [[]]
    private func nestedArrays(levels: Int) -> String {
        String(repeating: "[", count: levels) + String(repeating: "]", count: levels)
    }

    // objectをlevels段入れ子にしたJSON断片。例: levels=2 → {"n":{}}
    private func nestedObjects(levels: Int) -> String {
        String(repeating: #"{"n":"#, count: levels - 1) + "{}" + String(repeating: "}", count: levels - 1)
    }

    // positive control用。parserを通過し、ID token検証まで1回だけ進んだことを確かめる
    private func assertAccepts(
        body: Data,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let verifier = verified()
        XCTAssertNoThrow(try parse(body: body, verifier: verifier), label, file: file, line: line)
        XCTAssertEqual(verifier.calls.count, 1, "\(label): ID token検証closureの呼び出し回数", file: file, line: line)
    }

    func testSurrogatePairEscapeIsAccepted() {
        // U+1F600 をUTF-16のsurrogate pairで書いたもの。hexの大文字小文字は区別しない
        let pair = unicodeEscape("D83D") + unicodeEscape("DE00")
        let cases: [(fragment: String, label: String)] = [
            (q(pair), "大文字hex"),
            (q(unicodeEscape("d83d") + unicodeEscape("de00")), "小文字hex"),
            (q("before" + pair + "after"), "前後に文字"),
            // 上位・下位の範囲の両端
            (q(unicodeEscape("D800") + unicodeEscape("DC00")), "U+10000"),
            (q(unicodeEscape("DBFF") + unicodeEscape("DFFF")), "U+10FFFF"),
        ]
        for (fragment, label) in cases {
            assertAccepts(body: makeBodyWithIgnoredValue(fragment), "surrogate pair: \(label)")
        }
    }

    func testSurrogatePairEscapeDecodesToSameKeyAsLiteralCharacter() throws {
        // surrogate pairが1つのscalar（U+1F600）にまとめられていることを、重複keyの判定で確かめる
        let emoji = String(Character(try XCTUnwrap(Unicode.Scalar(UInt32(0x1F600)))))
        let escapedKey = q(unicodeEscape("D83D") + unicodeEscape("DE00"))
        // 前提: それぞれ単独なら受け付ける
        assertAccepts(body: makeBody(extra: [(q(emoji), "1")]), "control: 文字そのもののkey")
        assertAccepts(body: makeBody(extra: [(escapedKey, "1")]), "control: surrogate pairのkey")

        assertRejects(
            body: makeBody(extra: [(q(emoji), "1"), (escapedKey, "2")]),
            as: .duplicateField,
            verifierCalls: 0,
            "文字そのもの → surrogate pairの同じkey"
        )
    }

    func testRejectsUnpairedSurrogateEscape() {
        let high = unicodeEscape("D83D")
        let low = unicodeEscape("DE00")
        let cases: [(fragment: String, label: String)] = [
            (q(high), "上位だけで文字列が終わる"),
            (q(high + "x"), "上位の後に普通の文字"),
            (q(high + unicodeEscape("0041")), "上位の後に通常のescape"),
            (q(high + Self.backslash + "n"), "上位の後に別種のescape"),
            (q(high + high), "上位の連続"),
            (q(high + unicodeEscape("E000")), "上位の後に下位の範囲外"),
            (q(low), "下位だけ"),
            (q("x" + low), "普通の文字の後に下位"),
            (q(low + high), "下位 → 上位の逆順"),
        ]
        for (fragment, label) in cases {
            assertRejects(
                body: makeBodyWithIgnoredValue(fragment),
                as: .malformedBody,
                verifierCalls: 0,
                "単独のsurrogate（値）: \(label)"
            )
        }
        // keyの中でも同じく拒否する
        assertRejects(body: makeBody(extra: [(q(high), "1")]), as: .malformedBody, verifierCalls: 0, "単独のsurrogate（key）")
    }

    func testRejectsDuplicateKeysInNestedObjects() {
        // 前提: 入れ子でも、keyが重ならなければ受け付ける
        let accepted: [(fragment: String, label: String)] = [
            (#"{"a":1,"b":2}"#, "異なるkey"),
            (#"{"a":{"a":1}}"#, "親子で同じkey（別のobject）"),
            (#"[{"a":1},{"a":2}]"#, "配列内の別々のobject"),
            (#"{"access_token":"synthetic-nested"}"#, "最上位と同じ名前のkey（別のobject）"),
        ]
        for (fragment, label) in accepted {
            assertAccepts(body: makeBodyWithIgnoredValue(fragment), "control: \(label)")
        }

        let rejected: [(fragment: String, label: String)] = [
            (#"{"a":1,"a":2}"#, "1段下のobject"),
            (#"{"a":1,"a":1}"#, "同値の重複"),
            ("{\"a\":1,\"" + unicodeEscape("0061") + "\":2}", "escape表記の重複"),
            (#"{"outer":{"a":1,"a":2}}"#, "2段下のobject"),
            (#"[{"a":1,"a":2}]"#, "配列の中のobject"),
        ]
        for (fragment, label) in rejected {
            assertRejects(
                body: makeBodyWithIgnoredValue(fragment),
                as: .duplicateField,
                verifierCalls: 0,
                "入れ子の重複: \(label)"
            )
        }
    }

    func testNestingDepthBoundary() throws {
        // 現在の実装の上限は、最上位objectを含めて32段（StrictJSONParser.maxDepth = 32）。
        // 最上位objectで1段使うので、知らない項目の値は31段まで、32段（合計33段）で拒否する
        let maximumTotalDepth = 32
        let valueLevelsAtLimit = maximumTotalDepth - 1

        let builders: [(kind: String, nested: (Int) -> String)] = [
            ("配列", { self.nestedArrays(levels: $0) }),
            ("object", { self.nestedObjects(levels: $0) }),
        ]
        for (kind, nested) in builders {
            let atLimit = nested(valueLevelsAtLimit)
            let overLimit = nested(valueLevelsAtLimit + 1)
            // 前提: 断片の入れ子の段数が意図どおり
            let opener: Character = kind == "配列" ? "[" : "{"
            XCTAssertEqual(atLimit.filter { $0 == opener }.count, valueLevelsAtLimit, kind)
            XCTAssertEqual(overLimit.filter { $0 == opener }.count, valueLevelsAtLimit + 1, kind)

            // 合計32段は受け付ける（境界まで実際に到達している）
            assertAccepts(body: makeBodyWithIgnoredValue(atLimit), "\(kind): 合計\(maximumTotalDepth)段")

            // 合計33段はJSONとしては正しいが、深さの上限で拒否する
            let overBody = makeBodyWithIgnoredValue(overLimit)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: overBody), "\(kind): 前提として正しいJSON")
            assertRejects(
                body: overBody,
                as: .malformedBody,
                verifierCalls: 0,
                "\(kind): 合計\(maximumTotalDepth + 1)段"
            )
        }
    }

    func testStrictUTF8Decoding() throws {
        // 前提: 正しいUTF-8の多バイト文字は受け付ける
        let valid: [(bytes: [UInt8], label: String)] = [
            ([0xC3, 0xA9], "2バイト（U+00E9）"),
            ([0xE3, 0x81, 0x82], "3バイト（U+3042）"),
            ([0xF0, 0x9F, 0x98, 0x80], "4バイト（U+1F600）"),
            ([0xF4, 0x8F, 0xBF, 0xBF], "最大のscalar（U+10FFFF）"),
        ]
        for (bytes, label) in valid {
            assertAccepts(body: try makeBodyWithIgnoredStringBytes(bytes), "control: \(label)")
        }

        let invalid: [(bytes: [UInt8], label: String)] = [
            ([0x80], "先頭にcontinuation byte"),
            ([0xC3], "2バイト文字の途中で終わる"),
            ([0xE3, 0x81], "3バイト文字の途中で終わる"),
            ([0xF0, 0x9F, 0x98], "4バイト文字の途中で終わる"),
            ([0xC0, 0xAF], "overlong（2バイト）"),
            ([0xC1, 0xBF], "overlong（C1）"),
            ([0xE0, 0x80, 0xAF], "overlong（3バイト）"),
            ([0xF0, 0x80, 0x80, 0xAF], "overlong（4バイト）"),
            ([0xED, 0xA0, 0x80], "surrogate（U+D800）をUTF-8にしたもの"),
            ([0xED, 0xBF, 0xBF], "surrogate（U+DFFF）をUTF-8にしたもの"),
            ([0xF4, 0x90, 0x80, 0x80], "U+10FFFFより大きい"),
            ([0xF5, 0x80, 0x80, 0x80], "使われない先頭バイト（F5）"),
            ([0xFE], "使われないバイト（FE）"),
            ([0xC3, 0x41], "continuation byteの代わりにASCII"),
        ]
        for (bytes, label) in invalid {
            assertRejects(
                body: try makeBodyWithIgnoredStringBytes(bytes),
                as: .malformedBody,
                verifierCalls: 0,
                "不正なUTF-8: \(label)"
            )
        }
    }

    func testNumberGrammar() throws {
        // 前提: RFC 8259の数値の文法に合うものは受け付ける
        let valid = ["0", "-0", "7", "123", "-123", "0.5", "-0.0", "1.25", "1e5", "1E5", "1e+5", "1e-5", "-1.5E-3", "0e0"]
        for fragment in valid {
            assertAccepts(body: makeBodyWithIgnoredValue(fragment), "control: number \(fragment)")
        }

        // 全角の「1」（U+FF11）。JSONの数字はASCIIの0-9だけ
        let fullWidthOne = String(Character(try XCTUnwrap(Unicode.Scalar(UInt32(0xFF11)))))
        let malformed = [
            "01", "00", "-01", "-", "--1", "+1", "1.", ".5", "-.5", "1.e5", "1e", "1e+", "1E-", "1e5.0",
            "0x10", "1_000", "1 2", "NaN", "Infinity", "-Infinity", fullWidthOne,
        ]
        for fragment in malformed {
            assertRejects(
                body: makeBodyWithIgnoredValue(fragment),
                as: .malformedBody,
                verifierCalls: 0,
                "malformed number: \(fragment)"
            )
        }
        // expires_inでも、数値の文法違反は項目の検証より前にJSONとして拒否する
        for fragment in ["03600", "3600.", "+3600", "-03600"] {
            assertRejects(
                body: makeBody(set: ["expires_in": fragment]),
                as: .malformedBody,
                verifierCalls: 0,
                "expires_in malformed number: \(fragment)"
            )
        }
    }

    // MARK: - bodyの形式

    func testRejectsMalformedBody() throws {
        let base = makeBodyString()
        var invalidUTF8 = makeBody(extra: [(q("synthetic_note"), q("MARKER"))])
        let marker = try XCTUnwrap(invalidUTF8.range(of: Data("MARKER".utf8)))
        invalidUTF8.replaceSubrange(marker, with: [0x4D, 0xFF, 0x4D])

        let cases: [(body: Data, label: String)] = [
            (Data(), "空のbody"),
            (Data("null".utf8), "null"),
            (Data("[]".utf8), "配列"),
            (Data("[\(base)]".utf8), "objectを包んだ配列"),
            (Data(#""synthetic""#.utf8), "文字列"),
            (Data("3600".utf8), "数値"),
            (Data("{".utf8), "閉じていないobject"),
            (Data(String(base.dropLast()).utf8), "末尾の欠けたobject"),
            (Data((base + "garbage").utf8), "末尾のゴミ"),
            (Data((base + base).utf8), "objectの連続"),
            (Data(base.replacingOccurrences(of: ",", with: ",,").utf8), "連続したカンマ"),
            (Data("synthetic=not-json".utf8), "form形式"),
            (invalidUTF8, "不正なUTF-8"),
            (try XCTUnwrap(base.data(using: .utf16)), "UTF-16（BOM付き）"),
            (try XCTUnwrap(base.data(using: .utf16LittleEndian)), "UTF-16LE"),
        ]
        for (body, label) in cases {
            assertRejects(body: body, as: .malformedBody, verifierCalls: 0, label)
        }
    }

    // MARK: - HTTP status

    func testRejectsNon200Status() {
        let statuses = [-200, 0, 100, 199, 201, 202, 204, 206, 299, 301, 302, 304, 400, 401, 403, 429, 500, 502, 503]
        for status in statuses {
            assertRejects(statusCode: status, as: .unexpectedStatus, verifierCalls: 0, "status: \(status)")
        }
        // OAuthのerror responseも、statusで拒否する
        let errorBody = Data(#"{"error":"invalid_grant","error_description":"synthetic"}"#.utf8)
        assertRejects(statusCode: 400, body: errorBody, as: .unexpectedStatus, verifierCalls: 0, "400 + error body")
    }

    // MARK: - データ上限

    func testRejectsBodyOverLimit() {
        let base = makeBodyString()
        let limit = ChatGPTOAuthTokenResponseParser.maxBodyLength
        // JSONとしては正しいまま、上限を1バイトだけ超える
        let overByOne = Data(("{" + String(repeating: " ", count: limit - base.utf8.count + 1) + base.dropFirst()).utf8)
        XCTAssertEqual(overByOne.count, limit + 1)
        assertRejects(body: overByOne, as: .bodyTooLarge, verifierCalls: 0, "上限+1バイト")

        // 巨大な値を持つbody。JSONの解析より前に拒否する
        let hugeToken = String(repeating: "A", count: limit * 4)
        assertRejects(body: makeBody(set: ["access_token": q(hugeToken)]), as: .bodyTooLarge, verifierCalls: 0, "巨大なaccess_token")
        assertRejects(body: Data(repeating: 0x20, count: limit * 4), as: .bodyTooLarge, verifierCalls: 0, "巨大な空白")
    }

    // MARK: - 呼び出し元の期待値

    func testRejectsEmptyCallerExpectations() {
        assertRejects(clientID: "", as: .invalidExpectation, verifierCalls: 0, "空のclient_id")
        assertRejects(nonce: "", as: .invalidExpectation, verifierCalls: 0, "空のnonce")
    }

    // MARK: - 秘密値の表示

    func testCandidateRenderingRedactsCredentials() throws {
        let candidate = try parse(verifier: verified())
        let secrets = [syntheticAccessToken, syntheticRefreshToken, syntheticIDToken, syntheticSubject]

        for rendered in renderedForms(of: candidate) {
            for secret in secrets {
                XCTAssertFalse(rendered.contains(secret), "表示に秘密値・識別子が出ている")
            }
            XCTAssertTrue(rendered.contains("redacted"), "伏せ字であることが分かる表示にする")
        }
        // Mirrorの子要素からも秘密値を辿れない
        XCTAssertFalse(Mirror(reflecting: candidate).children.contains { child in
            let value = String(describing: child.value)
            return secrets.contains { value.contains($0) }
        })
    }

    func testErrorsDoNotExposeCredentialsOrVerifierDetails() {
        let secrets = [syntheticAccessToken, syntheticRefreshToken, syntheticIDToken, syntheticSubject, syntheticClientID, syntheticNonce]
        // 検証側のerrorに秘密値が含まれていても、parserのerrorへは出さない
        let leakyFailure = SyntheticVerifierFailure(detail: "leak:\(syntheticIDToken):\(syntheticAccessToken)")
        let errors: [Error?] = [
            assertRejects(verifier: SyntheticIDTokenVerifier(.rejected(leakyFailure)), as: .idTokenRejected, "verifierのerror"),
            assertRejects(body: makeBody(set: ["scope": q("openid")]), as: .directUseNotGranted, "directなし"),
            assertRejects(body: makeBody(set: ["token_type": q("mac")]), as: .unsupportedTokenType, "token_type"),
            assertRejects(body: makeBody(extra: [(q("access_token"), q(syntheticRefreshToken))]), as: .duplicateField, "重複"),
            assertRejects(statusCode: 401, as: .unexpectedStatus, "status"),
            assertRejects(body: Data((makeBodyString() + syntheticAccessToken).utf8), as: .malformedBody, "malformed"),
        ]
        for error in errors.compactMap({ $0 }) {
            for rendered in renderedErrorForms(of: error) {
                for secret in secrets {
                    XCTAssertFalse(rendered.contains(secret), "errorの表示に秘密値が出ている: \(error)")
                }
                XCTAssertFalse(rendered.contains("leak:"), "verifierのerror内容がそのまま出ている")
            }
        }
    }
}
