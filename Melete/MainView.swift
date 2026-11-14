import SwiftData
import SwiftUI

private enum MeleteStyle {
    static let accent = Color(red: 0.76, green: 0.31, blue: 0.16)
}

struct MainView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Query(sort: \Workout.day, order: .reverse) private var workouts: [Workout]
    @State private var selection: String? = "記録"
    @FocusState private var focusedSection: String?
    @State private var showingExerciseForm = false
    @State private var showingWorkoutForm = false
    @State private var pendingWorkoutDeletion: Workout?
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MELETE")
                    .font(.caption.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                ForEach(["記録", "種目"], id: \.self) { item in
                    Button {
                        selection = item
                    } label: {
                        Label(item, systemImage: item == "記録" ? "calendar" : "dumbbell")
                            .symbolVariant(item == selection ? .fill : .none)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background {
                                if item == selection {
                                    RoundedRectangle(cornerRadius: 7).fill(MeleteStyle.accent.opacity(0.14))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(item == selection ? MeleteStyle.accent : .primary)
                    .accessibilityLabel(item)
                    .accessibilityAddTraits(item == selection ? .isSelected : [])
                    .focused($focusedSection, equals: item)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 196, alignment: .leading)
            .padding(.horizontal, 12)
            Group {
                if selection == "種目" { exerciseList } else { history }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 810, minHeight: 440)
        .background(.clear)
        .tint(MeleteStyle.accent)
        .sheet(isPresented: $showingExerciseForm) {
            ExerciseForm { name, metrics in saveExercise(name: name, metrics: metrics) }
        }
        .sheet(isPresented: $showingWorkoutForm) {
            WorkoutForm(exercises: exercises.filter { !$0.isArchived }) { day, entries in
                saveWorkout(day: day, entries: entries)
            }
        }
        .alert("操作できませんでした", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("運動記録を削除しますか？", isPresented: Binding(get: { pendingWorkoutDeletion != nil }, set: { if !$0 { pendingWorkoutDeletion = nil } }), titleVisibility: .visible) {
            Button("この運動を削除", role: .destructive) { confirmWorkoutDeletion() }
            Button("キャンセル", role: .cancel) { pendingWorkoutDeletion = nil }
        } message: {
            if let workout = pendingWorkoutDeletion {
                Text("対象日: \(Self.displayDay(workout.day))\nこの運動の全種目・セットが削除されます。削除した内容は元に戻せません。")
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("運動履歴").font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("運動を記録して、日付ごとに振り返れます。").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingWorkoutForm = true } label: {
                    Label("運動を追加", systemImage: "plus").fontWeight(.semibold)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(MeleteStyle.accent)
                    .disabled(exercises.filter { !$0.isArchived }.isEmpty)
                    .accessibilityIdentifier("addWorkoutButton")
            }
            if workouts.isEmpty {
                ContentUnavailableView {
                    Label("記録はまだありません", systemImage: "figure.strengthtraining.traditional")
                } description: {
                    Text(exercises.isEmpty ? "まず種目を作成してください。" : "「運動を追加」から最初の運動を記録できます。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(workouts) { workout in
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(Self.displayDay(workout.day)).font(.system(.title2, design: .rounded).weight(.bold))
                            Spacer()
                            Button(role: .destructive) {
                                pendingWorkoutDeletion = workout
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                            .labelStyle(.iconOnly)
                            .help("この運動記録を削除")
                            .accessibilityLabel("\(Self.displayDay(workout.day))の運動記録を削除")
                        }
                        Divider().overlay(.primary.opacity(0.12))
                        ForEach(workout.records.sorted { $0.sortOrder < $1.sortOrder }) { record in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(record.exerciseName).font(.headline)
                                ForEach(record.sets.sorted { $0.sortOrder < $1.sortOrder }) { set in
                                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                                        Text("セット \(set.sortOrder)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 66, alignment: .leading)
                                        Text(set.values.compactMap(displayValue).joined(separator: "　·　"))
                                            .font(.system(.title3, design: .rounded).weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            Spacer(minLength: 0)
        }.padding(28)
    }

    private var exerciseList: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("種目").font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("種目と記録する数値項目を管理します。").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingExerciseForm = true } label: {
                    Label("種目を作成", systemImage: "plus").fontWeight(.semibold)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(MeleteStyle.accent)
                    .accessibilityIdentifier("createExerciseButton")
            }
            if exercises.isEmpty {
                ContentUnavailableView {
                    Label("種目はまだありません", systemImage: "dumbbell")
                } description: {
                    Text("種目を作成すると、運動を記録できるようになります。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("使用中") {
                        ForEach(exercises.filter { !$0.isArchived }) { exercise in exerciseRow(exercise) }
                    }
                    if exercises.contains(where: \.isArchived) {
                        Section("アーカイブ済み") {
                            ForEach(exercises.filter(\.isArchived)) { exercise in exerciseRow(exercise) }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .listRowSeparator(.visible)
            }
            Spacer(minLength: 0)
        }.padding(28)
    }

    private func exerciseRow(_ exercise: Exercise) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(exercise.name).font(.headline)
                Text(exercise.metrics.filter(\.isActive).sorted { $0.sortOrder < $1.sortOrder }.map { "\($0.name)（\($0.unit)）\($0.isRequired ? "・必須" : "・任意")" }.joined(separator: "、"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(exercise.isArchived ? "復帰" : "アーカイブ") {
                do {
                    exercise.isArchived.toggle()
                    try context.save()
                } catch {
                    context.rollback()
                    errorMessage = error.localizedDescription
                }
            }
        }.padding(.vertical, 10)
    }

    private func displayValue(_ value: MetricValue) -> String? {
        guard let raw = value.scaledValue else { return "\(value.name): 未入力" }
        let number = Decimal(raw) / Decimal(1000)
        return "\(value.name): \(NSDecimalNumber(decimal: number).stringValue)\(value.unit)"
    }

    private static func displayDay(_ day: String) -> String {
        guard let date = Workout.dayFormatter.date(from: day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func saveExercise(name: String, metrics: [MetricDraft]) -> Bool {
        let definitions = metrics.enumerated().map { index, metric in
            MetricDefinition(name: metric.name, unit: metric.unit, allowsDecimal: metric.allowsDecimal, isRequired: metric.isRequired, sortOrder: index)
        }
        context.insert(Exercise(name: name, metrics: definitions))
        do { try context.save(); return true }
        catch { context.rollback(); errorMessage = error.localizedDescription; return false }
    }

    private func saveWorkout(day: Date, entries: [WorkoutEntryDraft]) -> Bool {
        let records = entries.enumerated().map { recordIndex, entry in
            let sets = entry.sets.enumerated().map { setIndex, values in
                let savedValues = entry.exercise.metrics.filter(\.isActive).sorted { $0.sortOrder < $1.sortOrder }.map { metric in
                    MetricValue(metric: metric, scaledValue: values.parsedValues[metric.id] ?? nil)
                }
                return SetRecord(sortOrder: setIndex + 1, values: savedValues)
            }
            return ExerciseRecord(exercise: entry.exercise, sortOrder: recordIndex, sets: sets)
        }
        context.insert(Workout(day: day, records: records))
        do { try context.save(); return true }
        catch { context.rollback(); errorMessage = error.localizedDescription; return false }
    }

    private func confirmWorkoutDeletion() {
        guard let workout = pendingWorkoutDeletion else { return }
        let workoutID = workout.id
        pendingWorkoutDeletion = nil
        do {
            try WorkoutDeletion.delete(workoutID: workoutID, in: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
