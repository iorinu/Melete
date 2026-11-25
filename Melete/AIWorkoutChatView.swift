import SwiftData
import SwiftUI

private enum AIWorkoutChatStyle {
    static let accent = Color(red: 0.76, green: 0.31, blue: 0.16)
}

@MainActor struct AIWorkoutChatView: View {
    private struct ReviewPresentation: Identifiable {
        let session: AIWorkoutProposalCoordinator.ReviewSession
        let context: ModelContext

        var id: UUID { session.id }
    }

    let presentation: AIWorkoutChatPresentation
    let context: ModelContext
    @State private var reviewPresentation: ReviewPresentation?
    @State private var canReopenReview = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if presentation.messages.isEmpty {
                            ContentUnavailableView {
                                Label("運動をチャットで記録", systemImage: "bubble.left.and.bubble.right")
                            } description: {
                                Text("依頼を入力すると、必要に応じて質問し、記録候補を確認画面に表示します。")
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
                Text("送信内容はAI接続先に送られます。記録は確認画面で承認した場合にのみ保存されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(.regularMaterial)
        }
        .frame(minWidth: 620, minHeight: 440)
        .tint(AIWorkoutChatStyle.accent)
        .onAppear(perform: presentReviewIfNeeded)
        .onChange(of: presentation.reviewSession?.id) { presentReviewIfNeeded() }
        .sheet(item: $reviewPresentation, onDismiss: {
            presentation.refreshReviewState()
            reviewPresentation = nil
            // pending sessionが残ったときだけ手動で再オープンできるようにする。
            canReopenReview = presentation.reviewSession != nil
        }) { item in
            AIWorkoutProposalReviewForm(session: item.session, context: item.context)
        }
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
            .accessibilityLabel("\(isUser ? "あなた" : "AIの質問"): \(message.text)")
    }

    private func presentReviewIfNeeded() {
        guard reviewPresentation == nil, let session = presentation.reviewSession else { return }
        reviewPresentation = ReviewPresentation(session: session, context: context)
    }
}
