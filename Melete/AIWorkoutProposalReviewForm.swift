import SwiftData
import SwiftUI

// AIの記録候補を確認・修正し、承認したときだけ保存する画面。
// AIへの接続は未実装で、この画面を開く入口もまだない。将来の接続画面が
// AIWorkoutProposalCoordinator.reviewSession(for:...) で得た組と、beginRequest に渡したのと同じstoreの context を渡して使う。
// 表示・修正する値は review が持つものだけを使い、この画面には値のコピーを持たない（表示と保存内容を食い違わせないため）

private enum AIReviewFormStyle {
    static let accent = Color(red: 0.76, green: 0.31, blue: 0.16)
}

// 承認・キャンセルのボタン操作の結果。画面から切り離して、単体テストで確かめられるようにしている
@MainActor enum AIWorkoutProposalReviewFormAction {
    enum Outcome: Equatable {
        // 保存済み。画面を閉じてよい
        case saved(workoutID: UUID)
        // キャンセル済み。何も保存せずに画面を閉じてよい
        case closed
        // 保存もキャンセルもしていない。画面を開いたまま、修正中の値を残してメッセージを表示する
        case failed(String)
    }

    // 保存は必ず coordinator の approve を通す（session.approve はそれを呼ぶだけ）。
    // 確認中でない候補には保存を試みない（連打や、閉じる途中の再タップで二重に保存しないため）
    static func approve(_ session: AIWorkoutProposalCoordinator.ReviewSession, in context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }) -> Outcome {
        switch session.review.state {
        case .pending: break
        case .saving: return .failed(AIWorkoutProposalReviewError.inProgress.localizedDescription)
        case let .saved(workoutID): return .saved(workoutID: workoutID)
        case .cancelled: return .closed
        }
        // 修正後の値に問題があれば保存を試みない（保存境界でも同じ検証をするが、ここで先に止めて理由を示す）
        if let message = session.review.validationMessage() { return .failed(message) }
        do {
            let workout = try session.approve(in: context, persist: persist)
            return .saved(workoutID: workout.id)
        } catch {
            // 失敗した場合、reviewは確認中に戻り、修正中の値もそのまま残る
            return .failed(error.localizedDescription)
        }
    }

    static func cancel(_ session: AIWorkoutProposalCoordinator.ReviewSession) -> Outcome {
        do {
            try session.cancel()
            return .closed
        } catch {
            // 保存処理中・保存済みの候補はキャンセルできない。保存済みなのに「キャンセルした」とは扱わない
            return .failed(error.localizedDescription)
        }
    }
}

// review・coordinator はMainActor上でだけ扱うので、画面全体をMainActorに置く
@MainActor struct AIWorkoutProposalReviewForm: View {
    @Environment(\.dismiss) private var dismiss
    let session: AIWorkoutProposalCoordinator.ReviewSession
    // beginRequest に渡したのと同じstore（container）の context。別storeなら coordinator が storeMismatch で拒否する
    let context: ModelContext
    @State private var actionError: String?
    // 保存またはキャンセルが確定した後は、閉じ終わるまで一切の操作を受け付けない
    @State private var isFinished = false

    private var review: AIWorkoutProposalReview { session.review }

    private var isEditable: Bool {
        !isFinished && review.state == .pending
    }

    var body: some View {
        let validationMessage = review.validationMessage()
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("AIの記録候補を確認").font(.system(.title, design: .rounded).weight(.bold))
                Text("内容を確認し、必要なら数値を直してください。「承認して保存」を押したときだけ記録します。日付・種目・セット数はこの画面では変更できません。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Form {
                LabeledContent("運動日") {
                    Text(dayText).accessibilityIdentifier("aiProposalReviewDay")
                }
                ForEach(review.entries) { entry in
                    Section(entry.exerciseName) {
                        ForEach(Array(entry.sets.enumerated()), id: \.element.id) { setIndex, set in
                            setEditor(entry: entry, set: set, setIndex: setIndex)
                        }
                    }
                }
            }
            .disabled(!isEditable)
            if let actionError {
                Text(actionError).foregroundStyle(.red).accessibilityIdentifier("aiProposalReviewActionError")
            }
            if let validationMessage, validationMessage != actionError {
                Text(validationMessage).foregroundStyle(.red).accessibilityIdentifier("aiProposalReviewValidationError")
            }
            HStack {
                Spacer()
                Button("キャンセル") { cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!isEditable)
                    .accessibilityIdentifier("cancelAIProposalButton")
                // 承認は明示的なクリックに限る（値の入力中にReturnキーで誤って承認しないよう、defaultActionは割り当てない）
                Button("承認して保存") { approve() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isEditable || validationMessage != nil)
                    .accessibilityIdentifier("approveAIProposalButton")
            }
        }
        .padding(26)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 640)
        .tint(AIReviewFormStyle.accent)
        // 承認・キャンセル以外の方法で閉じないようにする（閉じても保存はしないが、確認中のまま画面だけ消えるのを避ける）
        .interactiveDismissDisabled()
        // 保存済み・キャンセル済みの session が新しい画面として表示された場合、ボタンがすべて無効のまま閉じられなくなるので閉じる
        .onAppear { dismissIfAlreadyFinished() }
        // 同じ session を表示している別の画面で保存・キャンセルが確定した場合も、無効なボタンのまま残らないよう閉じる
        .onChange(of: review.state) { dismissIfAlreadyFinished() }
    }

    // 既に確定した候補なら、保存もキャンセルも呼ばずに閉じるだけにする。
    // 確認中(pending)・保存処理中(saving)は自動で保存・キャンセルせず、そのまま表示する
    private func dismissIfAlreadyFinished() {
        // この画面で確定させて閉じ始めた後に state の変化が届いても、もう一度 dismiss しない
        guard !isFinished else { return }
        switch review.state {
        case .saved, .cancelled:
            isFinished = true
            dismiss()
        case .pending, .saving:
            break
        }
    }

    @ViewBuilder private func setEditor(entry: WorkoutEntryDraft, set: WorkoutSetDraft, setIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("セット \(setIndex + 1)").font(.headline)
            ForEach(entry.metricSnapshots, id: \.id) { metric in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(metric.name)（\(metric.unit)）")
                        Text(metric.isRequired ? "必須" : "任意")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    TextField(metric.allowsDecimal ? "小数第3位まで" : "0以上の整数", text: valueBinding(exerciseID: entry.exerciseID, setID: set.id, metricID: metric.id))
                        .frame(minWidth: 100, maxWidth: 180)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(entry.exerciseName)・セット\(setIndex + 1)の\(metric.name)（\(metric.unit)）\(metric.isRequired ? "必須" : "任意")")
                        .accessibilityIdentifier("aiProposalValue_\(set.id.uuidString)_\(metric.id.uuidString)")
                }
            }
        }
        .padding(.vertical, 4)
    }

    // 値の読み書きはどちらも review に対して行う。位置(index)ではなくIDで探すので、表示の更新と食い違わない
    private func valueBinding(exerciseID: UUID, setID: UUID, metricID: UUID) -> Binding<String> {
        let review = review
        return Binding(get: {
            review.entries.first { $0.exerciseID == exerciseID }?.sets.first { $0.id == setID }?.values[metricID] ?? ""
        }, set: { text in
            do {
                try review.setValue(text, exerciseID: exerciseID, setID: setID, metricID: metricID)
                // 前回の保存失敗の表示は、値を直した時点で消す（検証メッセージは常に最新の値から表示する）
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        })
    }

    private var dayText: String {
        // 検証に使ったカレンダーで表示する（端末のタイムゾーンと違っても、保存される日付と同じ日を示すため）
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.calendar = review.calendar
        style.timeZone = review.calendar.timeZone
        return review.day.formatted(style)
    }

    private func approve() {
        guard !isFinished else { return }
        finish(with: AIWorkoutProposalReviewFormAction.approve(session, in: context))
    }

    private func cancel() {
        guard !isFinished else { return }
        finish(with: AIWorkoutProposalReviewFormAction.cancel(session))
    }

    // 保存・キャンセルが確定したときだけ閉じる。失敗時は値を残したまま理由を表示する
    private func finish(with outcome: AIWorkoutProposalReviewFormAction.Outcome) {
        switch outcome {
        case .saved, .closed:
            isFinished = true
            dismiss()
        case let .failed(message):
            actionError = message
        }
    }
}

#if DEBUG
// プレビュー専用の合成データ。メモリ上だけのstoreを使い、通常ストア・ネットワークには触れない。
// AIの応答を模した固定の候補で、本物のAI応答として扱う入口ではない
@MainActor private enum AIWorkoutProposalReviewPreviewFixture {
    struct Loaded {
        let session: AIWorkoutProposalCoordinator.ReviewSession
        let context: ModelContext
    }

    static func make(invalidValue: Bool = false) throws -> Loaded {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("AIWorkoutProposalReviewPreview-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let weight = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let reps = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 1)
        let assist = MetricDefinition(name: "補助", unit: "段階", allowsDecimal: false, isRequired: false, sortOrder: 2)
        let exercise = Exercise(name: "合成種目A", metrics: [weight, reps, assist])
        context.insert(exercise)
        try context.save()

        // 日付の文字列化と候補の検証で同じ暦を使う（既存画面と同じ組み立てのグレゴリオ暦。端末の暦設定に左右されないため）
        let calendar = WorkoutCalendarLogic.calendar(timeZone: .current)
        let coordinator = AIWorkoutProposalCoordinator()
        let request = try coordinator.beginRequest(in: context)
        let set: [String: Any] = ["values": [
            ["metricID": weight.id.uuidString, "value": "60", "unit": "kg"],
            ["metricID": reps.id.uuidString, "value": "10", "unit": "回"],
        ]]
        let json: [String: Any] = [
            "kind": AIWorkoutProposal.createWorkoutKind,
            "day": Workout.dayString(from: .now, calendar: calendar),
            "entries": [["exerciseID": exercise.id.uuidString, "sets": [set, set, set]]],
        ]
        let proposal = try AIWorkoutProposal.decode(from: JSONSerialization.data(withJSONObject: json))
        let session = try coordinator.reviewSession(for: request.id, proposal: proposal, in: context, calendar: calendar)
        if invalidValue, let firstSet = session.review.entries.first?.sets.first {
            try session.review.setValue("6.5", exerciseID: exercise.id, setID: firstSet.id, metricID: reps.id)
        }
        return Loaded(session: session, context: context)
    }
}

@MainActor private struct AIWorkoutProposalReviewPreview: View {
    // body で作ると再描画のたびに新しいstoreになり、修正中の値が消えるので @State に一度だけ持つ
    @State private var loaded: AIWorkoutProposalReviewPreviewFixture.Loaded?

    init(invalidValue: Bool) {
        _loaded = State(initialValue: try? AIWorkoutProposalReviewPreviewFixture.make(invalidValue: invalidValue))
    }

    var body: some View {
        if let loaded {
            AIWorkoutProposalReviewForm(session: loaded.session, context: loaded.context)
        } else {
            Text("プレビュー用の合成データを作れませんでした。")
        }
    }
}

#Preview("確認中") {
    AIWorkoutProposalReviewPreview(invalidValue: false)
}

#Preview("検証エラー") {
    AIWorkoutProposalReviewPreview(invalidValue: true)
}
#endif
