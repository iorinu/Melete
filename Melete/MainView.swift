import SwiftData
import SwiftUI

struct MainView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Query(sort: \Workout.day, order: .reverse) private var workouts: [Workout]
    @State private var selection: String? = "記録"
    @State private var showingExerciseForm = false
    @State private var showingWorkoutForm = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            List(["記録", "種目"], id: \.self, selection: $selection) { item in
                Label(item, systemImage: item == "記録" ? "calendar" : "dumbbell")
            }
            .navigationTitle("Melete")
            .frame(minWidth: 170)
        } detail: {
            Group {
                if selection == "種目" { exerciseList } else { history }
            }
            .frame(minWidth: 620, minHeight: 440)
        }
        .sheet(isPresented: $showingExerciseForm) {
            ExerciseForm { name, metrics in saveExercise(name: name, metrics: metrics) }
        }
        .sheet(isPresented: $showingWorkoutForm) {
            WorkoutForm(exercises: exercises.filter { !$0.isArchived }) { day, entries in
                saveWorkout(day: day, entries: entries)
            }
        }
        .alert("保存できませんでした", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("運動履歴").font(.largeTitle.bold())
                    Text("運動を記録して、日付ごとに振り返れます。").foregroundStyle(.secondary)
                }
                Spacer()
                Button("運動を追加", systemImage: "plus") { showingWorkoutForm = true }
                    .disabled(exercises.filter { !$0.isArchived }.isEmpty)
            }
            if workouts.isEmpty {
                ContentUnavailableView("記録はまだありません", systemImage: "figure.strengthtraining.traditional", description: Text(exercises.isEmpty ? "まず種目を作成してください。" : "「運動を追加」から最初の運動を記録できます。"))
            } else {
                List(workouts) { workout in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Self.displayDay(workout.day)).font(.headline)
                        ForEach(workout.records.sorted { $0.sortOrder < $1.sortOrder }) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.exerciseName).fontWeight(.medium)
                                ForEach(record.sets.sorted { $0.sortOrder < $1.sortOrder }) { set in
                                    Text("セット\(set.sortOrder): " + set.values.compactMap(displayValue).joined(separator: "　"))
                                        .foregroundStyle(.secondary)
                                }
                            }.padding(.leading, 12)
                        }
                    }.padding(.vertical, 7)
                }.listStyle(.inset)
            }
            Spacer(minLength: 0)
        }.padding(24)
    }

    private var exerciseList: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("種目").font(.largeTitle.bold())
                    Text("種目と記録する数値項目を管理します。").foregroundStyle(.secondary)
                }
                Spacer()
                Button("種目を作成", systemImage: "plus") { showingExerciseForm = true }
            }
            if exercises.isEmpty {
                ContentUnavailableView("種目はまだありません", systemImage: "dumbbell", description: Text("種目を作成すると、運動を記録できるようになります。"))
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
                }.listStyle(.inset)
            }
            Spacer(minLength: 0)
        }.padding(24)
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
        }.padding(.vertical, 5)
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
}
