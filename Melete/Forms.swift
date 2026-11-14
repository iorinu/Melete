import SwiftUI

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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("種目を作成").font(.title2.bold())
            Form {
                TextField("種目名", text: $name).accessibilityIdentifier("exerciseNameField")
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
        }.padding(22).frame(width: 590, height: 560)
    }
}

struct WorkoutEntryDraft: Identifiable {
    let id = UUID()
    let exercise: Exercise
    var sets: [WorkoutSetDraft] = [WorkoutSetDraft()]
}

struct WorkoutSetDraft: Identifiable {
    let id = UUID()
    var values: [UUID: String] = [:]
    var parsedValues: [UUID: Int64?] = [:]
}

struct WorkoutForm: View {
    @Environment(\.dismiss) private var dismiss
    let exercises: [Exercise]
    var onSave: (Date, [WorkoutEntryDraft]) -> Bool
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var entries: [WorkoutEntryDraft] = []
    @State private var selectedExerciseID: UUID?
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("運動を追加").font(.title2.bold())
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
        }.padding(22).frame(width: 650, height: 650)
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
                        Text("セット \(setIndex + 1)").fontWeight(.medium)
                        Spacer()
                        if entry.wrappedValue.sets.count > 1 {
                            Button("削除", role: .destructive) { entry.wrappedValue.sets.remove(at: setIndex) }
                        }
                    }
                    ForEach(metrics) { metric in
                        HStack {
                            Text("\(metric.name)（\(metric.unit)）\(metric.isRequired ? "*" : "" )").frame(width: 190, alignment: .leading)
                            TextField(metric.allowsDecimal ? "0.000まで" : "0以上の整数", text: valueBinding(entry: entry, setID: set.id, metric: metric))
                                .frame(width: 140)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("set\(setIndex + 1)_metric_\(metric.name)")
                        }
                    }
                }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            Button("セットを追加", systemImage: "plus") { entry.wrappedValue.sets.append(WorkoutSetDraft()) }.accessibilityIdentifier("addSetButton")
        }.padding(.vertical, 6)
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
        entries.append(WorkoutEntryDraft(exercise: exercise))
        self.selectedExerciseID = exercises.first(where: { candidate in !entries.contains(where: { $0.exercise.id == candidate.id }) })?.id
    }

    private func save() {
        let calendar = Calendar.current
        guard calendar.startOfDay(for: day) <= calendar.startOfDay(for: .now) else { validationError = "運動日は今日以前の日付を選択してください。"; return }
        let metricsByEntry = entries.map { ($0, $0.exercise.metrics.filter(\.isActive)) }
        for (entry, metrics) in metricsByEntry {
            for (index, set) in entry.sets.enumerated() {
                for metric in metrics {
                    let raw = set.values[metric.id] ?? ""
                    let value = raw.isEmpty ? nil : MetricInput.parse(raw, allowsDecimal: metric.allowsDecimal)
                    if !raw.isEmpty && value == nil {
                        validationError = "\(entry.exercise.name)・セット\(index + 1)の「\(metric.name)」は0以上の有効な数値を入力してください。"
                        return
                    }
                    if metric.isRequired && value == nil {
                        validationError = "\(entry.exercise.name)・セット\(index + 1)の「\(metric.name)」は必須です。"
                        return
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
