import SwiftUI

private enum FormStyle {
    static let accent = Color(red: 0.76, green: 0.31, blue: 0.16)
}

struct MetricDraft: Identifiable {
    let id = UUID()
    var name = ""
    var unit = ""
    var allowsDecimal = false
    var isRequired = true
}

struct ExerciseForm: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: (String, [MetricDraft]) -> Bool
    @State private var name = ""
    @State private var metrics = [MetricDraft()]
    @State private var validationError: String?

    @ViewBuilder
    private func formHeading(eyebrow: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(eyebrow).font(.caption.weight(.bold)).tracking(2).foregroundStyle(FormStyle.accent)
            Text(title).font(.system(.title, design: .rounded).weight(.bold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            formHeading(eyebrow: "", title: "種目を作成", subtitle: "記録する数値項目を設定します。")
            Form {
                Section("基本情報") {
                    TextField("種目名", text: $name).accessibilityIdentifier("exerciseNameField")
                }
                Section("記録項目") {
                    ForEach($metrics) { $metric in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("項目名（例: 重量）", text: $metric.name).accessibilityIdentifier("metricNameField\(metrics.firstIndex(where: { $0.id == metric.id }) ?? 0)")
                            HStack {
                                TextField("単位（例: kg）", text: $metric.unit).accessibilityIdentifier("metricUnitField\(metrics.firstIndex(where: { $0.id == metric.id }) ?? 0)").frame(maxWidth: 150)
                                Picker("形式", selection: $metric.allowsDecimal) {
                                    Text("整数").tag(false)
                                    Text("小数（第3位まで）").tag(true)
                                }.accessibilityIdentifier("metricFormatPicker\(metrics.firstIndex(where: { $0.id == metric.id }) ?? 0)").frame(maxWidth: 210)
                                Toggle("必須", isOn: $metric.isRequired).toggleStyle(.checkbox)
                            }
                        }.padding(.vertical, 4)
                    }
                    Button("項目を追加", systemImage: "plus") { metrics.append(MetricDraft()) }
                    if metrics.count > 1 {
                        Button("最後の項目を削除", role: .destructive) { metrics.removeLast() }
                    }
                }
            }
            if let validationError { Text(validationError).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("作成") {
                    let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanedMetrics = metrics.map { draft -> MetricDraft in
                        var result = draft
                        result.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        result.unit = draft.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                        return result
                    }
                    guard !cleanedName.isEmpty, !cleanedMetrics.isEmpty,
                          cleanedMetrics.allSatisfy({ !$0.name.isEmpty && !$0.unit.isEmpty }),
                          Set(cleanedMetrics.map { $0.name.lowercased() }).count == cleanedMetrics.count else {
                        validationError = "種目名・項目名・単位を入力してください。項目名は重複できません。"
                        return
                    }
                    if onSave(cleanedName, cleanedMetrics) { dismiss() }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("saveExerciseButton")
            }
        }.padding(26).frame(minWidth: 570, idealWidth: 610, minHeight: 520, idealHeight: 590)
            .tint(FormStyle.accent)
    }
}

struct ExerciseNameEditForm: View {
    @Environment(\.dismiss) private var dismiss
    let exercise: Exercise
    var onSave: (String) -> String?
    @State private var name: String
    @State private var validationError: String?

    init(exercise: Exercise, onSave: @escaping (String) -> String?) {
        self.exercise = exercise
        self.onSave = onSave
        _name = State(initialValue: exercise.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("種目名を編集").font(.system(.title, design: .rounded).weight(.bold))
                Text("過去の運動記録には、記録当時の種目名が残ります。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Form {
                Section("基本情報") {
                    TextField("種目名", text: $name).accessibilityIdentifier("editExerciseNameField")
                }
            }
            if let validationError { Text(validationError).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") {
                    guard let cleaned = ExerciseNameEditing.validatedName(name) else {
                        validationError = ExerciseNameEditError.emptyName.localizedDescription
                        return
                    }
                    guard let error = onSave(cleaned) else { dismiss(); return }
                    validationError = error
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("saveExerciseNameButton")
            }
        }
        .padding(26)
        .frame(minWidth: 500, idealWidth: 570, minHeight: 250, idealHeight: 300)
        .tint(FormStyle.accent)
    }
}

struct MetricDefinitionEditForm: View {
    @Environment(\.dismiss) private var dismiss
    let exercise: Exercise
    let allowsExistingDefinitionEditing: Bool
    var onSave: ([MetricDefinitionDraft]) -> String?
    @State private var metrics: [MetricDefinitionDraft]
    @State private var validationError: String?

    init(exercise: Exercise, allowsExistingDefinitionEditing: Bool = false, initialDrafts: [MetricDefinitionDraft]? = nil, onSave: @escaping ([MetricDefinitionDraft]) -> String?) {
        self.exercise = exercise
        self.allowsExistingDefinitionEditing = allowsExistingDefinitionEditing
        self.onSave = onSave
        _metrics = State(initialValue: initialDrafts ?? MetricDefinitionEditing.draft(for: exercise))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("記録項目を管理").font(.system(.title, design: .rounded).weight(.bold))
                Text(allowsExistingDefinitionEditing
                     ? "\(exercise.name)の項目定義を編集できます。過去の記録は記録当時の名前・単位・入力条件・値を保持します。"
                     : "\(exercise.name)の項目を追加し、入力欄で使うかを選びます。過去の記録は変更されません。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Form {
                Section("項目一覧") {
                    ForEach($metrics) { $metric in
                        VStack(alignment: .leading, spacing: 8) {
                            if metric.original == nil || allowsExistingDefinitionEditing {
                                TextField("項目名（例: 重量）", text: $metric.name)
                                    .accessibilityIdentifier("metricDefinitionName_\(metric.id.uuidString)")
                                HStack {
                                    TextField("単位（例: kg）", text: $metric.unit)
                                        .accessibilityIdentifier("metricDefinitionUnit_\(metric.id.uuidString)")
                                        .frame(maxWidth: 130)
                                    Picker("形式", selection: $metric.allowsDecimal) {
                                        Text("整数").tag(false)
                                        Text("小数（第3位まで）").tag(true)
                                    }
                                    .accessibilityIdentifier("metricDefinitionFormat_\(metric.id.uuidString)")
                                    .frame(maxWidth: 200)
                                    Toggle("必須", isOn: $metric.isRequired)
                                        .accessibilityIdentifier("metricDefinitionRequired_\(metric.id.uuidString)")
                                        .toggleStyle(.checkbox)
                                }
                            } else {
                                Text("\(metric.name)（\(metric.unit)）・\(metric.allowsDecimal ? "小数" : "整数")・\(metric.isRequired ? "必須" : "任意")")
                                    .font(.subheadline.weight(.medium))
                                    .accessibilityIdentifier("metricDefinitionSummary_\(metric.id.uuidString)")
                            }
                            Toggle(metric.isActive ? "入力欄で使用中" : "入力欄から外しています", isOn: $metric.isActive)
                                .accessibilityIdentifier("metricDefinitionActive_\(metric.id.uuidString)")
                                .toggleStyle(.switch)
                        }
                        .padding(.vertical, 5)
                    }
                    Button("項目を追加", systemImage: "plus") {
                        metrics.append(MetricDefinitionDraft(name: "", unit: "", allowsDecimal: false, isRequired: true))
                    }
                    .accessibilityIdentifier("addMetricDefinitionButton")
                }
            }
            if let validationError { Text(validationError).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") {
                    if let error = onSave(metrics) { validationError = error } else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("saveMetricDefinitionsButton")
            }
        }
        .padding(26)
        .frame(minWidth: 600, idealWidth: 670, minHeight: 450, idealHeight: 620)
        .tint(FormStyle.accent)
    }
}

struct WorkoutEntryDraft: Identifiable {
    let id = UUID()
    let exercise: Exercise
    var sets: [WorkoutSetDraft] = [WorkoutSetDraft()]
    // nilはV1またはV2 baseline未取得を表す。
    var historyBaseline: WorkoutEntryHistoryBaseline? = nil
}

struct WorkoutEntryHistoryBaseline: Equatable {
    let metrics: [MetricDefinitionSnapshot]
    let history: [UUID: MetricDefinitionHistoryBaseline]
}

struct WorkoutSetDraft: Identifiable {
    let id: UUID
    var values: [UUID: String] = [:]
    var parsedValues: [UUID: Int64?] = [:]

    init(values: [UUID: String] = [:]) {
        id = UUID()
        self.values = values
    }

    init(copying draft: WorkoutSetDraft) {
        id = UUID()
        values = draft.values
    }
}

enum WorkoutSetDraftEditing {
    static func duplicate(entryID: UUID, setID: UUID, in entries: inout [WorkoutEntryDraft]) {
        guard let entryIndex = entries.firstIndex(where: { $0.id == entryID }),
              let setIndex = entries[entryIndex].sets.firstIndex(where: { $0.id == setID }) else { return }
        entries[entryIndex].sets.insert(WorkoutSetDraft(copying: entries[entryIndex].sets[setIndex]), at: setIndex + 1)
    }

    static func remove(entryID: UUID, setID: UUID, from entries: inout [WorkoutEntryDraft]) {
        guard let entryIndex = entries.firstIndex(where: { $0.id == entryID }),
              let setIndex = entries[entryIndex].sets.firstIndex(where: { $0.id == setID }),
              entries[entryIndex].sets.count > 1 else { return }
        entries[entryIndex].sets.remove(at: setIndex)
    }

    static func validatedEntries(_ entries: [WorkoutEntryDraft]) -> Result<[WorkoutEntryDraft], WorkoutSetDraftValidationError> {
        for entry in entries {
            let metrics = entry.exercise.metrics.filter(\.isActive)
            guard !metrics.isEmpty else {
                return .failure(WorkoutSetDraftValidationError(message: "\(entry.exercise.name)は有効な記録項目がないため、セットを保存できません。項目を復帰してから再度お試しください。"))
            }
            for (index, set) in entry.sets.enumerated() {
                for metric in metrics {
                    let raw = set.values[metric.id] ?? ""
                    let value = raw.isEmpty ? nil : MetricInput.parse(raw, allowsDecimal: metric.allowsDecimal)
                    if !raw.isEmpty && value == nil {
                        return .failure(WorkoutSetDraftValidationError(message: "\(entry.exercise.name)・セット\(index + 1)の「\(metric.name)」は0以上の有効な数値を入力してください。"))
                    }
                    if metric.isRequired && value == nil {
                        return .failure(WorkoutSetDraftValidationError(message: "\(entry.exercise.name)・セット\(index + 1)の「\(metric.name)」は必須です。"))
                    }
                }
            }
        }
        var validatedEntries = entries
        for entryIndex in validatedEntries.indices {
            for setIndex in validatedEntries[entryIndex].sets.indices {
                var parsed: [UUID: Int64?] = [:]
                for metric in validatedEntries[entryIndex].exercise.metrics where metric.isActive {
                    let raw = validatedEntries[entryIndex].sets[setIndex].values[metric.id] ?? ""
                    parsed[metric.id] = raw.isEmpty ? nil : MetricInput.parse(raw, allowsDecimal: metric.allowsDecimal)
                }
                validatedEntries[entryIndex].sets[setIndex].parsedValues = parsed
            }
        }
        return .success(validatedEntries)
    }
}

struct WorkoutSetDraftValidationError: Error {
    let message: String
}

struct WorkoutForm: View {
    @Environment(\.dismiss) private var dismiss
    let exercises: [Exercise]
    var onSave: (Date, [WorkoutEntryDraft]) -> Bool
    var makeEntryDraft: (Exercise) throws -> WorkoutEntryDraft
    @State private var day: Date
    @State private var entries: [WorkoutEntryDraft] = []
    @State private var selectedExerciseID: UUID?
    @State private var validationError: String?

    init(exercises: [Exercise], initialDay: Date? = nil, makeEntryDraft: @escaping (Exercise) throws -> WorkoutEntryDraft = { WorkoutEntryDraft(exercise: $0) }, onSave: @escaping (Date, [WorkoutEntryDraft]) -> Bool) {
        self.exercises = exercises
        self.makeEntryDraft = makeEntryDraft
        self.onSave = onSave
        _day = State(initialValue: Calendar.current.startOfDay(for: initialDay ?? .now))
    }

    @ViewBuilder
    private func formHeading(eyebrow: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !eyebrow.isEmpty {
                Text(eyebrow).font(.caption.weight(.bold)).tracking(2).foregroundStyle(FormStyle.accent)
            }
            Text(title).font(.system(.title, design: .rounded).weight(.bold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            formHeading(eyebrow: "", title: "運動を追加", subtitle: "日付、種目、セットごとの数値を入力します。")
            Form {
                DatePicker("運動日", selection: $day, in: ...Date.now, displayedComponents: .date)
                Section("種目") {
                    if entries.isEmpty {
                        Text("まだ種目を追加していません。").foregroundStyle(.secondary)
                    }
                    ForEach($entries) { $entry in
                        entryEditor(entry: $entry)
                    }
                    if !exercises.isEmpty {
                        HStack {
                            Picker("種目を選択", selection: $selectedExerciseID) {
                                Text("選択してください").tag(UUID?.none)
                                ForEach(exercises) { exercise in Text(exercise.name).tag(Optional(exercise.id)) }
                            }.accessibilityIdentifier("exercisePicker")
                            Button("追加") { addSelectedExercise() }.disabled(selectedExerciseID == nil).accessibilityIdentifier("addExerciseToWorkoutButton")
                        }
                    }
                }
            }
            if let validationError { Text(validationError).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") { save() }.keyboardShortcut(.defaultAction).disabled(entries.isEmpty)
                    .accessibilityIdentifier("saveWorkoutButton")
            }
        }.padding(26).frame(minWidth: 620, idealWidth: 680, minHeight: 600, idealHeight: 700)
            .tint(FormStyle.accent)
            .onAppear { selectedExerciseID = exercises.first?.id }
    }

    @ViewBuilder private func entryEditor(entry: Binding<WorkoutEntryDraft>) -> some View {
        let metrics = entry.wrappedValue.exercise.metrics.filter(\.isActive).sorted { $0.sortOrder < $1.sortOrder }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.wrappedValue.exercise.name).font(.headline)
                Spacer()
                Button("種目を外す", role: .destructive) {
                    entries.removeAll { $0.id == entry.wrappedValue.id }
                }
            }
            ForEach(entry.wrappedValue.sets) { set in
                let setIndex = entry.wrappedValue.sets.firstIndex(where: { $0.id == set.id }) ?? 0
                VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("セット \(setIndex + 1)").font(.headline)
                        Spacer()
                        Button("複製") { WorkoutSetDraftEditing.duplicate(entryID: entry.wrappedValue.id, setID: set.id, in: &entries) }
                            .accessibilityLabel("\(entry.wrappedValue.exercise.name)・セット\(setIndex + 1)を複製")
                            .accessibilityIdentifier("duplicateSet_\(set.id.uuidString)")
                        if entry.wrappedValue.sets.count > 1 {
                            Button("削除", role: .destructive) { WorkoutSetDraftEditing.remove(entryID: entry.wrappedValue.id, setID: set.id, from: &entries) }
                        }
                    }
                    ForEach(metrics) { metric in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(metric.name)（\(metric.unit)）\(metric.isRequired ? "*" : "" )")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            TextField(metric.allowsDecimal ? "0.000まで" : "0以上の整数", text: valueBinding(entry: entry, setID: set.id, metric: metric))
                                .frame(minWidth: 100, maxWidth: 180)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("set\(setIndex + 1)_metric_\(metric.name)")
                        }
                    }
                }
                .padding(14)
                .overlay(alignment: .top) {
                    Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
                }
            }
            Button("セットを追加", systemImage: "plus") { entry.wrappedValue.sets.append(WorkoutSetDraft()) }.accessibilityIdentifier("addSetButton")
        }.padding(.vertical, 8)
    }

    private func valueBinding(entry: Binding<WorkoutEntryDraft>, setID: UUID, metric: MetricDefinition) -> Binding<String> {
        Binding(get: {
            entry.wrappedValue.sets.first(where: { $0.id == setID })?.values[metric.id] ?? ""
        }, set: { text in
            guard let index = entry.wrappedValue.sets.firstIndex(where: { $0.id == setID }) else { return }
            entry.wrappedValue.sets[index].values[metric.id] = text
        })
    }

    private func addSelectedExercise() {
        guard let selectedExerciseID,
              let exercise = exercises.first(where: { $0.id == selectedExerciseID }),
              !entries.contains(where: { $0.exercise.id == exercise.id }) else { return }
        do { entries.append(try makeEntryDraft(exercise)); validationError = nil }
        catch { validationError = error.localizedDescription; return }
        self.selectedExerciseID = exercises.first(where: { candidate in !entries.contains(where: { $0.exercise.id == candidate.id }) })?.id
    }

    private func save() {
        let calendar = Calendar.current
        guard calendar.startOfDay(for: day) <= calendar.startOfDay(for: .now) else { validationError = "運動日は今日以前の日付を選択してください。"; return }
        let validatedEntries: [WorkoutEntryDraft]
        switch WorkoutSetDraftEditing.validatedEntries(entries) {
        case .failure(let error): validationError = error.message; return
        case .success(let result): validatedEntries = result
        }
        guard onSave(day, validatedEntries) else { return }
        dismiss()
    }

    private static func parseValue(_ text: String, allowsDecimal: Bool) -> Int64? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.range(of: allowsDecimal ? #"^[0-9]+(?:\.[0-9]{1,3})?$"# : #"^[0-9]+$"#, options: .regularExpression) != nil,
              let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), decimal >= 0 else { return nil }
        var scaled = decimal * Decimal(1000)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled, let number = Int64(NSDecimalNumber(decimal: rounded).stringValue),
              allowsDecimal || number % 1000 == 0 else { return nil }
        return number
    }

}

struct WorkoutValueEditForm: View {
    @Environment(\.dismiss) private var dismiss
    let workout: Workout
    let exercises: [Exercise]
    var onSave: (Date, [WorkoutValueEditDraft], [WorkoutSetAdditionDraft]) -> String?
    var makeAdditionDraft: (ExerciseRecord, Exercise) throws -> WorkoutSetAdditionDraft?
    var onDeleteSet: (WorkoutSetDeletionTarget) -> String?
    var captureSetDeletionTarget: (Workout, ExerciseRecord, SetRecord) throws -> WorkoutSetDeletionTarget
    var onDeleteRecord: (WorkoutRecordDeletionTarget) -> String?
    var captureRecordDeletionTarget: (Workout, ExerciseRecord) throws -> WorkoutRecordDeletionTarget
    @State private var drafts: [WorkoutValueEditDraft]
    @State private var day: Date
    @State private var validationError: String?
    @State private var additions = WorkoutSetAdditionDrafts()
    @State private var pendingSetDeletion: WorkoutSetDeletionTarget?
    @State private var pendingRecordDeletion: WorkoutRecordDeletionTarget?

    init(workout: Workout, exercises: [Exercise], onSave: @escaping (Date, [WorkoutValueEditDraft], [WorkoutSetAdditionDraft]) -> String?, makeAdditionDraft: @escaping (ExerciseRecord, Exercise) throws -> WorkoutSetAdditionDraft? = { record, exercise in WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise) }, onDeleteSet: @escaping (WorkoutSetDeletionTarget) -> String? = { _ in "削除を利用できません。" }, captureSetDeletionTarget: @escaping (Workout, ExerciseRecord, SetRecord) throws -> WorkoutSetDeletionTarget = { workout, record, set in WorkoutSetDeletionTarget(workout: workout, record: record, set: set) }, onDeleteRecord: @escaping (WorkoutRecordDeletionTarget) -> String? = { _ in "削除を利用できません。" }, captureRecordDeletionTarget: @escaping (Workout, ExerciseRecord) throws -> WorkoutRecordDeletionTarget = { workout, record in WorkoutRecordDeletionTarget(workout: workout, record: record) }) {
        self.workout = workout
        self.exercises = exercises
        self.onSave = onSave
        self.makeAdditionDraft = makeAdditionDraft
        self.onDeleteSet = onDeleteSet
        self.captureSetDeletionTarget = captureSetDeletionTarget
        self.onDeleteRecord = onDeleteRecord
        self.captureRecordDeletionTarget = captureRecordDeletionTarget
        _drafts = State(initialValue: WorkoutValueEditing.drafts(for: workout))
        let storedDay = WorkoutValueEditing.date(from: workout.day)
        _day = State(initialValue: storedDay ?? Calendar.current.startOfDay(for: .now))
        _validationError = State(initialValue: storedDay == nil ? WorkoutValueEditError.invalidStoredDay.localizedDescription : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("記録を編集").font(.system(.title, design: .rounded).weight(.bold))
                Text("日付と既存値を編集し、有効な種目にはセットを追加できます。アーカイブ済み種目には追加できません。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Form {
                DatePicker("運動日", selection: $day, in: ...Date.now, displayedComponents: .date)
                    .disabled(WorkoutValueEditing.date(from: workout.day) == nil)
                ForEach(workout.records.sorted { $0.sortOrder < $1.sortOrder }) { record in
                    Section(record.exerciseName) {
                        Button("この種目記録を削除", role: .destructive) {
                            do { pendingRecordDeletion = try captureRecordDeletionTarget(workout, record) }
                            catch { validationError = error.localizedDescription }
                        }
                        ForEach(record.sets.sorted { $0.sortOrder < $1.sortOrder }) { set in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("セット \(set.sortOrder)").font(.headline)
                                Button("このセットを削除", role: .destructive) {
                                    do { pendingSetDeletion = try captureSetDeletionTarget(workout, record, set) }
                                    catch { validationError = error.localizedDescription }
                                }
                                .accessibilityIdentifier("deleteWorkoutSet_\(set.id.uuidString)")
                                ForEach(drafts.indices.filter { index in
                                    set.values.contains { $0.id == drafts[index].valueID }
                                }, id: \.self) { index in
                                    HStack {
                                        Text("\(drafts[index].name)（\(drafts[index].unit)）\(drafts[index].isRequired ? "*" : "")")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        TextField(drafts[index].allowsDecimal ? "小数第3位まで" : "0以上の整数", text: $drafts[index].text)
                                            .frame(minWidth: 100, maxWidth: 180)
                                            .textFieldStyle(.roundedBorder)
                                            .accessibilityLabel("\(drafts[index].name)（\(drafts[index].unit)）\(drafts[index].isRequired ? "必須" : "任意")")
                                            .accessibilityIdentifier("edit_set\(set.sortOrder)_metric_\(drafts[index].name)")
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        ForEach(additions.items.filter { $0.recordID == record.id }) { addition in
                            VStack(alignment: .leading, spacing: 8) {
                                let additionIndex = additions.items.filter { $0.recordID == record.id }.firstIndex(where: { $0.id == addition.id }) ?? 0
                                Text("追加セット \(additionIndex + 1)（未保存）").font(.headline)
                                if addition.metrics.isEmpty {
                                    Text("有効な項目がないため、この種目にはセットを追加できません。")
                                        .foregroundStyle(.red)
                                }
                                ForEach(addition.metrics, id: \.id) { metric in
                                    HStack {
                                        Text("\(metric.name)（\(metric.unit)）\(metric.isRequired ? "*" : "")")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        TextField(metric.allowsDecimal ? "小数第3位まで" : "0以上の整数", text: additionBinding(draftID: addition.id, metric: metric))
                                            .frame(minWidth: 100, maxWidth: 180).textFieldStyle(.roundedBorder)
                                            .accessibilityIdentifier("addedSetMetric_\(addition.id.uuidString)_\(metric.id.uuidString)")
                                    }
                                }
                                Button("追加を取り消す", role: .destructive) {
                                    additions.cancel(id: addition.id)
                                }
                                if exercises.contains(where: { $0.id == record.exerciseID && !$0.isArchived }) {
                                    Button("複製") { additions.duplicate(id: addition.id) }
                                        .accessibilityLabel("追加セット \(additionIndex + 1)を複製")
                                        .accessibilityIdentifier("duplicateAdditionSet_\(addition.id.uuidString)")
                                }
                            }.padding(.vertical, 4)
                        }
                        if let exercise = exercises.first(where: { $0.id == record.exerciseID && !$0.isArchived }) {
                            if exercise.metrics.contains(where: \.isActive) {
                                Button("セットを追加", systemImage: "plus") {
                                    do { if let draft = try makeAdditionDraft(record, exercise) { additions.append(draft) } }
                                    catch { validationError = error.localizedDescription }
                                }
                                .accessibilityIdentifier("addWorkoutSet_\(record.id.uuidString)")
                            } else {
                                Text("有効な項目がないため、この種目にセットを追加できません。項目を復帰してから再度お試しください。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let validationError { Text(validationError).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("saveWorkoutEditsButton")
                    .disabled(WorkoutValueEditing.date(from: workout.day) == nil)
            }
        }
        .padding(26)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 500, idealHeight: 620)
        .tint(FormStyle.accent)
        .confirmationDialog("セットを削除しますか？", isPresented: Binding(get: { pendingSetDeletion != nil }, set: { if !$0 { pendingSetDeletion = nil } }), titleVisibility: .visible) {
            Button("このセットを削除", role: .destructive) { confirmSetDeletion() }
                .accessibilityIdentifier("confirmDeleteWorkoutSet_\(pendingSetDeletion?.setID.uuidString ?? "none")")
            Button("キャンセル", role: .cancel) { pendingSetDeletion = nil }
        } message: {
            if let target = pendingSetDeletion {
                let record = target.recordSnapshot
                let set = record.sets.first { $0.id == target.setID }
                Text("対象日: \(target.workoutDay)\n種目: \(record.exerciseName)\nセット \(set?.sortOrder ?? 0): \(set.map(Self.valueSummary) ?? "値なし")\n\(record.sets.count == 1 ? "最後のセットのため種目記録も削除されます。" : "他のセットは残ります。")\n\(target.workoutRecords.count == 1 && record.sets.count == 1 ? "最後の種目記録のためWorkout全体も削除されます。" : "Workoutと他の種目記録は残ります。")\n削除後は元に戻せません。")
            }
        }
        .confirmationDialog("種目記録を削除しますか？", isPresented: Binding(get: { pendingRecordDeletion != nil }, set: { if !$0 { pendingRecordDeletion = nil } }), titleVisibility: .visible) {
            Button("この種目記録を削除", role: .destructive) { confirmRecordDeletion() }
                .accessibilityIdentifier("confirmDeleteWorkoutRecord_\(pendingRecordDeletion?.record.id.uuidString ?? "none")")
            Button("キャンセル", role: .cancel) { pendingRecordDeletion = nil }
        } message: {
            if let target = pendingRecordDeletion {
                let record = target.record
                Text("対象日: \(target.workoutDay)\n種目: \(record.exerciseName)\nセット数: \(record.sets.count)\n\(record.sets.sorted { $0.sortOrder < $1.sortOrder }.map { "セット \($0.sortOrder): \(Self.valueSummary($0))" }.joined(separator: "\n"))\n\(target.workoutRecords.count == 1 ? "最後の種目記録のためWorkout全体も削除されます。" : "他の種目記録とWorkoutは残ります。")\n削除後は元に戻せません。")
            }
        }
    }

    private func save() {
        guard WorkoutValueEditing.date(from: workout.day) != nil else {
            validationError = WorkoutValueEditError.invalidStoredDay.localizedDescription
            return
        }

        switch WorkoutValueEditing.validatedValues(from: drafts) {
        case .failure(let error):
            validationError = error.localizedDescription
        case .success:
            if let error = onSave(day, drafts, additions.items) {
                validationError = error
            } else {
                dismiss()
            }
        }
    }

    private func confirmSetDeletion() {
        guard let target = pendingSetDeletion else { return }
        pendingSetDeletion = nil
        let originalDrafts = WorkoutValueEditing.drafts(for: workout)
        guard let originalDay = WorkoutValueEditing.date(from: workout.day),
              WorkoutValueEditing.deletionDraftsAreClean(drafts, originalDrafts: originalDrafts, day: day, originalDay: originalDay, additions: additions.items) else {
            validationError = "日付・数値・追加セットに未保存の入力があります。保存または取り消してから削除してください。"
            return
        }
        if let error = onDeleteSet(target) { validationError = error }
        else { dismiss() }
    }

    private func confirmRecordDeletion() {
        guard let target = pendingRecordDeletion else { return }
        pendingRecordDeletion = nil
        let originalDrafts = WorkoutValueEditing.drafts(for: workout)
        guard let originalDay = WorkoutValueEditing.date(from: workout.day),
              WorkoutValueEditing.deletionDraftsAreClean(drafts, originalDrafts: originalDrafts, day: day, originalDay: originalDay, additions: additions.items) else {
            validationError = "日付・数値・追加セットに未保存の入力があります。保存または取り消してから削除してください。"
            return
        }
        if let error = onDeleteRecord(target) { validationError = error } else { dismiss() }
    }

    private static func valueSummary(_ set: WorkoutSetSnapshot) -> String {
        let summary = set.values.map { value in
            let amount = value.scaledValue.map { NSDecimalNumber(decimal: Decimal($0) / Decimal(1000)).stringValue } ?? "未入力"
            return "\(value.name): \(amount)\(value.unit)"
        }.joined(separator: "、")
        return summary.isEmpty ? "値なし" : summary
    }

    private func additionBinding(draftID: UUID, metric: WorkoutSetMetricDraft) -> Binding<String> {
        Binding(get: {
            additions.value(draftID: draftID, metricID: metric.id)
        }, set: { value in
            additions.setValue(value, draftID: draftID, metricID: metric.id)
        })
    }

}
