import Foundation
import SwiftData

// AI会話から運動記録を作る第1段階の基礎部分。
// ここにあるのは「送信用の定義カタログ」「AIの構造化候補の厳格な検証」「確認用draftと承認後の保存」
// 「リクエストIDごとのreviewの一元管理（同一アプリセッション内の二重登録防止）」だけで、
// AIへの接続・画面への配線・未登録種目の同時作成は含まない（docs/ai-conversation-recording.md の設計メモ参照）。

// MARK: - AIへ送る定義カタログ

// 記録追加の依頼時にAIへ渡す情報。種目名と有効な項目定義だけを持ち、過去の記録を入れる場所を型として用意しない。
struct AIWorkoutCatalog: Encodable, Equatable {
    struct MetricSummary: Encodable, Equatable {
        let id: UUID
        let name: String
        let unit: String
        let allowsDecimal: Bool
        let isRequired: Bool
    }

    struct ExerciseSummary: Encodable, Equatable {
        let id: UUID
        let name: String
        let metrics: [MetricSummary]
        // 送信時点の定義。承認前の比較に使うだけで、送信内容には含めない
        let metricSnapshots: [MetricDefinitionSnapshot]

        private enum CodingKeys: String, CodingKey {
            case id, name, metrics
        }
    }

    let exercises: [ExerciseSummary]

    // 未保存の変更がある context からは作らない（未確定の名前や定義を外部へ送らないため）
    @MainActor static func make(in context: ModelContext) throws -> AIWorkoutCatalog {
        guard !context.hasChanges else { throw AIWorkoutProposalError.unsavedContext }
        // 呼び出し元contextの登録済みモデルは、別contextで保存された変更を反映していないことがある。
        // 送る内容は新しいcontextから読んだ保存済みの定義にする。呼び出し元contextの定義と食い違う種目は承認時に必ず拒否されるが、
        // 黙って外すとAIが「未登録の種目」と誤認するので、外さずにカタログ作成全体を失敗させる（一部だけのカタログは返さない）。
        // 意図的に外すのは、保存済みでアーカイブ済みの種目と、有効な項目が0件の種目だけ
        let storeContext = ModelContext(context.container)
        let all = try storeContext.fetch(FetchDescriptor<Exercise>())
        let idCounts = Dictionary(all.map { ($0.id, 1) }, uniquingKeysWith: +)
        var summaries: [ExerciseSummary] = []
        var hasInconsistentDefinition = false
        var overLimitIDs: [UUID] = []
        var overLimitItems: Set<AIWorkoutProposalLimits.Item> = []
        for exercise in all {
            // 保存済みでアーカイブ済みの種目は、重複や不正な定義があっても送らないので確かめる必要がない
            if exercise.isArchived { continue }
            // 同じIDが複数ある・定義が不正な種目は、どれを送るべきか判断できない
            guard idCounts[exercise.id] == 1, let stored = AIWorkoutDefinitionState(exercise) else {
                hasInconsistentDefinition = true
                continue
            }
            guard !stored.metricSnapshots.isEmpty else { continue }
            // 呼び出し元contextで同じIDがちょうど1件あり、定義（名前・アーカイブ状態・項目）が保存済みと一致すること
            guard let local = try AIWorkoutDefinitionState.uniqueExercise(id: exercise.id, in: context),
                  AIWorkoutDefinitionState(local) == stored else {
                hasInconsistentDefinition = true
                continue
            }
            // 候補の読み込み上限（1セットあたりの値の数・単位のバイト数）を超える種目は、AIが正しく返しても必ず拒否される。
            // かといって黙って外すと、AIが「未登録の種目」と誤認して別の種目を作る提案につながるため、
            // 該当する種目を集めておき、ループの後でカタログ作成全体を失敗させる（一部だけのカタログは返さない）
            var exceeded: Set<AIWorkoutProposalLimits.Item> = []
            if stored.metricSnapshots.count > AIWorkoutProposalLimits.maxValuesPerSet { exceeded.insert(.valuesPerSet) }
            if stored.metricSnapshots.contains(where: { $0.unit.utf8.count > AIWorkoutProposalLimits.maxUnitBytes }) { exceeded.insert(.unitLength) }
            guard exceeded.isEmpty else {
                overLimitIDs.append(exercise.id)
                overLimitItems.formUnion(exceeded)
                continue
            }
            let metrics = stored.metricSnapshots.map {
                MetricSummary(id: $0.id, name: $0.name, unit: $0.unit, allowsDecimal: $0.allowsDecimal, isRequired: $0.isRequired)
            }
            summaries.append(ExerciseSummary(id: exercise.id, name: stored.name, metrics: metrics, metricSnapshots: stored.metricSnapshots))
        }
        // 定義の食い違い・上限超過が1件でもあれば、途中まで作った summaries は捨てて何も返さない。
        // 食い違いを先に報告する（開き直した後の定義でないと、上限超過の判定も確かではないため）
        guard !hasInconsistentDefinition else { throw AIWorkoutProposalError.catalogDefinitionInconsistent }
        guard overLimitIDs.isEmpty else {
            throw AIWorkoutProposalError.catalogExerciseOverLimit(exerciseIDs: overLimitIDs.sorted { $0.uuidString < $1.uuidString }, items: overLimitItems)
        }
        summaries.sort {
            if $0.name == $1.name { return $0.id.uuidString < $1.id.uuidString }
            return $0.name < $1.name
        }
        return AIWorkoutCatalog(exercises: summaries)
    }

    func exercise(id: UUID) -> ExerciseSummary? {
        exercises.first { $0.id == id }
    }

    // 送信用JSON。キー順を固定して、同じ定義なら同じ内容になるようにする
    func requestPayloadJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

// MARK: - 候補読み込みの安全上限

// AIの応答は信頼できない入力なので、読み込む大きさに上限を設ける。
// ここの値はメモリ枯渇や巨大な確認画面を防ぐための「実装上の安全上限」で、1日に記録できる量の仕様として
// 決めたものではない（数値の上限などの利用上の仕様は docs/design-doc.md で未確定のまま）。
// 各値の根拠:
// - maxValueBytes: MetricInput は千倍した値を Int64 に収めるので、整数部は最大16桁。小数点と小数3桁を足した20バイトを
//   超える文字列は、先頭に0を並べた場合を除いて解釈できない
// - maxEntries / maxSetsPerEntry / maxTotalValues: 生成するdraftの大きさを抑えるための値。
//   20種目×50セット×2項目 = 2,000値 を受け付けられる範囲とし、値の総数は maxTotalValues で別に抑える
//   （各上限を掛け合わせた 20×50×16 = 16,000値 までは許さない）
// - maxValuesPerSet / maxUnitBytes: カタログ作成時にも同じ上限で確かめる。超える種目があれば、その種目を外して送るのではなく
//   カタログ作成全体を明示エラーで止める（外すとAIが未登録と誤認し、別種目の作成につながりうるため）
// - maxResponseBytes: 上の上限いっぱいの候補を、整形（インデント）や \uXXXX エスケープ付きで書いても収まる大きさ。
//   そのような候補はおよそ0.7MB以下なので、余裕を持たせて1MiBとする（テストで上限いっぱいの候補が収まることを確かめている）
enum AIWorkoutProposalLimits {
    // どの上限を超えたか。AIの出力内容そのものはエラーに含めない
    // （Hashable はカタログ作成エラーで Set にまとめるため）
    enum Item: Hashable {
        case responseSize
        case entries
        case setsPerEntry
        case valuesPerSet
        case totalValues
        case valueLength
        case unitLength

        var label: String {
            switch self {
            case .responseSize: "応答の大きさ"
            case .entries: "種目の数"
            case .setsPerEntry: "1種目あたりのセット数"
            case .valuesPerSet: "1セットあたりの値の数"
            case .totalValues: "値の総数"
            case .valueLength: "値の長さ"
            case .unitLength: "単位の長さ"
            }
        }
    }

    static let maxResponseBytes = 1_048_576
    static let maxEntries = 20
    static let maxSetsPerEntry = 50
    static let maxValuesPerSet = 16
    static let maxTotalValues = 2_000
    static let maxValueBytes = 20
    static let maxUnitBytes = 64
}

// MARK: - AIの構造化候補

// AIが返す記録候補。表示用の文章とは別に受け取り、知らないフィールドがあれば読み込み自体を失敗させる。
// 配列の要素数と文字列の長さは AIWorkoutProposalLimits の上限を超えた時点で読み込みをやめる
struct AIWorkoutProposal: Decodable, Equatable {
    static let createWorkoutKind = "createWorkout"

    struct Entry: Decodable, Equatable {
        let exerciseID: UUID
        let sets: [SetProposal]

        init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(allowed: ["exerciseID", "sets"])
            let container = try decoder.container(keyedBy: CodingKeys.self)
            exerciseID = try container.decode(UUID.self, forKey: .exerciseID)
            sets = try container.decodeArray(SetProposal.self, forKey: .sets, limit: AIWorkoutProposalLimits.maxSetsPerEntry, item: .setsPerEntry)
        }

        private enum CodingKeys: String, CodingKey {
            case exerciseID, sets
        }
    }

    struct SetProposal: Decodable, Equatable {
        let values: [Value]

        init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(allowed: ["values"])
            let container = try decoder.container(keyedBy: CodingKeys.self)
            values = try container.decodeArray(Value.self, forKey: .values, limit: AIWorkoutProposalLimits.maxValuesPerSet, item: .valuesPerSet)
        }

        private enum CodingKeys: String, CodingKey {
            case values
        }
    }

    // 値は現行フォームと同じく文字列で受け取り、MetricInputで検証する。
    // 単位はAIが発言から読み取ったものを返してもらい、項目の単位と一致するか確かめる（自動換算はしない）
    struct Value: Decodable, Equatable {
        let metricID: UUID
        let value: String
        let unit: String

        init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(allowed: ["metricID", "value", "unit"])
            let container = try decoder.container(keyedBy: CodingKeys.self)
            metricID = try container.decode(UUID.self, forKey: .metricID)
            value = try container.decode(String.self, forKey: .value)
            unit = try container.decode(String.self, forKey: .unit)
            // 長さはUTF-8のバイト数で数える（文字数より実際のメモリ量に近く、エスケープの有無にも左右されない）
            guard value.utf8.count <= AIWorkoutProposalLimits.maxValueBytes else { throw AIWorkoutProposalError.limitExceeded(.valueLength) }
            guard unit.utf8.count <= AIWorkoutProposalLimits.maxUnitBytes else { throw AIWorkoutProposalError.limitExceeded(.unitLength) }
        }

        private enum CodingKeys: String, CodingKey {
            case metricID, value, unit
        }
    }

    let kind: String
    let day: String
    let entries: [Entry]

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: ["kind", "day", "entries"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        day = try container.decode(String.self, forKey: .day)
        entries = try container.decodeArray(Entry.self, forKey: .entries, limit: AIWorkoutProposalLimits.maxEntries, item: .entries)
        // 各配列の上限内でも、掛け合わせると大きくなるので値の総数を別に確かめる
        let totalValues = entries.reduce(0) { total, entry in entry.sets.reduce(total) { $0 + $1.values.count } }
        guard totalValues <= AIWorkoutProposalLimits.maxTotalValues else { throw AIWorkoutProposalError.limitExceeded(.totalValues) }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, day, entries
    }

    // 型の不一致・必須キーの欠落・未知のキーはすべて malformed にまとめる。
    // AIの出力内容をエラーメッセージやログへ流さないため、元のDecodingErrorは返さない。
    // 上限超過だけはどの上限かを区別して返す（内容は含めない）。依頼を分ければやり直せるため
    static func decode(from data: Data) throws -> AIWorkoutProposal {
        // JSONの解析は全体を一度に読み込むので、解析を始める前に大きさを確かめる
        guard data.count <= AIWorkoutProposalLimits.maxResponseBytes else { throw AIWorkoutProposalError.limitExceeded(.responseSize) }
        do {
            return try JSONDecoder().decode(AIWorkoutProposal.self, from: data)
        } catch let error as AIWorkoutProposalError {
            throw error
        } catch {
            throw AIWorkoutProposalError.malformed
        }
    }
}

private extension KeyedDecodingContainer {
    // 要素数の上限つきで配列を読む。上限を超える配列は、要素を構造体に変換する前に拒否する
    func decodeArray<T: Decodable>(_ type: T.Type, forKey key: Key, limit: Int, item: AIWorkoutProposalLimits.Item) throws -> [T] {
        var container = try nestedUnkeyedContainer(forKey: key)
        if let count = container.count, count > limit { throw AIWorkoutProposalError.limitExceeded(item) }
        var elements: [T] = []
        // count が分からない場合に備えて、読みながらも数を確かめる
        while !container.isAtEnd {
            guard elements.count < limit else { throw AIWorkoutProposalError.limitExceeded(item) }
            elements.append(try container.decode(T.self))
        }
        return elements
    }
}

// 任意の文字列キーでcontainerを開き、許可したキー以外が含まれていないか調べるためのキー型
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private extension Decoder {
    func rejectUnknownKeys(allowed: Set<String>) throws {
        let container = try container(keyedBy: AnyCodingKey.self)
        guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: codingPath, debugDescription: "unknown key"))
        }
    }
}

// MARK: - 定義の比較

// カタログ作成・候補検証で、種目の定義を context ごとに比べるための値。
// 項目IDの重複や他の種目に属する項目を持つ種目は整合性を判断できないので、作れない(nil)ようにしている
private struct AIWorkoutDefinitionState: Equatable {
    let name: String
    let isArchived: Bool
    let metricSnapshots: [MetricDefinitionSnapshot]

    @MainActor init?(_ exercise: Exercise) {
        let metricIDs = exercise.metrics.map(\.id)
        guard Set(metricIDs).count == metricIDs.count,
              exercise.metrics.allSatisfy({ $0.exercise?.id == exercise.id }) else { return nil }
        name = exercise.name
        isArchived = exercise.isArchived
        metricSnapshots = WorkoutEntryDraft(exercise: exercise).metricSnapshots
    }

    // 同じIDの種目がちょうど1件あるときだけ返す（0件は削除済み、2件以上は整合性を判断できない）
    @MainActor static func uniqueExercise(id: UUID, in context: ModelContext) throws -> Exercise? {
        let matches = try context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == id }))
        return matches.count == 1 ? matches.first : nil
    }
}

// MARK: - 検証

@MainActor enum AIWorkoutProposalValidation {
    // 候補を検証し、確認画面に出すためのdraftを作る。この段階では context に何も挿入・保存しない。
    // catalog はAIへ送ったものを渡す。送っていない種目や、送信後に定義が変わった種目は保存対象にしない。
    // fileprivate にして、このファイルの外（UI・@testable import したテストを含む）からは呼べないようにしている。
    // 外からreviewを得る経路を AIWorkoutProposalCoordinator.review(for:...) だけにし、同じ応答から別々のreviewを作らせないため
    fileprivate static func makeReview(for proposal: AIWorkoutProposal, catalog: AIWorkoutCatalog, in context: ModelContext, calendar: Calendar = .current, now: Date = .now) throws -> AIWorkoutProposalReview {
        guard !context.hasChanges else { throw AIWorkoutProposalError.unsavedContext }
        guard proposal.kind == AIWorkoutProposal.createWorkoutKind else { throw AIWorkoutProposalError.unsupportedKind }
        guard let day = date(from: proposal.day, calendar: calendar) else { throw AIWorkoutProposalError.invalidDay }
        guard calendar.startOfDay(for: day) <= calendar.startOfDay(for: now) else { throw AIWorkoutProposalError.futureDay }
        guard !proposal.entries.isEmpty else { throw AIWorkoutProposalError.emptyEntries }
        guard Set(proposal.entries.map(\.exerciseID)).count == proposal.entries.count else { throw AIWorkoutProposalError.duplicateExercise }

        // 呼び出し元contextの登録済みモデルは、別contextで保存された変更（アーカイブ・名前・項目定義・削除）を
        // 反映していないことがある。保存済みの定義は新しいcontextから読み、呼び出し元contextの定義とも突き合わせる
        // （V1保存境界と同じ二重確認。どちらか一方だけでは古い定義を見逃す）
        let storeContext = ModelContext(context.container)
        var drafts: [WorkoutEntryDraft] = []
        for entry in proposal.entries {
            guard let sent = catalog.exercise(id: entry.exerciseID) else { throw AIWorkoutProposalError.unknownExercise }
            guard let storedExercise = try AIWorkoutDefinitionState.uniqueExercise(id: entry.exerciseID, in: storeContext),
                  let stored = AIWorkoutDefinitionState(storedExercise),
                  let live = try AIWorkoutDefinitionState.uniqueExercise(id: entry.exerciseID, in: context),
                  AIWorkoutDefinitionState(live) == stored,
                  !stored.isArchived, stored.name == sent.name, stored.metricSnapshots == sent.metricSnapshots else {
                throw AIWorkoutProposalError.staleDefinition
            }
            // draftは保存時に使う呼び出し元contextのモデルから作る（定義は上で保存済みの定義と一致を確認済み）
            var draft = WorkoutEntryDraft(exercise: live)
            guard !entry.sets.isEmpty else { throw AIWorkoutProposalError.emptySets }

            // 項目IDの重複はAIWorkoutDefinitionStateで除外済みなので、uniqueKeysWithValuesでも落ちない
            let metricsByID = Dictionary(uniqueKeysWithValues: draft.metricSnapshots.map { ($0.id, $0) })
            var sets: [WorkoutSetDraft] = []
            for set in entry.sets {
                var values: [UUID: String] = [:]
                for value in set.values {
                    guard let metric = metricsByID[value.metricID] else { throw AIWorkoutProposalError.unknownMetric }
                    guard values[value.metricID] == nil else { throw AIWorkoutProposalError.duplicateMetric }
                    guard value.unit == metric.unit else { throw AIWorkoutProposalError.unitMismatch }
                    // 前後の空白も含めて受け付けない。MetricInputは空白を取り除いてから解釈するため、ここで先に弾く
                    guard value.value == value.value.trimmingCharacters(in: .whitespacesAndNewlines),
                          MetricInput.parse(value.value, allowsDecimal: metric.allowsDecimal) != nil else {
                        throw AIWorkoutProposalError.invalidValue
                    }
                    values[value.metricID] = value.value
                }
                // 任意項目は省略を許し、nilのまま保存する（0とは区別する）
                guard draft.metricSnapshots.allSatisfy({ !$0.isRequired || values[$0.id] != nil }) else {
                    throw AIWorkoutProposalError.missingRequiredValue
                }
                sets.append(WorkoutSetDraft(values: values))
            }
            draft.sets = sets
            drafts.append(draft)
        }

        // 通常フォームと同じ検証にも通しておく（ここで失敗するなら上の検証との食い違いなので保存させない）
        guard case .success = WorkoutSetDraftEditing.validatedEntries(drafts) else { throw AIWorkoutProposalError.invalidValue }
        // 検証に使ったcontextのcontainerをreviewに結び付け、承認はそのcontainerのcontextでだけ受け付ける
        return AIWorkoutProposalReview(day: day, entries: drafts, calendar: calendar, container: context.container)
    }

    // "yyyy-MM-dd" だけを受け付ける。2026-02-30 のような存在しない日付は、往復変換が一致しないので拒否する
    static func date(from text: String, calendar: Calendar) -> Date? {
        guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              Workout.dayString(from: date, calendar: calendar) == text else { return nil }
        return date
    }
}

enum AIWorkoutProposalError: LocalizedError, Equatable {
    case unsavedContext
    case malformed
    case unsupportedKind
    case invalidDay
    case futureDay
    case emptyEntries
    case duplicateExercise
    case unknownExercise
    case staleDefinition
    case emptySets
    case unknownMetric
    case duplicateMetric
    case unitMismatch
    case invalidValue
    case missingRequiredValue
    case limitExceeded(AIWorkoutProposalLimits.Item)
    // カタログ作成時に、安全上限を超える種目があった。画面で該当種目を示せるようIDを持つが、
    // 種目名は記録内容に近い情報なのでメッセージには入れない
    case catalogExerciseOverLimit(exerciseIDs: [UUID], items: Set<AIWorkoutProposalLimits.Item>)
    // カタログ作成時に、送る対象の種目の定義が呼び出し元contextと保存済みで食い違う、または同じIDが重複している・定義が不正で
    // 確かめられなかった。画面を開き直せば回復できる。種目名は記録内容に近い情報なのでメッセージには入れない
    case catalogDefinitionInconsistent

    var errorDescription: String? {
        switch self {
        case .unsavedContext: "未保存の変更があります。先に保存してからやり直してください。"
        case .malformed: "AIの記録候補を読み取れませんでした。"
        case let .limitExceeded(item): "AIの記録候補の\(item.label)が、この機能の実装上の安全上限（記録できる量の仕様ではありません）を超えたため、読み込みませんでした。内容を分けて依頼し直してください。"
        case let .catalogExerciseOverLimit(exerciseIDs, items):
            Self.catalogOverLimitMessage(exerciseCount: exerciseIDs.count, items: items)
        case .catalogDefinitionInconsistent: "種目または記録項目が別の場所で変更されたため、AIに送る種目一覧を作れませんでした。画面を開き直してからやり直してください。"
        case .unsupportedKind: "この種類の操作には対応していません。"
        case .invalidDay: "実施日を読み取れませんでした。"
        case .futureDay: "未来の日付は記録できません。"
        case .emptyEntries: "記録する種目が含まれていません。"
        case .duplicateExercise: "同じ種目が重複しています。"
        case .unknownExercise: "登録済みの種目に当てはまりませんでした。"
        case .staleDefinition: "種目または記録項目が変更されています。もう一度依頼してください。"
        case .emptySets: "セットが含まれていません。"
        case .unknownMetric: "種目にない記録項目が含まれています。"
        case .duplicateMetric: "同じ記録項目が1つのセットに重複しています。"
        case .unitMismatch: "単位が記録項目と一致しません。換算せずに保存を中止しました。"
        case .invalidValue: "0以上の有効な数値ではない値が含まれています。"
        case .missingRequiredValue: "必須の記録項目の値が足りません。"
        }
    }

    // どの上限を超えたかを、上限の値と一緒に説明する（Setは順序を持たないので、決まった順で確かめて文を組み立てる）
    private static func catalogOverLimitMessage(exerciseCount: Int, items: Set<AIWorkoutProposalLimits.Item>) -> String {
        var reasons: [String] = []
        if items.contains(.valuesPerSet) { reasons.append("有効な記録項目が\(AIWorkoutProposalLimits.maxValuesPerSet)個を超える") }
        if items.contains(.unitLength) { reasons.append("単位がUTF-8で\(AIWorkoutProposalLimits.maxUnitBytes)バイトを超える") }
        return "登録済みの種目のうち\(exerciseCount)件が、AIへ送る種目定義の実装上の安全上限（記録項目の仕様ではありません）を超えています"
            + "（\(reasons.joined(separator: "、"))）。"
            + "一部の種目を除いて送ると未登録の種目と誤認されるおそれがあるため、送信を中止しました。"
            + "該当する種目の記録項目または単位を見直してください。"
    }
}

// MARK: - 確認用draftと承認

// 確認画面で表示・修正し、承認またはキャンセルするための候補。
// 参照型(class)にして、値型のコピーから同じインスタンスの承認状態を迂回できないようにしている。
// 作成(makeReview)と承認(approve)はどちらも fileprivate で、このファイルの外からは呼べない（コンパイルエラーになる）。
// そのため外からは AIWorkoutProposalCoordinator を通してしかreviewを作れず、承認もできない。
// 外へ公開しているのは、確認画面に必要な値の読み取り・修正(setValue)・検証メッセージ・キャンセルだけ。
// 応答の再送・再生成に対する二重登録の防止は、同一アプリセッション内の同じcoordinatorインスタンスの範囲に限られる
// （coordinatorを複数作った場合・アプリ再起動後の再送は防げない。coordinatorの説明を参照）
@MainActor final class AIWorkoutProposalReview: Identifiable {
    enum State: Equatable {
        case pending
        case saving
        case saved(workoutID: UUID)
        case cancelled
    }

    let id = UUID()
    let day: Date
    let calendar: Calendar
    private(set) var entries: [WorkoutEntryDraft]
    private(set) var state: State = .pending
    // 検証に使ったcontextのcontainer。承認時に、これと同じインスタンス（===）のcontainerのcontextだけを受け付ける。
    // coordinator側の照合（storeMismatch）に加えた二重の防御で、coordinatorの外からは参照できない。
    // 強参照で持つのは、解放後に別のcontainerが同じメモリ番地を再利用して一致と誤判定されるのを防ぐため
    private let container: ModelContainer

    var dayString: String {
        Workout.dayString(from: day, calendar: calendar)
    }

    // 生成は検証(AIWorkoutProposalValidation.makeReview)からだけ行う
    fileprivate init(day: Date, entries: [WorkoutEntryDraft], calendar: Calendar, container: ModelContainer) {
        self.day = day
        self.entries = entries
        self.calendar = calendar
        self.container = container
    }

    // 確認中の値の修正。既存のセット・項目の値だけを書き換えられ、項目やセットの追加はできない
    func setValue(_ value: String, exerciseID: UUID, setID: UUID, metricID: UUID) throws {
        guard state == .pending else { throw AIWorkoutProposalReviewError.notEditable }
        guard let entryIndex = entries.firstIndex(where: { $0.exerciseID == exerciseID }),
              let setIndex = entries[entryIndex].sets.firstIndex(where: { $0.id == setID }),
              entries[entryIndex].metricSnapshots.contains(where: { $0.id == metricID }) else {
            throw AIWorkoutProposalReviewError.unknownField
        }
        entries[entryIndex].sets[setIndex].values[metricID] = value
    }

    // 修正後の値を通常フォームと同じ規則で検証し、問題があれば表示用のメッセージを返す
    func validationMessage() -> String? {
        if case let .failure(error) = WorkoutSetDraftEditing.validatedEntries(entries) { return error.message }
        return nil
    }

    func cancel() throws {
        switch state {
        case .pending: state = .cancelled
        case .cancelled: break
        case .saving, .saved: throw AIWorkoutProposalReviewError.notEditable
        }
    }

    // 承認時の保存。必ず通常V1の保存境界を通し、最新の定義と修正後の値をもう一度検証する。
    // fileprivate なので、呼べるのはこのファイル内の AIWorkoutProposalCoordinator.approve だけ。
    // 検証時とは別のcontainerのcontextは、状態の確認・保存より前に拒否する（状態もstoreも変えない）。
    // 成功したら saved になり、このインスタンスでの再承認は拒否する。
    // 失敗時は pending に戻して修正・再試行できるようにする
    fileprivate func approve(in context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }) throws -> Workout {
        guard context.container === container else { throw AIWorkoutProposalReviewError.storeMismatch }
        switch state {
        case .pending: break
        case .saving: throw AIWorkoutProposalReviewError.inProgress
        case .saved: throw AIWorkoutProposalReviewError.alreadySaved
        case .cancelled: throw AIWorkoutProposalReviewError.cancelled
        }
        state = .saving
        do {
            let workout = try WorkoutCreationV1.save(day: day, entries: entries, in: context, calendar: calendar, persist: persist)
            state = .saved(workoutID: workout.id)
            return workout
        } catch {
            state = .pending
            throw error
        }
    }
}

enum AIWorkoutProposalReviewError: LocalizedError, Equatable {
    case notEditable
    case unknownField
    case inProgress
    case alreadySaved
    case cancelled
    // 検証時とは別のcontainer（store）のcontextで承認しようとした
    case storeMismatch

    var errorDescription: String? {
        switch self {
        case .notEditable: "この候補は確認中ではないため変更できません。"
        case .unknownField: "修正しようとした項目が候補にありません。"
        case .inProgress: "保存処理中です。"
        case .alreadySaved: "この候補は保存済みです。"
        case .cancelled: "この候補はキャンセルされています。"
        case .storeMismatch: "確認を始めたときとは別の保存先が指定されたため、保存を中止しました。"
        }
    }
}

// MARK: - リクエスト単位の一元管理

// 同じAIの応答から確認用draftを何度も作って二重に記録しないよう、リクエストIDごとにreviewを1つだけ持つ。
// 保証する範囲と限界:
// - 対象は「同じアプリセッション内で、同じcoordinatorインスタンスを通した操作」だけ。
//   AIWorkoutProposalValidation.makeReview と review.approve は fileprivate なので、このファイルの外からは
//   このcoordinatorを通さずにreviewを作ることも承認することもできない（UIへの配線は未実装）。
//   ただしcoordinatorを複数作るとそれぞれ別の管理になり、互いの二重登録は防げない
// - 状態はメモリ上にだけあり、アプリを再起動すると失われる。再起動後に同じ応答を受け取った場合の二重登録は防げない
//   （防ぐにはリクエストIDの永続化が必要で、データベースモデルの追加・スキーマ移行を伴うため扱っていない）
// - 1つのIDは、beginRequestに渡したcontextのcontainer（store）に結び付く。review・承認は同じcontainerの別contextでもよいが、
//   別のcontainerのcontextは、種目・項目のIDや定義がまったく同じでも storeMismatch で拒否する。
//   この拒否は応答の固定・review作成・保存より前に行い、管理情報もどちらのstoreも変えない。
//   review自身も検証時のcontainerを持ち、承認時に別containerを拒否する（こちらの照合を先に通るので、通常は届かない二重の防御）
// - 異なるリクエストIDは、応答の内容が同じでも別の依頼として独立に記録できる（同じ内容の運動を2回行うことがあるため）。
//   通信の自動再試行など「同じ送信のやり直し」では、新しいIDを発行せず同じIDを使い続ける必要がある
// 各操作の扱い:
// - 応答: 1つのIDにつき最初に渡された応答だけを受け付ける。異なる応答は、検証に失敗した後でも conflictingResponse で拒否する。
//   同じ応答を何度渡しても、作成済みのreviewを返して作り直さない（確認中の修正も失われない）
// - 検証の失敗: 同じ応答で試し直せる（未保存の変更を保存した後など）。送ったカタログはIDに固定され、差し替えられない
// - 保存の失敗: reviewは確認中に戻り、同じreviewで再試行できる。定義の競合（staleDefinition）は再試行しても通らないので、
//   キャンセルして新しいリクエストから依頼し直す
// - 保存の成功: 以後、同じIDでのreview取得・承認・キャンセルをすべて alreadySaved で拒否する
// - キャンセル: そのIDは終了し、後から届いた応答や承認も cancelled で拒否する。記録するには新しいリクエストを始める
@MainActor final class AIWorkoutProposalCoordinator {
    enum Status: Equatable {
        case awaitingResponse
        case reviewing
        case saved(workoutID: UUID)
        case cancelled
    }

    // 発行したリクエストID と、そのIDでAIへ送るカタログの組
    struct Request {
        let id: UUID
        let catalog: AIWorkoutCatalog
    }

    private struct Slot {
        // beginRequestに渡したcontextのcontainer。IDではなくインスタンスの同一性（===）で照合する。
        // 強参照で持つのは、解放後に別のcontainerが同じメモリ番地を再利用して一致と誤判定されるのを防ぐため
        let container: ModelContainer
        let catalog: AIWorkoutCatalog
        var proposal: AIWorkoutProposal?
        var review: AIWorkoutProposalReview?
        // reviewを作る前（応答待ち・検証失敗の後）にキャンセルされたか。review作成後のキャンセルはreviewの状態で表す
        var cancelledWithoutReview = false

        // 状態はreviewから決める。外から呼べる review.cancel を直接呼ばれた場合も、キャンセル済みとして扱うため
        // 入れ子の型は外側の @MainActor を引き継がないため、MainActor隔離の review.state を読むここにも明示する
        @MainActor var status: Status {
            if cancelledWithoutReview { return .cancelled }
            switch review?.state {
            case nil: return .awaitingResponse
            case .pending, .saving: return .reviewing
            case let .saved(workoutID): return .saved(workoutID: workoutID)
            case .cancelled: return .cancelled
            }
        }
    }

    // 保存済み・キャンセル済みのIDも、再承認を拒否するためにセッション中は消さない
    private var slots: [UUID: Slot] = [:]

    // カタログを作り、新しいリクエストIDと結び付ける。IDはcoordinatorだけが発行する
    // （呼び出し側が任意のIDを作れると、再生成のたびに新しいIDを使って管理を迂回できてしまうため）
    func beginRequest(in context: ModelContext) throws -> Request {
        let catalog = try AIWorkoutCatalog.make(in: context)
        let id = UUID()
        slots[id] = Slot(container: context.container, catalog: catalog)
        return Request(id: id, catalog: catalog)
    }

    func status(of requestID: UUID) -> Status? {
        slots[requestID]?.status
    }

    // そのIDの応答から確認用のreviewを返す。作成済みなら同じインスタンスを返し、作り直さない
    func review(for requestID: UUID, proposal: AIWorkoutProposal, in context: ModelContext, calendar: Calendar = .current, now: Date = .now) throws -> AIWorkoutProposalReview {
        let slot = try openSlot(requestID, in: context)
        if let bound = slot.proposal, bound != proposal { throw AIWorkoutProposalCoordinatorError.conflictingResponse }
        if let review = slot.review { return review }
        // 検証より先に応答をIDへ固定する（検証に失敗した後で、別の応答に差し替えさせないため）
        slots[requestID]?.proposal = proposal
        let review = try AIWorkoutProposalValidation.makeReview(for: proposal, catalog: slot.catalog, in: context, calendar: calendar, now: now)
        slots[requestID]?.review = review
        return review
    }

    // 承認時の保存。外から承認できる唯一の入口。保存そのものと失敗時の扱いはreviewの approve に任せる（失敗すれば確認中に戻る）
    func approve(_ requestID: UUID, in context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }) throws -> Workout {
        guard let review = try openSlot(requestID, in: context).review else { throw AIWorkoutProposalCoordinatorError.noReview }
        return try review.approve(in: context, persist: persist)
    }

    // 何度呼んでもよい。保存処理中はreviewの cancel が notEditable で拒否する
    func cancel(_ requestID: UUID) throws {
        guard let slot = slots[requestID] else { throw AIWorkoutProposalCoordinatorError.unknownRequest }
        switch slot.status {
        case .cancelled: return
        case let .saved(workoutID): throw AIWorkoutProposalCoordinatorError.alreadySaved(workoutID: workoutID)
        case .awaitingResponse: slots[requestID]?.cancelledWithoutReview = true
        case .reviewing: try slot.review?.cancel()
        }
    }

    // まだ終了していない（保存済み・キャンセル済みでない）IDの管理情報を返す。
    // containerの照合は状態の確認より先に行い、別storeのcontextには状態に関係なく storeMismatch を返す
    // （ここでは読むだけで、slotもstoreも変えない）
    private func openSlot(_ requestID: UUID, in context: ModelContext) throws -> Slot {
        guard let slot = slots[requestID] else { throw AIWorkoutProposalCoordinatorError.unknownRequest }
        guard context.container === slot.container else { throw AIWorkoutProposalCoordinatorError.storeMismatch }
        switch slot.status {
        case let .saved(workoutID): throw AIWorkoutProposalCoordinatorError.alreadySaved(workoutID: workoutID)
        case .cancelled: throw AIWorkoutProposalCoordinatorError.cancelled
        case .awaitingResponse, .reviewing: return slot
        }
    }
}

// AIの応答内容はメッセージに含めない
enum AIWorkoutProposalCoordinatorError: LocalizedError, Equatable {
    // このcoordinatorが発行していないID（別のcoordinator・アプリ再起動前のIDを含む）
    case unknownRequest
    // 同じIDに、最初とは異なる応答が渡された
    case conflictingResponse
    case alreadySaved(workoutID: UUID)
    case cancelled
    // 応答からreviewを作る前に承認しようとした
    case noReview
    // beginRequestとは別のcontainer（store）のcontextで、reviewの作成や承認をしようとした
    case storeMismatch

    var errorDescription: String? {
        switch self {
        case .unknownRequest: "この依頼は見つかりませんでした。もう一度依頼してください。"
        case .conflictingResponse: "同じ依頼に対して異なる記録候補を受け取ったため、読み込みませんでした。もう一度依頼してください。"
        case .alreadySaved: "この依頼の記録は保存済みです。"
        case .cancelled: "この依頼はキャンセルされています。"
        case .noReview: "確認する記録候補がまだありません。"
        case .storeMismatch: "依頼を始めたときとは別の保存先が指定されたため、処理を中止しました。もう一度依頼してください。"
        }
    }
}
