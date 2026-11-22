import Foundation
import SwiftData

enum ExerciseNameEditing {
    static func validatedName(_ name: String) -> String? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func save(_ name: String, for exercise: Exercise, persist: () throws -> Void) throws {
        guard let cleaned = validatedName(name) else { throw ExerciseNameEditError.emptyName }
        let originalName = exercise.name
        exercise.name = cleaned
        do {
            try persist()
        } catch {
            exercise.name = originalName
            throw error
        }
    }
}

enum ExerciseNameEditError: LocalizedError {
    case emptyName

    var errorDescription: String? { "種目名を入力してください。" }
}

// 画面からの種目名保存境界。種目名はV2でもrevision対象外のため、通常V1と隔離V2で共用する。
// clean contextのみ許可し、無関係な未保存変更をcontext.saveに巻き込まない。
@MainActor enum ExerciseNameEditingInContext {
    static func save(_ name: String, for exercise: Exercise, in context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }) throws {
        // 拒否時は既存の未保存変更を破棄しないよう、rollbackせずにそのまま返す。
        guard !context.hasChanges else { throw ExerciseNameEditingInContextError.unsavedContext }
        guard exercise.modelContext === context else { throw ExerciseNameEditingInContextError.wrongContext }
        do {
            try ExerciseNameEditing.save(name, for: exercise) { try persist(context) }
        } catch {
            // cleanから開始しているため、共通saveが名前を復元した後にrollbackしてもcontextの変更は失われない。
            context.rollback()
            throw error
        }
    }
}

enum ExerciseNameEditingInContextError: LocalizedError, Equatable {
    case unsavedContext
    case wrongContext

    var errorDescription: String? {
        switch self {
        case .unsavedContext: "未保存の変更があるため、種目名を保存できません。先に変更を保存するか、画面を開き直してください。"
        case .wrongContext: "種目名の保存対象が現在のデータ画面に属していません。画面を開き直してください。"
        }
    }
}

struct MetricDefinitionDraft: Identifiable {
    let id: UUID
    let original: MetricDefinitionSnapshot?
    var name: String
    var unit: String
    var allowsDecimal: Bool
    var isRequired: Bool
    var isActive: Bool
    // nilはV1 draftまたはV2 baseline未取得。履歴なしはnoHistoryで明示する。
    var historyBaseline: MetricDefinitionHistoryBaseline?

    init(name: String, unit: String, allowsDecimal: Bool, isRequired: Bool, isActive: Bool = true) {
        id = UUID()
        original = nil
        self.name = name
        self.unit = unit
        self.allowsDecimal = allowsDecimal
        self.isRequired = isRequired
        self.isActive = isActive
        historyBaseline = nil
    }

    init(existing metric: MetricDefinition) {
        id = metric.id
        original = MetricDefinitionSnapshot(metric)
        name = metric.name
        unit = metric.unit
        allowsDecimal = metric.allowsDecimal
        isRequired = metric.isRequired
        isActive = metric.isActive
        historyBaseline = nil
    }
}

enum MetricDefinitionHistoryBaseline: Equatable {
    case latestRevision(UUID)
    case noHistory
}

struct MetricDefinitionSnapshot: Equatable {
    let id: UUID
    let name: String
    let unit: String
    let allowsDecimal: Bool
    let isRequired: Bool
    let isActive: Bool
    let sortOrder: Int

    init(_ metric: MetricDefinition) {
        id = metric.id
        name = metric.name
        unit = metric.unit
        allowsDecimal = metric.allowsDecimal
        isRequired = metric.isRequired
        isActive = metric.isActive
        sortOrder = metric.sortOrder
    }
}

// 永続化候補の改定遷移を表す純粋な入力・出力型。V1モデルには追加情報を持たせない。
struct MetricRevisionSnapshot: Equatable {
    let name: String
    let unit: String
    let allowsDecimal: Bool
    let isRequired: Bool
}

struct MetricRevisionTransitionInput: Equatable {
    let current: MetricRevisionSnapshot
    let proposed: MetricRevisionSnapshot
    let currentSeriesID: UUID
    let proposedRevisionID: UUID
    let proposedSeriesID: UUID
}

enum MetricRevisionTransitionKind: Equatable {
    case unchanged
    case inputConditionsChanged
    case nameOrUnitChanged
}

struct MetricRevisionTransition: Equatable {
    let kind: MetricRevisionTransitionKind
    let revisionID: UUID?
    let seriesID: UUID
}

enum MetricRevisionTransitionDecision {
    static func decide(_ input: MetricRevisionTransitionInput) -> MetricRevisionTransition {
        if input.current.name != input.proposed.name || input.current.unit != input.proposed.unit {
            return MetricRevisionTransition(
                kind: .nameOrUnitChanged,
                revisionID: input.proposedRevisionID,
                seriesID: input.proposedSeriesID
            )
        }

        if input.current.allowsDecimal != input.proposed.allowsDecimal
            || input.current.isRequired != input.proposed.isRequired {
            return MetricRevisionTransition(
                kind: .inputConditionsChanged,
                revisionID: input.proposedRevisionID,
                seriesID: input.currentSeriesID
            )
        }

        return MetricRevisionTransition(kind: .unchanged, revisionID: nil, seriesID: input.currentSeriesID)
    }
}

enum MetricDefinitionEditing {
    static func draft(for exercise: Exercise) -> [MetricDefinitionDraft] {
        exercise.metrics.sorted { $0.sortOrder == $1.sortOrder ? $0.id.uuidString < $1.id.uuidString : $0.sortOrder < $1.sortOrder }.map(MetricDefinitionDraft.init(existing:))
    }

    // 未保存の追加行（original == nil）のうち、IDが一致する行だけを取り除く。
    // 保存済み項目のIDや存在しないIDを渡した場合は何も消さず、残りの行の順序と入力内容は変えない。
    static func removeUnsavedDraft(id: UUID, from drafts: [MetricDefinitionDraft]) -> [MetricDefinitionDraft] {
        drafts.filter { !($0.id == id && $0.original == nil) }
    }

    static func save(_ drafts: [MetricDefinitionDraft], for exercise: Exercise, insert: (MetricDefinition) -> Void = { _ in }, discard: (MetricDefinition) -> Void = { _ in }, persist: () throws -> Void) throws {
        let originalMetrics = exercise.metrics
        let originalSnapshots = originalMetrics.map(MetricDefinitionSnapshot.init)
        let originalByID = Dictionary(uniqueKeysWithValues: originalMetrics.map { ($0.id, $0) })
        guard Set(drafts.map(\.id)).count == drafts.count else { throw MetricDefinitionEditingError.changed }
        guard Set(drafts.filter { $0.original != nil }.map(\.id)) == Set(originalMetrics.map(\.id)) else { throw MetricDefinitionEditingError.changed }
        guard drafts.allSatisfy({ draft in
            if let original = draft.original {
                return originalByID[draft.id].map(MetricDefinitionSnapshot.init) == original
                    && draft.name == original.name && draft.unit == original.unit
                    && draft.allowsDecimal == original.allowsDecimal && draft.isRequired == original.isRequired
            }
            return originalByID[draft.id] == nil
        }) else { throw MetricDefinitionEditingError.changed }

        let cleaned = drafts.map { draft -> (MetricDefinitionDraft, String, String) in
            (draft, draft.name.trimmingCharacters(in: .whitespacesAndNewlines), draft.unit.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ !$0.1.isEmpty && !$0.2.isEmpty }),
              Set(cleaned.map { $0.1.lowercased() }).count == cleaned.count else {
            throw MetricDefinitionEditingError.invalid
        }
        let additions = cleaned.filter { $0.0.original == nil }
        let maximumOrder = originalMetrics.map(\.sortOrder).max() ?? -1
        let (lastOrder, overflow) = maximumOrder.addingReportingOverflow(additions.count)
        guard !overflow, additions.isEmpty || lastOrder >= maximumOrder else { throw MetricDefinitionEditingError.sortOrderOverflow }

        var inserted: [MetricDefinition] = []
        var nextOrder = maximumOrder
        for (draft, name, unit) in cleaned {
            if let metric = originalByID[draft.id] {
                metric.isActive = draft.isActive
            } else {
                let (order, orderOverflow) = nextOrder.addingReportingOverflow(1)
                guard !orderOverflow else { throw MetricDefinitionEditingError.sortOrderOverflow }
                let metric = MetricDefinition(name: name, unit: unit, allowsDecimal: draft.allowsDecimal, isRequired: draft.isRequired, sortOrder: order)
                metric.isActive = draft.isActive
                insert(metric)
                inserted.append(metric)
                nextOrder = order
            }
        }
        exercise.metrics.append(contentsOf: inserted)
        do {
            try persist()
        } catch {
            exercise.metrics = originalMetrics
            for (metric, snapshot) in zip(originalMetrics, originalSnapshots) {
                metric.name = snapshot.name
                metric.unit = snapshot.unit
                metric.allowsDecimal = snapshot.allowsDecimal
                metric.isRequired = snapshot.isRequired
                metric.isActive = snapshot.isActive
                metric.sortOrder = snapshot.sortOrder
            }
            inserted.forEach(discard)
            throw error
        }
    }
}

enum MetricDefinitionEditingError: LocalizedError {
    case invalid
    case changed
    case sortOrderOverflow

    var errorDescription: String? {
        switch self {
        case .invalid: "種目名・項目名・単位を入力してください。項目名は重複できません。"
        case .changed: "項目定義が別の画面で変更されました。画面を開き直してから再度お試しください。"
        case .sortOrderOverflow: "項目の表示順の上限に達したため、追加できません。"
        }
    }
}

// 通常V1のアプリ保存境界。clean contextのみ許可し、対象モデルの所有者も照合する。
@MainActor enum MetricDefinitionEditingV1 {
    static func save(_ drafts: [MetricDefinitionDraft], for exercise: Exercise, in context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard !context.hasChanges else { throw MetricDefinitionEditingV1Error.unsavedContext }
        guard exercise.modelContext === context else { throw MetricDefinitionEditingV1Error.wrongContext }
        do {
            try MetricDefinitionEditing.save(
                drafts, for: exercise,
                insert: { context.insert($0) },
                discard: { context.delete($0) },
                persist: { try persist(context) }
            )
        } catch {
            // 共通saveがsnapshot復元と追加項目の破棄を終えた後にcontextをcleanに戻す。
            context.rollback()
            throw error
        }
    }
}

enum MetricDefinitionEditingV1Error: LocalizedError, Equatable {
    case unsavedContext
    case wrongContext

    var errorDescription: String? {
        switch self {
        case .unsavedContext: "未保存の変更があるため、項目定義を保存できません。先に変更を保存するか、画面を開き直してください。"
        case .wrongContext: "項目定義の保存対象が現在のデータ画面に属していません。画面を開き直してください。"
        }
    }
}

// V2実験ストアの既存項目編集境界。通常ストアからは呼び出さない。
@MainActor enum MetricDefinitionEditingV2 {
    private static func hasUniqueRevisionNumbers(_ revisions: [MetricDefinitionRevision]) -> Bool {
        Set(revisions.map(\.revision)).count == revisions.count
    }

    static func draft(for exercise: Exercise, in context: ModelContext) throws -> [MetricDefinitionDraft] {
        guard !context.hasChanges else { throw MetricDefinitionEditingV2Error.unsavedContext }
        let readContext = ModelContext(context.container)
        let exerciseID = exercise.id
        let exercises = try readContext.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID }))
        guard exercises.count == 1, let latestExercise = exercises.first,
              latestExercise.persistentModelID == exercise.persistentModelID,
              latestExercise.metrics.map(MetricDefinitionSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString })
                == exercise.metrics.map(MetricDefinitionSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) else {
            throw MetricDefinitionEditingV2Error.changed
        }
        let history = try readContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
        var drafts = MetricDefinitionEditing.draft(for: exercise)
        for index in drafts.indices {
            let revisions = history.filter { $0.metricID == drafts[index].id }
            guard hasUniqueRevisionNumbers(revisions) else {
                throw MetricValueRevisionLinkingError.duplicateRevision
            }
            if let latest = revisions.max(by: { $0.revision < $1.revision }) {
                guard let metric = latestExercise.metrics.first(where: { $0.id == drafts[index].id }),
                      MetricValueRevisionLinking.matchesSnapshot(metric, revision: latest) else {
                    throw MetricValueRevisionLinkingError.snapshotMismatch
                }
                drafts[index].historyBaseline = .latestRevision(latest.id)
            } else {
                drafts[index].historyBaseline = .noHistory
            }
        }
        return drafts
    }

    static func save(_ drafts: [MetricDefinitionDraft], for exercise: Exercise, in context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard !context.hasChanges else { throw MetricDefinitionEditingV2Error.unsavedContext }

        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        guard let storedExercise = exercises.first(where: { $0.id == exercise.id }),
              storedExercise.persistentModelID == exercise.persistentModelID else {
            throw MetricDefinitionEditingV2Error.changed
        }
        // 同じcontainerの新しいcontextから永続store上の現在値を読み、古いcontextのキャッシュを検査する。
        let readContext = ModelContext(context.container)
        let exerciseID = exercise.id
        let latestExercises = try readContext.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID }))
        guard let latestExercise = latestExercises.first,
              latestExercises.count == 1 else {
            throw MetricDefinitionEditingV2Error.changed
        }
        let contextMetrics = exercise.metrics
        let latestMetrics = latestExercise.metrics
        let contextMetricIDs = contextMetrics.map(\.id)
        let latestMetricIDs = latestMetrics.map(\.id)
        guard Set(contextMetricIDs).count == contextMetricIDs.count,
              Set(latestMetricIDs).count == latestMetricIDs.count,
              Set(contextMetricIDs) == Set(latestMetricIDs),
              contextMetrics.map(MetricDefinitionSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString })
                == latestMetrics.map(MetricDefinitionSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) else {
            throw MetricDefinitionEditingV2Error.changed
        }
        // 検証後からsaveまでのTOCTOU競合、および同時保存同士の直列化・排他は未解決。この確認だけでは防げない。
        let metrics = storedExercise.metrics
        let metricIDs = metrics.map(\.id)
        guard Set(metricIDs).count == metricIDs.count else { throw MetricDefinitionEditingV2Error.changed }
        let metricsByID = Dictionary(uniqueKeysWithValues: metrics.map { ($0.id, $0) })
        let originalMetrics = metrics
        let originalSnapshots = Dictionary(uniqueKeysWithValues: metrics.map { ($0.id, MetricDefinitionSnapshot($0)) })
        let existingDrafts = drafts.filter { $0.original != nil }
        let addedDrafts = drafts.filter { $0.original == nil }
        guard Set(drafts.map(\.id)).count == drafts.count,
              Set(existingDrafts.map(\.id)) == Set(metricIDs),
              existingDrafts.allSatisfy({ draft in
                  guard let original = draft.original, let metric = metricsByID[draft.id] else { return false }
                  return MetricDefinitionSnapshot(metric) == original
                      && original.sortOrder == metric.sortOrder
              }),
              addedDrafts.allSatisfy({ metricsByID[$0.id] == nil }) else {
            throw MetricDefinitionEditingV2Error.changed
        }

        let cleaned = drafts.map { draft in
            (draft, draft.name.trimmingCharacters(in: .whitespacesAndNewlines), draft.unit.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ !$0.1.isEmpty && !$0.2.isEmpty }),
              Set(cleaned.map { $0.1.lowercased() }).count == cleaned.count else {
            throw MetricDefinitionEditingError.invalid
        }

        let allDefinitions = try context.fetch(FetchDescriptor<MetricDefinition>())
        let storedIDs = Set(allDefinitions.map(\.id))
        guard addedDrafts.allSatisfy({ !storedIDs.contains($0.id) }) else { throw MetricDefinitionEditingV2Error.changed }
        let maximumOrder = metrics.map(\.sortOrder).max() ?? -1
        let (_, orderOverflow) = maximumOrder.addingReportingOverflow(addedDrafts.count)
        guard !orderOverflow, addedDrafts.isEmpty || maximumOrder < Int.max else {
            throw MetricDefinitionEditingError.sortOrderOverflow
        }

        let history = try readContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
        let historyByMetric = Dictionary(grouping: history, by: \.metricID)
        guard existingDrafts.allSatisfy({ draft in
            guard let baseline = draft.historyBaseline else { return false }
            let revisions = historyByMetric[draft.id] ?? []
            switch baseline {
            case let .latestRevision(id):
                guard let baselineRevision = revisions.first(where: { $0.id == id }) else { return false }
                return revisions.allSatisfy { $0.revision <= baselineRevision.revision }
            case .noHistory:
                return revisions.isEmpty
            }
        }) else { throw MetricDefinitionEditingV2Error.changed }
        var changes: [(MetricDefinition, String, String, Bool, Bool, MetricDefinitionRevision)] = []
        var initialRevisions: [MetricDefinitionRevision] = []
        var changedRevisionIDs: Set<UUID> = []
        for (draft, name, unit) in cleaned where draft.original != nil {
            guard let metric = metricsByID[draft.id] else { throw MetricDefinitionEditingV2Error.changed }
            let revisions = history.filter { $0.metricID == metric.id }
            guard Set(revisions.map(\.revision)).count == revisions.count else { throw MetricValueRevisionLinkingError.duplicateRevision }
            let current: MetricRevisionSnapshot
            let currentSeriesID: UUID
            let latestRevision: Int?
            if let latest = revisions.max(by: { $0.revision < $1.revision }) {
                guard MetricValueRevisionLinking.matchesSnapshot(metric, revision: latest) else { throw MetricValueRevisionLinkingError.snapshotMismatch }
                current = MetricRevisionSnapshot(name: latest.name, unit: latest.unit, allowsDecimal: latest.allowsDecimal, isRequired: latest.isRequired)
                currentSeriesID = latest.seriesID
                latestRevision = latest.revision
            } else {
                current = MetricRevisionSnapshot(name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired)
                currentSeriesID = UUID()
                latestRevision = nil
            }
            let proposed = MetricRevisionSnapshot(name: name, unit: unit, allowsDecimal: draft.allowsDecimal, isRequired: draft.isRequired)
            let transition = MetricRevisionTransitionDecision.decide(MetricRevisionTransitionInput(
                current: current, proposed: proposed, currentSeriesID: currentSeriesID,
                proposedRevisionID: UUID(), proposedSeriesID: UUID()
            ))
            let revision: MetricDefinitionRevision
            if transition.kind == .unchanged {
                revision = revisions.max(by: { $0.revision < $1.revision })
                    ?? MetricDefinitionRevision(
                        metricID: metric.id, seriesID: currentSeriesID, revision: 1,
                        name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal,
                        isRequired: metric.isRequired, sortOrder: metric.sortOrder
                    )
            } else {
                let nextRevision: Int
                if let latestRevision {
                    let (next, overflow) = latestRevision.addingReportingOverflow(1)
                    guard !overflow else { throw MetricDefinitionEditingV2Error.revisionOverflow }
                    nextRevision = next
                } else {
                    nextRevision = 2
                }
                if revisions.isEmpty {
                    initialRevisions.append(MetricDefinitionRevision(
                        metricID: metric.id, seriesID: currentSeriesID, revision: 1,
                        name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal,
                        isRequired: metric.isRequired, sortOrder: metric.sortOrder
                    ))
                }
                guard let revisionID = transition.revisionID else { throw MetricDefinitionEditingV2Error.changed }
                revision = MetricDefinitionRevision(
                    id: revisionID, metricID: metric.id, seriesID: transition.seriesID,
                    revision: nextRevision, name: name, unit: unit, allowsDecimal: draft.allowsDecimal,
                    isRequired: draft.isRequired, sortOrder: metric.sortOrder
                )
                changedRevisionIDs.insert(revision.id)
            }
            changes.append((metric, name, unit, draft.allowsDecimal, draft.isRequired, revision))
        }

        var addedMetrics: [MetricDefinition] = []
        var nextOrder = maximumOrder
        for (draft, name, unit) in cleaned where draft.original == nil {
            let (order, overflow) = nextOrder.addingReportingOverflow(1)
            guard !overflow else { throw MetricDefinitionEditingError.sortOrderOverflow }
            let metric = MetricDefinition(name: name, unit: unit, allowsDecimal: draft.allowsDecimal, isRequired: draft.isRequired, sortOrder: order)
            metric.isActive = draft.isActive
            addedMetrics.append(metric)
            nextOrder = order
        }
        let resultingIDs = metricIDs + addedMetrics.map(\.id)
        guard Set(resultingIDs).count == resultingIDs.count,
              addedMetrics.allSatisfy({ !storedIDs.contains($0.id) }) else {
            throw MetricDefinitionEditingV2Error.changed
        }

        var revisionsToInsert = initialRevisions
        for entry in changes where changedRevisionIDs.contains(entry.5.id)
            && !history.contains(where: { $0.id == entry.5.id })
            && !revisionsToInsert.contains(where: { $0.id == entry.5.id }) {
            revisionsToInsert.append(entry.5)
        }
        for (metric, name, unit, allowsDecimal, isRequired, _) in changes {
            metric.name = name
            metric.unit = unit
            metric.allowsDecimal = allowsDecimal
            metric.isRequired = isRequired
        }
        for draft in drafts where draft.original != nil {
            metricsByID[draft.id]?.isActive = draft.isActive
        }
        do {
            for metric in addedMetrics { context.insert(metric) }
            storedExercise.metrics.append(contentsOf: addedMetrics)
            revisionsToInsert.forEach(context.insert)
            try persist(context)
        } catch {
            // 保持中のモデル参照と親子関係を戻してからrollbackし、contextをcleanに戻す。
            for metric in metrics {
                guard let snapshot = originalSnapshots[metric.id] else { continue }
                metric.name = snapshot.name
                metric.unit = snapshot.unit
                metric.allowsDecimal = snapshot.allowsDecimal
                metric.isRequired = snapshot.isRequired
                metric.isActive = snapshot.isActive
                metric.sortOrder = snapshot.sortOrder
            }
            storedExercise.metrics = originalMetrics
            context.rollback()
            throw error
        }
    }
}

enum MetricDefinitionEditingV2Error: LocalizedError {
    case unsavedContext
    case changed
    case revisionOverflow

    var errorDescription: String? {
        switch self {
        case .unsavedContext: "未保存の変更があるため、項目定義を編集できません。"
        case .changed: "項目定義が別の画面で変更されたか、V2未対応の変更が含まれています。画面を開き直してください。"
        case .revisionOverflow: "項目改定番号の上限に達したため、保存できません。"
        }
    }
}

enum WorkoutDeletion {
    static func captureTarget(workout: Workout, in context: ModelContext) throws -> WorkoutDeletionTarget {
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        let workoutID = workout.id
        let descriptor = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID })
        let matches = try context.fetch(descriptor)
        guard matches.count == 1, let current = matches.first,
              WorkoutRecordDeletionSnapshot.hasUniqueIDs(current), current.day == workout.day,
              current.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString })
                == workout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) else { throw WorkoutSetDeletionError.changed }
        let readContext = ModelContext(context.container)
        let saved = try readContext.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID }))
        guard saved.count == 1, let latest = saved.first, WorkoutRecordDeletionSnapshot.hasUniqueIDs(latest),
              latest.day == current.day, latest.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString })
                == current.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) else { throw WorkoutSetDeletionError.changed }
        return WorkoutDeletionTarget(workoutID: current.id, workoutDay: current.day,
            workoutRecords: current.records.map(WorkoutRecordSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }, revisionLinks: [])
    }

    static func delete(_ target: WorkoutDeletionTarget, in context: ModelContext) throws {
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        let workoutID = target.workoutID
        let descriptor = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID })
        let matches = try context.fetch(descriptor)
        guard matches.count == 1, let workout = matches.first,
              WorkoutRecordDeletionSnapshot.hasUniqueIDs(workout), workout.day == target.workoutDay,
              workout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == target.workoutRecords else { throw WorkoutSetDeletionError.changed }
        let readContext = ModelContext(context.container)
        let latest = try readContext.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID }))
        guard latest.count == 1, let saved = latest.first,
              WorkoutRecordDeletionSnapshot.hasUniqueIDs(saved), saved.day == target.workoutDay,
              saved.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == target.workoutRecords else { throw WorkoutSetDeletionError.changed }
        // 照合後からsaveまでのTOCTOU競合は、この確認だけでは防げない。
        context.delete(workout)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

private enum WorkoutRecordDeletionSnapshot {
    static func hasUniqueIDs(_ workout: Workout) -> Bool {
        let records = workout.records, sets = records.flatMap(\.sets), values = sets.flatMap(\.values)
        return Set(records.map(\.id)).count == records.count && Set(sets.map(\.id)).count == sets.count
            && Set(values.map(\.id)).count == values.count
            && records.allSatisfy { record in Set(record.sets.map(\.id)).count == record.sets.count
                && record.sets.allSatisfy { Set($0.values.map(\.id)).count == $0.values.count } }
    }

    // 削除を適用するcontextとは分けて、永続状態が確認時snapshotと一致するか調べる。
    static func verifyPersistedState(workoutID: UUID, day: String, records: [WorkoutRecordSnapshot], in context: ModelContext) throws {
        let readContext = ModelContext(context.container)
        let matches = try readContext.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID }))
        guard matches.count == 1, let saved = matches.first, hasUniqueIDs(saved),
              saved.day == day,
              saved.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == records else {
            throw WorkoutSetDeletionError.changed
        }
    }
}

struct WorkoutValueSnapshot: Equatable {
    let id: UUID
    let metricID: UUID
    let name: String
    let unit: String
    let allowsDecimal: Bool
    let isRequired: Bool
    let scaledValue: Int64?

    init(_ value: MetricValue) {
        id = value.id; metricID = value.metricID; name = value.name; unit = value.unit
        allowsDecimal = value.allowsDecimal; isRequired = value.isRequired; scaledValue = value.scaledValue
    }
}

struct WorkoutSetSnapshot: Equatable {
    let id: UUID
    let sortOrder: Int
    let values: [WorkoutValueSnapshot]

    init(_ set: SetRecord) {
        id = set.id; sortOrder = set.sortOrder
        values = set.values.map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

struct WorkoutRecordSnapshot: Equatable {
    let id: UUID
    let exerciseID: UUID
    let exerciseName: String
    let sortOrder: Int
    let sets: [WorkoutSetSnapshot]

    init(_ record: ExerciseRecord) {
        id = record.id; exerciseID = record.exerciseID; exerciseName = record.exerciseName; sortOrder = record.sortOrder
        sets = record.sets.map(WorkoutSetSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

struct WorkoutSetDeletionTarget: Equatable {
    let workoutID: UUID
    let recordID: UUID
    let setID: UUID
    let recordSnapshot: WorkoutRecordSnapshot
    let workoutRecords: [WorkoutRecordSnapshot]
    let workoutDay: String
    let revisionLinks: [WorkoutRevisionLinkSnapshot]?

    init(workout: Workout, record: ExerciseRecord, set: SetRecord) {
        workoutID = workout.id
        recordID = record.id
        setID = set.id
        recordSnapshot = WorkoutRecordSnapshot(record)
        workoutRecords = workout.records.map(WorkoutRecordSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        workoutDay = workout.day
        revisionLinks = nil
    }

    init(workout: Workout, record: ExerciseRecord, set: SetRecord, revisionLinks: [WorkoutRevisionLinkSnapshot]) {
        workoutID = workout.id
        recordID = record.id
        setID = set.id
        recordSnapshot = WorkoutRecordSnapshot(record)
        workoutRecords = workout.records.map(WorkoutRecordSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        workoutDay = workout.day
        self.revisionLinks = revisionLinks
    }
}

struct WorkoutRevisionLinkSnapshot: Equatable {
    let id: UUID
    let valueID: UUID
    let revisionID: UUID

    init(_ link: MetricValueRevisionLink) {
        id = link.id
        valueID = link.valueID
        revisionID = link.revisionID
    }
}

struct WorkoutDeletionTarget: Equatable {
    let workoutID: UUID
    let workoutDay: String
    let workoutRecords: [WorkoutRecordSnapshot]
    let revisionLinks: [WorkoutRevisionLinkSnapshot]

    fileprivate init(workoutID: UUID, workoutDay: String, workoutRecords: [WorkoutRecordSnapshot], revisionLinks: [WorkoutRevisionLinkSnapshot]) {
        self.workoutID = workoutID
        self.workoutDay = workoutDay
        self.workoutRecords = workoutRecords
        self.revisionLinks = revisionLinks
    }
}

struct WorkoutRecordDeletionTarget: Equatable {
    let workoutID: UUID
    let workoutDay: String
    let record: WorkoutRecordSnapshot
    let workoutRecords: [WorkoutRecordSnapshot]
    let revisionLinks: [WorkoutRevisionLinkSnapshot]?

    init(workout: Workout, record: ExerciseRecord) {
        workoutID = workout.id; workoutDay = workout.day
        self.record = WorkoutRecordSnapshot(record)
        workoutRecords = workout.records.map(WorkoutRecordSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        revisionLinks = nil
    }

    init(workout: Workout, record: ExerciseRecord, revisionLinks: [WorkoutRevisionLinkSnapshot]) {
        workoutID = workout.id; workoutDay = workout.day
        self.record = WorkoutRecordSnapshot(record)
        workoutRecords = workout.records.map(WorkoutRecordSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        self.revisionLinks = revisionLinks
    }
}

@MainActor enum WorkoutSetDeletion {
    static func delete(_ target: WorkoutSetDeletionTarget, in context: ModelContext, persist: () throws -> Void) throws {
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        let workoutID = target.workoutID
        let descriptor = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID })
        let matches = try context.fetch(descriptor)
        guard matches.count == 1, let workout = matches.first,
              WorkoutRecordDeletionSnapshot.hasUniqueIDs(workout), workout.day == target.workoutDay,
              let record = workout.records.first(where: { $0.id == target.recordID }),
              workout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == target.workoutRecords,
              WorkoutRecordSnapshot(record) == target.recordSnapshot,
              record.sets.filter({ $0.id == target.setID }).count == 1,
              let set = record.sets.first(where: { $0.id == target.setID }) else {
            throw WorkoutSetDeletionError.changed
        }
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        try WorkoutRecordDeletionSnapshot.verifyPersistedState(workoutID: workoutID, day: target.workoutDay, records: target.workoutRecords, in: context)
        // 永続状態の照合後からsaveまでのTOCTOU競合は、この確認だけでは防げない。

        if record.sets.count == 1 {
            workout.records.removeAll { $0.id == record.id }
            record.workout = nil
            context.delete(record)
        } else {
            record.sets.removeAll { $0.id == set.id }
            set.exerciseRecord = nil
            context.delete(set)
        }
        if workout.records.isEmpty {
            context.delete(workout)
        }
        do {
            try persist()
        } catch {
            // 開始時にcleanで、削除とsaveの間に他の処理を挟まないため、このcontext内の変更は削除分のみ。
            context.rollback()
            throw error
        }
    }
}

@MainActor enum WorkoutRecordDeletion {
    static func delete(_ target: WorkoutRecordDeletionTarget, in context: ModelContext, persist: () throws -> Void) throws {
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        let workoutID = target.workoutID
        let descriptor = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID })
        let matches = try context.fetch(descriptor)
        guard matches.count == 1, let workout = matches.first,
              WorkoutRecordDeletionSnapshot.hasUniqueIDs(workout), workout.day == target.workoutDay,
              workout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == target.workoutRecords,
              workout.records.filter({ $0.id == target.record.id }).count == 1,
              let record = workout.records.first(where: { $0.id == target.record.id }),
              WorkoutRecordSnapshot(record) == target.record else { throw WorkoutSetDeletionError.changed }
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        try WorkoutRecordDeletionSnapshot.verifyPersistedState(workoutID: workoutID, day: target.workoutDay, records: target.workoutRecords, in: context)
        // 永続状態の照合後からsaveまでのTOCTOU競合は、この確認だけでは防げない。
        workout.records.removeAll { $0.id == record.id }
        record.workout = nil
        context.delete(record)
        if workout.records.isEmpty { context.delete(workout) }
        do { try persist() } catch { context.rollback(); throw error }
    }
}

enum WorkoutSetDeletionError: LocalizedError {
    case unsavedContext
    case changed

    var errorDescription: String? {
        switch self {
        case .unsavedContext: "未保存の変更があります。先に保存するか、画面を開き直してから削除してください。"
        case .changed: "削除対象が確認後に変更されました。画面を更新してから再度お試しください。"
        }
    }
}

enum WorkoutDeletionError: LocalizedError {
    case notFound

    var errorDescription: String? {
        "削除対象の運動記録が見つかりません。履歴を更新してから再度お試しください。"
    }
}

struct WorkoutValueEditDraft: Equatable {
    let valueID: UUID
    let exerciseName: String
    let setOrder: Int
    let name: String
    let unit: String
    let allowsDecimal: Bool
    let isRequired: Bool
    var text: String

    var id: UUID { valueID }
}

struct ValidatedWorkoutValue {
    let valueID: UUID
    let scaledValue: Int64?
}

struct WorkoutSetAdditionDraft: Identifiable {
    let id: UUID
    let recordID: UUID
    let exerciseID: UUID
    let exerciseName: String
    let metrics: [WorkoutSetMetricDraft]
    var values: [UUID: String]
    var historyBaselines: [UUID: MetricDefinitionHistoryBaseline]? = nil
}

struct WorkoutSetAdditionDrafts {
    private(set) var items: [WorkoutSetAdditionDraft] = []

    mutating func append(_ draft: WorkoutSetAdditionDraft) {
        items.append(draft)
    }

    mutating func duplicate(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let source = items[index]
        let copy = WorkoutSetAdditionDraft(
            id: UUID(), recordID: source.recordID, exerciseID: source.exerciseID,
            exerciseName: source.exerciseName, metrics: source.metrics, values: source.values,
            historyBaselines: source.historyBaselines
        )
        items.insert(copy, at: index + 1)
    }

    mutating func cancel(id: UUID) {
        items.removeAll { $0.id == id }
    }

    func value(draftID: UUID, metricID: UUID) -> String {
        items.first(where: { $0.id == draftID })?.values[metricID] ?? ""
    }

    mutating func setValue(_ value: String, draftID: UUID, metricID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == draftID }) else { return }
        items[index].values[metricID] = value
    }
}

struct WorkoutSetMetricDraft: Equatable {
    let id: UUID
    let name: String
    let unit: String
    let allowsDecimal: Bool
    let isRequired: Bool
}

enum WorkoutValueEditing {
    static func orderedActiveMetrics(_ metrics: [MetricDefinition]) -> [MetricDefinition] {
        metrics.filter(\.isActive).sorted {
            $0.sortOrder == $1.sortOrder
                ? $0.id.uuidString < $1.id.uuidString
                : $0.sortOrder < $1.sortOrder
        }
    }

    static func deletionDraftsAreClean(_ drafts: [WorkoutValueEditDraft], originalDrafts: [WorkoutValueEditDraft], day: Date, originalDay: Date, additions: [WorkoutSetAdditionDraft]) -> Bool {
        drafts == originalDrafts && additions.isEmpty && Calendar.current.startOfDay(for: day) == Calendar.current.startOfDay(for: originalDay)
    }

    static func date(from day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)),
              Workout.dayString(from: date, calendar: calendar) == day else { return nil }
        return date
    }

    static func drafts(for workout: Workout) -> [WorkoutValueEditDraft] {
        workout.records.sorted { $0.sortOrder == $1.sortOrder ? $0.id.uuidString < $1.id.uuidString : $0.sortOrder < $1.sortOrder }.flatMap { record in
            record.sets.sorted { $0.sortOrder == $1.sortOrder ? $0.id.uuidString < $1.id.uuidString : $0.sortOrder < $1.sortOrder }.flatMap { set in
                set.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { value in
                    WorkoutValueEditDraft(
                        valueID: value.id,
                        exerciseName: record.exerciseName,
                        setOrder: set.sortOrder,
                        name: value.name,
                        unit: value.unit,
                        allowsDecimal: value.allowsDecimal,
                        isRequired: value.isRequired,
                        text: value.scaledValue.map { NSDecimalNumber(decimal: Decimal($0) / Decimal(1000)).stringValue } ?? ""
                    )
                }
            }
        }
    }

    static func validatedValues(from drafts: [WorkoutValueEditDraft]) -> Result<[ValidatedWorkoutValue], WorkoutValueEditError> {
        var values: [ValidatedWorkoutValue] = []
        for draft in drafts {
            let raw = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = raw.isEmpty ? nil : MetricInput.parse(raw, allowsDecimal: draft.allowsDecimal)
            guard raw.isEmpty || parsed != nil else {
                return .failure(.invalid(exerciseName: draft.exerciseName, setOrder: draft.setOrder, metricName: draft.name))
            }
            guard !draft.isRequired || parsed != nil else {
                return .failure(.required(exerciseName: draft.exerciseName, setOrder: draft.setOrder, metricName: draft.name))
            }
            values.append(ValidatedWorkoutValue(valueID: draft.valueID, scaledValue: parsed))
        }
        return .success(values)
    }

    static func apply(_ values: [ValidatedWorkoutValue], to workout: Workout) {
        let modelValues = workout.records.flatMap({ $0.sets }).flatMap(\.values)
        for edit in values {
            if let value = modelValues.first(where: { $0.id == edit.valueID }) {
                value.scaledValue = edit.scaledValue
            }
        }
    }

    static func appendSetDraft(for record: ExerciseRecord, exercise: Exercise) -> WorkoutSetAdditionDraft? {
        guard exercise.id == record.exerciseID, !exercise.isArchived else { return nil }
        let metrics = orderedActiveMetrics(exercise.metrics).map {
            WorkoutSetMetricDraft(id: $0.id, name: $0.name, unit: $0.unit, allowsDecimal: $0.allowsDecimal, isRequired: $0.isRequired)
        }
        return WorkoutSetAdditionDraft(id: UUID(), recordID: record.id, exerciseID: exercise.id, exerciseName: exercise.name, metrics: metrics, values: [:], historyBaselines: nil)
    }

    // validatedValuesはdraft自身の項目設定で検証するため、保存済みMetricValueのsnapshotと一致するdraftだけを受け付ける。
    // 対象外・重複したvalueIDも、どの保存済み値を検証したか確定できないため拒否する。モデルは変更しない。
    static func verifyStoredSnapshots(_ drafts: [WorkoutValueEditDraft], in workout: Workout) throws {
        let storedByID = Dictionary(grouping: workout.records.flatMap(\.sets).flatMap(\.values), by: \.id)
        var seenValueIDs = Set<UUID>()
        for draft in drafts {
            guard seenValueIDs.insert(draft.valueID).inserted,
                  let matches = storedByID[draft.valueID], matches.count == 1, let stored = matches.first,
                  stored.name == draft.name, stored.unit == draft.unit,
                  stored.allowsDecimal == draft.allowsDecimal, stored.isRequired == draft.isRequired else {
                throw WorkoutValueEditError.storedValueMismatch
            }
        }
    }

    static func save(_ drafts: [WorkoutValueEditDraft], additions: [WorkoutSetAdditionDraft], day: Date, to workout: Workout, exercises: [Exercise], calendar: Calendar = .current, now: Date = .now, discard: (SetRecord) -> Void = { _ in }, persist: () throws -> Void) throws {
        // 入力値の検証より先に照合し、draftの設定を偽装した入力がその設定のまま検証されないようにする。
        try verifyStoredSnapshots(drafts, in: workout)
        guard case let .success(values) = validatedValues(from: drafts) else { throw WorkoutValueEditError.invalidDrafts }
        guard calendar.startOfDay(for: day) <= calendar.startOfDay(for: now) else { throw WorkoutValueEditError.futureDay }
        guard Self.date(from: workout.day, calendar: calendar) != nil else { throw WorkoutValueEditError.invalidStoredDay }

        var additionsToInsert: [(ExerciseRecord, SetRecord)] = []
        var nextOrders: [UUID: Int] = [:]
        var seenAdditionIDs = Set<UUID>()
        for addition in additions {
            guard seenAdditionIDs.insert(addition.id).inserted else { throw WorkoutValueEditError.duplicateAdditionDraft }
            guard let record = workout.records.first(where: { $0.id == addition.recordID }),
                  let exercise = exercises.first(where: { $0.id == addition.exerciseID }),
                  record.exerciseID == exercise.id, !exercise.isArchived else { throw WorkoutValueEditError.exerciseUnavailable }
            let current = orderedActiveMetrics(exercise.metrics).map {
                WorkoutSetMetricDraft(id: $0.id, name: $0.name, unit: $0.unit, allowsDecimal: $0.allowsDecimal, isRequired: $0.isRequired)
            }
            guard current == addition.metrics else { throw WorkoutValueEditError.metricsChanged }
            guard !current.isEmpty else { throw WorkoutValueEditError.emptySetMetrics }
            let baseOrder = nextOrders[record.id] ?? record.sets.map(\.sortOrder).max() ?? 0
            let (setOrder, overflow) = baseOrder.addingReportingOverflow(1)
            guard !overflow else { throw WorkoutValueEditError.setOrderOverflow }
            var savedValues: [MetricValue] = []
            for metric in current {
                let raw = (addition.values[metric.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = raw.isEmpty ? nil : MetricInput.parse(raw, allowsDecimal: metric.allowsDecimal)
                if !raw.isEmpty && parsed == nil { throw WorkoutValueEditError.invalid(exerciseName: addition.exerciseName, setOrder: setOrder, metricName: metric.name) }
                if metric.isRequired && parsed == nil { throw WorkoutValueEditError.required(exerciseName: addition.exerciseName, setOrder: setOrder, metricName: metric.name) }
                guard let definition = exercise.metrics.first(where: { $0.id == metric.id && $0.isActive }) else { throw WorkoutValueEditError.metricsChanged }
                savedValues.append(MetricValue(metric: definition, scaledValue: parsed))
            }
            let set = SetRecord(sortOrder: setOrder, values: savedValues)
            nextOrders[record.id] = setOrder
            additionsToInsert.append((record, set))
        }

        let originalDay = workout.day
        let originalValues = workout.records.flatMap { $0.sets }.flatMap(\.values).map { ($0.id, $0.scaledValue) }
        workout.day = Workout.dayString(from: day, calendar: calendar)
        apply(values, to: workout)
        for (record, set) in additionsToInsert { record.sets.append(set) }
        do {
            try persist()
        } catch {
            for (record, set) in additionsToInsert {
                record.sets.removeAll { $0.id == set.id }
                for value in set.values { value.setRecord = nil }
                set.exerciseRecord = nil
                discard(set)
            }
            let modelValues = workout.records.flatMap({ $0.sets }).flatMap(\.values)
            for (valueID, original) in originalValues { modelValues.first(where: { $0.id == valueID })?.scaledValue = original }
            workout.day = originalDay
            throw error
        }
    }

    static func save(_ drafts: [WorkoutValueEditDraft], day: Date, to workout: Workout, calendar: Calendar = .current, now: Date = .now, persist: () throws -> Void) throws {
        try save(drafts, additions: [], day: day, to: workout, exercises: [], calendar: calendar, now: now, persist: persist)
    }
}

// V1の追加セット保存境界。未保存変更を巻き込まないよう、clean contextだけで実行する。
struct WorkoutAdditionBaseline: Equatable {
    let workoutID: UUID
    let day: String
    let records: [WorkoutRecordSnapshot]

    init(_ workout: Workout) {
        workoutID = workout.id
        day = workout.day
        records = workout.records.map(WorkoutRecordSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

@MainActor enum WorkoutSetAdditionV1 {
    static func save(_ drafts: [WorkoutValueEditDraft], additions: [WorkoutSetAdditionDraft], baseline: WorkoutAdditionBaseline?, day: Date, to workout: Workout, exercises: [Exercise], in context: ModelContext, calendar: Calendar = .current, now: Date = .now, persist: (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard !context.hasChanges else { throw WorkoutValueEditError.unsavedContext }
        guard workout.modelContext === context else { throw WorkoutValueEditError.workoutContextMismatch }
        guard let baseline, baseline.workoutID == workout.id else { throw WorkoutValueEditError.workoutContextMismatch }

        let workoutID = workout.id
        let matches = try context.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID }))
        guard matches.count == 1, let currentWorkout = matches.first,
              currentWorkout.persistentModelID == workout.persistentModelID else {
            throw WorkoutValueEditError.workoutContextMismatch
        }
        let readContext = ModelContext(context.container)
        let latestWorkouts = try readContext.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID }))
        guard latestWorkouts.count == 1, let latestWorkout = latestWorkouts.first,
              latestWorkout.persistentModelID == workout.persistentModelID,
              WorkoutRecordDeletionSnapshot.hasUniqueIDs(latestWorkout),
              latestWorkout.day == currentWorkout.day,
              latestWorkout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString })
                == currentWorkout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }),
              baseline.day == latestWorkout.day,
              baseline.records == latestWorkout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) else {
            throw WorkoutValueEditError.workoutContextMismatch
        }

        // 各追加draftの基準と永続済み最新定義を別contextで比較する。
        for addition in additions {
            let readContext = ModelContext(context.container)
            let latest = try readContext.fetch(FetchDescriptor<Exercise>()).first { $0.id == addition.exerciseID }
            guard let latest, !latest.isArchived else { throw WorkoutValueEditError.metricsChanged }
            let current = WorkoutValueEditing.orderedActiveMetrics(latest.metrics).map {
                WorkoutSetMetricDraft(id: $0.id, name: $0.name, unit: $0.unit, allowsDecimal: $0.allowsDecimal, isRequired: $0.isRequired)
            }
            guard current == addition.metrics else { throw WorkoutValueEditError.metricsChanged }
        }

        do {
            try WorkoutValueEditing.save(
                drafts, additions: additions, day: day, to: workout, exercises: exercises,
                calendar: calendar, now: now,
                discard: { context.delete($0) }, persist: { try persist(context) }
            )
        } catch {
            context.rollback()
            throw error
        }
    }
}

enum WorkoutValueEditError: LocalizedError {
    case invalid(exerciseName: String, setOrder: Int, metricName: String)
    case required(exerciseName: String, setOrder: Int, metricName: String)
    case invalidDrafts
    case invalidStoredDay
    case futureDay
    case exerciseUnavailable
    case metricsChanged
    case duplicateAdditionDraft
    case setOrderOverflow
    case emptySetMetrics
    case storedValueMismatch
    case unsavedContext
    case workoutContextMismatch

    var errorDescription: String? {
        switch self {
        case let .invalid(exercise, set, metric): "\(exercise)・セット\(set)の「\(metric)」は0以上の有効な数値を入力してください。"
        case let .required(exercise, set, metric): "\(exercise)・セット\(set)の「\(metric)」は必須です。"
        case .invalidDrafts: "入力値を確認してください。"
        case .invalidStoredDay: "保存済みの運動日が不正なため、編集できません。"
        case .futureDay: "運動日は今日以前の日付を選択してください。"
        case .exerciseUnavailable: "種目が見つからないかアーカイブ済みです。画面を開き直してください。"
        case .metricsChanged: "種目の有効項目が変更されました。入力内容を確認して再度お試しください。"
        case .duplicateAdditionDraft: "追加セットの入力が重複しています。画面を開き直してください。"
        case .setOrderOverflow: "セット番号の上限に達したため、セットを追加できません。"
        case .emptySetMetrics: "有効な項目がない種目には、空のセットを追加できません。"
        case .storedValueMismatch: "編集内容が保存済みの記録値と一致しません。画面を開き直してから再度お試しください。"
        case .unsavedContext: "未保存の変更があるため、運動記録を保存できません。先に変更を保存するか、画面を開き直してください。"
        case .workoutContextMismatch: "運動記録が現在のデータ画面に属していません。画面を開き直してください。"
        }
    }
}

enum MeleteSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [ any PersistentModel.Type ] {
        [Exercise.self, MetricDefinition.self, Workout.self, ExerciseRecord.self, SetRecord.self, MetricValue.self]
    }
}

// 本番候補V2。V1の6型を変更せず、項目改定履歴と値からの任意リンクだけを追加する。
@Model final class MetricDefinitionRevision {
    var id: UUID
    var metricID: UUID
    var seriesID: UUID
    var revision: Int
    var name: String
    var unit: String
    var allowsDecimal: Bool
    var isRequired: Bool
    var sortOrder: Int

    init(id: UUID = UUID(), metricID: UUID, seriesID: UUID = UUID(), revision: Int, name: String, unit: String, allowsDecimal: Bool, isRequired: Bool, sortOrder: Int) {
        self.id = id
        self.metricID = metricID
        self.seriesID = seriesID
        self.revision = revision
        self.name = name
        self.unit = unit
        self.allowsDecimal = allowsDecimal
        self.isRequired = isRequired
        self.sortOrder = sortOrder
    }
}

@Model final class MetricValueRevisionLink {
    var id: UUID
    var valueID: UUID
    var revisionID: UUID

    init(id: UUID = UUID(), valueID: UUID, revisionID: UUID) {
        self.id = id
        self.valueID = valueID
        self.revisionID = revisionID
    }
}

// raw ModelContextの任意挿入を封じるものではなく、アプリがリンクを作る唯一の境界。
enum MetricValueRevisionLinking {
    // sortOrderは表示順であり、系列を識別するsnapshotには含めない。
    static func matchesSnapshot(name: String, unit: String, allowsDecimal: Bool, isRequired: Bool, revision: MetricDefinitionRevision) -> Bool {
        name == revision.name
            && unit == revision.unit
            && allowsDecimal == revision.allowsDecimal
            && isRequired == revision.isRequired
    }

    static func matchesSnapshot(_ metric: MetricDefinition, revision: MetricDefinitionRevision) -> Bool {
        matchesSnapshot(name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, revision: revision)
    }

    static func matchesSnapshot(_ metric: WorkoutSetMetricDraft, revision: MetricDefinitionRevision) -> Bool {
        matchesSnapshot(name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, revision: revision)
    }

    static func removeLinks(for values: [MetricValue], in context: ModelContext) throws -> [MetricValueRevisionLink] {
        let ids = Set(values.map(\.id))
        let links = try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).filter { ids.contains($0.valueID) }
        links.forEach(context.delete)
        return links
    }

    static func register(value: MetricValue, revision: MetricDefinitionRevision, in context: ModelContext) throws -> MetricValueRevisionLink {
        let values = try context.fetch(FetchDescriptor<MetricValue>())
        let revisions = try context.fetch(FetchDescriptor<MetricDefinitionRevision>())
        let links = try context.fetch(FetchDescriptor<MetricValueRevisionLink>())

        guard let storedValue = values.first(where: { $0.id == value.id }),
              let storedRevision = revisions.first(where: { $0.id == revision.id }) else {
            throw MetricValueRevisionLinkingError.missingEntity
        }
        guard storedValue.metricID == storedRevision.metricID else {
            throw MetricValueRevisionLinkingError.metricMismatch
        }
        guard matchesSnapshot(name: storedValue.name, unit: storedValue.unit, allowsDecimal: storedValue.allowsDecimal, isRequired: storedValue.isRequired, revision: storedRevision) else {
            throw MetricValueRevisionLinkingError.snapshotMismatch
        }
        guard !links.contains(where: { $0.valueID == storedValue.id }) else {
            throw MetricValueRevisionLinkingError.valueAlreadyLinked
        }
        guard !revisions.contains(where: {
            $0.id != storedRevision.id
                && $0.metricID == storedRevision.metricID
                && $0.revision == storedRevision.revision
        }) else {
            throw MetricValueRevisionLinkingError.duplicateRevision
        }

        let link = MetricValueRevisionLink(valueID: storedValue.id, revisionID: storedRevision.id)
        context.insert(link)
        return link
    }
}

// 既存Workoutへの新規set追加用。既存値のrevision状態には触れない。
@MainActor enum WorkoutValueEditingV2 {
    static func appendSetDraft(for record: ExerciseRecord, exercise: Exercise, in context: ModelContext) throws -> WorkoutSetAdditionDraft? {
        guard !context.hasChanges else { throw WorkoutCreationV2Error.unsavedContext }
        guard var draft = WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise) else { return nil }
        let readContext = ModelContext(context.container)
        let revisions = try readContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
        let exerciseID = exercise.id
        let latestExercise = try readContext.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID }))
        guard latestExercise.count == 1, let currentExercise = latestExercise.first,
              currentExercise.metrics.map(MetricDefinitionSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == exercise.metrics.map(MetricDefinitionSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) else { throw WorkoutValueEditError.metricsChanged }
        var baselines: [UUID: MetricDefinitionHistoryBaseline] = [:]
        for metric in draft.metrics {
            let matches = revisions.filter { $0.metricID == metric.id }
            guard Set(matches.map(\.revision)).count == matches.count else { throw MetricValueRevisionLinkingError.duplicateRevision }
            if let latest = matches.max(by: { $0.revision < $1.revision }) {
                guard MetricValueRevisionLinking.matchesSnapshot(metric, revision: latest) else { throw MetricValueRevisionLinkingError.snapshotMismatch }
                baselines[metric.id] = .latestRevision(latest.id)
            } else { baselines[metric.id] = .noHistory }
        }
        draft.historyBaselines = baselines
        return draft
    }

    static func save(_ drafts: [WorkoutValueEditDraft], additions: [WorkoutSetAdditionDraft], day: Date, to workout: Workout, exercises: [Exercise], in context: ModelContext, calendar: Calendar = .current, now: Date = .now, persist: (ModelContext) throws -> Void = { try $0.save() }) throws {
        // workoutの変更は所有contextに記録されるため、別contextやcontext無しではsaveしても永続化されない。どのモデルにも触れる前に拒否する。
        guard let owner = workout.modelContext, owner === context else { throw WorkoutValueEditingV2Error.workoutContextMismatch }
        guard !context.hasChanges else { throw WorkoutCreationV2Error.unsavedContext }
        // revision挿入より前に照合し、偽装draftでcontextを一時的にも変更しない。
        try WorkoutValueEditing.verifyStoredSnapshots(drafts, in: workout)
        let readContext = ModelContext(context.container)
        let freshRevisions = try readContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
        var latestExercisesByID: [UUID: Exercise] = [:]
        for exerciseID in Set(additions.map(\.exerciseID)) {
            let matches = try readContext.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID }))
            guard matches.count == 1, let latestExercise = matches.first, !latestExercise.isArchived else {
                throw WorkoutValueEditError.exerciseUnavailable
            }
            latestExercisesByID[exerciseID] = latestExercise
        }
        var batchBaselines: [UUID: MetricDefinitionHistoryBaseline] = [:]
        for addition in additions {
            let metricIDs = addition.metrics.map(\.id)
            guard Set(metricIDs).count == metricIDs.count,
                  let latestExercise = latestExercisesByID[addition.exerciseID] else {
                throw WorkoutValueEditError.metricsChanged
            }
            let latestMetrics = WorkoutValueEditing.orderedActiveMetrics(latestExercise.metrics).map {
                WorkoutSetMetricDraft(id: $0.id, name: $0.name, unit: $0.unit, allowsDecimal: $0.allowsDecimal, isRequired: $0.isRequired)
            }
            guard latestMetrics == addition.metrics else { throw WorkoutValueEditError.metricsChanged }
            guard let baselines = addition.historyBaselines, Set(baselines.keys) == Set(addition.metrics.map(\.id)) else { throw WorkoutValueEditError.metricsChanged }
            for metric in addition.metrics {
                let matches = freshRevisions.filter { $0.metricID == metric.id }
                let actual: MetricDefinitionHistoryBaseline = matches.max(by: { $0.revision < $1.revision }).map { .latestRevision($0.id) } ?? .noHistory
                guard baselines[metric.id] == actual else { throw WorkoutValueEditError.metricsChanged }
                if let previous = batchBaselines[metric.id], previous != actual { throw WorkoutValueEditError.metricsChanged }
                batchBaselines[metric.id] = actual
            }
        }
        // snapshot照合からsaveまでのTOCTOU競合は、この確認だけでは防げない。
        let originalValueIDs = Set(workout.records.flatMap(\.sets).flatMap(\.values).map(\.id))
        let history = try context.fetch(FetchDescriptor<MetricDefinitionRevision>())
        var chosen: [UUID: MetricDefinitionRevision] = [:]
        for metric in additions.flatMap(\.metrics) {
            if chosen[metric.id] == nil {
                let revisions = history.filter { $0.metricID == metric.id }
                guard Set(revisions.map(\.revision)).count == revisions.count else { throw MetricValueRevisionLinkingError.duplicateRevision }
                if let current = revisions.max(by: { $0.revision < $1.revision }) {
                    guard MetricValueRevisionLinking.matchesSnapshot(metric, revision: current) else { throw MetricValueRevisionLinkingError.snapshotMismatch }
                    chosen[metric.id] = current
                } else {
                    let sortOrder = exercises.flatMap(\.metrics).first(where: { $0.id == metric.id })?.sortOrder ?? 0
                    chosen[metric.id] = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: sortOrder)
                }
            }
        }
        var insertedRevisions: [MetricDefinitionRevision] = []
        var insertedLinks: [MetricValueRevisionLink] = []
        do {
            for revision in chosen.values where !history.contains(where: { $0.id == revision.id }) {
                context.insert(revision); insertedRevisions.append(revision)
            }
            try WorkoutValueEditing.save(drafts, additions: additions, day: day, to: workout, exercises: exercises, calendar: calendar, now: now, discard: { set in context.delete(set) }) {
                for set in workout.records.flatMap(\.sets) where !additions.isEmpty {
                    for value in set.values where !originalValueIDs.contains(value.id) && !insertedLinks.contains(where: { $0.valueID == value.id }) {
                        guard let revision = chosen[value.metricID] else {
                            throw MetricValueRevisionLinkingError.missingEntity
                        }
                        insertedLinks.append(try MetricValueRevisionLinking.register(value: value, revision: revision, in: context))
                    }
                }
                try persist(context)
            }
        } catch {
            insertedLinks.forEach(context.delete)
            insertedRevisions.forEach(context.delete)
            // 開始時にcleanであることを確認した同期処理なので、この処理中の変更だけを破棄できる。
            context.rollback()
            throw error
        }
    }
}

enum WorkoutValueEditingV2Error: LocalizedError {
    case workoutContextMismatch

    var errorDescription: String? {
        switch self {
        case .workoutContextMismatch: "編集対象の運動記録が現在の保存先と一致しないため、保存できません。画面を開き直してください。"
        }
    }
}

@MainActor enum WorkoutDeletionV2 {
    private static func hasUniqueIDs(_ workout: Workout) -> Bool {
        let records = workout.records
        let sets = records.flatMap(\.sets)
        let values = sets.flatMap(\.values)
        return Set(records.map(\.id)).count == records.count
            && Set(sets.map(\.id)).count == sets.count
            && Set(values.map(\.id)).count == values.count
            && records.allSatisfy({ record in
                Set(record.sets.map(\.id)).count == record.sets.count
                    && record.sets.allSatisfy({ set in Set(set.values.map(\.id)).count == set.values.count })
            })
    }

    // 新しいcontextは永続状態の照合にだけ使う。削除処理・saveは呼び出し元contextに限定する。
    private static func verifyPersistedState(workoutID: UUID, in context: ModelContext, expectedRecords: [WorkoutRecordSnapshot], expectedDay: String, affectedValueIDs: Set<UUID>) throws {
        let readContext = ModelContext(context.container)
        let workouts = try readContext.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID }))
        guard workouts.count == 1, let latestWorkout = workouts.first,
              hasUniqueIDs(latestWorkout), latestWorkout.day == expectedDay,
              latestWorkout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == expectedRecords else {
            throw WorkoutSetDeletionError.changed
        }

        let latestLinks = try readContext.fetch(FetchDescriptor<MetricValueRevisionLink>())
            .filter { affectedValueIDs.contains($0.valueID) }.map(WorkoutRevisionLinkSnapshot.init)
        let contextLinks = try context.fetch(FetchDescriptor<MetricValueRevisionLink>())
            .filter { affectedValueIDs.contains($0.valueID) }.map(WorkoutRevisionLinkSnapshot.init)
        guard Set(latestLinks.map(\.id)).count == latestLinks.count,
              Set(latestLinks.map(\.valueID)).count == latestLinks.count,
              Set(contextLinks.map(\.id)).count == contextLinks.count,
              Set(contextLinks.map(\.valueID)).count == contextLinks.count,
              latestLinks.sorted(by: { $0.id.uuidString < $1.id.uuidString })
                == contextLinks.sorted(by: { $0.id.uuidString < $1.id.uuidString }) else {
            throw WorkoutSetDeletionError.changed
        }
    }

    private static func deleteCaptured(_ target: WorkoutDeletionTarget, in context: ModelContext, persist: (ModelContext) throws -> Void) throws {
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        guard Set(target.workoutRecords.map(\.id)).count == target.workoutRecords.count,
              Set(target.revisionLinks.map(\.id)).count == target.revisionLinks.count,
              Set(target.revisionLinks.map(\.valueID)).count == target.revisionLinks.count else { throw WorkoutSetDeletionError.changed }
        let workoutID = target.workoutID
        let matches = try context.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID }))
        guard matches.count == 1, let workout = matches.first, hasUniqueIDs(workout),
              workout.day == target.workoutDay,
              workout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == target.workoutRecords else { throw WorkoutSetDeletionError.changed }
        let values = workout.records.flatMap(\.sets).flatMap(\.values)
        let ids = Set(values.map(\.id))
        let contextLinks = try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).filter { ids.contains($0.valueID) }.map(WorkoutRevisionLinkSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        guard contextLinks == target.revisionLinks else { throw WorkoutSetDeletionError.changed }
        let readContext = ModelContext(context.container)
        let saved = try readContext.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID }))
        guard saved.count == 1, let latest = saved.first, hasUniqueIDs(latest), latest.day == target.workoutDay,
              latest.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == target.workoutRecords else { throw WorkoutSetDeletionError.changed }
        let savedLinks = try readContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).filter { ids.contains($0.valueID) }.map(WorkoutRevisionLinkSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        guard Set(savedLinks.map(\.id)).count == savedLinks.count, Set(savedLinks.map(\.valueID)).count == savedLinks.count,
              savedLinks == target.revisionLinks else { throw WorkoutSetDeletionError.changed }
        // 照合後からsaveまでのTOCTOU競合は、この確認だけでは防げない。
        _ = try MetricValueRevisionLinking.removeLinks(for: values, in: context)
        context.delete(workout)
        do { try persist(context) } catch { context.rollback(); throw error }
    }

    static func captureWorkoutDeletionTarget(workout: Workout, in context: ModelContext) throws -> WorkoutDeletionTarget {
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        guard hasUniqueIDs(workout) else { throw WorkoutSetDeletionError.changed }
        let workoutID = workout.id
        let contextMatches = try context.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID }))
        guard contextMatches.count == 1, let current = contextMatches.first, hasUniqueIDs(current), current.day == workout.day,
              current.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString })
                == workout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) else { throw WorkoutSetDeletionError.changed }
        let valueIDs = Set(workout.records.flatMap(\.sets).flatMap(\.values).map(\.id))
        let links = try context.fetch(FetchDescriptor<MetricValueRevisionLink>())
            .filter { valueIDs.contains($0.valueID) }
            .map(WorkoutRevisionLinkSnapshot.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard Set(links.map(\.id)).count == links.count, Set(links.map(\.valueID)).count == links.count else { throw WorkoutSetDeletionError.changed }
        let readContext = ModelContext(context.container)
        let saved = try readContext.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID }))
        guard saved.count == 1, let latest = saved.first, hasUniqueIDs(latest), latest.day == current.day,
              latest.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString })
                == current.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) else { throw WorkoutSetDeletionError.changed }
        let savedLinks = try readContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).filter { valueIDs.contains($0.valueID) }
            .map(WorkoutRevisionLinkSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        guard Set(savedLinks.map(\.id)).count == savedLinks.count, Set(savedLinks.map(\.valueID)).count == savedLinks.count,
              savedLinks == links else { throw WorkoutSetDeletionError.changed }
        return WorkoutDeletionTarget(
            workoutID: workout.id,
            workoutDay: workout.day,
            workoutRecords: workout.records.map(WorkoutRecordSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString },
            revisionLinks: links
        )
    }

    static func delete(_ target: WorkoutDeletionTarget, in context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }) throws {
        try deleteCaptured(target, in: context, persist: persist)
    }

    static func deleteSet(_ target: WorkoutSetDeletionTarget, in context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        guard let confirmedLinks = target.revisionLinks else { throw WorkoutSetDeletionError.changed }
        let workoutID = target.workoutID
        let matches = try context.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID }))
        guard matches.count == 1, let workout = matches.first,
              hasUniqueIDs(workout),
              workout.day == target.workoutDay,
              workout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == target.workoutRecords,
              let record = workout.records.first(where: { $0.id == target.recordID }),
              WorkoutRecordSnapshot(record) == target.recordSnapshot,
              let set = record.sets.first(where: { $0.id == target.setID }) else { throw WorkoutSetDeletionError.changed }
        let affectedValueIDs = Set(set.values.map(\.id))
        try verifyPersistedState(workoutID: workoutID, in: context, expectedRecords: target.workoutRecords, expectedDay: target.workoutDay, affectedValueIDs: affectedValueIDs)
        let currentLinks = try context.fetch(FetchDescriptor<MetricValueRevisionLink>())
            .filter { affectedValueIDs.contains($0.valueID) }
            .map(WorkoutRevisionLinkSnapshot.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let persistedContext = ModelContext(context.container)
        let latestLinks = try persistedContext.fetch(FetchDescriptor<MetricValueRevisionLink>())
            .filter { affectedValueIDs.contains($0.valueID) }
            .map(WorkoutRevisionLinkSnapshot.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard Set(currentLinks.map(\.id)).count == currentLinks.count,
              Set(currentLinks.map(\.valueID)).count == currentLinks.count,
              Set(latestLinks.map(\.id)).count == latestLinks.count,
              Set(latestLinks.map(\.valueID)).count == latestLinks.count,
              currentLinks == confirmedLinks, latestLinks == confirmedLinks else { throw WorkoutSetDeletionError.changed }
        // この永続状態確認後からsaveまでのTOCTOU競合は、この確認だけでは防げない。
        _ = try MetricValueRevisionLinking.removeLinks(for: set.values, in: context)
        if record.sets.count == 1 { workout.records.removeAll { $0.id == record.id }; context.delete(record) }
        else { record.sets.removeAll { $0.id == set.id }; context.delete(set) }
        if workout.records.isEmpty { context.delete(workout) }
        do { try persist(context) } catch { context.rollback(); throw error }
    }

    static func captureSetDeletionTarget(workout: Workout, record: ExerciseRecord, set: SetRecord, in context: ModelContext) throws -> WorkoutSetDeletionTarget {
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        guard hasUniqueIDs(workout),
              workout.records.filter({ $0.id == record.id }).count == 1,
              record.sets.filter({ $0.id == set.id }).count == 1 else { throw WorkoutSetDeletionError.changed }
        let valueIDs = Set(set.values.map(\.id))
        let links = try context.fetch(FetchDescriptor<MetricValueRevisionLink>())
            .filter { valueIDs.contains($0.valueID) }
            .map(WorkoutRevisionLinkSnapshot.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return WorkoutSetDeletionTarget(workout: workout, record: record, set: set, revisionLinks: links)
    }

    static func captureRecordDeletionTarget(workout: Workout, record: ExerciseRecord, in context: ModelContext) throws -> WorkoutRecordDeletionTarget {
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        guard hasUniqueIDs(workout),
              workout.records.filter({ $0.id == record.id }).count == 1 else { throw WorkoutSetDeletionError.changed }
        let valueIDs = Set(record.sets.flatMap(\.values).map(\.id))
        let links = try context.fetch(FetchDescriptor<MetricValueRevisionLink>())
            .filter { valueIDs.contains($0.valueID) }
            .map(WorkoutRevisionLinkSnapshot.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return WorkoutRecordDeletionTarget(workout: workout, record: record, revisionLinks: links)
    }

    static func deleteRecord(_ target: WorkoutRecordDeletionTarget, in context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        guard let confirmedLinks = target.revisionLinks else { throw WorkoutSetDeletionError.changed }
        let workoutID = target.workoutID
        let matches = try context.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID }))
        guard matches.count == 1, let workout = matches.first,
              hasUniqueIDs(workout),
              workout.day == target.workoutDay,
              workout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == target.workoutRecords,
              let record = workout.records.first(where: { $0.id == target.record.id }), WorkoutRecordSnapshot(record) == target.record else { throw WorkoutSetDeletionError.changed }
        let affectedValueIDs = Set(record.sets.flatMap(\.values).map(\.id))
        try verifyPersistedState(workoutID: workoutID, in: context, expectedRecords: target.workoutRecords, expectedDay: target.workoutDay, affectedValueIDs: affectedValueIDs)
        let currentLinks = try context.fetch(FetchDescriptor<MetricValueRevisionLink>())
            .filter { affectedValueIDs.contains($0.valueID) }
            .map(WorkoutRevisionLinkSnapshot.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let persistedContext = ModelContext(context.container)
        let latestLinks = try persistedContext.fetch(FetchDescriptor<MetricValueRevisionLink>())
            .filter { affectedValueIDs.contains($0.valueID) }
            .map(WorkoutRevisionLinkSnapshot.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard Set(currentLinks.map(\.id)).count == currentLinks.count,
              Set(currentLinks.map(\.valueID)).count == currentLinks.count,
              Set(latestLinks.map(\.id)).count == latestLinks.count,
              Set(latestLinks.map(\.valueID)).count == latestLinks.count,
              currentLinks == confirmedLinks, latestLinks == confirmedLinks else { throw WorkoutSetDeletionError.changed }
        // この永続状態確認後からsaveまでのTOCTOU競合は、この確認だけでは防げない。
        _ = try MetricValueRevisionLinking.removeLinks(for: record.sets.flatMap(\.values), in: context)
        workout.records.removeAll { $0.id == record.id }; context.delete(record)
        if workout.records.isEmpty { context.delete(workout) }
        do { try persist(context) } catch { context.rollback(); throw error }
    }
}

enum MetricValueRevisionLinkingError: LocalizedError {
    case missingEntity
    case metricMismatch
    case valueAlreadyLinked
    case duplicateRevision
    case snapshotMismatch

    var errorDescription: String? {
        switch self {
        case .missingEntity: "値または項目改定が見つかりません。"
        case .metricMismatch: "値と項目改定のmetricIDが一致しません。"
        case .valueAlreadyLinked: "値にはすでに項目改定リンクがあります。"
        case .duplicateRevision: "同じ項目の改定番号が重複しています。"
        case .snapshotMismatch: "項目定義と最新の項目改定が一致しません。履歴を確認してから保存してください。"
        }
    }
}

// V1の新規Workout保存境界。検証後は同じcontextから取得した参照だけで記録を構築する。
@MainActor enum WorkoutCreationV1 {
    static func save(day: Date, entries: [WorkoutEntryDraft], in context: ModelContext, calendar: Calendar = .current, persist: (ModelContext) throws -> Void = { try $0.save() }) throws -> Workout {
        guard !context.hasChanges else { throw WorkoutCreationV1Error.unsavedContext }
        guard calendar.startOfDay(for: day) <= calendar.startOfDay(for: .now), !entries.isEmpty,
              Set(entries.map(\.exerciseID)).count == entries.count,
              case let .success(validated) = WorkoutSetDraftEditing.validatedEntries(entries) else {
            throw WorkoutCreationV1Error.invalidEntries
        }

        let readContext = ModelContext(context.container)
        var liveExercises: [UUID: Exercise] = [:]
        for entry in validated {
            guard !entry.sets.isEmpty,
                  Set(entry.metricSnapshots.map(\.id)).count == entry.metricSnapshots.count else {
                throw WorkoutCreationV1Error.invalidEntries
            }
            let exerciseID = entry.exerciseID
            let matches = try readContext.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID }))
            guard matches.count == 1, let live = matches.first, !live.isArchived,
                  live.name == entry.exerciseName else { throw WorkoutCreationV1Error.staleDefinition }
            let liveMetricIDs = live.metrics.map(\.id)
            guard Set(liveMetricIDs).count == liveMetricIDs.count else { throw WorkoutCreationV1Error.staleDefinition }
            let metrics = Self.sortedSnapshots(live.metrics.filter(\.isActive))
            guard metrics == entry.metricSnapshots else { throw WorkoutCreationV1Error.staleDefinition }
            guard live.metrics.allSatisfy({ $0.exercise?.id == live.id }) else { throw WorkoutCreationV1Error.staleDefinition }
            let localMatches = try context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID }))
            guard localMatches.count == 1, let local = localMatches.first, !local.isArchived,
                  local.name == entry.exerciseName else {
                throw WorkoutCreationV1Error.staleDefinition
            }
            let localMetricIDs = local.metrics.map(\.id)
            guard Set(localMetricIDs).count == localMetricIDs.count,
                  Self.sortedSnapshots(local.metrics.filter(\.isActive)) == entry.metricSnapshots else {
                throw WorkoutCreationV1Error.staleDefinition
            }
            liveExercises[exerciseID] = local
        }

        let workout = Workout(day: day, records: [], calendar: calendar)
        var records: [ExerciseRecord] = []
        for (recordIndex, entry) in validated.enumerated() {
            guard let live = liveExercises[entry.exerciseID] else { throw WorkoutCreationV1Error.staleDefinition }
            var sets: [SetRecord] = []
            for (setIndex, draft) in entry.sets.enumerated() {
                var values: [MetricValue] = []
                for metric in entry.metricSnapshots {
                    guard let liveMetric = live.metrics.first(where: { $0.id == metric.id }) else {
                        throw WorkoutCreationV1Error.staleDefinition
                    }
                    values.append(MetricValue(metric: liveMetric, scaledValue: draft.parsedValues[metric.id] ?? nil))
                }
                sets.append(SetRecord(sortOrder: setIndex + 1, values: values))
            }
            records.append(ExerciseRecord(exercise: live, sortOrder: recordIndex, sets: sets))
        }
        workout.records = records
        do {
            context.insert(workout)
            try persist(context)
            return workout
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func sortedSnapshots(_ metrics: [MetricDefinition]) -> [MetricDefinitionSnapshot] {
        let snapshots: [MetricDefinitionSnapshot] = metrics.map(MetricDefinitionSnapshot.init)
        return snapshots.sorted {
            if $0.sortOrder == $1.sortOrder { return $0.id.uuidString < $1.id.uuidString }
            return $0.sortOrder < $1.sortOrder
        }
    }
}

enum WorkoutCreationV1Error: LocalizedError {
    case unsavedContext
    case invalidEntries
    case staleDefinition

    var errorDescription: String? {
        switch self {
        case .unsavedContext: "未保存の変更があります。先に保存してから新しい運動記録を作成してください。"
        case .invalidEntries: "入力内容を確認してください。"
        case .staleDefinition: "種目または記録項目が変更されています。画面を開き直してください。"
        }
    }
}

// V2専用の新規Workout保存境界。V1 containerからは呼び出さず、V2 entityをfetchしない。
@MainActor enum WorkoutCreationV2 {
    static func makeEntryDraft(for exercise: Exercise, in context: ModelContext) throws -> WorkoutEntryDraft {
        guard !context.hasChanges else { throw WorkoutCreationV2Error.unsavedContext }
        let readContext = ModelContext(context.container)
        let exerciseID = exercise.id
        let matches = try readContext.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID }))
        guard matches.count == 1, let latest = matches.first, !latest.isArchived,
              latest.name == exercise.name,
              latest.metrics.map(MetricDefinitionSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString })
                == exercise.metrics.map(MetricDefinitionSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) else {
            throw WorkoutCreationV2Error.missingReference
        }
        let revisions = try readContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
        var baselines: [UUID: MetricDefinitionHistoryBaseline] = [:]
        for metric in latest.metrics where metric.isActive {
            let matches = revisions.filter { $0.metricID == metric.id }
            guard Set(matches.map(\.revision)).count == matches.count else { throw MetricValueRevisionLinkingError.duplicateRevision }
            if let current = matches.max(by: { $0.revision < $1.revision }) {
                baselines[metric.id] = .latestRevision(current.id)
            } else { baselines[metric.id] = .noHistory }
        }
        var draft = WorkoutEntryDraft(exercise: exercise)
        draft.historyBaseline = WorkoutEntryHistoryBaseline(
            metrics: latest.metrics.map(MetricDefinitionSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString },
            history: baselines
        )
        return draft
    }

    static func save(day: Date, entries: [WorkoutEntryDraft], in context: ModelContext, calendar: Calendar = .current, persist: (ModelContext) throws -> Void = { try $0.save() }) throws -> Workout {
        guard !context.hasChanges else { throw WorkoutCreationV2Error.unsavedContext }
        guard calendar.startOfDay(for: day) <= calendar.startOfDay(for: .now) else {
            throw WorkoutCreationV2Error.invalidEntries
        }
        guard !entries.isEmpty,
              Set(entries.map { $0.exercise.id }).count == entries.count else {
            throw WorkoutCreationV2Error.invalidEntries
        }
        guard case let .success(validated) = WorkoutSetDraftEditing.validatedEntries(entries) else {
            throw WorkoutCreationV2Error.invalidEntries
        }

        // 新しいcontextは永続store上の最新定義の照合だけに使う。
        let readContext = ModelContext(context.container)
        let freshHistory = try readContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
        for entry in validated {
            guard let baseline = entry.historyBaseline,
                  baseline.metrics == entry.exercise.metrics.map(MetricDefinitionSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) else {
                throw WorkoutCreationV2Error.missingReference
            }
            let activeIDs = entry.exercise.metrics.filter(\.isActive).map(\.id)
            guard Set(activeIDs) == Set(baseline.history.keys) else { throw WorkoutCreationV2Error.missingReference }
            for metricID in activeIDs {
                let revisions = freshHistory.filter { $0.metricID == metricID }
                guard Set(revisions.map(\.revision)).count == revisions.count else { throw MetricValueRevisionLinkingError.duplicateRevision }
                let current = revisions.max(by: { $0.revision < $1.revision }).map { MetricDefinitionHistoryBaseline.latestRevision($0.id) } ?? .noHistory
                guard baseline.history[metricID] == current else { throw WorkoutCreationV2Error.missingReference }
            }
            let exerciseID = entry.exercise.id
            let latestExercises = try readContext.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID }))
            guard latestExercises.count == 1, let latestExercise = latestExercises.first,
                  latestExercise.name == entry.exercise.name,
                  !latestExercise.isArchived else { throw WorkoutCreationV2Error.missingReference }

            let entryMetrics = entry.exercise.metrics.filter(\.isActive)
            let latestMetrics = latestExercise.metrics.filter(\.isActive)
            let entryMetricIDs = entryMetrics.map(\.id)
            let latestMetricIDs = latestMetrics.map(\.id)
            guard Set(entryMetricIDs).count == entryMetricIDs.count,
                  Set(latestMetricIDs).count == latestMetricIDs.count else {
                throw WorkoutCreationV2Error.ambiguousMetric
            }
            let byID = Dictionary(uniqueKeysWithValues: entryMetrics.map { ($0.id, MetricDefinitionSnapshot($0)) })
            guard entryMetrics.count == latestMetrics.count,
                  latestMetrics.allSatisfy({ byID[$0.id] == MetricDefinitionSnapshot($0) }) else {
                throw WorkoutCreationV2Error.missingReference
            }
        }
        // 履歴baseline照合後からsaveまでのTOCTOU競合は未解決で、この確認だけでは防げない。
        let storedExercises = try context.fetch(FetchDescriptor<Exercise>())
        let storedMetrics = try context.fetch(FetchDescriptor<MetricDefinition>())
        for entry in validated {
            guard let storedExercise = storedExercises.first(where: { $0.id == entry.exercise.id }),
                  storedExercise.name == entry.exercise.name,
                  !storedExercise.isArchived else { throw WorkoutCreationV2Error.missingReference }
            let activeMetrics = entry.exercise.metrics.filter(\.isActive)
            guard Set(activeMetrics.map(\.id)).count == activeMetrics.count else {
                throw WorkoutCreationV2Error.ambiguousMetric
            }
            for metric in activeMetrics {
                guard let storedMetric = storedMetrics.first(where: { $0.id == metric.id }),
                      storedMetric.exercise?.id == storedExercise.id,
                      storedMetric.isActive,
                      storedMetric.name == metric.name, storedMetric.unit == metric.unit,
                      storedMetric.allowsDecimal == metric.allowsDecimal,
                      storedMetric.isRequired == metric.isRequired,
                      storedMetric.sortOrder == metric.sortOrder else {
                    throw WorkoutCreationV2Error.missingReference
                }
            }
        }
        let history = try context.fetch(FetchDescriptor<MetricDefinitionRevision>())
        var selected: [UUID: MetricDefinitionRevision] = [:]
        for metric in validated.flatMap({ $0.exercise.metrics.filter(\.isActive) }) {
            guard selected[metric.id] == nil else { continue }
            let revisions = history.filter { $0.metricID == metric.id }
            guard Set(revisions.map(\.revision)).count == revisions.count else {
                throw MetricValueRevisionLinkingError.duplicateRevision
            }
            if let current = revisions.max(by: { $0.revision < $1.revision }) {
                guard MetricValueRevisionLinking.matchesSnapshot(metric, revision: current) else { throw MetricValueRevisionLinkingError.snapshotMismatch }
                selected[metric.id] = current
            } else {
                let initial = MetricDefinitionRevision(metricID: metric.id, revision: 1, name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: metric.sortOrder)
                selected[metric.id] = initial
            }
        }

        let workout = Workout(day: day, records: [], calendar: calendar)
        var records: [ExerciseRecord] = []
        var sets: [SetRecord] = []
        var values: [MetricValue] = []
        var newRevisions: [MetricDefinitionRevision] = []
        var links: [MetricValueRevisionLink] = []
        for (recordIndex, entry) in validated.enumerated() {
            let recordSets = entry.sets.enumerated().map { setIndex, draft in
                let setValues = entry.exercise.metrics.filter(\.isActive).sorted { $0.sortOrder < $1.sortOrder }.map { metric in
                    let value = MetricValue(metric: metric, scaledValue: draft.parsedValues[metric.id] ?? nil)
                    return value
                }
                let set = SetRecord(sortOrder: setIndex + 1, values: setValues)
                sets.append(set)
                values.append(contentsOf: setValues)
                return set
            }
            records.append(ExerciseRecord(exercise: entry.exercise, sortOrder: recordIndex, sets: recordSets))
        }
        workout.records = records
        newRevisions = selected.values.filter { revision in !history.contains(where: { $0.id == revision.id }) }

        do {
            for revision in newRevisions { context.insert(revision) }
            context.insert(workout)
            for value in values {
                context.insert(value)
                guard let revision = selected[value.metricID] else { throw MetricValueRevisionLinkingError.missingEntity }
                links.append(try MetricValueRevisionLinking.register(value: value, revision: revision, in: context))
            }
            try persist(context)
            return workout
        } catch {
            // clean contextからの同期処理なので、失敗時はrollbackで処理中の変更を戻す。
            context.rollback()
            throw error
        }
    }
}

enum WorkoutCreationV2Error: LocalizedError {
    case unsavedContext
    case invalidEntries
    case missingReference
    case ambiguousMetric

    var errorDescription: String? {
        switch self {
        case .unsavedContext: "未保存の変更があります。先に保存してから新しい運動記録を作成してください。"
        case .invalidEntries: "入力内容を確認してください。"
        case .missingReference: "種目または項目が見つからないか、変更されています。画面を開き直してください。"
        case .ambiguousMetric: "項目IDが重複しているため、運動記録を作成できません。"
        }
    }
}

enum MeleteSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        MeleteSchemaV1.models + [MetricDefinitionRevision.self, MetricValueRevisionLink.self]
    }
}

enum MeleteMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MeleteSchemaV1.self, MeleteSchemaV2.self] }
    static var stages: [MigrationStage] {
        [MigrationStage.lightweight(fromVersion: MeleteSchemaV1.self, toVersion: MeleteSchemaV2.self)]
    }
}

// V2の既存書き込み境界へ委譲し、アプリ側の書き込み経路を集約する。
@MainActor final class WorkoutWritingServiceV2 {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func saveMetricDefinitions(_ drafts: [MetricDefinitionDraft], for exercise: Exercise) throws {
        try MetricDefinitionEditingV2.save(drafts, for: exercise, in: context)
    }

    func createWorkout(day: Date, entries: [WorkoutEntryDraft], calendar: Calendar = .current) throws -> Workout {
        try WorkoutCreationV2.save(day: day, entries: entries, in: context, calendar: calendar)
    }

    func makeWorkoutEntryDraft(for exercise: Exercise) throws -> WorkoutEntryDraft {
        try WorkoutCreationV2.makeEntryDraft(for: exercise, in: context)
    }

    func saveWorkoutEdits(_ drafts: [WorkoutValueEditDraft], additions: [WorkoutSetAdditionDraft], day: Date, to workout: Workout, exercises: [Exercise], calendar: Calendar = .current, now: Date = .now) throws {
        try WorkoutValueEditingV2.save(drafts, additions: additions, day: day, to: workout, exercises: exercises, in: context, calendar: calendar, now: now)
    }

    func appendSetDraft(for record: ExerciseRecord, exercise: Exercise) throws -> WorkoutSetAdditionDraft? {
        try WorkoutValueEditingV2.appendSetDraft(for: record, exercise: exercise, in: context)
    }

    func deleteSet(_ target: WorkoutSetDeletionTarget) throws {
        try WorkoutDeletionV2.deleteSet(target, in: context)
    }

    func captureSetDeletionTarget(workout: Workout, record: ExerciseRecord, set: SetRecord) throws -> WorkoutSetDeletionTarget {
        try WorkoutDeletionV2.captureSetDeletionTarget(workout: workout, record: record, set: set, in: context)
    }

    func captureRecordDeletionTarget(workout: Workout, record: ExerciseRecord) throws -> WorkoutRecordDeletionTarget {
        try WorkoutDeletionV2.captureRecordDeletionTarget(workout: workout, record: record, in: context)
    }

    func deleteRecord(_ target: WorkoutRecordDeletionTarget) throws {
        try WorkoutDeletionV2.deleteRecord(target, in: context)
    }

    func captureWorkoutDeletionTarget(workout: Workout) throws -> WorkoutDeletionTarget {
        try WorkoutDeletionV2.captureWorkoutDeletionTarget(workout: workout, in: context)
    }

    func deleteWorkout(_ target: WorkoutDeletionTarget) throws {
        try WorkoutDeletionV2.delete(target, in: context)
    }
}

@Model final class Exercise {
    var id: UUID
    var name: String
    var isArchived: Bool
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \MetricDefinition.exercise) var metrics: [MetricDefinition]

    init(name: String, metrics: [MetricDefinition]) {
        id = UUID()
        self.name = name
        isArchived = false
        createdAt = .now
        self.metrics = metrics
    }
}

@Model final class MetricDefinition {
    var id: UUID
    var name: String
    var unit: String
    var allowsDecimal: Bool
    var isRequired: Bool
    var isActive: Bool
    var sortOrder: Int
    var exercise: Exercise?

    init(name: String, unit: String, allowsDecimal: Bool, isRequired: Bool, sortOrder: Int) {
        id = UUID()
        self.name = name
        self.unit = unit
        self.allowsDecimal = allowsDecimal
        self.isRequired = isRequired
        isActive = true
        self.sortOrder = sortOrder
    }
}

@Model final class Workout {
    var id: UUID
    var day: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \ExerciseRecord.workout) var records: [ExerciseRecord]

    init(day: Date, records: [ExerciseRecord], calendar: Calendar = .current) {
        id = UUID()
        self.day = Self.dayString(from: day, calendar: calendar)
        createdAt = .now
        self.records = records
    }

    static func dayString(from date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

@Model final class ExerciseRecord {
    var id: UUID
    var exerciseID: UUID
    var exerciseName: String
    var sortOrder: Int
    var workout: Workout?
    @Relationship(deleteRule: .cascade, inverse: \SetRecord.exerciseRecord) var sets: [SetRecord]

    init(exercise: Exercise, sortOrder: Int, sets: [SetRecord]) {
        id = UUID()
        exerciseID = exercise.id
        exerciseName = exercise.name
        self.sortOrder = sortOrder
        self.sets = sets
    }
}

@Model final class SetRecord {
    var id: UUID
    var sortOrder: Int
    var createdAt: Date
    var exerciseRecord: ExerciseRecord?
    @Relationship(deleteRule: .cascade, inverse: \MetricValue.setRecord) var values: [MetricValue]

    init(sortOrder: Int, values: [MetricValue]) {
        id = UUID()
        self.sortOrder = sortOrder
        createdAt = .now
        self.values = values
    }
}

@Model final class MetricValue {
    var id: UUID
    var metricID: UUID
    var name: String
    var unit: String
    var allowsDecimal: Bool
    var isRequired: Bool
    var scaledValue: Int64?
    var setRecord: SetRecord?

    init(metric: MetricDefinition, scaledValue: Int64?) {
        id = UUID()
        metricID = metric.id
        name = metric.name
        unit = metric.unit
        allowsDecimal = metric.allowsDecimal
        isRequired = metric.isRequired
        self.scaledValue = scaledValue
    }
}
