import SwiftData
import SwiftUI

private enum MeleteStyle {
    static let accent = Color(red: 0.76, green: 0.31, blue: 0.16)
}

enum WorkoutCalendarLogic {
    enum AddWorkoutBlock: Equatable {
        case noActiveExercises
        case futureDay
        case invalidSelectedDay
    }

    static func initialWorkoutDay(selectedDay: String?, now: Date, calendar: Calendar) -> Date? {
        guard let selectedDay else { return calendar.startOfDay(for: now) }
        guard let date = WorkoutValueEditing.date(from: selectedDay, calendar: calendar) else { return nil }
        return calendar.startOfDay(for: date)
    }

    static func addWorkoutBlocks(activeExerciseCount: Int, selectedDay: String?, now: Date, calendar: Calendar) -> [AddWorkoutBlock] {
        var blocks: [AddWorkoutBlock] = []
        if activeExerciseCount == 0 { blocks.append(.noActiveExercises) }
        if let selectedDay {
            guard let date = WorkoutValueEditing.date(from: selectedDay, calendar: calendar) else {
                blocks.append(.invalidSelectedDay)
                return blocks
            }
            if calendar.startOfDay(for: date) > calendar.startOfDay(for: now) { blocks.append(.futureDay) }
        }
        return blocks
    }

    static func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        return calendar
    }

    static func monthGrid(for date: Date, calendar: Calendar) -> (start: Date, dayCount: Int, weekdayOffset: Int, cellCount: Int) {
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let dayCount = calendar.range(of: .day, in: .month, for: start)?.count ?? 0
        let weekdayOffset = (calendar.component(.weekday, from: start) + 5) % 7
        return (start, dayCount, weekdayOffset, ((weekdayOffset + dayCount + 6) / 7) * 7)
    }

    static func date(day: Int, in grid: (start: Date, dayCount: Int, weekdayOffset: Int, cellCount: Int), calendar: Calendar) -> Date? {
        guard (1...grid.dayCount).contains(day) else { return nil }
        return calendar.date(byAdding: .day, value: day - 1, to: grid.start)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        Workout.dayString(from: date, calendar: calendar)
    }

    static func workouts(on day: String?, from workouts: [Workout]) -> [Workout] {
        guard let day else { return workouts }
        return workouts.filter { $0.day == day }
    }
}

struct MetricDefinitionEditingSession: Identifiable {
    enum Mode: Equatable { case v1, v2 }

    let id: UUID
    let exercise: Exercise
    let mode: Mode
    let drafts: [MetricDefinitionDraft]

    private init(id: UUID = UUID(), exercise: Exercise, mode: Mode, drafts: [MetricDefinitionDraft]) {
        self.id = id
        self.exercise = exercise
        self.mode = mode
        self.drafts = drafts
    }

    static func v1(exercise: Exercise) -> MetricDefinitionEditingSession {
        MetricDefinitionEditingSession(exercise: exercise, mode: .v1, drafts: MetricDefinitionEditing.draft(for: exercise))
    }

    static func v2(exercise: Exercise, drafts: [MetricDefinitionDraft]) throws -> MetricDefinitionEditingSession {
        try validateV2Drafts(drafts)
        return MetricDefinitionEditingSession(exercise: exercise, mode: .v2, drafts: drafts)
    }

    static func validateV2Drafts(_ drafts: [MetricDefinitionDraft]) throws {
        guard drafts.allSatisfy({ $0.original == nil || $0.historyBaseline != nil }) else {
            throw MetricDefinitionEditingSessionError.missingBaseline
        }
    }
}

enum MetricDefinitionEditingSessionError: LocalizedError, Equatable {
    case missingBaseline

    var errorDescription: String? {
        "項目の履歴基準を取得できないため、編集を保存できません。画面を開き直してください。"
    }
}

struct MainView: View {
    enum StoreMode: Equatable { case v1, isolatedV2Experimental }
    let storeMode: StoreMode
    @Environment(\.modelContext) private var context
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Query(sort: \Workout.day, order: .reverse) private var workouts: [Workout]
    @State private var selection: String? = "ホーム"
    @FocusState private var focusedSection: String?
    @State private var showingExerciseForm = false
    @State private var editingExercise: Exercise?
    @State private var metricDefinitionEditingSession: MetricDefinitionEditingSession?
    @State private var showingWorkoutForm = false
    @State private var pendingWorkoutDeletion: WorkoutDeletionTarget?
    @State private var editingWorkout: Workout?
    @State private var errorMessage: String?
    @State private var displayedMonth = Calendar(identifier: .gregorian).dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var selectedWorkoutDay: String?

    init(storeMode: StoreMode = .v1) { self.storeMode = storeMode }

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
                ForEach(["ホーム", "記録", "種目"], id: \.self) { item in
                    Button {
                        selection = item
                    } label: {
                        Label(item, systemImage: Self.symbol(for: item))
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
                if selection == "ホーム" { home }
                else if selection == "種目" { exerciseList }
                else { history }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 810, minHeight: 440)
        .background(.clear)
        .tint(MeleteStyle.accent)
        .sheet(isPresented: $showingExerciseForm) {
            ExerciseForm { name, metrics in saveExercise(name: name, metrics: metrics) }
        }
        .sheet(item: $editingExercise) { exercise in
            ExerciseNameEditForm(exercise: exercise) { name in saveExerciseName(name, for: exercise) }
        }
        .sheet(item: $metricDefinitionEditingSession) { session in
            MetricDefinitionEditForm(exercise: session.exercise, allowsExistingDefinitionEditing: session.mode == .v2, initialDrafts: session.drafts) { drafts in saveMetricDefinitions(drafts, for: session) }
        }
        .sheet(isPresented: $showingWorkoutForm) {
            WorkoutForm(
                exercises: exercises.filter { !$0.isArchived && $0.metrics.contains(where: \.isActive) },
                initialDay: WorkoutCalendarLogic.initialWorkoutDay(selectedDay: selectedWorkoutDay, now: .now, calendar: Self.workoutCalendar),
                makeEntryDraft: { exercise in
                    if storeMode == .isolatedV2Experimental {
                        return try WorkoutWritingServiceV2(context: context).makeWorkoutEntryDraft(for: exercise)
                    }
                    return WorkoutEntryDraft(exercise: exercise)
                }
            ) { day, entries in
                saveWorkout(day: day, entries: entries)
            }
        }
        .sheet(item: $editingWorkout) { workout in
            WorkoutValueEditForm(workout: workout, exercises: exercises, onSave: { day, drafts, additions, baseline in
                saveWorkoutEdits(workout: workout, day: day, drafts: drafts, additions: additions, baseline: baseline)
            }, makeAdditionDraft: { record, exercise in
                if storeMode == .isolatedV2Experimental { return try WorkoutWritingServiceV2(context: context).appendSetDraft(for: record, exercise: exercise) }
                return WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise)
            }, onDeleteSet: { target in deleteWorkoutSet(target) }, captureSetDeletionTarget: { workout, record, set in
                if storeMode == .isolatedV2Experimental {
                    return try WorkoutWritingServiceV2(context: context).captureSetDeletionTarget(workout: workout, record: record, set: set)
                }
                return WorkoutSetDeletionTarget(workout: workout, record: record, set: set)
            }, onDeleteRecord: { target in deleteWorkoutRecord(target) }, captureRecordDeletionTarget: { workout, record in
                if storeMode == .isolatedV2Experimental {
                    return try WorkoutWritingServiceV2(context: context).captureRecordDeletionTarget(workout: workout, record: record)
                }
                return WorkoutRecordDeletionTarget(workout: workout, record: record)
            })
        }
        .alert("操作できませんでした", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("運動記録を削除しますか？", isPresented: Binding(get: { pendingWorkoutDeletion != nil }, set: { if !$0 { pendingWorkoutDeletion = nil } }), titleVisibility: .visible) {
            Button("この運動を削除", role: .destructive) { confirmWorkoutDeletion() }
                .accessibilityIdentifier("confirmDeleteWorkout_\(pendingWorkoutDeletion?.workoutID.uuidString ?? "none")")
            Button("キャンセル", role: .cancel) { pendingWorkoutDeletion = nil }
        } message: {
            if let target = pendingWorkoutDeletion {
                Text("対象日: \(Self.displayDay(target.workoutDay))\nこの運動の全種目・セットが削除されます。削除した内容は元に戻せません。")
            }
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("ホーム")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("最近の運動記録を振り返れます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let workout = workouts.first {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("直近の運動")
                                .font(.title2.weight(.semibold))
                            Spacer()
                            Button("履歴を見る") { selection = "記録" }
                                .buttonStyle(.link)
                        }
                        Text(Self.displayDay(workout.day))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ForEach(workout.records.sorted { $0.sortOrder < $1.sortOrder }) { record in
                            VStack(alignment: .leading, spacing: 9) {
                                Text(record.exerciseName).font(.headline)
                                ForEach(record.sets.sorted { $0.sortOrder < $1.sortOrder }) { set in
                                    Text("セット \(set.sortOrder)　" + set.values.compactMap(displayValue).joined(separator: "　·　"))
                                        .font(.system(.body, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if record.id != workout.records.sorted(by: { $0.sortOrder < $1.sortOrder }).last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MeleteStyle.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    ContentUnavailableView {
                        Label("運動記録はまだありません", systemImage: "figure.strengthtraining.traditional")
                    } description: {
                        Text(exercises.filter { !$0.isArchived }.isEmpty
                             ? "まず種目を作成すると、運動を記録できます。"
                             : "運動を記録すると、ここに最新の内容が表示されます。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                }

                Text("目標・分析・設定・AIチャットは未実装です。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollContentBackground(.hidden)
    }

    private static func symbol(for item: String) -> String {
        switch item {
        case "ホーム": "house"
        case "記録": "calendar"
        default: "dumbbell"
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
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
                    .disabled(!addWorkoutBlocks.isEmpty)
                    .accessibilityIdentifier("addWorkoutButton")
            }
            if !addWorkoutBlocks.isEmpty {
                Text([
                    addWorkoutBlocks.contains(.noActiveExercises) ? "有効な記録項目がある種目がありません。項目を追加・復帰するか、種目を作成してください。" : nil,
                    addWorkoutBlocks.contains(.futureDay) ? "未来の日付が選択されています。今日以前の日付を選ぶか、全履歴に戻してください。" : nil,
                    addWorkoutBlocks.contains(.invalidSelectedDay) ? "選択日を読み取れません。全履歴に戻してから日付を選び直してください。" : nil
                ].compactMap { $0 }.joined(separator: " "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("addWorkoutDisabledReason")
            }
            HStack(alignment: .top, spacing: 18) {
                calendarView
                    .frame(width: 250, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(selectedWorkoutDay.map(Self.displayDay) ?? "全履歴")
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        if selectedWorkoutDay != nil {
                            Button("全履歴") { selectedWorkoutDay = nil }
                                .help("選択を解除して全履歴を表示")
                        }
                    }
                    .accessibilityElement(children: .contain)

                    let visibleWorkouts = WorkoutCalendarLogic.workouts(on: selectedWorkoutDay, from: workouts)
                    if visibleWorkouts.isEmpty {
                        ContentUnavailableView {
                            Label(selectedWorkoutDay == nil ? "記録はまだありません" : "この日は未記録です", systemImage: "figure.strengthtraining.traditional")
                        } description: {
                            Text(selectedWorkoutDay == nil
                                 ? (exercises.isEmpty ? "まず種目を作成してください。" : "「運動を追加」から最初の運動を記録できます。")
                                 : "選択した日に運動記録はありません。")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(visibleWorkouts) { workout in
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text(Self.displayDay(workout.day)).font(.system(.title2, design: .rounded).weight(.bold))
                                    Spacer()
                                    Button("編集", systemImage: "pencil") {
                                        editingWorkout = workout
                                    }
                                    .accessibilityIdentifier("editWorkout_\(workout.id.uuidString)")
                                    Button(role: .destructive) {
                                        do {
                                            if storeMode == .isolatedV2Experimental {
                                                pendingWorkoutDeletion = try WorkoutWritingServiceV2(context: context).captureWorkoutDeletionTarget(workout: workout)
                                            } else {
                                                pendingWorkoutDeletion = try WorkoutDeletion.captureTarget(workout: workout, in: context)
                                            }
                                        } catch {
                                            errorMessage = error.localizedDescription
                                        }
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var calendarView: some View {
        let calendar = Self.workoutCalendar
        let grid = WorkoutCalendarLogic.monthGrid(for: displayedMonth, calendar: calendar)
        let monthStart = grid.start
        let recordedDays = Set(workouts.map(\.day))

        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("運動カレンダー").font(.headline)
                HStack(spacing: 4) {
                    Button { changeDisplayedMonth(by: -1) } label: {
                        Image(systemName: "chevron.left").frame(width: 28, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("前の月")
                    Spacer(minLength: 0)
                    Text(monthStart.formatted(.dateTime.year().month().locale(Locale(identifier: "ja_JP"))))
                        .font(.subheadline.weight(.semibold))
                        .fixedSize()
                        .accessibilityAddTraits(.updatesFrequently)
                    Spacer(minLength: 0)
                    Button { changeDisplayedMonth(by: 1) } label: {
                        Image(systemName: "chevron.right").frame(width: 28, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("次の月")
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 5) {
                ForEach(["月", "火", "水", "木", "金", "土", "日"], id: \.self) { weekday in
                    Text(weekday).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).accessibilityLabel("\(weekday)曜日")
                }
                ForEach(0..<grid.cellCount, id: \.self) { index in
                    let day = index - grid.weekdayOffset + 1
                    if let date = WorkoutCalendarLogic.date(day: day, in: grid, calendar: calendar) {
                        let dayKey = WorkoutCalendarLogic.dayKey(date, calendar: calendar)
                        let hasWorkout = recordedDays.contains(dayKey)
                        Button {
                            selectedWorkoutDay = selectedWorkoutDay == dayKey ? nil : dayKey
                        } label: {
                            VStack(spacing: 1) {
                                Text("\(day)").font(.system(.callout, design: .rounded).weight(selectedWorkoutDay == dayKey ? .bold : .regular))
                                Circle().fill(hasWorkout ? MeleteStyle.accent : .clear).frame(width: 4, height: 4)
                            }
                            .frame(maxWidth: .infinity, minHeight: 29)
                            .background {
                                if selectedWorkoutDay == dayKey {
                                    RoundedRectangle(cornerRadius: 7).fill(MeleteStyle.accent.opacity(0.18))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selectedWorkoutDay == dayKey ? MeleteStyle.accent : .primary)
                        .accessibilityLabel("\(Self.displayDay(dayKey))、\(hasWorkout ? "運動記録あり" : "未記録")\(selectedWorkoutDay == dayKey ? "、選択中" : "、未選択")")
                        .accessibilityAddTraits(selectedWorkoutDay == dayKey ? .isSelected : [])
                        .help("\(Self.displayDay(dayKey))、\(hasWorkout ? "運動記録あり" : "未記録")")
                    } else {
                        Color.clear.frame(height: 29).accessibilityHidden(true)
                    }
                }
            }
            HStack(spacing: 7) {
                Circle().fill(MeleteStyle.accent).frame(width: 7, height: 7)
                Text("運動記録あり").foregroundStyle(.secondary)
                Text("・日付を選択").foregroundStyle(.tertiary)
                Spacer()
            }.font(.caption)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var activeExercises: [Exercise] {
        exercises.filter { !$0.isArchived && $0.metrics.contains(where: \.isActive) }
    }

    private var addWorkoutBlocks: [WorkoutCalendarLogic.AddWorkoutBlock] {
        WorkoutCalendarLogic.addWorkoutBlocks(
            activeExerciseCount: activeExercises.count,
            selectedDay: selectedWorkoutDay,
            now: .now,
            calendar: Self.workoutCalendar
        )
    }

    private func changeDisplayedMonth(by amount: Int) {
        guard let nextMonth = Self.workoutCalendar.date(byAdding: .month, value: amount, to: displayedMonth) else { return }
        displayedMonth = nextMonth
        selectedWorkoutDay = nil
    }

    private static var workoutCalendar: Calendar {
        WorkoutCalendarLogic.calendar(timeZone: .current)
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
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(exercise.name).font(.headline)
                let metrics = exercise.metrics.sorted { $0.sortOrder == $1.sortOrder ? $0.id.uuidString < $1.id.uuidString : $0.sortOrder < $1.sortOrder }
                if metrics.isEmpty {
                    Text("記録項目はありません").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(metrics) { metric in
                            HStack(spacing: 6) {
                                Image(systemName: metric.isActive ? "checkmark.circle.fill" : "minus.circle")
                                    .foregroundStyle(metric.isActive ? MeleteStyle.accent : .secondary)
                                Text("\(metric.name)（\(metric.unit)）・\(metric.allowsDecimal ? "小数" : "整数")・\(metric.isRequired ? "必須" : "任意")")
                                    .foregroundStyle(metric.isActive ? .primary : .secondary)
                            }.font(.subheadline)
                        }
                    }
                }
            }
            Spacer()
            Button("項目を管理") { beginMetricDefinitionEditing(exercise) }
                .accessibilityIdentifier("manageMetricDefinitions_\(exercise.id.uuidString)")
            Button("名前を編集", systemImage: "pencil") { editingExercise = exercise }
            Button(exercise.isArchived ? "復帰" : "アーカイブ") {
                let original = exercise.isArchived
                do {
                    exercise.isArchived.toggle()
                    try context.save()
                } catch {
                    exercise.isArchived = original
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

    private func saveExerciseName(_ name: String, for exercise: Exercise) -> String? {
        do {
            try ExerciseNameEditing.save(name, for: exercise) { try context.save() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func saveMetricDefinitions(_ drafts: [MetricDefinitionDraft], for session: MetricDefinitionEditingSession) -> String? {
        do {
            switch session.mode {
            case .v2:
                try MetricDefinitionEditingSession.validateV2Drafts(drafts)
                try WorkoutWritingServiceV2(context: context).saveMetricDefinitions(drafts, for: session.exercise)
            case .v1:
                try MetricDefinitionEditingV1.save(drafts, for: session.exercise, in: context)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func beginMetricDefinitionEditing(_ exercise: Exercise) {
        if storeMode == .isolatedV2Experimental {
            do {
                let drafts = try MetricDefinitionEditingV2.draft(for: exercise, in: context)
                metricDefinitionEditingSession = try MetricDefinitionEditingSession.v2(exercise: exercise, drafts: drafts)
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            metricDefinitionEditingSession = .v1(exercise: exercise)
        }
    }

    private func saveWorkout(day: Date, entries: [WorkoutEntryDraft]) -> Bool {
        if storeMode == .isolatedV2Experimental {
            do { try WorkoutWritingServiceV2(context: context).createWorkout(day: day, entries: entries); return true }
            catch { errorMessage = error.localizedDescription; return false }
        }
        let workout = Workout(day: day, records: Self.workoutRecords(from: entries))
        context.insert(workout)
        do { try context.save(); return true }
        catch { context.rollback(); errorMessage = error.localizedDescription; return false }
    }

    static func workoutRecords(from entries: [WorkoutEntryDraft]) -> [ExerciseRecord] {
        entries.enumerated().map { recordIndex, entry in
            let sets = entry.sets.enumerated().map { setIndex, values in
                let savedValues = entry.exercise.metrics.filter(\.isActive).sorted { $0.sortOrder < $1.sortOrder }.map { metric in
                    MetricValue(metric: metric, scaledValue: values.parsedValues[metric.id] ?? nil)
                }
                return SetRecord(sortOrder: setIndex + 1, values: savedValues)
            }
            return ExerciseRecord(exercise: entry.exercise, sortOrder: recordIndex, sets: sets)
        }
    }

    private func saveWorkoutEdits(workout: Workout, day: Date, drafts: [WorkoutValueEditDraft], additions: [WorkoutSetAdditionDraft], baseline: WorkoutAdditionBaseline) -> String? {
        do {
            if storeMode == .isolatedV2Experimental {
                try WorkoutWritingServiceV2(context: context).saveWorkoutEdits(drafts, additions: additions, day: day, to: workout, exercises: exercises)
            } else if !additions.isEmpty {
                try WorkoutSetAdditionV1.save(drafts, additions: additions, baseline: baseline, day: day, to: workout, exercises: exercises, in: context)
            } else {
                try WorkoutValueEditing.save(drafts, additions: [], day: day, to: workout, exercises: exercises, discard: { context.delete($0) }) { try context.save() }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func deleteWorkoutSet(_ target: WorkoutSetDeletionTarget) -> String? {
        guard !context.hasChanges else { return WorkoutSetDeletionError.unsavedContext.localizedDescription }
        do {
            if storeMode == .isolatedV2Experimental { try WorkoutWritingServiceV2(context: context).deleteSet(target) }
            else { try WorkoutSetDeletion.delete(target, in: context) { try context.save() } }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func deleteWorkoutRecord(_ target: WorkoutRecordDeletionTarget) -> String? {
        guard !context.hasChanges else { return WorkoutSetDeletionError.unsavedContext.localizedDescription }
        do {
            if storeMode == .isolatedV2Experimental { try WorkoutWritingServiceV2(context: context).deleteRecord(target) }
            else { try WorkoutRecordDeletion.delete(target, in: context) { try context.save() } }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func confirmWorkoutDeletion() {
        guard let workout = pendingWorkoutDeletion else { return }
        pendingWorkoutDeletion = nil
        do {
            if storeMode == .isolatedV2Experimental { try WorkoutWritingServiceV2(context: context).deleteWorkout(workout) }
            else { try WorkoutDeletion.delete(workout, in: context) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
