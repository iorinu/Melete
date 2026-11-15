import Foundation
import SwiftData

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

enum WorkoutDeletionError: LocalizedError {
    case notFound

    var errorDescription: String? {
        "削除対象の運動記録が見つかりません。履歴を更新してから再度お試しください。"
    }
}

struct WorkoutValueEditDraft {
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

enum WorkoutValueEditing {
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

    static func save(_ drafts: [WorkoutValueEditDraft], to workout: Workout, persist: () throws -> Void) throws {
        guard case let .success(values) = validatedValues(from: drafts) else {
            throw WorkoutValueEditError.invalidDrafts
        }
        let originalValues = workout.records.flatMap { $0.sets }.flatMap(\.values).map { ($0.id, $0.scaledValue) }
        apply(values, to: workout)
        do {
            try persist()
        } catch {
            let modelValues = workout.records.flatMap({ $0.sets }).flatMap(\.values)
            for (valueID, original) in originalValues {
                modelValues.first(where: { $0.id == valueID })?.scaledValue = original
            }
            throw error
        }
    }
}

enum WorkoutValueEditError: LocalizedError {
    case invalid(exerciseName: String, setOrder: Int, metricName: String)
    case required(exerciseName: String, setOrder: Int, metricName: String)
    case invalidDrafts

    var errorDescription: String? {
        switch self {
        case let .invalid(exercise, set, metric): "\(exercise)・セット\(set)の「\(metric)」は0以上の有効な数値を入力してください。"
        case let .required(exercise, set, metric): "\(exercise)・セット\(set)の「\(metric)」は必須です。"
        case .invalidDrafts: "入力値を確認してください。"
        }
    }
}

enum MeleteSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [ any PersistentModel.Type ] {
        [Exercise.self, MetricDefinition.self, Workout.self, ExerciseRecord.self, SetRecord.self, MetricValue.self]
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
