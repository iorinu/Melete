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

struct MetricDefinitionDraft: Identifiable {
    let id: UUID
    let original: MetricDefinitionSnapshot?
    var name: String
    var unit: String
    var allowsDecimal: Bool
    var isRequired: Bool
    var isActive: Bool

    init(name: String, unit: String, allowsDecimal: Bool, isRequired: Bool, isActive: Bool = true) {
        id = UUID()
        original = nil
        self.name = name
        self.unit = unit
        self.allowsDecimal = allowsDecimal
        self.isRequired = isRequired
        self.isActive = isActive
    }

    init(existing metric: MetricDefinition) {
        id = metric.id
        original = MetricDefinitionSnapshot(metric)
        name = metric.name
        unit = metric.unit
        allowsDecimal = metric.allowsDecimal
        isRequired = metric.isRequired
        isActive = metric.isActive
    }
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

enum MetricDefinitionEditing {
    static func draft(for exercise: Exercise) -> [MetricDefinitionDraft] {
        exercise.metrics.sorted { $0.sortOrder == $1.sortOrder ? $0.id.uuidString < $1.id.uuidString : $0.sortOrder < $1.sortOrder }.map(MetricDefinitionDraft.init(existing:))
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

enum WorkoutDeletion {
    static func delete(workoutID: UUID, in context: ModelContext) throws {
        let descriptor = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID })
        guard let workout = try context.fetch(descriptor).first else {
            throw WorkoutDeletionError.notFound
        }
        context.delete(workout)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
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

    init(workout: Workout, record: ExerciseRecord, set: SetRecord) {
        workoutID = workout.id
        recordID = record.id
        setID = set.id
        recordSnapshot = WorkoutRecordSnapshot(record)
        workoutRecords = workout.records.map(WorkoutRecordSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
        workoutDay = workout.day
    }
}

struct WorkoutRecordDeletionTarget: Equatable {
    let workoutID: UUID
    let workoutDay: String
    let record: WorkoutRecordSnapshot
    let workoutRecords: [WorkoutRecordSnapshot]

    init(workout: Workout, record: ExerciseRecord) {
        workoutID = workout.id; workoutDay = workout.day
        self.record = WorkoutRecordSnapshot(record)
        workoutRecords = workout.records.map(WorkoutRecordSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

@MainActor enum WorkoutSetDeletion {
    static func delete(_ target: WorkoutSetDeletionTarget, in context: ModelContext, persist: () throws -> Void) throws {
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        let workoutID = target.workoutID
        let descriptor = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID })
        guard let workout = try context.fetch(descriptor).first,
              workout.day == target.workoutDay,
              let record = workout.records.first(where: { $0.id == target.recordID }),
              workout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == target.workoutRecords,
              WorkoutRecordSnapshot(record) == target.recordSnapshot,
              let set = record.sets.first(where: { $0.id == target.setID }) else {
            throw WorkoutSetDeletionError.changed
        }
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }

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
        guard let workout = try context.fetch(descriptor).first, workout.day == target.workoutDay,
              workout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == target.workoutRecords,
              let record = workout.records.first(where: { $0.id == target.record.id }),
              WorkoutRecordSnapshot(record) == target.record else { throw WorkoutSetDeletionError.changed }
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
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
            exerciseName: source.exerciseName, metrics: source.metrics, values: source.values
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
        workout.records.sorted { $0.sortOrder < $1.sortOrder }.flatMap { record in
            record.sets.sorted { $0.sortOrder < $1.sortOrder }.flatMap { set in
                set.values.map { value in
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
        let metrics = exercise.metrics.filter(\.isActive).sorted { $0.sortOrder < $1.sortOrder }.map {
            WorkoutSetMetricDraft(id: $0.id, name: $0.name, unit: $0.unit, allowsDecimal: $0.allowsDecimal, isRequired: $0.isRequired)
        }
        return WorkoutSetAdditionDraft(id: UUID(), recordID: record.id, exerciseID: exercise.id, exerciseName: exercise.name, metrics: metrics, values: [:])
    }

    static func save(_ drafts: [WorkoutValueEditDraft], additions: [WorkoutSetAdditionDraft], day: Date, to workout: Workout, exercises: [Exercise], calendar: Calendar = .current, now: Date = .now, discard: (SetRecord) -> Void = { _ in }, persist: () throws -> Void) throws {
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
            let current = exercise.metrics.filter(\.isActive).sorted { $0.sortOrder < $1.sortOrder }.map {
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
    var revision: Int
    var name: String
    var unit: String
    var allowsDecimal: Bool
    var isRequired: Bool
    var sortOrder: Int

    init(id: UUID = UUID(), metricID: UUID, revision: Int, name: String, unit: String, allowsDecimal: Bool, isRequired: Bool, sortOrder: Int) {
        self.id = id
        self.metricID = metricID
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
    static func save(_ drafts: [WorkoutValueEditDraft], additions: [WorkoutSetAdditionDraft], day: Date, to workout: Workout, exercises: [Exercise], in context: ModelContext, calendar: Calendar = .current, now: Date = .now, persist: (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard !context.hasChanges else { throw WorkoutCreationV2Error.unsavedContext }
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

@MainActor enum WorkoutDeletionV2 {
    static func delete(workoutID: UUID, in context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        guard let workout = try context.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID })).first else { throw WorkoutDeletionError.notFound }
        let values = workout.records.flatMap(\.sets).flatMap(\.values)
        _ = try MetricValueRevisionLinking.removeLinks(for: values, in: context)
        context.delete(workout)
        do { try persist(context) } catch { context.rollback(); throw error }
    }

    static func deleteSet(_ target: WorkoutSetDeletionTarget, in context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        let workoutID = target.workoutID
        guard let workout = try context.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID })).first,
              workout.day == target.workoutDay,
              workout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == target.workoutRecords,
              let record = workout.records.first(where: { $0.id == target.recordID }),
              WorkoutRecordSnapshot(record) == target.recordSnapshot,
              let set = record.sets.first(where: { $0.id == target.setID }) else { throw WorkoutSetDeletionError.changed }
        _ = try MetricValueRevisionLinking.removeLinks(for: set.values, in: context)
        if record.sets.count == 1 { workout.records.removeAll { $0.id == record.id }; context.delete(record) }
        else { record.sets.removeAll { $0.id == set.id }; context.delete(set) }
        if workout.records.isEmpty { context.delete(workout) }
        do { try persist(context) } catch { context.rollback(); throw error }
    }

    static func deleteRecord(_ target: WorkoutRecordDeletionTarget, in context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard !context.hasChanges else { throw WorkoutSetDeletionError.unsavedContext }
        let workoutID = target.workoutID
        guard let workout = try context.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutID })).first,
              workout.day == target.workoutDay,
              workout.records.map(WorkoutRecordSnapshot.init).sorted(by: { $0.id.uuidString < $1.id.uuidString }) == target.workoutRecords,
              let record = workout.records.first(where: { $0.id == target.record.id }), WorkoutRecordSnapshot(record) == target.record else { throw WorkoutSetDeletionError.changed }
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

// V2専用の新規Workout保存境界。V1 containerからは呼び出さず、V2 entityをfetchしない。
@MainActor enum WorkoutCreationV2 {
    static func save(day: Date, entries: [WorkoutEntryDraft], in context: ModelContext, calendar: Calendar = .current, persist: (ModelContext) throws -> Void = { try $0.save() }) throws -> Workout {
        guard !context.hasChanges else { throw WorkoutCreationV2Error.unsavedContext }
        guard case let .success(validated) = WorkoutSetDraftEditing.validatedEntries(entries) else {
            throw WorkoutCreationV2Error.invalidEntries
        }

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
            for link in links { context.delete(link) }
            for value in values { context.delete(value) }
            for set in sets { context.delete(set) }
            for record in records { context.delete(record) }
            context.delete(workout)
            for revision in newRevisions { context.delete(revision) }
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
