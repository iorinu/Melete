import SwiftData
import SwiftUI

private enum AIWorkoutChatStyle {
    static let accent = Color(red: 0.76, green: 0.31, blue: 0.16)
}

@MainActor struct AIWorkoutChatView: View {
    // 表示文言の切り替え。demo は外部通信なしの固定台本（AIWorkoutChatDemoSession）で使う
    enum Mode: Equatable {
        case standard
        // isV2Route: V2検証用の起動でも、デモはV1形式のメモリ上だけで動くことを示すため
        case demo(isV2Route: Bool)
    }

    private struct ReviewPresentation: Identifiable {
        let session: AIWorkoutProposalCoordinator.ReviewSession
        let context: ModelContext

        var id: UUID { session.id }
    }

    let presentation: AIWorkoutChatPresentation
    let context: ModelContext
    var mode: Mode = .standard
    @State private var reviewPresentation: ReviewPresentation?
    @State private var canReopenReview = false

    private var isDemo: Bool { mode != .standard }

    var body: some View {
        VStack(spacing: 0) {
            if case let .demo(isV2Route) = mode {
                demoBanner(isV2Route: isV2Route)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if presentation.messages.isEmpty {
                            ContentUnavailableView {
                                Label("運動をチャットで記録", systemImage: "bubble.left.and.bubble.right")
                            } description: {
                                Text(isDemo
                                     ? "依頼を入力すると、固定の台本で質問し、合成値の記録候補を確認画面に表示します。入力内容は読み取りません。"
                                     : "依頼を入力すると、必要に応じて質問し、記録候補を確認画面に表示します。")
                            }
                            .frame(maxWidth: .infinity, minHeight: 220)
                        }
                        ForEach(presentation.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                        if presentation.isSending || presentation.isCancelling {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(presentation.isCancelling ? "取消中です。停止を確認しています…" : "送信中…")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            .id("sending-status")
                            .accessibilityIdentifier(presentation.isCancelling ? "chatCancellingStatus" : "chatSendingStatus")
                        }
                        if let error = presentation.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("chatFailureMessage")
                        }
                        if canReopenReview, reviewPresentation == nil, presentation.reviewSession != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("確認画面が閉じられました。記録候補の確認はまだ完了していません。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Button("確認画面を開く", systemImage: "arrow.up.right.square") {
                                    canReopenReview = false
                                    presentReviewIfNeeded()
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("reopenWorkoutReviewButton")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(24)
                }
                .onChange(of: presentation.messages) {
                    if let last = presentation.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if presentation.pendingQuestion != nil {
                    Text("質問への回答を入力")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("運動内容を入力…", text: Binding(
                        get: { presentation.inputText },
                        set: { presentation.inputText = $0 }
                    ), axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .disabled(presentation.isSending || presentation.isCancelling || presentation.reviewSession != nil)
                        .accessibilityIdentifier("chatInput")
                    if presentation.isSending || presentation.isCancelling {
                        Button("取消", systemImage: "stop.circle") { presentation.cancel() }
                            .buttonStyle(.bordered)
                            .disabled(presentation.isCancelling)
                            .accessibilityIdentifier("cancelChatRequestButton")
                    } else {
                        if presentation.pendingQuestion != nil {
                            Button("会話を破棄", systemImage: "xmark.circle") { presentation.cancel() }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("discardChatConversationButton")
                        }
                        Button {
                            Task { await presentation.submit() }
                        } label: {
                            Label("送信", systemImage: "arrow.up.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(presentation.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || presentation.reviewSession != nil)
                        .accessibilityIdentifier("submitChatButton")
                    }
                }
                Text(isDemo
                     ? "デモのため外部へは送信しません。記録は確認画面で承認した場合にのみ、デモ用メモリへ保存されます。"
                     : "送信内容はAI接続先に送られます。記録は確認画面で承認した場合にのみ保存されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(.regularMaterial)
        }
        // 通常画面のサイドバー横に収まる大きさ（MainViewの最小幅を広げない）
        .frame(minWidth: 560, minHeight: 360)
        .tint(AIWorkoutChatStyle.accent)
        .onAppear(perform: presentReviewIfNeeded)
        .onChange(of: presentation.reviewSession?.id) { presentReviewIfNeeded() }
        .sheet(item: $reviewPresentation, onDismiss: {
            presentation.refreshReviewState()
            reviewPresentation = nil
            // pending sessionが残ったときだけ手動で再オープンできるようにする。
            canReopenReview = presentation.reviewSession != nil
        }) { item in
            AIWorkoutProposalReviewForm(session: item.session, context: item.context, notice: isDemo
                ? "デモ: 数値は固定の合成値で、チャットの入力内容は反映されていません。承認するとこのウィンドウ内のデモ用メモリにだけ保存し、通常の履歴には反映されません。ウィンドウを閉じると消えます。"
                : nil)
        }
    }

    private func demoBanner(isV2Route: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("デモ（合成AI・外部通信なし）", systemImage: "theatermasks")
                .font(.subheadline.weight(.semibold))
            Text("実際のAIには接続していません。固定の台本で応答し、入力内容は読み取りません。承認した記録はこのウィンドウ内のデモ用メモリにだけ保存され、通常の履歴には反映されず、ウィンドウを閉じると消えます。")
            if isV2Route {
                Text("V2検証用ストアとは別の、V1形式のデモ用メモリを使います。V2としては保存しません。")
            }
            AIWorkoutChatDemoSavedCount()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chatDemoBanner")
    }

    @ViewBuilder private func messageBubble(_ message: AIWorkoutChatPresentation.Message) -> some View {
        HStack {
            if message.role == .assistant { bubble(message, isUser: false); Spacer(minLength: 70) }
            else { Spacer(minLength: 70); bubble(message, isUser: true) }
        }
        .frame(maxWidth: .infinity)
    }

    private func bubble(_ message: AIWorkoutChatPresentation.Message, isUser: Bool) -> some View {
        Text(message.text)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(isUser ? .white : .primary)
            .background(isUser ? AIWorkoutChatStyle.accent : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: 520, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(isUser ? "あなた" : (isDemo ? "デモの質問" : "AIの質問")): \(message.text)")
    }

    private func presentReviewIfNeeded() {
        guard reviewPresentation == nil, let session = presentation.reviewSession else { return }
        reviewPresentation = ReviewPresentation(session: session, context: context)
    }
}

// MARK: - デモ（合成AI・外部通信なし）

// デモで保存した件数だけを表示する。modelContainer環境はデモのcontainerに差し替えてあるので、
// このQueryが読むのはデモ用のmemory storeだけ
private struct AIWorkoutChatDemoSavedCount: View {
    @Query private var workouts: [Workout]

    var body: some View {
        Text("このデモで保存した記録: \(workouts.count)件（デモ用メモリ内のみ）")
            .accessibilityIdentifier("chatDemoSavedCount")
    }
}

// 通常画面の「チャットで記録」から開くデモ一式。実際のAIには接続せず、固定の台本で応答する。
// - containerはこのfactoryが毎回新しく作るmemory-onlyのV1 storeだけで、外から渡す口はない
//   （通常ストア・V2検証用ストアのcontainer/contextを受け取らないので、そこへは保存できない）
// - 種目・項目も固定の合成データで、実データを読まない
// - 承認した記録はこのstoreにだけ保存され、通常の履歴には出ない。インスタンスが解放されれば消える
@MainActor final class AIWorkoutChatDemoSession {
    enum Preparation {
        case ready(AIWorkoutChatDemoSession)
        case failed(String)
    }

    static let exerciseName = "デモ種目（合成）"
    static let question = "（デモ）何セット行いましたか？\nこれは固定の台本です。回答の内容は読み取らず、次に決まった合成値の記録候補を表示します。"
    static let weightValue = "40"
    static let repsValue = "8"
    static let setCount = 2
    // 初期化に失敗したときの固定文。内部のエラー内容は表示しない
    static let unavailableMessage = "デモを準備できませんでした。何も保存していません。通常の記録には影響ありません。"

    let container: ModelContainer
    let presentation: AIWorkoutChatPresentation
    let exerciseID: UUID
    let weightMetricID: UUID
    let repsMetricID: UUID

    // 表示（modelContainer環境）と承認の両方で同じcontextを使うため、mainContextに揃える
    var context: ModelContext { container.mainContext }

    private init(container: ModelContainer, presentation: AIWorkoutChatPresentation, exerciseID: UUID, weightMetricID: UUID, repsMetricID: UUID) {
        self.container = container
        self.presentation = presentation
        self.exerciseID = exerciseID
        self.weightMetricID = weightMetricID
        self.repsMetricID = repsMetricID
    }

    static func make(calendar: Calendar = .current) throws -> AIWorkoutChatDemoSession {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("MeleteChatDemo-\(UUID().uuidString)", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let weight = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let reps = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 1)
        let exercise = Exercise(name: exerciseName, metrics: [weight, reps])
        context.insert(exercise)
        try context.save()

        let provider = AIWorkoutChatDemoProvider(exerciseID: exercise.id, weightMetricID: weight.id, repsMetricID: reps.id)
        let presentation = AIWorkoutChatPresentation(coordinator: AIWorkoutChatCoordinator(provider: provider), context: context, calendar: calendar)
        return AIWorkoutChatDemoSession(container: container, presentation: presentation, exerciseID: exercise.id, weightMetricID: weight.id, repsMetricID: reps.id)
    }

    // 失敗しても通常ストアへは切り替えず、固定のエラーにする（fail closed）
    // make はテストで失敗を模すためだけに差し替える（nilなら通常のfactory）。どちらもcontainerは受け取らない
    static func prepare(using make: (() throws -> AIWorkoutChatDemoSession)? = nil) -> Preparation {
        do {
            if let make { return .ready(try make()) }
            return .ready(try Self.make())
        } catch {
            return .failed(unavailableMessage)
        }
    }
}

// デモ用の固定台本provider。通信は一切せず、入力文も読まない。
// 新しい会話（履歴なし）には質問を、回答（履歴あり）にはseedの種目IDと固定の合成値の候補を返す。
// 日付は依頼時に coordinator が決めた today をそのまま使う（未来日にならない）
@MainActor private final class AIWorkoutChatDemoProvider: AIWorkoutChatProvider {
    private let exerciseID: UUID
    private let weightMetricID: UUID
    private let repsMetricID: UUID

    init(exerciseID: UUID, weightMetricID: UUID, repsMetricID: UUID) {
        self.exerciseID = exerciseID
        self.weightMetricID = weightMetricID
        self.repsMetricID = repsMetricID
    }

    func send(_ request: AIWorkoutChatRequest) async throws -> AIWorkoutChatResponse {
        try Task.checkCancellation()
        let json: [String: Any]
        if request.history.isEmpty {
            json = ["kind": "askQuestion", "question": AIWorkoutChatDemoSession.question]
        } else {
            let set: [String: Any] = ["values": [
                ["metricID": weightMetricID.uuidString, "value": AIWorkoutChatDemoSession.weightValue, "unit": "kg"],
                ["metricID": repsMetricID.uuidString, "value": AIWorkoutChatDemoSession.repsValue, "unit": "回"],
            ]]
            json = [
                "kind": AIWorkoutProposal.createWorkoutKind,
                "day": request.today,
                "entries": [["exerciseID": exerciseID.uuidString, "sets": Array(repeating: set, count: AIWorkoutChatDemoSession.setCount)]],
            ]
        }
        return AIWorkoutChatResponse(json: try JSONSerialization.data(withJSONObject: json))
    }
}
