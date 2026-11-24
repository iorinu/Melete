import XCTest
@testable import Melete

// Responses APIのSSE受信部（AIResponsesStreamParser）の仕様テスト。
// 合成したバイト列だけを使い、ネットワーク・認証・実データ・ストアには触れない。
final class AIResponsesStreamTests: XCTestCase {
    private typealias Failure = AIResponsesStreamFailure

    // 上限に引っかからない十分大きい設定（上限以外のテスト用）
    private let roomy = AIResponsesStreamLimits(maxInputBytes: 1 << 20, maxEventBytes: 1 << 16, maxOutputBytes: 1 << 16)

    // 外部応答に含まれる文字列がエラー文言へ漏れていないかを調べる目印
    private let marker = "EXTERNAL-RESPONSE-MARKER-7f3a"

    // MARK: - 合成ストリームの組み立て

    // JSON文字列を作る。エスケープはJSONSerializationに任せる（非ASCII文字は生のUTF-8のまま出る）
    private func json(_ object: [String: Any]) -> String {
        // 文字列・辞書だけで組み立てるので失敗しない
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    // 1イベント分のSSEテキスト。typeはJSON内に必ず入れ、event行は付けるかどうかを選べる
    private func event(_ type: String, _ fields: [String: Any] = [:], eventLine: Bool = true, newline: String = "\n") -> String {
        var object = fields
        object["type"] = type
        var text = ""
        if eventLine { text += "event: \(type)\(newline)" }
        text += "data: \(json(object))\(newline)\(newline)"
        return text
    }

    // 公式の response.output_text.delta が持つ識別子（item_id / output_index / content_index）のダミー値。
    // 実サービスの値ではなく、形式だけを合わせた合成値
    private static let dummyItemID = "msg_dummy_0001"

    // 生のSSE文字列でdeltaを書くテスト用の、識別子部分のJSON断片（先頭・末尾のカンマは含まない）
    private var rawIdentifiers: String {
        "\"content_index\":0,\"item_id\":\"\(Self.dummyItemID)\",\"output_index\":0"
    }

    // output_text.delta のフィールド一式。欠落・型違いのテストではここから書き換える
    private func deltaFields(_ text: String, itemID: String = AIResponsesStreamTests.dummyItemID, outputIndex: Int = 0, contentIndex: Int = 0) -> [String: Any] {
        ["delta": text, "item_id": itemID, "output_index": outputIndex, "content_index": contentIndex]
    }

    private func delta(_ text: String, itemID: String = AIResponsesStreamTests.dummyItemID, outputIndex: Int = 0, contentIndex: Int = 0, newline: String = "\n") -> String {
        event("response.output_text.delta", deltaFields(text, itemID: itemID, outputIndex: outputIndex, contentIndex: contentIndex), newline: newline)
    }

    // 拒否応答のイベント（公式: response.refusal.delta / response.refusal.done）
    private func refusalDelta(_ text: String, contentIndex: Int = 0) -> String {
        event("response.refusal.delta", ["delta": text, "item_id": Self.dummyItemID, "output_index": 0, "content_index": contentIndex])
    }

    private func refusalDone(_ text: String, contentIndex: Int = 0) -> String {
        event("response.refusal.done", ["refusal": text, "item_id": Self.dummyItemID, "output_index": 0, "content_index": contentIndex])
    }

    private func completed(newline: String = "\n") -> String {
        event("response.completed", ["response": ["id": "resp_1", "status": "completed"]], newline: newline)
    }

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    // chunk列を順に流し、各consumeの戻り値とfinishの結果を返す
    private func run(_ chunks: [Data], limits: AIResponsesStreamLimits? = nil) -> (states: [AIResponsesStreamState], result: Result<String, Failure>) {
        var parser = AIResponsesStreamParser(limits: limits ?? roomy)
        let states = chunks.map { parser.consume($0) }
        return (states, parser.finish())
    }

    private func run(_ text: String, limits: AIResponsesStreamLimits? = nil) -> Result<String, Failure> {
        run([bytes(text)], limits: limits).result
    }

    // MARK: - 正常終了

    func testDeltasFollowedByCompletedReturnConcatenatedText() {
        let stream = event("response.created", ["response": ["id": "resp_1", "status": "in_progress"]])
            + delta("ベンチ")
            + delta("プレス 60kg")
            + completed()
        XCTAssertEqual(run(stream), .success("ベンチプレス 60kg"))
    }

    func testCompletedWithoutDeltasSucceedsWithEmptyText() {
        XCTAssertEqual(run(completed()), .success(""))
    }

    func testConsumeReportsCompletedStateOnlyAfterCompletedEventIsDispatched() {
        var parser = AIResponsesStreamParser(limits: roomy)
        XCTAssertEqual(parser.consume(bytes(delta("a"))), .receiving)
        // data行は届いたが区切りの空行がまだ無い段階では完了扱いにしない
        XCTAssertEqual(parser.consume(bytes("event: response.completed\ndata: {\"type\":\"response.completed\"}\n")), .receiving)
        XCTAssertEqual(parser.consume(bytes("\n")), .completed)
        XCTAssertEqual(parser.state, .completed)
        XCTAssertEqual(parser.finish(), .success("a"))
    }

    func testFinishIsIdempotent() {
        var parser = AIResponsesStreamParser(limits: roomy)
        parser.consume(bytes(delta("ab") + completed()))
        XCTAssertEqual(parser.finish(), .success("ab"))
        XCTAssertEqual(parser.finish(), .success("ab"))
    }

    // MARK: - SSEフレーミング

    func testCRLFLineEndings() {
        let stream = delta("x", newline: "\r\n") + completed(newline: "\r\n")
        XCTAssertEqual(run(stream), .success("x"))
    }

    func testCROnlyLineEndings() {
        let stream = delta("x", newline: "\r") + completed(newline: "\r")
        XCTAssertEqual(run(stream), .success("x"))
    }

    func testMixedLineEndingsInOneStream() {
        let stream = delta("a", newline: "\n") + delta("b", newline: "\r\n") + delta("c", newline: "\r") + completed(newline: "\n")
        XCTAssertEqual(run(stream), .success("abc"))
    }

    // chunk末尾のCRと次chunk先頭のLFは1つの改行。2つの改行（=空行）と誤認すると途中のdataで早まってイベントが確定してしまう
    func testCRAtChunkEndAndLFAtNextChunkStartAreOneLineEnding() {
        let chunks = [
            bytes("data: {\"type\":\"response.output_text.delta\",\r"),
            bytes("\ndata: \(rawIdentifiers),\"delta\":\"x\"}\r\n\r\n" + completed(newline: "\r\n")),
        ]
        XCTAssertEqual(run(chunks).result, .success("x"))
    }

    // 複数のdata行は改行でつながる（JSON上は空白なので1つのオブジェクトとして読める）
    func testMultipleDataLinesAreJoinedWithNewline() {
        let stream = "event: response.output_text.delta\n"
            + "data: {\"type\":\"response.output_text.delta\",\n"
            + "data: \(rawIdentifiers),\"delta\":\"multi\"}\n\n"
            + completed()
        XCTAssertEqual(run(stream), .success("multi"))
    }

    func testDataFieldWithoutSpaceAfterColon() {
        let stream = "data:{\"type\":\"response.output_text.delta\",\(rawIdentifiers),\"delta\":\"nospace\"}\n\n" + completed()
        XCTAssertEqual(run(stream), .success("nospace"))
    }

    func testEventWithoutEventLineUsesJSONType() {
        let stream = event("response.output_text.delta", deltaFields("q"), eventLine: false)
            + event("response.completed", eventLine: false)
        XCTAssertEqual(run(stream), .success("q"))
    }

    func testCommentsBlankLinesAndIgnoredFieldsDoNotAffectResult() {
        let stream = ": keep-alive\n\n\n"
            + "id: 1\nretry: 1000\nunknown-field: value\n"
            + "event: response.output_text.delta\n"
            + ": comment inside event\n"
            + "data: {\"type\":\"response.output_text.delta\",\(rawIdentifiers),\"delta\":\"ok\"}\n"
            + "\n\n\n"
            + ":\n"
            + completed()
        XCTAssertEqual(run(stream), .success("ok"))
    }

    func testLeadingUTF8BOMIsIgnored() {
        XCTAssertEqual(run("\u{FEFF}" + delta("bom") + completed()), .success("bom"))
    }

    // event行だけでdataが無いブロックはイベントとして確定しない（完了の偽装にならない）
    func testEventLineWithoutDataIsNotDispatched() {
        XCTAssertEqual(run(delta("a") + "event: response.completed\n\n"), .failure(.truncated))
    }

    // どの位置で2つに分割しても、マルチバイト文字やCRLFを含めて同じ結果になる
    func testEverySingleSplitPointProducesSameResult() {
        let stream = bytes(delta("あい😀", newline: "\r\n") + delta("う", newline: "\r\n") + completed(newline: "\r\n"))
        for index in 0...stream.count {
            let chunks = [stream.prefix(index), stream.dropFirst(index)].map { Data($0) }
            XCTAssertEqual(run(chunks).result, .success("あい😀う"), "分割位置 \(index)")
        }
    }

    func testByteByByteFeedingWithMultibyteText() {
        let stream = bytes(delta("日本語") + delta("🏋️") + completed())
        let chunks = stream.map { Data([$0]) }
        XCTAssertEqual(run(chunks).result, .success("日本語🏋️"))
    }

    func testEmptyChunksAreHarmless() {
        let chunks = [Data(), bytes(delta("e")), Data(), bytes(completed()), Data()]
        XCTAssertEqual(run(chunks).result, .success("e"))
    }

    // MARK: - 未知イベント

    // 未知・対象外のイベントは無視し、output_text.done の全文などを出力へ二重に足さない
    func testUnknownAndUnhandledEventsAreIgnored() {
        let stream = event("response.created", ["response": ["status": "in_progress"]])
            + event("response.in_progress")
            + event("response.output_item.added", ["output_index": 0, "item": ["id": Self.dummyItemID, "type": "message"]])
            + event("response.content_part.added", [
                "item_id": Self.dummyItemID, "output_index": 0, "content_index": 0,
                "part": ["type": "output_text", "text": ""],
            ])
            + delta("only")
            + event("response.output_text.done", [
                "item_id": Self.dummyItemID, "output_index": 0, "content_index": 0,
                "text": "SHOULD-NOT-BE-APPENDED",
            ])
            + event("response.future_event_type", ["anything": ["nested": true]])
            + completed()
        XCTAssertEqual(run(stream), .success("only"))
    }

    // MARK: - deltaの識別子

    // 識別子が既定値（0番）以外でも、すべてのdeltaで同じ組なら連結して成功する
    func testDeltasWithSameNonDefaultIdentifiersAreConcatenated() {
        let stream = delta("スクワット", itemID: "msg_dummy_0002", outputIndex: 2, contentIndex: 3)
            + delta(" 80kg", itemID: "msg_dummy_0002", outputIndex: 2, contentIndex: 3)
            + completed()
        XCTAssertEqual(run(stream), .success("スクワット 80kg"))
    }

    // item_id / output_index / content_index の組が途中で変わったら、別の出力を1つの文字列へ連結せず失敗にする
    func testDeltaIdentifierChangeIsNotConcatenated() {
        let changes: [(label: String, second: String)] = [
            ("item_id", delta("後半", itemID: "msg_dummy_0002")),
            ("output_index", delta("後半", outputIndex: 1)),
            ("content_index", delta("後半", contentIndex: 1)),
            ("all", delta("後半", itemID: "msg_dummy_0002", outputIndex: 1, contentIndex: 1)),
        ]
        for (label, second) in changes {
            XCTAssertEqual(run(delta("前半") + second + completed()), .failure(.malformedEvent), label)
            // 一度変わってから元の組に戻っても成功にしない
            XCTAssertEqual(run(delta("前半") + second + delta("戻り") + completed()), .failure(.malformedEvent), label)
        }
    }

    // MARK: - 拒否応答

    // 公式の streaming events では、拒否は response.refusal.delta / response.refusal.done で届く。
    // completed の前に現れたら、それまでの output_text の途中テキストを含めて成功にしない
    func testRefusalBeforeCompletedFailsAndDiscardsPartialText() {
        let streams: [(label: String, stream: String)] = [
            ("delta only", delta("途中まで") + refusalDelta(marker, contentIndex: 1) + completed()),
            ("done only", delta("途中まで") + refusalDone(marker, contentIndex: 1) + completed()),
            ("delta and done", delta("途中まで") + refusalDelta(marker, contentIndex: 1) + refusalDone(marker, contentIndex: 1) + completed()),
            ("text after refusal", refusalDelta(marker) + refusalDone(marker) + delta("後から", contentIndex: 1) + completed()),
        ]
        for (label, stream) in streams {
            XCTAssertEqual(run(stream), .failure(.malformedEvent), label)
        }
    }

    // 出力テキストが1つも無い拒否も、空文字列の成功にしない
    func testRefusalWithoutTextDoesNotSucceedWithEmptyString() {
        XCTAssertEqual(run(refusalDelta(marker) + refusalDone(marker) + completed()), .failure(.malformedEvent))
    }

    // 拒否を受け取った時点で停止し、後から completed が来ても完了状態にならない
    func testRefusalStopsBeforeCompletedIsDispatched() {
        var parser = AIResponsesStreamParser(limits: roomy)
        XCTAssertEqual(parser.consume(bytes(delta("途中まで"))), .receiving)
        XCTAssertEqual(parser.consume(bytes(refusalDelta(marker, contentIndex: 1))), .failed(.malformedEvent))
        XCTAssertEqual(parser.consume(bytes(completed())), .failed(.malformedEvent))
        XCTAssertEqual(parser.finish(), .failure(.malformedEvent))
    }

    // MARK: - 不正なイベント

    func testInvalidJSONIsMalformed() {
        XCTAssertEqual(run("data: {not json\n\n" + completed()), .failure(.malformedEvent))
    }

    func testNonObjectJSONIsMalformed() {
        XCTAssertEqual(run("data: [1,2]\n\n" + completed()), .failure(.malformedEvent))
    }

    func testMissingTypeIsMalformed() {
        XCTAssertEqual(run("data: {\"delta\":\"x\"}\n\n" + completed()), .failure(.malformedEvent))
    }

    func testNonStringTypeIsMalformed() {
        XCTAssertEqual(run("data: {\"type\":1}\n\n" + completed()), .failure(.malformedEvent))
    }

    // 識別子は正しく付けたうえで、delta本体だけが欠けている・文字列でない場合
    func testDeltaMissingOrNonStringIsMalformed() {
        var missing = deltaFields("x")
        missing["delta"] = nil
        XCTAssertEqual(run(event("response.output_text.delta", missing) + completed()), .failure(.malformedEvent))
        var nonString = deltaFields("x")
        nonString["delta"] = 5
        XCTAssertEqual(run(event("response.output_text.delta", nonString) + completed()), .failure(.malformedEvent))
    }

    // 公式の output_text.delta には item_id（文字列）/ output_index・content_index（整数）が必ず付く。
    // 欠けていると、どの出力の続きか判断できないので連結せずに失敗にする
    func testDeltaMissingIdentifierIsMalformed() {
        for key in ["item_id", "output_index", "content_index"] {
            var fields = deltaFields("x")
            fields[key] = nil
            XCTAssertEqual(run(event("response.output_text.delta", fields) + completed()), .failure(.malformedEvent), key)
            // 正しいdeltaの後に欠けたdeltaが来た場合も、前半の出力で成功にしない
            XCTAssertEqual(run(delta("前半") + event("response.output_text.delta", fields) + completed()), .failure(.malformedEvent), key)
        }
    }

    // 型が違う識別子も失敗にする。true は NSNumber として Int へ変換できてしまうので、整数とは別に扱う必要がある
    func testDeltaIdentifierWithWrongTypeIsMalformed() {
        let cases: [(key: String, value: Any)] = [
            ("item_id", 1), ("item_id", NSNull()), ("item_id", [Self.dummyItemID]),
            ("output_index", "0"), ("output_index", NSNull()), ("output_index", 0.5), ("output_index", true),
            ("content_index", "0"), ("content_index", NSNull()), ("content_index", 0.5), ("content_index", true),
        ]
        for (key, value) in cases {
            var fields = deltaFields("x")
            fields[key] = value
            XCTAssertEqual(run(event("response.output_text.delta", fields) + completed()), .failure(.malformedEvent), "\(key)=\(value)")
        }
    }

    func testEmptyDataIsMalformed() {
        XCTAssertEqual(run("data:\n\n" + completed()), .failure(.malformedEvent))
    }

    // event行とJSONのtypeが食い違う場合は、どちらを信じても危険なので失敗にする
    func testEventLineAndJSONTypeMismatchIsMalformed() {
        let fakeCompletion = "event: response.completed\ndata: {\"type\":\"response.output_text.delta\",\(rawIdentifiers),\"delta\":\"x\"}\n\n"
        XCTAssertEqual(run(fakeCompletion), .failure(.malformedEvent))
        let hiddenCompletion = "event: response.output_text.delta\ndata: {\"type\":\"response.completed\"}\n\n"
        XCTAssertEqual(run(delta("a") + hiddenCompletion), .failure(.malformedEvent))
    }

    func testInvalidUTF8IsMalformed() {
        var data = bytes("data: {\"type\":\"response.output_text.delta\",\(rawIdentifiers),\"delta\":\"")
        data.append(contentsOf: [0xC3, 0x28])
        data.append(bytes("\"}\n\n" + completed()))
        XCTAssertEqual(run([data]).result, .failure(.malformedEvent))
    }

    // MARK: - 失敗イベント

    func testResponseFailedDiscardsPartialOutput() {
        var parser = AIResponsesStreamParser(limits: roomy)
        parser.consume(bytes(delta("途中まで")))
        let failed = event("response.failed", ["response": ["status": "failed", "error": ["code": "server_error", "message": marker]]])
        XCTAssertEqual(parser.consume(bytes(failed)), .failed(.responseFailed))
        XCTAssertEqual(parser.finish(), .failure(.responseFailed))
    }

    func testResponseIncompleteDiscardsPartialOutput() {
        let incomplete = event("response.incomplete", ["response": ["status": "incomplete", "incomplete_details": ["reason": marker]]])
        XCTAssertEqual(run(delta("途中") + incomplete), .failure(.responseIncomplete))
    }

    func testErrorEventDiscardsPartialOutput() {
        let error = event("error", ["code": "rate_limit", "message": marker])
        XCTAssertEqual(run(delta("途中") + error), .failure(.serverError))
    }

    // 失敗後に届いた入力は処理せず、completedが来ても成功に戻らない
    func testFailureIsStickyAndStopsProcessing() {
        var parser = AIResponsesStreamParser(limits: roomy)
        parser.consume(bytes(event("error", ["message": marker])))
        XCTAssertEqual(parser.consume(bytes(delta("after") + completed())), .failed(.serverError))
        XCTAssertEqual(parser.state, .failed(.serverError))
        XCTAssertEqual(parser.finish(), .failure(.serverError))
    }

    // MARK: - 終端前のEOF

    func testEmptyStreamIsTruncated() {
        XCTAssertEqual(run([]).result, .failure(.truncated))
    }

    func testEOFBeforeCompletedDiscardsPartialOutput() {
        XCTAssertEqual(run(delta("a") + delta("b")), .failure(.truncated))
    }

    func testEOFInsideCompletedEventIsTruncated() {
        // 区切りの空行が来る前に切れたcompletedは確定していない
        let unterminated = "event: response.completed\ndata: {\"type\":\"response.completed\"}\n"
        XCTAssertEqual(run(delta("a") + unterminated), .failure(.truncated))
        let noNewline = "event: response.completed\ndata: {\"type\":\"response.completed\"}"
        XCTAssertEqual(run(delta("a") + noNewline), .failure(.truncated))
    }

    func testUnprocessedInputAfterCompletedAtEOFIsTruncated() {
        XCTAssertEqual(run(delta("a") + completed() + "data: {"), .failure(.truncated))
    }

    // MARK: - 成功後の不正イベント

    func testDeltaAfterCompletedFails() {
        var parser = AIResponsesStreamParser(limits: roomy)
        XCTAssertEqual(parser.consume(bytes(delta("a") + completed())), .completed)
        XCTAssertEqual(parser.consume(bytes(delta("extra"))), .failed(.unexpectedEventAfterCompletion))
        XCTAssertEqual(parser.finish(), .failure(.unexpectedEventAfterCompletion))
    }

    func testAnyEventAfterCompletedFails() {
        let trailers = [
            completed(),
            event("response.future_event_type"),
            event("response.failed", ["response": ["status": "failed"]]),
            event("error", ["message": marker]),
            refusalDelta(marker),
            refusalDone(marker),
            "data: not json\n\n",
        ]
        for trailer in trailers {
            XCTAssertEqual(run(delta("a") + completed() + trailer), .failure(.unexpectedEventAfterCompletion), trailer)
        }
    }

    func testCommentsAndBlankLinesAfterCompletedAreAllowed() {
        XCTAssertEqual(run(delta("a") + completed() + ": bye\n\n\r\n"), .success("a"))
    }

    // MARK: - 上限

    func testInputLimitBoundary() {
        let stream = delta("ab") + completed()
        let size = bytes(stream).count
        let exact = AIResponsesStreamLimits(maxInputBytes: size, maxEventBytes: 1 << 16, maxOutputBytes: 1 << 16)
        XCTAssertEqual(run(stream, limits: exact), .success("ab"))
        let tight = AIResponsesStreamLimits(maxInputBytes: size - 1, maxEventBytes: 1 << 16, maxOutputBytes: 1 << 16)
        XCTAssertEqual(run(stream, limits: tight), .failure(.inputLimitExceeded))
    }

    // 上限を超えるchunkにcompletedが含まれていても処理せず停止する
    func testInputLimitStopsBeforeProcessingOverflowingChunk() {
        let first = bytes(delta("ab"))
        let limits = AIResponsesStreamLimits(maxInputBytes: first.count + 10, maxEventBytes: 1 << 16, maxOutputBytes: 1 << 16)
        var parser = AIResponsesStreamParser(limits: limits)
        XCTAssertEqual(parser.consume(first), .receiving)
        XCTAssertEqual(parser.consume(bytes(completed())), .failed(.inputLimitExceeded))
        XCTAssertEqual(parser.finish(), .failure(.inputLimitExceeded))
    }

    // 改行が来ないまま巨大な行が届いたら、行の終わりを待たずに止める
    func testEventLimitStopsLongLineWithoutNewline() {
        let limits = AIResponsesStreamLimits(maxInputBytes: 1 << 20, maxEventBytes: 64, maxOutputBytes: 1 << 16)
        var parser = AIResponsesStreamParser(limits: limits)
        XCTAssertEqual(parser.consume(bytes("data: " + String(repeating: "a", count: 200))), .failed(.eventLimitExceeded))
        XCTAssertEqual(parser.consume(bytes("\n\n" + completed())), .failed(.eventLimitExceeded))
        XCTAssertEqual(parser.finish(), .failure(.eventLimitExceeded))
    }

    // 短い行でも、区切りの空行が無いまま1イベント分が膨らんだら止める
    func testEventLimitCountsAccumulatedLinesWithinOneEvent() {
        let limits = AIResponsesStreamLimits(maxInputBytes: 1 << 20, maxEventBytes: 64, maxOutputBytes: 1 << 16)
        let dataFlood = String(repeating: "data: 1\n", count: 20)
        XCTAssertEqual(run(dataFlood + "\n" + completed(), limits: limits), .failure(.eventLimitExceeded))
        let commentFlood = String(repeating: ": x\n", count: 40)
        XCTAssertEqual(run(commentFlood + "\n" + completed(), limits: limits), .failure(.eventLimitExceeded))
    }

    // イベント上限は1イベントごと。小さいイベントが多数あっても合計では判定しない
    func testEventLimitIsPerEvent() {
        let stream = String(repeating: delta("z"), count: 20) + completed()
        let largestEvent = max(bytes(delta("z")).count, bytes(completed()).count)
        let limits = AIResponsesStreamLimits(maxInputBytes: 1 << 20, maxEventBytes: largestEvent, maxOutputBytes: 1 << 16)
        XCTAssertEqual(run(stream, limits: limits), .success(String(repeating: "z", count: 20)))
    }

    func testOutputLimitBoundaryInUTF8Bytes() {
        let limits = AIResponsesStreamLimits(maxInputBytes: 1 << 20, maxEventBytes: 1 << 16, maxOutputBytes: 5)
        XCTAssertEqual(run(delta("abc") + delta("de") + completed(), limits: limits), .success("abcde"))
        XCTAssertEqual(run(delta("abc") + delta("def") + completed(), limits: limits), .failure(.outputLimitExceeded))
        // 「あ」はUTF-8で3バイトなので2文字で6バイトになり超過する（文字数では数えない）
        XCTAssertEqual(run(delta("あ") + delta("あ") + completed(), limits: limits), .failure(.outputLimitExceeded))
    }

    // 出力上限に達した時点で停止し、後からcompletedが来ても途中の出力を返さない
    func testOutputLimitStopsImmediatelyAndIsSticky() {
        let limits = AIResponsesStreamLimits(maxInputBytes: 1 << 20, maxEventBytes: 1 << 16, maxOutputBytes: 3)
        var parser = AIResponsesStreamParser(limits: limits)
        XCTAssertEqual(parser.consume(bytes(delta("abcd"))), .failed(.outputLimitExceeded))
        XCTAssertEqual(parser.consume(bytes(completed())), .failed(.outputLimitExceeded))
        XCTAssertEqual(parser.finish(), .failure(.outputLimitExceeded))
    }

    // MARK: - エラー文言

    // 失敗理由の文言は固定で、外部応答の文字列（エラーメッセージ等）を含まない
    func testFailureDescriptionsAreFixedAndDoNotContainExternalText() {
        let streams: [(String, Failure)] = [
            (event("response.failed", ["response": ["status": "failed", "error": ["message": marker]]]), .responseFailed),
            (event("response.incomplete", ["response": ["incomplete_details": ["reason": marker]]]), .responseIncomplete),
            (event("error", ["message": marker, "code": marker]), .serverError),
            ("data: {\"type\":\"\(marker)\"\n\n", .malformedEvent),
        ]
        for (stream, expected) in streams {
            let result = run(stream)
            XCTAssertEqual(result, .failure(expected))
            guard case .failure(let failure) = result else { continue }
            XCTAssertFalse(String(describing: failure).contains(marker))
            XCTAssertFalse(failure.localizedDescription.contains(marker))
        }

        let all: [Failure] = [
            .responseFailed, .responseIncomplete, .serverError, .malformedEvent, .truncated,
            .unexpectedEventAfterCompletion, .inputLimitExceeded, .eventLimitExceeded, .outputLimitExceeded,
        ]
        for failure in all {
            let description = failure.errorDescription
            XCTAssertNotNil(description, "\(failure)")
            XCTAssertFalse(description?.isEmpty ?? true, "\(failure)")
        }
        // 種類ごとに区別できる文言にする
        XCTAssertEqual(Set(all.compactMap(\.errorDescription)).count, all.count)
    }
}
