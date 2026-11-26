import Foundation
import Observation
import SwiftData

// 会話の入力文から、AIの記録候補の確認画面(ReviewSession)までをつなぐ、接続方式に依存しない部分。
// ここにあるのは「AIへ渡す内容の型」「接続先(provider)の差し込み口」「1回の依頼の進行管理」だけで、
// 実際の接続先の実装やネットワーク通信はこのファイルには含まない
// （Responses API向けの通信部品は AIResponsesChatProvider.swift・AIResponsesHTTPTransport.swift にある）。
// 本番コードには実サービスへ接続するproviderの配線がなく、このcoordinatorを作るのは
// 通常画面から開く外部通信なしの固定台本デモ（AIWorkoutChatDemoSession。デモ用memory storeのみ）とテストだけ。
// 候補の検証・reviewの作成・承認と保存は、既存の AIWorkoutProposalCoordinator にすべて任せる。

// MARK: - AIへ渡す内容

// 聞き返しの会話の1件の発言。利用者が入力した文("user")か、AIの質問("assistant")だけを持つ。
// coordinatorのメモリにだけ置き、保存しない。過去のDBの記録は発言として入れない
struct AIWorkoutChatTurn: Encodable, Equatable {
    enum Role: String, Encodable {
        case user
        case assistant
    }

    let role: Role
    let text: String

    // 作るのはこのファイルの AIWorkoutChatCoordinator だけ（会話で実際にやりとりした文に限るため）
    fileprivate init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

// 記録追加の依頼でproviderへ渡す内容。入力文と、送信時点の種目・項目定義のカタログ、
// 依頼時点の現地の日付(today)とタイムゾーン、同じ会話の直前までのやりとり(history)だけを持つ
// （日付とタイムゾーンを送ることはユーザー承認済み）。
// 過去の記録を入れる場所は型として用意しない（カタログも記録を持たない。AIWorkoutCatalog の説明を参照）
struct AIWorkoutChatRequest: Encodable, Equatable {
    // 今回の入力文（最初の依頼文、または質問への回答）
    let message: String
    let catalog: AIWorkoutCatalog
    // 依頼時点の現地のグレゴリオ暦の日付 "yyyy-MM-dd"。送信時に1度だけ決め、後で時計が進んでも変えない
    let today: String
    // 依頼時点のタイムゾーンの識別子（"Asia/Tokyo" など）
    let timeZone: String
    // 同じ会話の直前までのやりとり（利用者の入力とAIの質問を古い順に）。新しい会話の最初の依頼では空
    let history: [AIWorkoutChatTurn]

    // 作るのはこのファイルの AIWorkoutChatCoordinator だけ（カタログは beginRequest で作ったものに限るため）
    fileprivate init(message: String, catalog: AIWorkoutCatalog, today: String, timeZone: String, history: [AIWorkoutChatTurn]) {
        self.message = message
        self.catalog = catalog
        self.today = today
        self.timeZone = timeZone
        self.history = history
    }

    // 送信用JSON。キー順を固定する。カタログの定義比較用の値(metricSnapshots)は含まれない
    func payloadJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

// providerから受け取る内容。AIの構造化出力(JSON)をそのまま持ち、中身は信頼しない。
// "kind" で記録候補("createWorkout")と聞き返しの質問("askQuestion")を区別し、検証はcoordinatorで行う。
// 質問は {"kind": "askQuestion", "question": "..."} の2つのキーだけを受け付ける。
// 候補の形式（JSON Schema・ツール呼び出しなど）は未決なので、ここでは決めていない
struct AIWorkoutChatResponse: Equatable {
    let json: Data
}

// 聞き返しの会話の上限。会話はメモリにだけ持ち、上限を超えたら古い発言を捨てずにエラーで止める。
// どの値も、この機能を安全に動かすための暫定の安全制約で、仕様として決めた値ではない
// （実際の接続先や利用状況を確かめた上で見直す前提）
enum AIWorkoutChatLimits {
    // AIの質問1件の最大の長さ（UTF-8のバイト数）
    static let maxQuestionBytes = 2_000
    // 再送時に渡す、同じ会話の履歴（利用者の入力とAIの質問）の最大件数。4往復分
    static let maxHistoryTurns = 8
    // 1回の送信で渡す会話の文（履歴＋今回の入力）の合計の最大の長さ（UTF-8のバイト数）
    static let maxConversationBytes = 32_768
}

// AIの接続先の差し込み口。実際の接続先はまだ1つも実装していない。
// MainActor に置くのは、coordinator と同じactorで呼び、状態の食い違いを起こさないため
// （通信などの待ちは send の中で await すればよく、画面は止まらない）。
// 実装する側が守ること（このcoordinatorでは確かめられない）:
// - 受け取った内容以外（過去の記録・ファイル・認証情報など）を送らない
// - 応答を読み込む大きさを自分でも制限する（AIWorkoutProposal.decode の上限は、読み込んだ後のDataにしか効かない）
// - キャンセルされたら通信をやめてから、send から戻る（return でも throw でもよい）。
//   coordinatorは send が戻ったことを「停止を確認できた」とみなし、それまで次の依頼を受け付けない。
//   やめずに応答を返しても、coordinatorは破棄する。
//   send がいつまでも戻らなければ、coordinatorはずっとキャンセル中（busy）のままになる
//   （時間切れで停止済みとはみなさない。止まっていない通信と次の依頼が同時に走らないようにするため）
// - エラーに応答内容・送信内容を含めない（coordinatorは内容を表示しないが、ログ等へ流さないため）
@MainActor protocol AIWorkoutChatProvider {
    func send(_ request: AIWorkoutChatRequest) async throws -> AIWorkoutChatResponse
}

// MARK: - 依頼の進行管理

// 1回の依頼（入力文の送信→応答の検証→確認画面）を進める。
// 同時に進められる依頼は1つだけで、送信中・キャンセル中・確認中に次の依頼は受け付けない（busy）。
// 依頼が終わる（保存・キャンセル・失敗）までは、新しい依頼を始められない。
// 応答待ちの依頼を取り消した場合は、providerの send が実際に戻る（=通信の停止を確認できる）まで
// キャンセル中として busy を保つ。取り消した依頼の応答が後から届いても破棄し、reviewを作らない。
// 承認・保存は確認画面が ReviewSession を通して行い、このcoordinatorは保存しない。
//
// 聞き返しの会話: AIが記録候補ではなく質問を返したら、保存もreviewも作らず、質問と会話の履歴をメモリにだけ持つ。
// - 回答は answer で、同じ会話の直前までのやりとりを history として付けて送る（回答のたびに新しい依頼IDを使う）
// - 回答待ちの質問がある間、send は questionPending で拒否する（確認なしに会話を捨てないため）。
//   新しく依頼するには、answer で答えるか、cancelCurrent で会話全体を破棄してから send する
// - 回答の送信が失敗・取り消しで終わっても、直前の質問と成功したやりとりの履歴は残し、answer で答え直せる
// - 履歴の件数・文の長さが上限を超えたら、古い発言を捨てずにエラーで会話を終える
// - 完全な候補が返ったら会話は終わり、確認画面の組を返す（保存は確認画面の承認でだけ行う）
@Observable @MainActor final class AIWorkoutChatCoordinator {
    // 回答待ちの聞き返しの会話。メモリにだけ持ち、保存しない
    private struct Conversation {
        // 会話を見分けるためのID。回答の送信中に会話が入れ替わっていないかを確かめるのに使う
        let id: UUID
        // 会話を始めた依頼のcontextのcontainer。回答は同じcontainerのcontextでだけ受け付ける（別の保存先の定義を送らないため）。
        // AIWorkoutProposalCoordinator と同じく、解放後のメモリ番地の再利用で一致と誤判定しないよう強参照で持つ
        let container: ModelContainer
        // 成功したやりとりだけを古い順に持つ。最後は回答待ちの質問（question と同じ文）
        let history: [AIWorkoutChatTurn]
        let question: String
    }

    // providerの応答を読んだ結果。質問か、まだ検証していない記録候補
    private enum Reply {
        case question(String)
        case proposal(AIWorkoutProposal)
    }

    private static let askQuestionKind = "askQuestion"

    private enum Active {
        // providerの応答を待っている。call はproviderを呼んでいるタスクで、取り消し時に止めるために持つ
        case sending(requestID: UUID, call: Task<AIWorkoutChatResponse, Error>)
        // 取り消した。providerには取り消しを伝え済みで、send が戻る（停止を確認できる）のを待っている。
        // 依頼自体はキャンセル済みなので、この間に届いた応答は使わない
        case cancelling(requestID: UUID)
        // 確認画面に出す候補ができた。保存・キャンセルの状態は session（=AIWorkoutProposalCoordinator）が持つ
        case reviewing(AIWorkoutProposalCoordinator.ReviewSession)
    }

    // 1回の送信の結果。完全な候補なら確認画面の組、不足があればAIからの質問（保存もreviewも作らない）
    enum Outcome {
        case review(AIWorkoutProposalCoordinator.ReviewSession)
        case question(String)
    }

    private let provider: any AIWorkoutChatProvider
    // reviewの作成・承認・二重登録の防止はこのcoordinatorに任せる。外から別のインスタンスを渡させない
    // （複数のインスタンスがあると、互いの二重登録を防げないため）
    private let proposals: AIWorkoutProposalCoordinator
    private var active: Active?
    // active の Observation 再入で外側の代入に上書きされても、依頼単位の取消を失わない
    private var cancellationMarks: Set<UUID> = []
    // 回答待ちの質問があるときだけ値を持つ。回答の送信中も、答えている質問として持ち続ける
    private var conversation: Conversation?
    // 今の時刻を読む関数。テストでは進め方を決められる時計を渡し、通常は実際の時計を使う。
    // coordinatorと同じ MainActor で呼ぶので、MainActor上の時計（テストの TestClock など）も安全に読める
    private let now: @MainActor () -> Date

    init(provider: any AIWorkoutChatProvider, now: @escaping @MainActor () -> Date = { Date() }) {
        self.provider = provider
        self.now = now
        proposals = AIWorkoutProposalCoordinator()
    }

    // 応答待ちの依頼のID。応答待ちでなければnil
    var sendingRequestID: UUID? {
        if case let .sending(requestID, _) = active { return requestID }
        return nil
    }

    // 取り消した後、providerの停止を待っている依頼のID。キャンセル中でなければnil。
    // 画面はこれで「キャンセル中（まだ次の依頼はできない）」を表示できる
    var cancellingRequestID: UUID? {
        if case let .cancelling(requestID) = active { return requestID }
        return nil
    }

    // キャンセル中（providerの停止を待っている）か
    var isCancelling: Bool {
        cancellingRequestID != nil
    }

    // 確認中（保存・キャンセルされていない）の候補。なければnil
    var currentReviewSession: AIWorkoutProposalCoordinator.ReviewSession? {
        if case let .reviewing(session) = active, session.status == .reviewing { return session }
        return nil
    }

    // 回答待ちのAIの質問。なければnil。
    // 回答の送信中・その取り消し中も、答えている質問として返す（送信中かどうかは isBusy で分かる）
    var pendingQuestion: String? {
        conversation?.question
    }

    // 送信中・キャンセル中・確認中の依頼があるか。回答待ちの質問があるだけなら busy ではない
    var isBusy: Bool {
        sendingRequestID != nil || isCancelling || currentReviewSession != nil
    }

    // このcoordinatorで始めた依頼の状態（取り消し・失敗した依頼は cancelled になる）
    func requestStatus(_ requestID: UUID) -> AIWorkoutProposalCoordinator.Status? {
        proposals.status(of: requestID)
    }

    // 新しい会話として、入力文とカタログをproviderへ送る（履歴は空）。この時点では何も保存しない。
    // 完全な候補なら確認画面用の組を、不足があればAIの質問を返す（質問は answer で答える）。
    // 失敗したらその依頼は終了し（同じ応答から後でreviewを作れない）、AIWorkoutChatError を投げる。
    // 回答待ちの質問がある間は、会話を黙って捨てないよう questionPending で拒否する。
    // 呼び出し元のタスクの取り消しは、結果を公開した直後の確認までを反映する（それ以後の取り消しは成功として返す）。
    // context は、承認時にも使う store（container）の、未保存の変更がない context を渡す
    func send(_ message: String, in context: ModelContext, calendar: Calendar = .current) async throws -> Outcome {
        guard !Self.isBlank(message) else { throw AIWorkoutChatError.emptyMessage }
        guard !isBusy else { throw AIWorkoutChatError.busy }
        guard conversation == nil else { throw AIWorkoutChatError.questionPending }
        // 呼び出し元のタスクが既に取り消されていれば、何も送らない
        guard !Task.isCancelled else { throw AIWorkoutChatError.cancelled }
        try Self.checkLimits(history: [], message: message)
        return try await perform(message: message, history: [], continuing: nil, in: context, calendar: calendar)
    }

    // 回答待ちの質問への答えを、同じ会話の直前までのやりとり（history）と一緒に送る。
    // 結果の扱いは send と同じで、質問が返れば会話を続け、完全な候補が返れば会話を終えて確認画面用の組を返す。
    // 送信が失敗・取り消しで終わったら、直前の質問と履歴はそのまま残る（失敗した回答は履歴に入れない）。
    // 履歴の件数・文の長さが上限を超えるときは送らず、会話を終えて conversationLimitExceeded を投げる。
    // context は会話を始めたときと同じ store（container）のものでなければならない
    func answer(_ text: String, in context: ModelContext, calendar: Calendar = .current) async throws -> Outcome {
        guard !Self.isBlank(text) else { throw AIWorkoutChatError.emptyMessage }
        guard !isBusy else { throw AIWorkoutChatError.busy }
        guard let current = conversation else { throw AIWorkoutChatError.noPendingQuestion }
        // 別の保存先の定義をカタログとして送らないよう、カタログを作る前に止める（質問は残す）
        guard context.container === current.container else { throw AIWorkoutChatError.request(.storeMismatch) }
        guard !Task.isCancelled else { throw AIWorkoutChatError.cancelled }
        do {
            try Self.checkLimits(history: current.history, message: text)
        } catch {
            // 古い発言を捨てて続けることはせず、会話を終える。何も送らない
            conversation = nil
            throw error
        }
        return try await perform(message: text, history: current.history, continuing: current, in: context, calendar: calendar)
    }

    // send / answer の共通部分。1つの依頼IDで送り、応答を質問か確認画面の組にする。
    // continuing は答えている会話（新しい会話ならnil）。失敗・取り消しのときは会話を continuing のまま変えない
    private func perform(message: String, history: [AIWorkoutChatTurn], continuing: Conversation?,
                         in context: ModelContext, calendar: Calendar) async throws -> Outcome {
        let request: AIWorkoutProposalCoordinator.Request
        do {
            // カタログ作成に失敗したら（未保存の変更・定義の食い違いなど）、何も送らない
            request = try proposals.beginRequest(in: context)
        } catch {
            throw Self.chatError(from: error)
        }
        // 時計は依頼ごとに1回だけ読む。送る today と、応答の未来日判定の両方をこの時刻で行い、
        // 応答待ちの間に日付が変わっても、AIに伝えた「今日」と判定の基準が食い違わないようにする。
        // 暦は候補の日付の解釈と同じく、呼び出し元calendarのタイムゾーンだけを引き継いだグレゴリオ暦にする
        let requestedAt = now()
        let requestCalendar = AIWorkoutProposalValidation.calendar(from: calendar)
        let chatRequest = AIWorkoutChatRequest(
            message: message,
            catalog: request.catalog,
            today: Workout.dayString(from: requestedAt, calendar: requestCalendar),
            timeZone: requestCalendar.timeZone.identifier,
            history: history
        )
        // 種目カタログを含む実際の送信JSON全体を、providerを呼ぶ前に制限する。
        // カタログを省略せず、上限超過なら今回作った未使用requestだけを終了する。
        let payload: Data
        do {
            payload = try chatRequest.payloadJSON()
        } catch {
            try? proposals.cancel(request.id)
            throw Self.chatError(from: error)
        }
        guard payload.count <= AIWorkoutProposalLimits.maxResponseBytes else {
            try? proposals.cancel(request.id)
            throw AIWorkoutChatError.conversationLimitExceeded
        }
        // 実際の provider インターフェースには payload Data ではなく型付き request を渡す。
        // 上の計測は、その型が送信用にエンコードされるJSONのUTF-8サイズを検査する。
        let provider = self.provider
        // providerは別のタスクで呼ぶ。cancelCurrent からも通信を止められるようにするため
        let call = Task { @MainActor in try await provider.send(chatRequest) }
        // ここまで await を挟まないので、busy の確認から状態の設定までの間に別の send が割り込むことはない
        active = .sending(requestID: request.id, call: call)

        // providerの send が戻るまで待つ。call.value は呼び出し元が取り消されても待ち続けるので、
        // ここを抜けた時点で「providerが実際に return/throw した（停止を確認できた）」と言える
        let outcome: Result<AIWorkoutChatResponse, Error>
        do {
            let requestID = request.id
            let response = try await withTaskCancellationHandler {
                try await call.value
            } onCancel: {
                // 呼び出し元のタスクが取り消されたら、providerのタスクにも取り消しを伝える。
                // onCancel は MainActor 以外で呼ばれうるので、状態の変更は MainActor へ頼んで後で行う。
                // その間に応答が届いて依頼が終わっていても、markCancelling 側でIDを見て何もしない
                call.cancel()
                Task { @MainActor in self.markCancelling(requestID) }
            }
            outcome = .success(response)
        } catch {
            outcome = .failure(error)
        }

        // 取り消し済みの依頼は、providerの停止を確認できたこの時点で解放する。応答は成功・失敗とも内容を見ずに破棄する
        let markedCancelled = cancellationMarks.remove(request.id) != nil
        if cancellingRequestID == request.id || markedCancelled {
            active = nil
            throw AIWorkoutChatError.cancelled
        }
        // ここに来るのは応答待ちのままのはず。そうでなければ今の状態（次の依頼かもしれない）には触れない
        guard sendingRequestID == request.id else { throw AIWorkoutChatError.cancelled }
        // 呼び出し元のタスクが取り消されていれば、providerが応答を返していても使わない
        // （markCancelling がまだ動いていなくても、取り消しの印はタスク自体に先に付いている）
        guard !Task.isCancelled else {
            finish(request.id)
            throw AIWorkoutChatError.cancelled
        }
        let response: AIWorkoutChatResponse
        switch outcome {
        case let .success(value):
            response = value
        case let .failure(error):
            finish(request.id)
            // providerのエラーは内容（応答や送信内容を含みうる）を表示しないよう、種類だけにまとめる
            if error is CancellationError { throw AIWorkoutChatError.cancelled }
            throw AIWorkoutChatError.providerFailed
        }
        // 応答待ちの間は busy なので会話は変わらないはずだが、念のため答えていた会話のままかを確かめる。
        // 変わっていたら、この応答をどの会話にも入れない
        guard conversation?.id == continuing?.id else {
            finish(request.id)
            throw AIWorkoutChatError.cancelled
        }
        let reply: Reply
        do {
            reply = try Self.decodeReply(response.json)
        } catch {
            finish(request.id)
            throw Self.chatError(from: error)
        }
        switch reply {
        case let .question(question):
            return try publishQuestion(question, message: message, history: history, continuing: continuing,
                                       requestID: request.id, container: context.container)
        case let .proposal(proposal):
            return try publishReview(proposal, continuing: continuing, requestID: request.id, in: context,
                                     calendar: calendar, requestedAt: requestedAt)
        }
    }

    // AIの質問を会話に加えて返す。保存もreviewもせず、質問を受けた依頼IDは終了する（同じIDから後でreviewを作れない）
    private func publishQuestion(_ question: String, message: String, history: [AIWorkoutChatTurn], continuing: Conversation?,
                                 requestID: UUID, container: ModelContainer) throws -> Outcome {
        let next = Conversation(
            id: continuing?.id ?? UUID(),
            container: container,
            history: history + [AIWorkoutChatTurn(role: .user, text: message), AIWorkoutChatTurn(role: .assistant, text: question)],
            question: question
        )
        // 会話を先に差し替えてから依頼を終える。差し替えの書き込み中に cancelCurrent が割り込んでも、
        // まだ応答待ちなのでキャンセル中になるだけで、会話は消されない
        conversation = next
        finish(requestID)
        // 公開中に cancelCurrent で取り消された場合、providerは既に戻っているので、ここでキャンセル中を解放する
        let markedCancelled = cancellationMarks.remove(requestID) != nil
        let cancelledWhilePublishing = cancellingRequestID == requestID || markedCancelled
        if cancelledWhilePublishing { active = nil }
        // review と同じく、公開した直後にもう一度取り消されていないかを確かめる。成功の確定点はこの確認
        guard Task.isCancelled || cancelledWhilePublishing else { return .question(question) }
        // 取り消された質問は採用せず、答える前の会話（新しい会話ならなし）に戻す
        if conversation?.id == next.id { conversation = continuing }
        throw AIWorkoutChatError.cancelled
    }

    // 記録候補を既存の仕組みで検証し、確認画面用の組を返す。会話はここで終わる
    private func publishReview(_ proposal: AIWorkoutProposal, continuing: Conversation?, requestID: UUID, in context: ModelContext,
                               calendar: Calendar, requestedAt: Date) throws -> Outcome {
        let session: AIWorkoutProposalCoordinator.ReviewSession
        do {
            // 種目と項目の実在・値・単位・日付の検証は既存の仕組みに任せる。
            // 曖昧・不完全な候補はここで拒否され、reviewは作られない（会話は残り、答え直せる）
            session = try proposals.reviewSession(for: requestID, proposal: proposal, in: context, calendar: calendar, now: requestedAt)
            active = .reviewing(session)
        } catch {
            finish(requestID)
            throw Self.chatError(from: error)
        }
        // 完全な候補ができたので会話は終わる。回答待ちの質問は残さない
        conversation = nil
        // 公開した直後にもう一度、取り消されていないかを確かめる。
        // 上の Task.isCancelled の確認から公開までの間にも、別スレッドから呼び出し元のタスクが取り消されうる
        // （active の書き込みを観測した処理が取り消す場合など）。また公開の書き込み中に cancelCurrent が
        // 割り込んで候補をキャンセル済みにした場合も、ここで確認中ではなくなっている
        guard Task.isCancelled || session.status != .reviewing else {
            // 成功の確定点はこの確認。これより後（return までの間）に呼び出し元のタスクが取り消されても、
            // 候補は確認中のまま返し、取り消しには cancelCurrent で応じる（ここでは確かめようがない）
            return .review(session)
        }
        // 未承認の候補をキャンセル済みにしてから解放する。cancel は何度呼んでもよく、キャンセル済みなら何もしない。
        // 失敗（保存処理中・保存済み）したら、キャンセルできていない候補を解放しない（握り潰して空けると、
        // 確認中の候補が残ったまま次の依頼を受け付けてしまうため）。キャンセルできていないので cancelled とは言わない。
        // その場合は候補が保存に進んでいるので、会話も終わったままにする
        do {
            try session.cancel()
        } catch {
            throw Self.chatError(from: error)
        }
        // 今もこの依頼の候補を持っているときだけ解放する（別の依頼の状態には触れない）
        if case let .reviewing(current) = active, current.requestID == requestID { active = nil }
        // 取り消した回答は採用しないので、答える前の質問に戻す（新しい会話ならなし）
        if conversation == nil { conversation = continuing }
        throw AIWorkoutChatError.cancelled
    }

    // 今の依頼を取り消す。何度呼んでもよい。
    // 応答待ちなら、依頼をすぐキャンセル済みにしてproviderへ取り消しを伝え、キャンセル中にする。
    // providerの send が戻るまでは busy のままで、戻った時点で解放される（後から届いた応答は破棄する）。
    // 確認中ならreviewをキャンセルする（何も保存しない）。
    // 保存処理中のreviewはキャンセルできず、エラーを投げて状態は変えない。
    // 回答待ちの質問だけがある（送信中でない）なら、会話全体（履歴と質問）を破棄する。
    // 回答の送信中に呼んだ場合は送信だけを取り消し、質問と履歴は残す（もう一度呼ぶと会話を破棄できる）
    func cancelCurrent() throws {
        switch active {
        case nil:
            conversation = nil
        case let .sending(requestID, call):
            call.cancel()
            markCancelling(requestID)
        case .cancelling:
            // 既に取り消し済みで、providerの停止を待っている。待つ以外にできることはない
            return
        case let .reviewing(session):
            // 保存済み・キャンセル済みならもう終わっているので、状態を片付けるだけ
            if session.status == .reviewing { try session.cancel() }
            active = nil
        }
    }

    // 応答待ちの依頼をキャンセル中にする。依頼はすぐキャンセル済みにして、同じIDから後でreviewを作れないようにする。
    // 解放（active = nil）は send がproviderの停止を確認してから行う。
    // 呼び出し元タスクの取り消しから遅れて呼ばれることがあるので、今もその依頼の応答待ちのときだけ変える
    // （既に終わった・次の依頼に移った後なら何もしない）
    private func markCancelling(_ requestID: UUID) {
        guard sendingRequestID == requestID else { return }
        guard cancellationMarks.insert(requestID).inserted else { return }
        try? proposals.cancel(requestID)
        active = .cancelling(requestID: requestID)
    }

    // 応答待ちの依頼を終了させる。AIWorkoutProposalCoordinator側でもキャンセル済みにして、
    // 同じIDから後でreviewを作れないようにする（応答待ちのIDの cancel は失敗しないので、エラーは無視してよい）
    private func finish(_ requestID: UUID) {
        try? proposals.cancel(requestID)
        if sendingRequestID == requestID { active = nil }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // 送る履歴の件数と、会話の文（履歴＋今回の入力）の合計の長さを確かめる（暫定の安全上限。AIWorkoutChatLimits を参照）
    private static func checkLimits(history: [AIWorkoutChatTurn], message: String) throws {
        guard history.count <= AIWorkoutChatLimits.maxHistoryTurns else { throw AIWorkoutChatError.conversationLimitExceeded }
        let bytes = history.reduce(message.utf8.count) { $0 + $1.text.utf8.count }
        guard bytes <= AIWorkoutChatLimits.maxConversationBytes else { throw AIWorkoutChatError.conversationLimitExceeded }
    }

    // 応答を質問か記録候補として読む。"kind" が "askQuestion" のときだけ質問として厳しく読み、
    // それ以外（JSONでない・kindがない・別のkind）は記録候補として既存の読み込み（未知のキーは malformed）に任せる。
    // そのため、記録候補に question が混ざっていれば malformed、質問に候補の項目が混ざっていれば invalidQuestion になる
    private static func decodeReply(_ data: Data) throws -> Reply {
        // JSONの解析は全体を一度に読み込むので、どちらの形でも解析を始める前に大きさを確かめる
        guard data.count <= AIWorkoutProposalLimits.maxResponseBytes else { throw AIWorkoutProposalError.limitExceeded(.responseSize) }
        // try? で、JSONとして読めない応答は質問ではないものとして扱う（下の記録候補の読み込みで malformed になる）
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           object["kind"] as? String == askQuestionKind {
            return .question(try question(from: object))
        }
        return .proposal(try AIWorkoutProposal.decode(from: data))
    }

    // 質問は "kind" と "question" の2つのキーだけを持ち、question は空でなく上限以内の文字列でなければならない。
    // 内容はエラーに含めない
    private static func question(from object: [String: Any]) throws -> String {
        guard Set(object.keys) == ["kind", "question"],
              let text = object["question"] as? String,
              !isBlank(text),
              text.utf8.count <= AIWorkoutChatLimits.maxQuestionBytes
        else { throw AIWorkoutChatError.invalidQuestion }
        return text
    }

    private static func chatError(from error: Error) -> AIWorkoutChatError {
        switch error {
        case let error as AIWorkoutChatError: return error
        case let error as AIWorkoutProposalError: return .proposal(error)
        case let error as AIWorkoutProposalCoordinatorError: return .request(error)
        // SwiftDataの読み込みエラーなど。内容は表示しない
        default: return .unexpected
        }
    }
}

// AIの応答内容・送信内容・providerのエラー内容はメッセージに含めない
enum AIWorkoutChatError: LocalizedError, Equatable {
    case emptyMessage
    // 送信中または確認中の依頼がある
    case busy
    // 取り消された依頼（利用者の取り消し・呼び出し元タスクの取り消し・置き換え）。応答は使わない
    case cancelled
    // 接続先でのエラー（通信エラーなど）。内容は含めない
    case providerFailed
    // カタログ作成・候補の読み込み・検証で拒否された
    case proposal(AIWorkoutProposalError)
    // 依頼の管理（保存先の不一致など）で拒否された
    case request(AIWorkoutProposalCoordinatorError)
    // AIの質問が不正（文字列でない・空・長すぎる・余分な項目がある）
    case invalidQuestion
    // 回答する質問がない（聞き返しの会話をしていない）
    case noPendingQuestion
    // 回答待ちの質問があるのに新しい依頼を始めようとした。会話を黙って捨てないため拒否する
    case questionPending
    // 会話の履歴・文の長さが（暫定の安全）上限を超えた。古い発言を捨てて続けることはしない
    case conversationLimitExceeded
    case unexpected

    var errorDescription: String? {
        switch self {
        case .invalidQuestion: "AIからの質問を読み込めませんでした。何も保存していません。もう一度依頼してください。"
        case .noPendingQuestion: "回答する質問がありません。新しく依頼してください。"
        case .questionPending: "AIからの質問に回答していません。回答するか、キャンセルして会話を破棄してから新しく依頼してください。"
        case .conversationLimitExceeded: "会話がこの機能の実装上の安全上限（暫定の値で、仕様ではありません）を超えたため続けられません。何も保存していません。新しく依頼し直してください。"
        case .emptyMessage: "依頼の内容を入力してください。"
        case .busy: "進行中の依頼があります。保存またはキャンセルしてから、もう一度依頼してください。"
        case .cancelled: "依頼を取り消しました。何も保存していません。"
        case .providerFailed: "AIとの通信に失敗しました。何も保存していません。もう一度依頼してください。"
        case let .proposal(error): error.errorDescription
        case let .request(error): error.errorDescription
        case .unexpected: "依頼を処理できませんでした。何も保存していません。"
        }
    }
}
