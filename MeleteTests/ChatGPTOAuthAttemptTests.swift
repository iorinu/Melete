import XCTest
@testable import Melete

// ChatGPT OAuth初回登録の「1回の認可試行」の境界だけを検証する（テストファーストのRED）。
// ネットワーク・listener・ブラウザ・Keychain・保存・UIには一切触れない。
// 値はすべてテスト専用の合成固定値で、時刻は固定のモック時計だけを使う。
// 判定順: 消費済み → キャンセル済み → 期限 → state照合 → （消費） → 残りのcallback検証 → token request構築
// stateの一意一致を確認できない応答（構文エラーを含む）は試行を保ち、state一致後の失敗・時計の異常は消費する
@MainActor
final class ChatGPTOAuthAttemptTests: XCTestCase {
    // 合成の固定値（実際の認証には使われない）。それぞれ43文字のunreserved文字
    private let syntheticState = "SyntheticAttemptState0123456789-_abcdefghij"
    private let syntheticNonce = "SyntheticAttemptNonce0123456789-_klmnopqrst"
    private let syntheticVerifier = "SyntheticAttemptVerifier0123456789-._~abcde"
    // 別の試行用の合成固定値
    private let otherState = "OtherAttemptState0123456789-_abcdefghijklmn"
    private let otherNonce = "OtherAttemptNonce0123456789-_opqrstuvwxyzab"
    private let otherVerifier = "OtherAttemptVerifier0123456789-._~abcdefghi"

    private let syntheticHostID = "urn:uuid:11111111-2222-4333-8444-555555555555"
    private let syntheticRedirect = "http://127.0.0.1:49152/auth/callback"
    private let syntheticCode = "SyntheticAttemptCode0123456789"
    private let otherCode = "OtherSyntheticAttemptCode0123456789"
    private let syntheticClientID = "synthetic_issued_client_attempt_0123"

    private let lifetime: TimeInterval = 300
    // 固定の開始時刻（実時刻は使わない）
    private let startDate = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - fixture

    // テスト中に手で進めるだけの時計
    private final class MockClock {
        var current: Date
        init(_ start: Date) { current = start }
        func advance(by seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
    }

    // テスト中に手で進めるだけの単調時計（起動からの経過秒を模す。実際のuptimeは使わない）
    private final class MockUptime {
        var current: TimeInterval
        init(_ start: TimeInterval) { current = start }
        func advance(by seconds: TimeInterval) { current += seconds }
    }

    // makeSecretsが何回呼ばれたかを数える（乱数の取得が1回だけであることの確認用）
    private final class Counter {
        var value = 0
    }

    private func secrets(state: String, nonce: String, verifier: String) -> ChatGPTOAuthAuthorizationSecrets {
        ChatGPTOAuthAuthorizationSecrets(state: state, nonce: nonce, codeVerifier: verifier)
    }

    private var syntheticSecrets: ChatGPTOAuthAuthorizationSecrets {
        secrets(state: syntheticState, nonce: syntheticNonce, verifier: syntheticVerifier)
    }

    private var otherSecrets: ChatGPTOAuthAuthorizationSecrets {
        secrets(state: otherState, nonce: otherNonce, verifier: otherVerifier)
    }

    private func makeAttempt(
        secrets: ChatGPTOAuthAuthorizationSecrets? = nil,
        clock: MockClock,
        lifetime: TimeInterval? = nil,
        counter: Counter? = nil
    ) throws -> ChatGPTOAuthAttempt {
        let fixed = secrets ?? syntheticSecrets
        let builder = ChatGPTOAuthAuthorizationRequestBuilder(makeSecrets: {
            counter?.value += 1
            return fixed
        })
        return try ChatGPTOAuthAttempt(
            agentHostID: syntheticHostID,
            redirectURI: URL(string: syntheticRedirect)!,
            lifetime: lifetime ?? self.lifetime,
            authorizationBuilder: builder,
            now: { clock.current }
        )
    }

    // 値はすべてunreserved文字なので、percent-encodingなしでqueryに並べられる
    private func callbackURL(
        state: String? = nil,
        code: String? = nil,
        clientID: String? = nil,
        error: String? = nil,
        includeCode: Bool = true,
        includeClientID: Bool = true
    ) -> String {
        var items: [String] = []
        if includeCode { items.append("code=\(code ?? syntheticCode)") }
        items.append("state=\(state ?? syntheticState)")
        if includeClientID { items.append("client_id=\(clientID ?? syntheticClientID)") }
        if let error { items.append("error=\(error)") }
        return "\(syntheticRedirect)?\(items.joined(separator: "&"))"
    }

    // 既存の純粋なbuilderを独立に呼び、期待するtoken requestを作る（attemptを経由しない）
    private func expectedTokenRequest(
        secrets: ChatGPTOAuthAuthorizationSecrets? = nil,
        code: String? = nil
    ) throws -> ChatGPTOAuthTokenRequest {
        let fixed = secrets ?? syntheticSecrets
        let authorization = try ChatGPTOAuthAuthorizationRequestBuilder(makeSecrets: { fixed })
            .build(agentHostID: syntheticHostID, redirectURI: URL(string: syntheticRedirect)!)
        return try ChatGPTOAuthTokenRequestBuilder.build(
            authorization: authorization,
            callback: ChatGPTOAuthCallbackResult(code: code ?? syntheticCode, clientID: syntheticClientID)
        )
    }

    private func assertSameRequest(
        _ actual: ChatGPTOAuthTokenRequest,
        _ expected: ChatGPTOAuthTokenRequest,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.url, expected.url, label, file: file, line: line)
        XCTAssertEqual(actual.method, expected.method, label, file: file, line: line)
        XCTAssertEqual(actual.headers, expected.headers, label, file: file, line: line)
        XCTAssertEqual(actual.body, expected.body, label, file: file, line: line)
    }

    // 「何かthrowすればよい」ではなく、期待した理由で拒否されたことまで確認する
    private func assertRejects(
        _ attempt: ChatGPTOAuthAttempt,
        _ callback: String,
        as expected: ChatGPTOAuthAttemptError,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try attempt.consumeCallback(callback), label, file: file, line: line) { error in
            XCTAssertEqual(error as? ChatGPTOAuthAttemptError, expected, label, file: file, line: line)
        }
    }

    // print・dump・デバッガ表示で出る文字列をまとめて返す
    private func renderedForms(of value: Any) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), dumped]
    }

    private var secretValues: [String] {
        [syntheticState, syntheticNonce, syntheticVerifier, syntheticCode, syntheticClientID]
    }

    // MARK: - fixtureの前提

    func testSyntheticRandomValuesAre43Characters() {
        for value in [syntheticState, syntheticNonce, syntheticVerifier, otherState, otherNonce, otherVerifier] {
            XCTAssertEqual(value.count, 43, "合成値の長さがfixtureの前提と違う")
        }
    }

    func testExpectedTokenRequestFixtureCanBeBuilt() throws {
        // 期待値側の組み立て自体が壊れていないこと（attemptのREDと区別するため）
        XCTAssertNoThrow(try expectedTokenRequest())
        XCTAssertNoThrow(try expectedTokenRequest(secrets: otherSecrets))
    }

    // MARK: - 試行の生成

    func testAttemptFetchesSecretsExactlyOnceAndExposesMatchingAuthorizationURL() throws {
        let clock = MockClock(startDate)
        let counter = Counter()
        let attempt = try makeAttempt(clock: clock, counter: counter)
        XCTAssertEqual(counter.value, 1, "試行の生成で乱数を1回だけ取得する")

        let fixed = syntheticSecrets
        let expectedURL = try ChatGPTOAuthAuthorizationRequestBuilder(makeSecrets: { fixed })
            .build(agentHostID: syntheticHostID, redirectURI: URL(string: syntheticRedirect)!)
            .authorizationURL
        XCTAssertEqual(attempt.authorizationURL, expectedURL)

        // callbackを処理しても乱数を取り直さない
        _ = try? attempt.consumeCallback(callbackURL())
        _ = try? attempt.consumeCallback(callbackURL())
        XCTAssertEqual(counter.value, 1, "callback処理で乱数を取り直してはいけない")
    }

    func testInvalidLifetimeIsRejected() {
        let clock = MockClock(startDate)
        for invalid in [0, -1, TimeInterval.nan, TimeInterval.infinity] {
            XCTAssertThrowsError(try makeAttempt(clock: clock, lifetime: invalid), "lifetime=\(invalid)") { error in
                XCTAssertEqual(error as? ChatGPTOAuthAttemptError, .invalidLifetime, "lifetime=\(invalid)")
            }
        }
    }

    // 乱数の取得元が想定外の型のエラー（中身に秘密値を含みうる）を投げても、
    // 固定値の .unexpectedFailure へ置き換え、元のエラーの中身をどの表示経路にも出さない
    func testSecretSourceFailureIsReplacedWithUnexpectedFailureWithoutLeakingMarker() {
        // 合成の目印（実際の秘密値ではない）。漏れたかどうかの検出だけに使う
        let marker = "SyntheticSecretSourceMarker0123456789"
        let builder = ChatGPTOAuthAuthorizationRequestBuilder(makeSecrets: {
            throw NSError(
                domain: "MeleteTests.Synthetic.\(marker)",
                code: 4242,
                userInfo: [
                    NSLocalizedDescriptionKey: "synthetic description \(marker)",
                    NSLocalizedFailureReasonErrorKey: "synthetic reason \(marker)",
                    NSDebugDescriptionErrorKey: "synthetic debug \(marker)",
                    "SyntheticCustomKey": marker,
                ]
            )
        })

        let start = startDate
        XCTAssertThrowsError(
            try ChatGPTOAuthAttempt(
                agentHostID: syntheticHostID,
                redirectURI: URL(string: syntheticRedirect)!,
                lifetime: lifetime,
                authorizationBuilder: builder,
                now: { start }
            )
        ) { error in
            XCTAssertEqual(error as? ChatGPTOAuthAttemptError, .unexpectedFailure, "想定外のエラーは固定値へ置き換える")

            // Swiftのエラーは NSError へブリッジされてログやUIに渡ることがあるため、その経路も確認する
            let nsError = error as NSError
            var rendered = renderedForms(of: error) + renderedForms(of: nsError)
            rendered += [
                error.localizedDescription,
                nsError.localizedDescription,
                nsError.domain,
                String(describing: nsError.userInfo),
                nsError.localizedFailureReason ?? "",
                nsError.debugDescription,
            ]
            for text in rendered {
                XCTAssertFalse(text.contains(marker), "元のエラーの中身が表示に含まれている")
            }
        }
    }

    // MARK: - positive control

    func testValidCallbackProducesExactlyTheExpectedTokenRequest() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)
        let request = try attempt.consumeCallback(callbackURL())
        assertSameRequest(request, try expectedTokenRequest(), "正しいcallbackから期待どおりのtoken requestを1つ作る")
    }

    func testValidCallbackJustBeforeExpiryIsAccepted() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)
        clock.advance(by: lifetime - 1)
        let request = try attempt.consumeCallback(callbackURL())
        assertSameRequest(request, try expectedTokenRequest(), "期限の1秒前はまだ有効")
    }

    // MARK: - 一度だけの消費

    func testSecondCallbackIsRejectedAfterSuccess() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)
        _ = try attempt.consumeCallback(callbackURL())

        assertRejects(attempt, callbackURL(), as: .alreadyConsumed, "同じcallbackの再送")
        assertRejects(attempt, callbackURL(code: otherCode), as: .alreadyConsumed, "別codeの2通目")
    }

    // MARK: - state照合とOAuth error

    func testStateMismatchIsRejected() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)
        assertRejects(attempt, callbackURL(state: otherState), as: .callbackRejected(.invalidState), "state不一致")
    }

    func testStateMismatchKeepsAttemptPendingForValidCallback() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)
        assertRejects(attempt, callbackURL(state: otherState), as: .callbackRejected(.invalidState), "state不一致")

        let request = try attempt.consumeCallback(callbackURL())
        assertSameRequest(request, try expectedTokenRequest(), "不正stateの後に正当callbackを受け付ける")
    }

    func testOAuthErrorResponseIsRejected() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)
        assertRejects(
            attempt,
            callbackURL(error: "access_denied", includeCode: false, includeClientID: false),
            as: .callbackRejected(.authorizationFailed),
            "OAuthのerror応答"
        )
    }

    func testOAuthErrorTerminatesAttempt() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)
        assertRejects(
            attempt,
            callbackURL(error: "access_denied", includeCode: false, includeClientID: false),
            as: .callbackRejected(.authorizationFailed),
            "最初の認可拒否"
        )
        assertRejects(attempt, callbackURL(), as: .alreadyConsumed, "認可拒否後の正しいcallback")
    }

    // state照合前に見つかった構文エラーは、stateが正しく見えても一致を確認できないため試行を消費しない
    func testSyntaxErrorBeforeStateConfirmationKeepsAttemptPending() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)
        let cases: [(String, String)] = [
            ("\(syntheticRedirect)?state=\(syntheticState)&&code=\(syntheticCode)&client_id=\(syntheticClientID)", "空セグメント"),
            (callbackURL() + "&x_synthetic=%FF", "未知keyの不正なUTF-8"),
            (callbackURL() + "#fragment", "fragment付き"),
        ]
        for (malformed, label) in cases {
            assertRejects(attempt, malformed, as: .callbackRejected(.malformedCallback), label)
        }

        let request = try attempt.consumeCallback(callbackURL())
        assertSameRequest(request, try expectedTokenRequest(), "構文エラーの後に正当callbackを受け付ける")
    }

    // stateの欠落・重複・不一致は、scope重複などの構造エラーと組み合わさっていても試行を消費しない
    func testUnconfirmedStateKeepsAttemptPendingEvenWithDuplicatedScope() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)
        let duplicatedScope = "&scope=openid&scope=profile"
        let base = "\(syntheticRedirect)?code=\(syntheticCode)&client_id=\(syntheticClientID)"
        let cases: [(String, String)] = [
            (base, "state欠落"),
            ("\(base)&state=\(syntheticState)&state=\(syntheticState)", "state重複（同じ値）"),
            ("\(base)&state=\(syntheticState)&state=\(otherState)", "state重複（異なる値）"),
            ("\(base)&state=\(syntheticState)&%73tate=\(otherState)", "encodeされたkeyによるstate重複"),
            ("\(base)&state=", "空のstate"),
            (callbackURL(state: otherState), "state不一致"),
            (callbackURL(state: otherState) + duplicatedScope, "state不一致 + scope重複"),
            (base + duplicatedScope, "state欠落 + scope重複"),
            ("\(base)&state=\(syntheticState)&state=\(syntheticState)" + duplicatedScope, "state重複 + scope重複"),
            (callbackURL(state: otherState) + "&error_description=a", "state不一致 + errorの無いerror_description"),
        ]
        for (callback, label) in cases {
            assertRejects(attempt, callback, as: .callbackRejected(.invalidState), label)
        }

        let request = try attempt.consumeCallback(callbackURL())
        assertSameRequest(request, try expectedTokenRequest(), "state未確認の応答の後に正当callbackを受け付ける")
    }

    // 正しいstateを持つ応答は、悪意あるscope重複で拒否されても試行を消費する（fail closed）
    func testMatchingStateWithDuplicatedScopeTerminatesAttempt() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)
        assertRejects(
            attempt,
            callbackURL() + "&scope=openid&scope=profile",
            as: .callbackRejected(.malformedCallback),
            "正しいstate + scope重複"
        )
        assertRejects(attempt, callbackURL(), as: .alreadyConsumed, "scope重複で消費された後の正当callback")
    }

    func testOAuthErrorWithCodeIsRejected() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)
        assertRejects(
            attempt,
            callbackURL(error: "access_denied"),
            as: .callbackRejected(.conflictingParameters),
            "errorとcodeの併存"
        )
    }

    // MARK: - 期限とキャンセル

    func testCallbackAtExpiryIsRejected() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)
        // 期限ちょうどは失効扱い（now >= 開始時刻 + lifetime）
        clock.advance(by: lifetime)
        assertRejects(attempt, callbackURL(), as: .expired, "期限ちょうど")
        clock.advance(by: 1)
        assertRejects(attempt, callbackURL(), as: .expired, "期限後")
    }

    func testClockRollbackFailsClosed() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)
        // 生成時刻より前に戻った時計は信用できないので、期限切れとして拒否する
        clock.advance(by: -1)
        assertRejects(attempt, callbackURL(), as: .expired, "生成時刻より前の時計")
        // 時計が生成時刻に戻っても、試行はすでに終了している
        clock.current = startDate
        assertRejects(attempt, callbackURL(), as: .alreadyConsumed, "時計復帰後の正しいcallback")
    }

    func testNonFiniteClockFailsClosed() throws {
        // NaNや無限大の時刻では期限の比較が当てにならないため、期限切れとして拒否する。
        // 拒否で試行が終了する可能性があるので、値ごとに新しい試行を使う
        for value in [TimeInterval.nan, TimeInterval.infinity, -TimeInterval.infinity] {
            let clock = MockClock(startDate)
            let attempt = try makeAttempt(clock: clock)
            clock.current = Date(timeIntervalSince1970: value)
            assertRejects(attempt, callbackURL(), as: .expired, "clock=\(value)")
        }
    }

    // 壁時計は利用者やNTPで巻き戻せるため、期限は単調時計でも判定する。
    // 単調時計がlifetimeを超えていれば、壁時計が期限内に見えても期限切れとして拒否する
    func testMonotonicClockBeyondLifetimeExpiresEvenIfWallClockRolledBackIntoWindow() throws {
        let clock = MockClock(startDate)
        // 合成の固定値（実際のuptimeとは無関係）
        let uptime = MockUptime(1_000)
        let fixed = syntheticSecrets
        let attempt = try ChatGPTOAuthAttempt(
            agentHostID: syntheticHostID,
            redirectURI: URL(string: syntheticRedirect)!,
            lifetime: lifetime,
            authorizationBuilder: ChatGPTOAuthAuthorizationRequestBuilder(makeSecrets: { fixed }),
            now: { clock.current },
            uptime: { uptime.current }
        )

        // 実際には期限を過ぎるまで時間が経った
        clock.advance(by: lifetime + 60)
        uptime.advance(by: lifetime + 60)
        // 壁時計だけを巻き戻し、開始時刻は下回らず期限内にあるように見せる
        // （既存の「開始時刻より前」の検査には引っかからない値にする）
        clock.current = startDate.addingTimeInterval(1)

        assertRejects(attempt, callbackURL(), as: .expired, "単調時計で期限超過、壁時計は期限内に見える")
    }

    func testCallbackAfterCancelIsRejected() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)
        attempt.cancel()
        assertRejects(attempt, callbackURL(), as: .cancelled, "キャンセル後の正しいcallback")
    }

    // MARK: - 別試行との混線

    func testCallbackFromAnotherAttemptIsRejected() throws {
        let clock = MockClock(startDate)
        let first = try makeAttempt(secrets: syntheticSecrets, clock: clock)
        let second = try makeAttempt(secrets: otherSecrets, clock: clock)

        assertRejects(first, callbackURL(state: otherState), as: .callbackRejected(.invalidState), "2つ目の試行のcallbackを1つ目へ")
        assertRejects(second, callbackURL(state: syntheticState), as: .callbackRejected(.invalidState), "1つ目の試行のcallbackを2つ目へ")
    }

    func testConsumingOneAttemptDoesNotConsumeAnother() throws {
        let clock = MockClock(startDate)
        let first = try makeAttempt(secrets: syntheticSecrets, clock: clock)
        let second = try makeAttempt(secrets: otherSecrets, clock: clock)

        let firstRequest = try first.consumeCallback(callbackURL())
        assertSameRequest(firstRequest, try expectedTokenRequest(), "1つ目の試行")

        // 2つ目は自分のverifierでtoken requestを作る（1つ目の値と混ざらない）
        let secondRequest = try second.consumeCallback(callbackURL(state: otherState, code: otherCode))
        assertSameRequest(
            secondRequest,
            try expectedTokenRequest(secrets: otherSecrets, code: otherCode),
            "2つ目の試行"
        )
        XCTAssertNotEqual(firstRequest.body, secondRequest.body)

        assertRejects(first, callbackURL(), as: .alreadyConsumed, "1つ目の再送")
        assertRejects(second, callbackURL(state: otherState, code: otherCode), as: .alreadyConsumed, "2つ目の再送")
    }

    // MARK: - 秘密値を表示に出さない

    func testAttemptAndOutcomesDoNotRenderSecrets() throws {
        let clock = MockClock(startDate)
        let attempt = try makeAttempt(clock: clock)

        var rendered = renderedForms(of: attempt)
        // 成功時の戻り値と、拒否時のエラーも表示に秘密値を出さない
        do {
            rendered += renderedForms(of: try attempt.consumeCallback(callbackURL()))
        } catch {
            rendered += renderedForms(of: error)
        }
        do {
            rendered += renderedForms(of: try attempt.consumeCallback(callbackURL()))
        } catch {
            rendered += renderedForms(of: error)
        }
        rendered += renderedForms(of: attempt)

        for text in rendered {
            for secret in secretValues {
                XCTAssertFalse(text.contains(secret), "表示に秘密値が含まれている")
            }
            XCTAssertFalse(text.contains("code_challenge"), "表示に認可URLの中身が含まれている")
        }
    }
}
