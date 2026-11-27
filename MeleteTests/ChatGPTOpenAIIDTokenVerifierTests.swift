import CryptoKit
import Security
import XCTest
@testable import Melete

// OpenAI ID tokenの署名・claims検証だけを検証する。
// 鍵はテスト中だけSecurityでメモリ上に生成し（永続化しない）、JWTも本物のRS256署名で合成する。
// 実鍵・実トークン・ネットワーク・Keychain・保存には一切触れない。値はすべてテスト専用の合成固定値。
// 署名の生成には検証対象と同じライブラリ（JOSESwift）を使わず、Securityだけで行う
final class ChatGPTOpenAIIDTokenVerifierTests: XCTestCase {
    // 合成の固定値（実際の認証には使われない）
    private let issuer = "https://auth.openai.com"
    private let syntheticClientID = "issued-synthetic-client"
    private let otherClientID = "other-synthetic-client"
    private let syntheticNonce = "SyntheticNonceValue0123456789-_abcdefghijk"
    private let otherNonce = "OtherSyntheticNonceValue0123456789-_abcdef"
    private let syntheticSubject = "synthetic-subject-0123456789"
    private let trustedKeyID = "synthetic-trusted-kid"
    private let untrustedKeyID = "synthetic-untrusted-kid"
    // Unicodeの正規等価だがコードポイント（UTF-8のバイト列）は異なる合成識別子。
    // 前者は合成済みのé（U+00E9）、後者はe + 結合アクセント（U+0065 U+0301）
    private let precomposedIdentifier = "synthetic-caf\u{00E9}"
    private let decomposedIdentifier = "synthetic-cafe\u{0301}"

    // 固定時刻。iat=発行時刻、exp=発行から1時間後、now=発行から1分後
    private let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private var expiresAt: Date { issuedAt.addingTimeInterval(3600) }
    private var validNow: Date { issuedAt.addingTimeInterval(60) }

    // MARK: - 鍵とJWTの合成

    // メモリ上だけのRSA鍵ペアを生成する。kSecAttrIsPermanent=falseでKeychainに保存させない
    private func makeKeyPair(bits: Int = 2048) throws -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: bits,
            kSecAttrIsPermanent: false,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false],
        ]
        var error: Unmanaged<CFError>?
        // エラー内容は出力しない（失敗したことだけ分かればよい）
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            _ = error?.takeRetainedValue()
            throw FixtureError.keyGenerationFailed
        }
        return privateKey
    }

    // 秘密鍵から公開鍵を取り出し、JWK（kty=RSA, n, e）のJSONオブジェクトにする
    // key_ops（配列）なども足せるよう、値はAnyで持つ
    private func publicJWK(for privateKey: SecKey, keyID: String) throws -> [String: Any] {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            _ = error?.takeRetainedValue()
            throw FixtureError.publicKeyExportFailed
        }
        // RSA公開鍵の外部表現はPKCS#1のRSAPublicKey（SEQUENCE { modulus, publicExponent }）
        let (modulus, exponent) = try parsePKCS1RSAPublicKey(der)
        return [
            "kty": "RSA",
            "kid": keyID,
            "use": "sig",
            "alg": "RS256",
            "n": base64URL(modulus),
            "e": base64URL(exponent),
        ]
    }

    // extraはJWKSのトップレベルに足すメンバー（サイズ調整用の詰め物など）。verifierはkeys以外を読まない
    private func jwksData(_ keys: [[String: Any]], extra: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["keys": keys]
        object.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // 正しいclaims。必要に応じて一部だけ上書きして異常系を作る
    private func claims(
        audience: String? = nil,
        nonce: String? = nil
    ) -> [String: Any] {
        [
            "iss": issuer,
            "aud": audience ?? syntheticClientID,
            "nonce": nonce ?? syntheticNonce,
            "sub": syntheticSubject,
            "iat": Int(issuedAt.timeIntervalSince1970),
            "exp": Int(expiresAt.timeIntervalSince1970),
        ]
    }

    private func encodedSegment(_ object: [String: Any]) throws -> String {
        base64URL(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    // JWTのheader。keyIDがnilならkidを書かない。extraで任意のメンバー（critなど）を足せる
    private func header(keyID: String?, extra: [String: Any] = [:]) -> [String: Any] {
        var header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
        if let keyID {
            header["kid"] = keyID
        }
        header.merge(extra) { _, new in new }
        return header
    }

    // header.payload をSecurityのRSASSA-PKCS1-v1_5 + SHA-256（=RS256）で署名したcompact JWTを返す
    private func signRS256(
        claims: [String: Any],
        keyID: String?,
        privateKey: SecKey,
        extraHeader: [String: Any] = [:]
    ) throws -> String {
        let signingInput = try encodedSegment(header(keyID: keyID, extra: extraHeader)) + "." + encodedSegment(claims)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &error
        ) as Data? else {
            _ = error?.takeRetainedValue()
            throw FixtureError.signingFailed
        }
        return signingInput + "." + base64URL(signature)
    }

    // 信頼する鍵1個だけのJWKSと、その鍵で署名する秘密鍵を用意する
    private func makeTrustedFixture() throws -> (privateKey: SecKey, jwks: Data) {
        let privateKey = try makeKeyPair()
        let jwks = try jwksData([try publicJWK(for: privateKey, keyID: trustedKeyID)])
        return (privateKey, jwks)
    }

    // 正しいclaimsと正しい署名のまま、compact JWT全体がちょうどtargetバイトになるtokenを作る。
    // base64urlの長さは元の長さの4/3倍で飛び飛びの値になるので、headerとpayloadの詰め物の長さを両方動かして探す
    private func signedToken(exactLength target: Int, privateKey: SecKey) throws -> String {
        // RS256の署名長は鍵長（バイト）と同じなので、署名前に署名セグメントの長さが分かる
        let signatureLength = base64URL(Data(count: SecKeyGetBlockSize(privateKey))).count
        var emptyPadded = claims()
        emptyPadded["x_synthetic_pad"] = ""
        let baseJSONLength = try JSONSerialization.data(withJSONObject: emptyPadded, options: [.sortedKeys]).count

        for headerPadCount in 0..<4 {
            let extraHeader: [String: Any] = ["x_synthetic_pad": String(repeating: "h", count: headerPadCount)]
            let headerLength = try encodedSegment(header(keyID: trustedKeyID, extra: extraHeader)).count
            // "." 2個分を引いた、payloadセグメントに必要な長さ
            let payloadTarget = target - headerLength - signatureLength - 2
            // 必要な詰め物の長さの見当を付け、その前後だけを調べる
            let estimate = max(0, payloadTarget * 3 / 4 - baseJSONLength - 4)
            for payloadPadCount in estimate..<(estimate + 8) {
                var padded = claims()
                padded["x_synthetic_pad"] = String(repeating: "p", count: payloadPadCount)
                if try encodedSegment(padded).count == payloadTarget {
                    return try signRS256(
                        claims: padded,
                        keyID: trustedKeyID,
                        privateKey: privateKey,
                        extraHeader: extraHeader
                    )
                }
            }
        }
        throw FixtureError.lengthNotReachable
    }

    // 信頼する鍵のJWKSに詰め物を足し、JSON全体がちょうどtargetバイトになるようにする
    private func jwksData(exactLength target: Int, privateKey: SecKey) throws -> Data {
        let keys = [try publicJWK(for: privateKey, keyID: trustedKeyID)]
        let baseLength = try jwksData(keys, extra: ["x_synthetic_pad": ""]).count
        guard target >= baseLength else { throw FixtureError.lengthNotReachable }
        // ASCIIの1文字はJSONでも1バイトなので、差の分だけ詰めればよい
        let pad = String(repeating: "p", count: target - baseLength)
        return try jwksData(keys, extra: ["x_synthetic_pad": pad])
    }

    // JWKのnから鍵長（bit）を数える（fixtureの前提確認用）
    private func modulusBits(_ jwk: [String: Any]) throws -> Int {
        let modulusString = try XCTUnwrap(jwk["n"] as? String)
        let modulus = try XCTUnwrap(base64URLDecode(modulusString))
        let first = try XCTUnwrap(modulus.first)
        return (modulus.count - 1) * 8 + (8 - first.leadingZeroBitCount)
    }

    private func verify(
        _ token: String,
        jwks: Data,
        now: Date? = nil
    ) throws -> ChatGPTOpenAIIDTokenVerificationResult {
        try ChatGPTOpenAIIDTokenVerifier.verify(
            token: token,
            jwks: jwks,
            clientID: syntheticClientID,
            nonce: syntheticNonce,
            now: now ?? validNow
        )
    }

    // 「何かthrowすればよい」ではなく、期待した理由で拒否されたことまで確認する。
    // 失敗メッセージにtokenやJWKSを含めない
    private func assertRejects(
        _ token: String,
        jwks: Data,
        now: Date? = nil,
        as expected: ChatGPTOpenAIIDTokenError,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try verify(token, jwks: jwks, now: now), label, file: file, line: line) { error in
            XCTAssertEqual(error as? ChatGPTOpenAIIDTokenError, expected, label, file: file, line: line)
        }
    }

    // 異常系と対になる正常系（前提の分離）の確認。失敗メッセージにtokenやJWKSを含めない
    private func assertAccepts(
        _ token: String,
        jwks: Data,
        now: Date? = nil,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNoThrow(try verify(token, jwks: jwks, now: now), label, file: file, line: line)
    }

    // MARK: - fixtureの前提

    func testSyntheticFixturesHaveExpectedShape() throws {
        XCTAssertNotEqual(syntheticNonce, otherNonce)
        XCTAssertNotEqual(syntheticClientID, otherClientID)
        XCTAssertNotEqual(trustedKeyID, untrustedKeyID)
        XCTAssertLessThan(validNow, expiresAt)

        // 合成したJWTが3セグメントで、header.payloadに対する署名が公開鍵で実際に通ることを確認する
        // （verifierと独立した、Securityだけによる確認）
        let (privateKey, _) = try makeTrustedFixture()
        let token = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(segments.count, 3)
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        let signature = try XCTUnwrap(base64URLDecode(String(segments[2])))
        XCTAssertTrue(SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signingInput as CFData,
            signature as CFData,
            nil
        ))
    }

    // MARK: - positive control

    func testAcceptsValidTokenAndReturnsOnlySubject() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        let token = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)

        let result = try verify(token, jwks: jwks)
        XCTAssertTrue(result.subject == syntheticSubject)
        // 結果を表示してもsubが漏れない
        XCTAssertFalse(String(describing: result).contains(syntheticSubject))
        XCTAssertFalse(String(reflecting: result).contains(syntheticSubject))
    }

    // MARK: - 署名と鍵

    func testRejectsTamperedSignature() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        let token = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)
        var segments = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var signature = try XCTUnwrap(base64URLDecode(segments[2]))
        // 署名の途中の1バイトを反転させる（長さと形式は正しいまま）
        signature[signature.count / 2] ^= 0xFF
        segments[2] = base64URL(signature)

        assertRejects(segments.joined(separator: "."), jwks: jwks, as: .invalidSignature, "tampered signature")
    }

    func testRejectsTamperedPayloadWithOriginalSignature() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        let token = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)
        var segments = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // claims自体は正しい値のまま別のsubに差し替え、署名は元のものを流用する
        var tampered = claims()
        tampered["sub"] = "synthetic-subject-tampered"
        segments[1] = try encodedSegment(tampered)

        assertRejects(segments.joined(separator: "."), jwks: jwks, as: .invalidSignature, "tampered payload")
    }

    func testRejectsTokenSignedByKeyNotInJWKS() throws {
        let (_, jwks) = try makeTrustedFixture()
        let untrustedKey = try makeKeyPair()
        let token = try signRS256(claims: claims(), keyID: untrustedKeyID, privateKey: untrustedKey)

        assertRejects(token, jwks: jwks, as: .untrustedKey, "unknown kid")
    }

    func testRejectsTokenSignedByOtherKeyUsingTrustedKeyID() throws {
        // kidだけ信頼する鍵のものを名乗っても、署名は信頼する鍵で検証されて通らない
        let (_, jwks) = try makeTrustedFixture()
        let otherKey = try makeKeyPair()
        let token = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: otherKey)

        assertRejects(token, jwks: jwks, as: .invalidSignature, "trusted kid with other key")
    }

    func testRejectsCanonicallyEquivalentButByteDifferentKeyID() throws {
        // kidの照合はJWT（RFC 7515 §4.1.4）上は大文字小文字も含めた完全一致。
        // Swiftの==は正規等価を同一視するので、バイト列が違うことを前提として確認しておく
        XCTAssertNotEqual(Array(precomposedIdentifier.utf8), Array(decomposedIdentifier.utf8))

        // 署名に使う鍵は同じ。違うのはheaderのkidとJWKのkidのコードポイントだけ
        let privateKey = try makeKeyPair()
        let jwks = try jwksData([try publicJWK(for: privateKey, keyID: decomposedIdentifier)])
        let token = try signRS256(claims: claims(), keyID: precomposedIdentifier, privateKey: privateKey)

        assertRejects(token, jwks: jwks, as: .untrustedKey, "canonically equivalent kid")
    }

    // MARK: - claims

    func testRejectsNonceMismatch() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        let token = try signRS256(claims: claims(nonce: otherNonce), keyID: trustedKeyID, privateKey: privateKey)

        assertRejects(token, jwks: jwks, as: .invalidNonce, "nonce mismatch")
    }

    func testRejectsAudienceMismatch() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        let token = try signRS256(claims: claims(audience: otherClientID), keyID: trustedKeyID, privateKey: privateKey)

        assertRejects(token, jwks: jwks, as: .invalidAudience, "audience mismatch")
    }

    func testRejectsCanonicallyEquivalentButByteDifferentAudience() throws {
        // audの照合はJWT（RFC 7519 §4.1.3, §7.3）上はコードポイントの完全一致。
        // Swiftの==は正規等価を同一視するので、バイト列が違うことを前提として確認しておく
        XCTAssertNotEqual(Array(precomposedIdentifier.utf8), Array(decomposedIdentifier.utf8))

        // 署名は正しい。違うのは署名されたaudと照合するclientIDのコードポイントだけ
        let (privateKey, jwks) = try makeTrustedFixture()
        let token = try signRS256(
            claims: claims(audience: precomposedIdentifier),
            keyID: trustedKeyID,
            privateKey: privateKey
        )

        // 共通のverify(_:jwks:)はclientIDが固定なので、ここでは直接呼んで照合側の値を差し替える
        XCTAssertThrowsError(
            try ChatGPTOpenAIIDTokenVerifier.verify(
                token: token,
                jwks: jwks,
                clientID: decomposedIdentifier,
                nonce: syntheticNonce,
                now: validNow
            ),
            "canonically equivalent audience"
        ) { error in
            XCTAssertEqual(error as? ChatGPTOpenAIIDTokenError, .invalidAudience, "canonically equivalent audience")
        }
    }

    func testRejectsExpiredToken() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        let token = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)
        // 時計のずれの許容幅に左右されないよう、expから十分に（1時間）過ぎた時刻で判定する
        let afterExpiry = expiresAt.addingTimeInterval(3600)

        assertRejects(token, jwks: jwks, now: afterExpiry, as: .expired, "expired")
    }

    // MARK: - algorithm confusion

    func testRejectsAlgNone() throws {
        let (_, jwks) = try makeTrustedFixture()
        let header: [String: Any] = ["alg": "none", "kid": trustedKeyID, "typ": "JWT"]
        // alg=noneは署名セグメントが空のunsecured JWT
        let token = try encodedSegment(header) + "." + encodedSegment(claims()) + "."

        assertRejects(token, jwks: jwks, as: .unsupportedAlgorithm, "alg none")
    }

    func testRejectsHS256SignedWithPublicKeyMaterial() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        // 典型的なalgorithm confusion: 公開鍵（誰でも知り得る値）をHMACの共有鍵として使う
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let publicDER = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let header: [String: Any] = ["alg": "HS256", "kid": trustedKeyID, "typ": "JWT"]
        let signingInput = try encodedSegment(header) + "." + encodedSegment(claims())
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8),
            using: SymmetricKey(data: publicDER)
        )
        let token = signingInput + "." + base64URL(Data(mac))

        assertRejects(token, jwks: jwks, as: .unsupportedAlgorithm, "alg HS256")
    }

    // MARK: - 検証の順序（署名より前にclaimsを判断しない）

    func testInvalidSignatureTakesPrecedenceOverInvalidIssuer() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        var wrongIssuer = claims()
        wrongIssuer["iss"] = "https://synthetic-issuer.invalid"

        // 前提: 正しく署名すれば、このclaimsはissの不一致だけで拒否される
        let validlySigned = try signRS256(claims: wrongIssuer, keyID: trustedKeyID, privateKey: privateKey)
        assertRejects(validlySigned, jwks: jwks, as: .invalidIssuer, "control: signed wrong issuer")

        // a. 同じclaimsを、信頼するkidを名乗った別の鍵で署名する
        let otherKey = try makeKeyPair()
        let signedByOtherKey = try signRS256(claims: wrongIssuer, keyID: trustedKeyID, privateKey: otherKey)
        assertRejects(signedByOtherKey, jwks: jwks, as: .invalidSignature, "other key + wrong issuer")

        // b. 正しい署名の1バイトを反転させる
        var segments = validlySigned.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var signature = try XCTUnwrap(base64URLDecode(segments[2]))
        signature[signature.count / 2] ^= 0xFF
        segments[2] = base64URL(signature)
        assertRejects(segments.joined(separator: "."), jwks: jwks, as: .invalidSignature, "tampered signature + wrong issuer")

        // c. 正しいclaimsの署名を流用し、payloadだけをissが不正なものに差し替える
        let validToken = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)
        var swapped = validToken.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        swapped[1] = try encodedSegment(wrongIssuer)
        assertRejects(swapped.joined(separator: "."), jwks: jwks, as: .invalidSignature, "swapped payload + wrong issuer")
    }

    // MARK: - JWKSの鍵の用途・重複・秘密要素

    func testRejectsJWKWithKeyOperationsOtherThanVerify() throws {
        let privateKey = try makeKeyPair()
        let token = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)

        // 前提: key_ops=[verify]だけなら受け付ける（key_opsがあること自体は拒否理由ではない）
        var verifyOnly = try publicJWK(for: privateKey, keyID: trustedKeyID)
        verifyOnly["key_ops"] = ["verify"]
        assertAccepts(token, jwks: try jwksData([verifyOnly]), "control: key_ops verify")

        var withSign = try publicJWK(for: privateKey, keyID: trustedKeyID)
        withSign["key_ops"] = ["verify", "sign"]
        assertRejects(token, jwks: try jwksData([withSign]), as: .untrustedKey, "key_ops verify + sign")
    }

    func testRejectsJWKForEncryptionUse() throws {
        let privateKey = try makeKeyPair()
        let token = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)
        // 前提: use=sigのままなら受け付ける
        assertAccepts(token, jwks: try jwksData([try publicJWK(for: privateKey, keyID: trustedKeyID)]), "control: use sig")

        var encryption = try publicJWK(for: privateKey, keyID: trustedKeyID)
        encryption["use"] = "enc"
        assertRejects(token, jwks: try jwksData([encryption]), as: .untrustedKey, "use enc")
    }

    func testRejectsJWKSWithDuplicateKeyID() throws {
        let privateKey = try makeKeyPair()
        let token = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)
        let signingJWK = try publicJWK(for: privateKey, keyID: trustedKeyID)
        // 前提: 署名した鍵1件だけなら受け付ける
        assertAccepts(token, jwks: try jwksData([signingJWK]), "control: single key")

        // 同じ鍵が同じkidで2件
        assertRejects(token, jwks: try jwksData([signingJWK, signingJWK]), as: .untrustedKey, "same key twice")
        // 別の鍵が同じkidを名乗っている
        let otherJWK = try publicJWK(for: try makeKeyPair(), keyID: trustedKeyID)
        assertRejects(token, jwks: try jwksData([signingJWK, otherJWK]), as: .untrustedKey, "other key with same kid")
    }

    func testRejectsJWKSContainingPrivateKeyMember() throws {
        let privateKey = try makeKeyPair()
        let token = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)
        let signingJWK = try publicJWK(for: privateKey, keyID: trustedKeyID)
        let otherJWK = try publicJWK(for: try makeKeyPair(), keyID: untrustedKeyID)
        // 前提: 秘密要素が無ければ、無関係な鍵が並んでいても受け付ける
        assertAccepts(token, jwks: try jwksData([signingJWK, otherJWK]), "control: public keys only")

        // dの値は合成の固定値。verifierはメンバー名だけで拒否する
        let syntheticPrivateExponent = base64URL(Data("synthetic-private-exponent".utf8))

        var signingWithD = signingJWK
        signingWithD["d"] = syntheticPrivateExponent
        assertRejects(token, jwks: try jwksData([signingWithD]), as: .untrustedKey, "d in signing key")

        // 照合しない別の鍵に混ざっていても、JWKS全体を信頼しない
        var otherWithD = otherJWK
        otherWithD["d"] = syntheticPrivateExponent
        assertRejects(token, jwks: try jwksData([signingJWK, otherWithD]), as: .untrustedKey, "d in other key")
    }

    func testRejectsRSAKeyBelowMinimumModulusBits() throws {
        // 前提: 通常のfixtureは2048 bitで、受け付けられる
        let (privateKey, jwks) = try makeTrustedFixture()
        let trustedJWK = try publicJWK(for: privateKey, keyID: trustedKeyID)
        XCTAssertEqual(try modulusBits(trustedJWK), 2048)
        let validToken = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)
        assertAccepts(validToken, jwks: jwks, "control: 2048 bit")

        // Securityが1024 bitの鍵を作れない環境では、このケースだけskipする
        let weakKey: SecKey
        do {
            weakKey = try makeKeyPair(bits: 1024)
        } catch {
            throw XCTSkip("Security could not generate a 1024-bit RSA key")
        }
        let weakJWK = try publicJWK(for: weakKey, keyID: trustedKeyID)
        XCTAssertEqual(try modulusBits(weakJWK), 1024)
        let weakToken = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: weakKey)
        assertRejects(weakToken, jwks: try jwksData([weakJWK]), as: .untrustedKey, "1024 bit key")
    }

    // MARK: - header

    func testRejectsMissingKeyID() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        // kidが無いこと以外は正しい（署名もJWKSの鍵で行う）
        let token = try signRS256(claims: claims(), keyID: nil, privateKey: privateKey)

        assertRejects(token, jwks: jwks, as: .untrustedKey, "missing kid")
    }

    func testRejectsCriticalHeader() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        let token = try signRS256(
            claims: claims(),
            keyID: trustedKeyID,
            privateKey: privateKey,
            extraHeader: ["crit": ["exp"]]
        )

        assertRejects(token, jwks: jwks, as: .malformedToken, "crit header")
    }

    // MARK: - claimsの追加ケース（すべて正しく署名する）

    func testRejectsIssuerMismatch() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        let issuers = [
            "https://synthetic-issuer.invalid",
            // 末尾の/だけ違う
            "https://auth.openai.com/",
            // 大文字小文字だけ違う
            "https://Auth.OpenAI.com",
        ]
        for wrongIssuer in issuers {
            var mismatched = claims()
            mismatched["iss"] = wrongIssuer
            let token = try signRS256(claims: mismatched, keyID: trustedKeyID, privateKey: privateKey)
            assertRejects(token, jwks: jwks, as: .invalidIssuer, "issuer \(wrongIssuer)")
        }
    }

    func testRejectsBooleanIssuedAt() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        // JSONSerializationではtrueもNSNumberになるが、NumericDateとしては扱わない
        var booleanIssuedAt = claims()
        booleanIssuedAt["iat"] = true
        let token = try signRS256(claims: booleanIssuedAt, keyID: trustedKeyID, privateKey: privateKey)

        assertRejects(token, jwks: jwks, as: .invalidClaims, "iat true")
    }

    func testRejectsNumericDateClaimsWithInvalidType() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        // 前提: nbfが正しい数値なら受け付ける
        var validNotBefore = claims()
        validNotBefore["nbf"] = Int(issuedAt.timeIntervalSince1970)
        let validToken = try signRS256(claims: validNotBefore, keyID: trustedKeyID, privateKey: privateKey)
        assertAccepts(validToken, jwks: jwks, "control: numeric nbf")

        let invalidValues: [(label: String, value: Any)] = [
            ("string", String(Int(issuedAt.timeIntervalSince1970))),
            ("boolean", true),
            ("negative", -1),
            ("array", [Int(issuedAt.timeIntervalSince1970)]),
        ]
        for claimName in ["exp", "iat", "nbf"] {
            for invalid in invalidValues {
                var modified = claims()
                modified[claimName] = invalid.value
                let token = try signRS256(claims: modified, keyID: trustedKeyID, privateKey: privateKey)
                assertRejects(token, jwks: jwks, as: .invalidClaims, "\(claimName) as \(invalid.label)")
            }
        }
    }

    func testRejectsAuthorizedPartyNotMatchingClientID() throws {
        let (privateKey, jwks) = try makeTrustedFixture()

        // 前提: azpが自分のclient_idなら、audが単数でも複数でも受け付ける
        var singleMatching = claims()
        singleMatching["azp"] = syntheticClientID
        assertAccepts(
            try signRS256(claims: singleMatching, keyID: trustedKeyID, privateKey: privateKey),
            jwks: jwks,
            "control: azp matches single aud"
        )
        var multipleMatching = claims()
        multipleMatching["aud"] = [syntheticClientID, otherClientID]
        multipleMatching["azp"] = syntheticClientID
        assertAccepts(
            try signRS256(claims: multipleMatching, keyID: trustedKeyID, privateKey: privateKey),
            jwks: jwks,
            "control: azp matches multiple aud"
        )

        // audには自分が含まれるが、azpはaudに無い別のclient
        var notInAudience = claims()
        notInAudience["azp"] = "unlisted-synthetic-client"
        assertRejects(
            try signRS256(claims: notInAudience, keyID: trustedKeyID, privateKey: privateKey),
            jwks: jwks,
            as: .invalidAudience,
            "azp not in aud"
        )
        // azpはaudに含まれる別のclient（自分ではない）
        var otherInAudience = claims()
        otherInAudience["aud"] = [syntheticClientID, otherClientID]
        otherInAudience["azp"] = otherClientID
        assertRejects(
            try signRS256(claims: otherInAudience, keyID: trustedKeyID, privateKey: privateKey),
            jwks: jwks,
            as: .invalidAudience,
            "azp is other aud"
        )
    }

    func testRejectsNotBeforeInFuture() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        var future = claims()
        // 時計のずれの許容幅に左右されないよう、nowから1時間後にする
        future["nbf"] = Int(validNow.timeIntervalSince1970) + 3600
        let token = try signRS256(claims: future, keyID: trustedKeyID, privateKey: privateKey)

        assertRejects(token, jwks: jwks, as: .invalidIssuedAt, "nbf in future")
    }

    // MARK: - sub（OIDC Core §2: ASCIIで最大255文字）
    // どのケースも、正しい鍵で署名し、sub以外のclaimsは正常な値のままにする

    // subだけを差し替えて正しく署名したtoken
    private func signedToken(subject: String, privateKey: SecKey) throws -> String {
        var modified = claims()
        modified["sub"] = subject
        return try signRS256(claims: modified, keyID: trustedKeyID, privateKey: privateKey)
    }

    // コード値から1文字の文字列を作る（制御文字などをソース上のescape表記に頼らず用意する）
    private func scalarString(_ value: UInt32) throws -> String {
        String(Character(try XCTUnwrap(Unicode.Scalar(value))))
    }

    // positive control: 既存の正常なASCIIのsubなら、同じ鍵・JWKS・時刻で受け付けてsubを返す
    private func assertAcceptsASCIISubjectControl(
        privateKey: SecKey,
        jwks: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(syntheticSubject.utf8.allSatisfy { (0x21...0x7E).contains($0) }, file: file, line: line)
        let result = try verify(try signedToken(subject: syntheticSubject, privateKey: privateKey), jwks: jwks)
        XCTAssertTrue(result.subject == syntheticSubject, "control: ASCII sub", file: file, line: line)
    }

    func testRejectsNonASCIISubjectInNFCAndNFD() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        try assertAcceptsASCIISubjectControl(privateKey: privateKey, jwks: jwks)

        // 前提: NFC（合成済みのé）とNFD（e + 結合アクセント）で、正規等価だがバイト列は異なり、
        // どちらも非ASCIIを含み、長さはUTF-8で255バイト以内（長さの上限では拒否されない）
        let nfc = precomposedIdentifier
        let nfd = decomposedIdentifier
        XCTAssertEqual(nfc.precomposedStringWithCanonicalMapping, nfc)
        XCTAssertEqual(nfd.decomposedStringWithCanonicalMapping, nfd)
        XCTAssertEqual(nfd.precomposedStringWithCanonicalMapping, nfc)
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))

        for (subject, label) in [(nfc, "NFC"), (nfd, "NFD")] {
            XCTAssertFalse(subject.utf8.allSatisfy { $0 < 0x80 }, "\(label): 非ASCIIを含む")
            XCTAssertLessThanOrEqual(subject.utf8.count, 255, "\(label): 長さの上限以内")
            let token = try signedToken(subject: subject, privateKey: privateKey)
            assertRejects(token, jwks: jwks, as: .invalidClaims, "non-ASCII sub (\(label))")
        }
    }

    func testRejectsSubjectWithControlCharacters() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        try assertAcceptsASCIISubjectControl(privateKey: privateKey, jwks: jwks)

        // ASCIIの制御文字（0x00-0x1F, 0x7F）。JSONSerializationが必要に応じてescapeして署名する
        let controls: [(value: UInt32, label: String)] = [
            (0x00, "NUL"),
            (0x09, "TAB"),
            (0x0A, "LF"),
            (0x0D, "CR"),
            (0x1B, "ESC"),
            (0x1F, "US"),
            (0x7F, "DEL"),
        ]
        for (value, label) in controls {
            let control = try scalarString(value)
            let positions: [(subject: String, position: String)] = [
                ("synthetic-subject" + control + "0123", "middle"),
                (control + "synthetic-subject", "leading"),
                ("synthetic-subject" + control, "trailing"),
            ]
            for (subject, position) in positions {
                // 前提: 制御文字以外は正常なASCIIで、長さも上限以内
                XCTAssertLessThanOrEqual(subject.utf8.count, 255)
                let token = try signedToken(subject: subject, privateKey: privateKey)
                assertRejects(token, jwks: jwks, as: .invalidClaims, "sub with \(label) (\(position))")
            }
        }
        // 制御文字だけのsub
        assertRejects(
            try signedToken(subject: try scalarString(0x00), privateKey: privateKey),
            jwks: jwks,
            as: .invalidClaims,
            "sub is only NUL"
        )
    }

    func testSubjectLengthBoundary() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        try assertAcceptsASCIISubjectControl(privateKey: privateKey, jwks: jwks)

        // ASCIIで255文字ちょうどは受け付け、そのまま返す
        let atLimit = String(repeating: "s", count: 255)
        let result = try verify(try signedToken(subject: atLimit, privateKey: privateKey), jwks: jwks)
        XCTAssertTrue(result.subject == atLimit, "sub at 255 chars")

        // 256文字以上は拒否する。tokenの長さの上限（16 KiB）より十分短いので、sub自体の上限で拒否される
        for length in [256, 1024, 4096] {
            let subject = String(repeating: "s", count: length)
            let token = try signedToken(subject: subject, privateKey: privateKey)
            XCTAssertLessThan(token.utf8.count, 16 * 1024)
            assertRejects(token, jwks: jwks, as: .invalidClaims, "sub of \(length) chars")
        }
    }

    // MARK: - 日付の境界（現在の実装の許容幅は5秒）

    func testExpirationBoundary() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        let token = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)

        // now < exp + 5 の間だけ有効
        assertAccepts(token, jwks: jwks, now: expiresAt.addingTimeInterval(4), "exp + 4s")
        assertRejects(token, jwks: jwks, now: expiresAt.addingTimeInterval(5), as: .expired, "exp + 5s")
    }

    func testIssuedAtBoundary() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        let token = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)

        // iat <= now + 5 なら有効（未来の発行は5秒まで許す）
        assertAccepts(token, jwks: jwks, now: issuedAt.addingTimeInterval(-5), "now = iat - 5s")
        assertRejects(token, jwks: jwks, now: issuedAt.addingTimeInterval(-6), as: .invalidIssuedAt, "now = iat - 6s")
    }

    func testIssuedAtAfterExpirationBoundary() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        let expiration = Int(expiresAt.timeIntervalSince1970)

        // iat == exp は有効、iat > exp は無効。nowはexpちょうどにして他の条件を満たしておく
        var sameAsExpiration = claims()
        sameAsExpiration["iat"] = expiration
        let sameToken = try signRS256(claims: sameAsExpiration, keyID: trustedKeyID, privateKey: privateKey)
        assertAccepts(sameToken, jwks: jwks, now: expiresAt, "iat = exp")

        var afterExpiration = claims()
        afterExpiration["iat"] = expiration + 1
        let afterToken = try signRS256(claims: afterExpiration, keyID: trustedKeyID, privateKey: privateKey)
        assertRejects(afterToken, jwks: jwks, now: expiresAt, as: .invalidIssuedAt, "iat = exp + 1s")
    }

    func testNotBeforeBoundary() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        let current = Int(validNow.timeIntervalSince1970)

        // now + 5 >= nbf なら有効
        var withinSkew = claims()
        withinSkew["nbf"] = current + 5
        let withinToken = try signRS256(claims: withinSkew, keyID: trustedKeyID, privateKey: privateKey)
        assertAccepts(withinToken, jwks: jwks, "nbf = now + 5s")

        var beyondSkew = claims()
        beyondSkew["nbf"] = current + 6
        let beyondToken = try signRS256(claims: beyondSkew, keyID: trustedKeyID, privateKey: privateKey)
        assertRejects(beyondToken, jwks: jwks, as: .invalidIssuedAt, "nbf = now + 6s")
    }

    // MARK: - 入力サイズの上限

    func testTokenLengthLimit() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        // 現在の実装の上限は16 KiB（UTF-8のバイト数）
        let limit = 16 * 1024

        let atLimit = try signedToken(exactLength: limit, privateKey: privateKey)
        XCTAssertEqual(atLimit.utf8.count, limit)
        assertAccepts(atLimit, jwks: jwks, "token at limit")

        let overLimit = try signedToken(exactLength: limit + 1, privateKey: privateKey)
        XCTAssertEqual(overLimit.utf8.count, limit + 1)
        assertRejects(overLimit, jwks: jwks, as: .malformedToken, "token over limit")
    }

    func testJWKSLengthLimit() throws {
        let privateKey = try makeKeyPair()
        let token = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)
        // 現在の実装の上限は64 KiB
        let limit = 64 * 1024

        let atLimit = try jwksData(exactLength: limit, privateKey: privateKey)
        XCTAssertEqual(atLimit.count, limit)
        assertAccepts(token, jwks: atLimit, "jwks at limit")

        let overLimit = try jwksData(exactLength: limit + 1, privateKey: privateKey)
        XCTAssertEqual(overLimit.count, limit + 1)
        assertRejects(token, jwks: overLimit, as: .untrustedKey, "jwks over limit")
    }

    // MARK: - 結果の表示

    func testDumpDoesNotRevealSubject() throws {
        let (privateKey, jwks) = try makeTrustedFixture()
        let token = try signRS256(claims: claims(), keyID: trustedKeyID, privateKey: privateKey)
        let result = try verify(token, jwks: jwks)
        // 前提: 値そのものは保持している
        XCTAssertTrue(result.subject == syntheticSubject)

        var dumped = ""
        dump(result, to: &dumped)
        XCTAssertFalse(dumped.contains(syntheticSubject))
        XCTAssertFalse(Mirror(reflecting: result).children.contains { child in
            String(describing: child.value).contains(syntheticSubject)
        })
    }

    // MARK: - base64url・DERの補助（テスト専用）

    private enum FixtureError: Error {
        case keyGenerationFailed
        case publicKeyExportFailed
        case signingFailed
        case malformedDER
        case lengthNotReachable
    }

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

    // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER } を読む。
    // JWKのn・eは符号なしの値なので、DER INTEGERの先頭に付く0x00は取り除く
    private func parsePKCS1RSAPublicKey(_ der: Data) throws -> (modulus: Data, exponent: Data) {
        let bytes = [UInt8](der)
        var index = 0
        let sequence = try readTLV(bytes, at: &index, expectedTag: 0x30)
        guard sequence.upperBound == bytes.count else { throw FixtureError.malformedDER }
        index = sequence.lowerBound
        let modulus = try readTLV(bytes, at: &index, expectedTag: 0x02)
        index = modulus.upperBound
        let exponent = try readTLV(bytes, at: &index, expectedTag: 0x02)
        guard exponent.upperBound == sequence.upperBound else { throw FixtureError.malformedDER }
        return (stripLeadingZeros(bytes[modulus]), stripLeadingZeros(bytes[exponent]))
    }

    // tagとlengthを読み、中身（value）の範囲を返す。indexはvalueの先頭に進める
    private func readTLV(_ bytes: [UInt8], at index: inout Int, expectedTag: UInt8) throws -> Range<Int> {
        guard index < bytes.count, bytes[index] == expectedTag else { throw FixtureError.malformedDER }
        index += 1
        guard index < bytes.count else { throw FixtureError.malformedDER }
        var length = Int(bytes[index])
        index += 1
        // 0x80以上は長形式。下位7bitが後続の長さバイト数
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), index + count <= bytes.count else { throw FixtureError.malformedDER }
            length = bytes[index..<(index + count)].reduce(0) { $0 << 8 | Int($1) }
            index += count
        }
        guard index + length <= bytes.count else { throw FixtureError.malformedDER }
        return index..<(index + length)
    }

    private func stripLeadingZeros(_ bytes: ArraySlice<UInt8>) -> Data {
        Data(bytes.drop { $0 == 0 })
    }
}
