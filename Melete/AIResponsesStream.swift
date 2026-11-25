import Foundation

// ChatGPTのResponses API（stream: true / store: false）から届くSSEを受け取るための小さい受信部。
// ネットワーク・認証・ログ・ストアには触れず、呼び出し元から渡されたバイト列（chunk）だけを扱う。
// 成功として出力文字列を返すのは「response.completed を受け取り、その後に正常に終端した」場合だけで、
// 失敗・中断・上限超過のときは途中まで届いた出力を一切取り出せないようにする。
//
// 挙動の仕様は MeleteTests/AIResponsesStreamTests.swift。テストは合成したSSEだけを使っており、
// 実サービスから取得したSSEのfixtureでは検証していない。次の点は未検証なので、根拠なく成功扱いを広げないこと:
// - `data: [DONE]` は終端として扱わない（completed前なら malformedEvent、completed後なら unexpectedEventAfterCompletion）
// - response.completed の response.status は、存在する場合だけ "completed" であることを確認する（無い場合は許す）
// - output_text.delta は item_id（文字列）/ output_index・content_index（0以上の整数）を必須とし、
//   最初のdeltaと同じ組のものだけを届いた順に連結する（組が変わったら malformedEvent。複数の出力の扱いは未対応）
// - response.refusal.delta / response.refusal.done を受け取ったら、内容に関係なく途中の出力を捨てて malformedEvent にする

// MARK: - 上限

// 受信時の上限。すべてバイト数（UTF-8）で数える。
struct AIResponsesStreamLimits: Equatable, Sendable {
    // 受信した生バイトの累計の上限
    let maxInputBytes: Int
    // 1イベント分（直前のイベント区切り以降の生バイト。コメント行、CRLFのLF、確定させる空行の改行も含む）の上限。
    // 改行が来ない巨大な入力も止める
    let maxEventBytes: Int
    // 連結した出力テキスト（output_text.delta の合計）の上限
    let maxOutputBytes: Int

    init(maxInputBytes: Int, maxEventBytes: Int, maxOutputBytes: Int) {
        // 0以下の上限は設定ミスなので、黙って受け入れずに止める
        precondition(maxInputBytes > 0 && maxEventBytes > 0 && maxOutputBytes > 0, "上限は正の値にする")
        self.maxInputBytes = maxInputBytes
        self.maxEventBytes = maxEventBytes
        self.maxOutputBytes = maxOutputBytes
    }

    static let `default` = AIResponsesStreamLimits(
        maxInputBytes: 4 * 1024 * 1024,
        maxEventBytes: 256 * 1024,
        maxOutputBytes: 64 * 1024
    )
}

// MARK: - 失敗の種類

// 失敗理由。外部応答の文字列（エラーメッセージ等）を持ち込まないよう、関連値を持たない列挙型にしている。
enum AIResponsesStreamFailure: Error, Equatable, Sendable, LocalizedError {
    // response.failed を受信した
    case responseFailed
    // response.incomplete を受信した
    case responseIncomplete
    // error イベントを受信した
    case serverError
    // SSEやJSONとして解釈できない、UTF-8として不正、必須フィールドが無い・型が違う、event名とtypeが食い違う
    case malformedEvent
    // response.completed の前に（または未処理の入力を残して）ストリームが終わった
    case truncated
    // response.completed の後に別のイベントが届いた
    case unexpectedEventAfterCompletion
    // 受信バイトの累計が上限を超えた
    case inputLimitExceeded
    // 1イベント分のバイトが上限を超えた
    case eventLimitExceeded
    // 出力テキストが上限を超えた
    case outputLimitExceeded

    // 表示用の固定文言。外部応答の内容は含めない
    var errorDescription: String? {
        switch self {
        case .responseFailed: "AIの応答が失敗しました。"
        case .responseIncomplete: "AIの応答が途中で打ち切られました。"
        case .serverError: "AIサービスからエラーが返されました。"
        case .malformedEvent: "AIの応答を解釈できませんでした。"
        case .truncated: "AIの応答が完了する前に通信が終わりました。"
        case .unexpectedEventAfterCompletion: "AIの応答の完了後に想定外のデータが届きました。"
        case .inputLimitExceeded: "AIの応答のデータ量が上限を超えました。"
        case .eventLimitExceeded: "AIの応答の1件あたりのデータ量が上限を超えました。"
        case .outputLimitExceeded: "AIの応答の文章量が上限を超えました。"
        }
    }
}

// MARK: - 受信状態

enum AIResponsesStreamState: Equatable, Sendable {
    // まだ response.completed を受け取っていない
    case receiving
    // response.completed を受け取った（出力の取り出しは finish() で終端を確認してから）
    case completed
    // 失敗して停止した。以後の入力は無視され、状態は変わらない
    case failed(AIResponsesStreamFailure)
}

// MARK: - パーサ本体

// 任意の区切りで届くdata chunkを受け取るSSE状態機械。
// 途中経過の出力を読むプロパティは意図的に用意しない（完成していない出力を候補にしないため）。
struct AIResponsesStreamParser: Sendable {
    let limits: AIResponsesStreamLimits

    // 現在の状態
    private(set) var state: AIResponsesStreamState = .receiving

    // 受信した生バイトの累計
    private var inputByteCount = 0
    // 直前のイベント区切り（空行）以降に受け取った生バイト数
    private var eventByteCount = 0
    // 空行でイベントを確定させた直後か。CRで確定した場合、続くLFも同じイベントのバイトとして数えるため、
    // eventByteCount のリセットは次のイベントの最初のバイトが来るまで遅らせる
    private var isEventDispatched = false
    // まだ改行が来ていない行のバイト。UTF-8の文字がchunk境界で分断されても、ここで行単位にまとまる
    private var lineBuffer: [UInt8] = []
    // 直前のバイトがCRだったか。CRLFを1つの改行として扱うため、続くLFを読み飛ばすのに使う
    private var previousWasCR = false
    // まだ最初の行を処理していないか（先頭のBOMを取り除くため）
    private var isFirstLine = true

    // 処理中のイベントブロックの内容（空行で確定する）
    private var eventNameBytes: [UInt8]?
    private var dataBytes: [UInt8] = []
    private var hasDataLine = false

    // 連結済みの出力。外へ出すのは finish() で成功したときだけ
    private var output = ""
    private var outputByteCount = 0
    // 最初に受け取ったdeltaの識別子。以後のdeltaはこれと完全に一致しなければならない
    private var deltaIdentifier: DeltaIdentifier?
    // finish() を呼んだか。2回目以降は同じ結果を返す
    private var isFinished = false

    init(limits: AIResponsesStreamLimits = .default) {
        self.limits = limits
    }

    // chunkを1つ受け取り、処理後の状態を返す。失敗・上限超過になった時点で以降の処理を止める。
    @discardableResult
    mutating func consume(_ chunk: Data) -> AIResponsesStreamState {
        if case .failed = state { return state }
        if isFinished { return state }

        // 上限を超えるchunkは中身を1バイトも処理しない（completedが含まれていても成功させない）
        // 引き算で比べるのは、足し算のオーバーフローを避けるため
        guard chunk.count <= limits.maxInputBytes - inputByteCount else {
            fail(.inputLimitExceeded)
            return state
        }
        inputByteCount += chunk.count

        for byte in chunk {
            processByte(byte)
            if case .failed = state { break }
        }
        return state
    }

    // ストリームの終端（EOF）を伝える。completed に到達し、未処理の入力が残っていない場合だけ出力を返す。
    mutating func finish() -> Result<String, AIResponsesStreamFailure> {
        if !isFinished {
            isFinished = true
            // 改行で終わっていない行や、空行で確定していないdata/event行が残っていたら途中で切れたとみなす。
            // コメント行だけが残っている場合は、イベントの内容が無いので問題にしない
            let hasUnprocessedInput = !lineBuffer.isEmpty || hasDataLine || eventNameBytes != nil
            if state == .receiving || hasUnprocessedInput {
                fail(.truncated)
            }
        }

        switch state {
        case .completed: return .success(output)
        case .failed(let failure): return .failure(failure)
        // isFinished の時点で receiving は failed(.truncated) へ移しているので、ここには来ない
        case .receiving: return .failure(.truncated)
        }
    }

    // MARK: - SSEフレーミング

    private mutating func processByte(_ byte: UInt8) {
        let lf: UInt8 = 0x0A
        let cr: UInt8 = 0x0D

        // CRの直後のLFは、CRLFという1つの改行の後半。CRとLFが別々のchunkに分かれていてもここで判定できる
        let isLFOfCRLF = previousWasCR && byte == lf
        previousWasCR = false

        // 確定済みのイベントに属さないバイトが来たら、ここから次のイベントとして数え直す。
        // 空行のCRLFのLFは、確定させたイベント側の改行なので数え直さない
        if isEventDispatched && !isLFOfCRLF {
            isEventDispatched = false
            eventByteCount = 0
        }

        // 1イベント分の生バイト数を数える（CRLFのLFも含む）。改行が来ない巨大な行もここで止まる
        eventByteCount += 1
        guard eventByteCount <= limits.maxEventBytes else {
            fail(.eventLimitExceeded)
            return
        }

        // CRLFのLFは、行の区切りとしてはCRの時点で処理済みなので行として扱わない
        if isLFOfCRLF { return }

        switch byte {
        case lf:
            processLine()
        case cr:
            previousWasCR = true
            processLine()
        default:
            lineBuffer.append(byte)
        }
    }

    // 改行まで届いた1行を処理する（SSEの仕様: 空行=イベント確定、":"始まり=コメント、それ以外=フィールド）
    private mutating func processLine() {
        var line = lineBuffer[...]
        lineBuffer.removeAll(keepingCapacity: true)

        // ストリーム先頭のUTF-8 BOM（EF BB BF）は読み飛ばす
        if isFirstLine {
            isFirstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) {
                line = line.dropFirst(3)
            }
        }

        if line.isEmpty {
            dispatchEvent()
            return
        }

        let colon: UInt8 = 0x3A
        // コメント行（keep-alive等）は無視する
        if line.first == colon { return }

        // 最初の ":" でフィールド名と値に分ける。":" が無い行は値が空のフィールドとして扱う
        let name: ArraySlice<UInt8>
        var value: ArraySlice<UInt8>
        if let colonIndex = line.firstIndex(of: colon) {
            name = line[..<colonIndex]
            value = line[line.index(after: colonIndex)...]
            // ":" 直後の空白は1つだけ取り除く
            if value.first == 0x20 { value = value.dropFirst() }
        } else {
            name = line
            value = []
        }

        if name.elementsEqual("data".utf8) {
            // 複数のdata行は改行でつなぐ。最後の改行は確定時に取り除く
            dataBytes.append(contentsOf: value)
            dataBytes.append(0x0A)
            hasDataLine = true
        } else if name.elementsEqual("event".utf8) {
            eventNameBytes = Array(value)
        }
        // id・retry・未知のフィールドはこの用途では使わないので無視する
    }

    // 空行でイベントブロックを確定させる
    private mutating func dispatchEvent() {
        // 次のイベントのために、ブロック単位の状態を先に取り出してリセットする
        let nameBytes = eventNameBytes
        var data = dataBytes
        let hadData = hasDataLine
        eventNameBytes = nil
        dataBytes.removeAll(keepingCapacity: true)
        hasDataLine = false
        // eventByteCount はここでは0にしない（空行がCRLFなら、続くLFもこのイベントの分として数えるため）
        isEventDispatched = true

        // data行が1つも無いブロックはイベントにならない（event行だけで完了を偽装させない）
        guard hadData else { return }

        // 完了後に届いたイベントは、内容が正しいかどうかに関係なく失敗にする
        if state == .completed {
            fail(.unexpectedEventAfterCompletion)
            return
        }

        data.removeLast()  // data行ごとに足した改行のうち最後の1つ
        guard let type = Self.decodeEventType(data: data) else {
            fail(.malformedEvent)
            return
        }

        // event行がある場合は、JSONのtypeと完全に一致していることを要求する
        if let nameBytes {
            guard let name = Self.decodeUTF8(nameBytes[...]), name == type.name else {
                fail(.malformedEvent)
                return
            }
        }

        handleEvent(type.name, object: type.object)
    }

    // MARK: - イベント処理

    private mutating func handleEvent(_ type: String, object: [String: Any]) {
        switch type {
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String,
                  let identifier = Self.decodeDeltaIdentifier(object)
            else {
                fail(.malformedEvent)
                return
            }
            // 別の出力（item / output / content）のdeltaを1つの文字列へ混ぜない
            if let deltaIdentifier {
                guard identifier == deltaIdentifier else {
                    fail(.malformedEvent)
                    return
                }
            } else {
                deltaIdentifier = identifier
            }
            let deltaBytes = delta.utf8.count
            guard deltaBytes <= limits.maxOutputBytes - outputByteCount else {
                fail(.outputLimitExceeded)
                return
            }
            output += delta
            outputByteCount += deltaBytes

        case "response.completed":
            // status が付いている場合は "completed" 以外を成功扱いにしない（付いていない形はテストで許している）
            if let response = object["response"] {
                guard let response = response as? [String: Any] else {
                    fail(.malformedEvent)
                    return
                }
                if let status = response["status"] {
                    guard let status = status as? String, status == "completed" else {
                        fail(.malformedEvent)
                        return
                    }
                }
            }
            state = .completed

        case "response.failed":
            fail(.responseFailed)
        case "response.incomplete":
            fail(.responseIncomplete)
        case "error":
            fail(.serverError)
        case "response.refusal.delta", "response.refusal.done":
            // 拒否応答は記録の候補にならないので、届いた時点で途中の出力ごと捨てて止める。
            // 拒否の文面は外部応答なので、読まずに固定の失敗理由だけを残す
            fail(.malformedEvent)

        default:
            // response.created や output_text.done など、出力の組み立てに使わないイベントは無視する。
            // output_text.done の全文を足すと delta と二重になるため使わない
            break
        }
    }

    // 失敗状態へ移り、途中までの出力やバッファを捨てる
    private mutating func fail(_ failure: AIResponsesStreamFailure) {
        state = .failed(failure)
        output = ""
        outputByteCount = 0
        deltaIdentifier = nil
        lineBuffer = []
        dataBytes = []
        eventNameBytes = nil
        hasDataLine = false
    }

    // MARK: - デコード

    // dataをUTF-8として検証し、JSONオブジェクトの "type"（文字列）を取り出す。条件を満たさなければ nil
    private static func decodeEventType(data: [UInt8]) -> (name: String, object: [String: Any])? {
        guard let text = decodeUTF8(data[...]), !text.isEmpty else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let object = parsed as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        return (type, object)
    }

    // output_text.delta がどの出力の続きかを表す識別子の組
    private struct DeltaIdentifier: Equatable, Sendable {
        let itemID: String
        let outputIndex: Int
        let contentIndex: Int
    }

    // item_id（文字列）/ output_index・content_index（0以上の整数）がすべて正しい型でそろっていれば返す
    private static func decodeDeltaIdentifier(_ object: [String: Any]) -> DeltaIdentifier? {
        guard let itemID = object["item_id"] as? String,
              let outputIndex = nonNegativeInteger(object["output_index"]),
              let contentIndex = nonNegativeInteger(object["content_index"])
        else { return nil }
        return DeltaIdentifier(itemID: itemID, outputIndex: outputIndex, contentIndex: contentIndex)
    }

    // JSONの整数値だけを Int として取り出す。
    // JSONSerialization の数値は NSNumber で届き、`as? Int` だと true（→1）や 0.5（→0 など）まで
    // 整数として通ってしまうことがあるため、Core Foundation の型を直接確かめる
    private static func nonNegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        // 真偽値は CFBoolean という別の型なので、CFNumber でないものはここで落とす（NSDecimalNumber等も同様）
        guard CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        // 小数として読まれた値（0.5 や 1.0、1e2 など）は整数として扱わない
        guard !CFNumberIsFloatType(number as CFNumber) else { return nil }
        // 64bit整数へ値を失わずに変換できるときだけ受け付ける（範囲外なら false が返る）
        var integer: Int64 = 0
        guard CFNumberGetValue(number as CFNumber, .sInt64Type, &integer), integer >= 0 else { return nil }
        return Int(exactly: integer)
    }

    // 不正なUTF-8を置換文字で埋めずに nil にする（壊れた入力を黙って通さないため）
    private static func decodeUTF8(_ bytes: ArraySlice<UInt8>) -> String? {
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        var scalars = String.UnicodeScalarView()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: return String(scalars)
            case .error: return nil
            }
        }
    }
}
