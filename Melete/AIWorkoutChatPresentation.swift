import Foundation
import Observation
import SwiftData

@Observable @MainActor final class AIWorkoutChatPresentation {
    struct Message: Identifiable, Equatable {
        enum Role: Equatable {
            case user
            case assistant
        }

        let id: UUID
        let role: Role
        let text: String

        init(id: UUID = UUID(), role: Role, text: String) {
            self.id = id
            self.role = role
            self.text = text
        }
    }

    var inputText = ""
    private(set) var messages: [Message] = []
    private(set) var pendingQuestion: String?
    private(set) var reviewSession: AIWorkoutProposalCoordinator.ReviewSession?
    private(set) var errorMessage: String?
    private(set) var isSending = false

    var isCancelling: Bool { coordinator.isCancelling }

    private let coordinator: AIWorkoutChatCoordinator
    private let context: ModelContext
    private let calendar: Calendar

    init(coordinator: AIWorkoutChatCoordinator, context: ModelContext, calendar: Calendar = .current) {
        self.coordinator = coordinator
        self.context = context
        self.calendar = calendar
    }

    func submit() async {
        // async処理を始める前に状態を立て、連続タップによる二重送信を防ぐ。
        guard !isSending, !coordinator.isBusy else { return }
        let text = inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = AIWorkoutChatError.emptyMessage.localizedDescription
            return
        }

        isSending = true
        errorMessage = nil
        let answeringQuestion = coordinator.pendingQuestion
        do {
            let outcome: AIWorkoutChatCoordinator.Outcome
            if answeringQuestion != nil {
                outcome = try await coordinator.answer(text, in: context, calendar: calendar)
            } else {
                outcome = try await coordinator.send(text, in: context, calendar: calendar)
            }

            // 履歴には成功した依頼だけを加える。入力中に編集された場合は新しい入力を消さない。
            messages.append(Message(role: .user, text: text))
            switch outcome {
            case let .question(question):
                pendingQuestion = question
                messages.append(Message(role: .assistant, text: question))
            case let .review(session):
                pendingQuestion = nil
                reviewSession = session
            }
            if inputText == text { inputText = "" }
        } catch let error as AIWorkoutChatError {
            errorMessage = error.localizedDescription
        } catch {
            // provider等の任意エラー内容には個人情報が含まれる可能性があるため表示しない。
            errorMessage = AIWorkoutChatError.unexpected.localizedDescription
        }
        isSending = false
    }

    func approveReview() -> AIWorkoutProposalReviewFormAction.Outcome? {
        guard let session = reviewSession else { return nil }
        let outcome = AIWorkoutProposalReviewFormAction.approve(session, in: context)
        switch outcome {
        case .saved:
            reviewSession = nil
            errorMessage = nil
            // 保存完了後のreviewをcoordinatorから解放する。保存自体は上のapprove経由のみ。
            try? coordinator.cancelCurrent()
        case .closed:
            reviewSession = nil
            try? coordinator.cancelCurrent()
        case .failed:
            // review由来の任意文字列は画面へ流さず、安全な固定文言にする。
            errorMessage = AIWorkoutChatError.unexpected.localizedDescription
        }
        return outcome
    }

    func refreshReviewState() {
        guard let session = reviewSession else { return }
        switch session.status {
        case .saved, .cancelled:
            reviewSession = nil
        case .awaitingResponse, .reviewing, nil:
            // 応答待ち・確認中・状態不明は終了とみなさず、画面を維持する。
            break
        }
    }

    func cancel() {
        do {
            try coordinator.cancelCurrent()
            // 送信中の取消ではproviderの停止確認までisSendingを維持する。
            // 確認画面の取消はsessionを閉じ、回答待ち会話の取消は質問履歴も破棄する。
            if !isSending {
                reviewSession = nil
                if pendingQuestion != nil { messages = [] }
                pendingQuestion = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = AIWorkoutChatError.unexpected.localizedDescription
        }
    }
}
