import XCTest
import SwiftData
@testable import Melete

final class MeleteTests: XCTestCase {
    func testMetricDefinitionEditingAddsAndTogglesWithoutChangingSnapshots() throws {
        let existing = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "種目", metrics: [existing])
        let oldValue = MetricValue(metric: existing, scaledValue: 12_500)
        let oldSet = SetRecord(sortOrder: 1, values: [oldValue])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [oldSet])
        let workout = Workout(day: .now, records: [record])
        var draft = MetricDefinitionEditing.draft(for: exercise)
        draft.append(MetricDefinitionDraft(name: " 回数 ", unit: " 回 ", allowsDecimal: false, isRequired: false))
        draft[0].isActive = false

        XCTAssertNoThrow(try MetricDefinitionEditing.save(draft, for: exercise) {})
        XCTAssertEqual(exercise.metrics.map(\.id), [existing.id, exercise.metrics[1].id])
        XCTAssertFalse(existing.isActive)
        XCTAssertEqual(exercise.metrics[1].name, "回数")
        XCTAssertEqual(exercise.metrics[1].unit, "回")
        XCTAssertFalse(exercise.metrics[1].allowsDecimal)
        XCTAssertFalse(exercise.metrics[1].isRequired)
        XCTAssertEqual(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise)?.metrics.map(\.name), ["回数"])
        XCTAssertEqual(oldValue.metricID, existing.id)
        XCTAssertEqual(oldValue.name, "重量")
        XCTAssertEqual(oldValue.scaledValue, 12_500)
        XCTAssertEqual(workout.records.first?.sets.first?.values.count, 1)

        let addition = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
        var filledAddition = addition
        filledAddition.values[exercise.metrics[1].id] = "8"
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day))
        XCTAssertNoThrow(try WorkoutValueEditing.save([], additions: [filledAddition], day: day, to: workout, exercises: [exercise]) {})
        let addedSet = try XCTUnwrap(record.sets.first { $0.sortOrder == 2 })
        XCTAssertEqual(addedSet.values.map(\.metricID), [exercise.metrics[1].id])
        XCTAssertEqual(addedSet.values.first?.scaledValue, 8_000)

        exercise.metrics[1].isActive = false
        XCTAssertThrowsError(try WorkoutValueEditing.save([], additions: [addition], day: day, to: workout, exercises: [exercise]) {}) { error in
            XCTAssertEqual((error as? WorkoutValueEditError)?.errorDescription, WorkoutValueEditError.metricsChanged.errorDescription)
        }
        XCTAssertTrue(record.sets.allSatisfy { $0.values.count == 1 || $0.sortOrder == 2 })
    }

    func testMetricDefinitionEditingRejectsInvalidNamesAndSortOrderOverflowWithoutMutation() throws {
        let first = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: Int.max)
        let exercise = Exercise(name: "種目", metrics: [first])
        for candidate in [
            MetricDefinitionDraft(name: " 重量 ", unit: "lb", allowsDecimal: false, isRequired: false),
            MetricDefinitionDraft(name: "  ", unit: "回", allowsDecimal: false, isRequired: false),
            MetricDefinitionDraft(name: "回数", unit: " \n", allowsDecimal: false, isRequired: false)
        ] {
            XCTAssertThrowsError(try MetricDefinitionEditing.save([MetricDefinitionDraft(existing: first), candidate], for: exercise) {})
            XCTAssertEqual(exercise.metrics.map(\.id), [first.id])
            XCTAssertEqual(first.name, "重量")
        }

        let valid = [MetricDefinitionDraft(existing: first), MetricDefinitionDraft(name: "回数", unit: "回", allowsDecimal: false, isRequired: true)]
        XCTAssertThrowsError(try MetricDefinitionEditing.save(valid, for: exercise) {}) { error in
            XCTAssertEqual((error as? MetricDefinitionEditingError)?.errorDescription, MetricDefinitionEditingError.sortOrderOverflow.errorDescription)
        }
        XCTAssertEqual(exercise.metrics.map(\.id), [first.id])
    }

    func testMetricDefinitionEditingRestoresOnlyTargetOnSaveFailureAndRejectsStaleDraft() throws {
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "種目", metrics: [metric])
        let other = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 0)
        let otherExercise = Exercise(name: "別種目", metrics: [other])
        var draft = MetricDefinitionEditing.draft(for: exercise)
        draft[0].isActive = false
        draft.append(MetricDefinitionDraft(name: "距離", unit: "m", allowsDecimal: true, isRequired: false))
        other.name = "未保存の変更"

        XCTAssertThrowsError(try MetricDefinitionEditing.save(draft, for: exercise) {
            throw NSError(domain: "InjectedSaveFailure", code: 1)
        })
        XCTAssertTrue(metric.isActive)
        XCTAssertEqual(exercise.metrics.map(\.id), [metric.id])
        XCTAssertEqual(other.name, "未保存の変更")
        XCTAssertEqual(otherExercise.metrics.first?.name, "未保存の変更")

        var stale = MetricDefinitionEditing.draft(for: exercise)
        stale[0].isActive = false
        metric.name = "別画面の変更"
        XCTAssertThrowsError(try MetricDefinitionEditing.save(stale, for: exercise) {}) { error in
            XCTAssertEqual((error as? MetricDefinitionEditingError)?.errorDescription, MetricDefinitionEditingError.changed.errorDescription)
        }
        XCTAssertEqual(metric.name, "別画面の変更")
        XCTAssertTrue(metric.isActive)
    }

    func testMetricDefinitionEditingPersistsAndReopensAddedAndInactiveDefinitions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteMetricDefinitionEdit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("MetricDefinitionEdit", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        let exerciseID = UUID()
        let existingMetricID = UUID()
        let newMetricID: UUID

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let existing = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
            existing.id = existingMetricID
            let exercise = Exercise(name: "種目", metrics: [existing])
            exercise.id = exerciseID
            let oldValue = MetricValue(metric: existing, scaledValue: 12_500)
            let workout = Workout(day: .now, records: [ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [oldValue])])])
            context.insert(exercise)
            context.insert(workout)
            try context.save()

            var drafts = MetricDefinitionEditing.draft(for: exercise)
            drafts[0].isActive = false
            drafts.append(MetricDefinitionDraft(name: " 回数 ", unit: " 回 ", allowsDecimal: false, isRequired: false))
            try MetricDefinitionEditing.save(drafts, for: exercise, insert: { context.insert($0) }, discard: { context.delete($0) }) { try context.save() }
            newMetricID = try XCTUnwrap(exercise.metrics.first { $0.name == "回数" }?.id)
            XCTAssertEqual(oldValue.name, "重量")
            XCTAssertEqual(oldValue.scaledValue, 12_500)
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let savedExercise = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseID })
        let savedExisting = try XCTUnwrap(savedExercise.metrics.first { $0.id == existingMetricID })
        let savedNew = try XCTUnwrap(savedExercise.metrics.first { $0.id == newMetricID })
        XCTAssertFalse(savedExisting.isActive)
        XCTAssertEqual(savedExisting.sortOrder, 0)
        XCTAssertEqual(savedNew.name, "回数")
        XCTAssertEqual(savedNew.unit, "回")
        XCTAssertFalse(savedNew.allowsDecimal)
        XCTAssertFalse(savedNew.isRequired)
        XCTAssertTrue(savedNew.isActive)
        XCTAssertEqual(savedNew.sortOrder, 1)
        let savedWorkout = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Workout>()).first)
        let savedValue = try XCTUnwrap(savedWorkout.records.first?.sets.first?.values.first)
        XCTAssertEqual(savedValue.metricID, existingMetricID)
        XCTAssertEqual(savedValue.name, "重量")
        XCTAssertEqual(savedValue.scaledValue, 12_500)
    }

    func testMetricDefinitionEditingAllowsNoActiveItemsButBlocksNewWorkoutSet() throws {
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "種目", metrics: [metric])
        var drafts = MetricDefinitionEditing.draft(for: exercise)
        drafts[0].isActive = false
        XCTAssertNoThrow(try MetricDefinitionEditing.save(drafts, for: exercise) {})
        XCTAssertFalse(metric.isActive)

        let entry = WorkoutEntryDraft(exercise: exercise)
        if case .success = WorkoutSetDraftEditing.validatedEntries([entry]) {
            XCTFail("有効項目がない種目の新規セット入力を拒否する")
        }
        XCTAssertTrue(exercise.metrics.contains { !$0.isActive }, "項目定義自体は復帰可能な状態で保持する")
        var restoredDrafts = MetricDefinitionEditing.draft(for: exercise)
        restoredDrafts[0].isActive = true
        XCTAssertNoThrow(try MetricDefinitionEditing.save(restoredDrafts, for: exercise) {})
        XCTAssertTrue(exercise.metrics[0].isActive)
    }

    func testWorkoutSetDraftCopyKeepsRawInputsButGetsIndependentIdentityAndNoParsedCache() {
        let metricID = UUID()
        var source = WorkoutSetDraft(values: [metricID: " 1.2345 ", UUID(): ""])
        source.parsedValues[metricID] = 1_234

        let copy = WorkoutSetDraft(copying: source)

        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.values, source.values, "不正な文字列や空欄も加工せず複製する")
        XCTAssertTrue(copy.parsedValues.isEmpty, "検証済みキャッシュを複製せず、保存時に再検証する")
        XCTAssertEqual(copy.values[metricID], " 1.2345 ")
        source.values[metricID] = "2"
        XCTAssertEqual(copy.values[metricID], " 1.2345 ", "複製後の編集は元draftに影響しない")
    }

    func testWorkoutSetDraftEditingUsesFormOperationsForOrderingRemovalAndSafeNoOps() throws {
        let required = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let optional = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 1)
        let exercise = Exercise(name: "種目", metrics: [required, optional])
        let otherExercise = Exercise(name: "別種目", metrics: [required])
        let firstEntry = WorkoutEntryDraft(exercise: exercise)
        let otherEntry = WorkoutEntryDraft(exercise: otherExercise)
        var entries = [firstEntry, otherEntry]
        entries[0].sets[0].values = [required.id: "0", optional.id: "", UUID(): "partial"]
        entries[0].sets[0].parsedValues[required.id] = 99
        let originalSet = entries[0].sets[0]

        WorkoutSetDraftEditing.duplicate(entryID: firstEntry.id, setID: originalSet.id, in: &entries)
        XCTAssertEqual(entries[0].sets.count, 2)
        let copy = try XCTUnwrap(entries[0].sets.last)
        XCTAssertEqual(copy.values, originalSet.values, "空欄・0・部分入力を含むraw値をそのまま保持")
        XCTAssertNotEqual(copy.id, originalSet.id)
        XCTAssertTrue(copy.parsedValues.isEmpty)
        XCTAssertEqual(entries[1].sets.map(\.id), otherEntry.sets.map(\.id), "他種目のセットは変更しない")

        entries[0].sets[0].values[required.id] = "4"
        XCTAssertEqual(entries[0].sets[1].values[required.id], "0", "複製後の編集は独立")
        let middle = WorkoutSetDraft(values: [required.id: "5"])
        entries[0].sets.append(middle)
        WorkoutSetDraftEditing.remove(entryID: firstEntry.id, setID: copy.id, from: &entries)
        XCTAssertEqual(entries[0].sets.map(\.id), [originalSet.id, middle.id], "削除後も残存セットIDで操作可能")
        WorkoutSetDraftEditing.duplicate(entryID: firstEntry.id, setID: middle.id, in: &entries)
        XCTAssertEqual(entries[0].sets.map(\.values[required.id]), ["4", "5", "5"])

        let unchanged = entries
        WorkoutSetDraftEditing.duplicate(entryID: UUID(), setID: middle.id, in: &entries)
        WorkoutSetDraftEditing.duplicate(entryID: firstEntry.id, setID: UUID(), in: &entries)
        WorkoutSetDraftEditing.remove(entryID: firstEntry.id, setID: UUID(), from: &entries)
        XCTAssertEqual(entries[0].sets.map(\.id), unchanged[0].sets.map(\.id), "無効IDは安全な無操作")
        for set in entries[0].sets.dropFirst() {
            WorkoutSetDraftEditing.remove(entryID: firstEntry.id, setID: set.id, from: &entries)
        }
        let onlySetID = try XCTUnwrap(entries[0].sets.first?.id)
        WorkoutSetDraftEditing.remove(entryID: firstEntry.id, setID: onlySetID, from: &entries)
        XCTAssertEqual(entries[0].sets.map(\.id), [onlySetID], "最後のセットは削除不可")
    }

    func testWorkoutSetDraftValidationAndSavePersistOrderedUniqueCopies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteWorkoutSetDraft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("WorkoutSetDraft", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let required = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let optional = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 1)
        let exercise = Exercise(name: "種目", metrics: [required, optional])
        let otherMetric = MetricDefinition(name: "距離", unit: "m", allowsDecimal: false, isRequired: true, sortOrder: 0)
        let otherExercise = Exercise(name: "別種目", metrics: [otherMetric])
        var entries = [WorkoutEntryDraft(exercise: exercise), WorkoutEntryDraft(exercise: otherExercise)]
        entries[0].sets[0].values = [required.id: "1.25", optional.id: ""]
        WorkoutSetDraftEditing.duplicate(entryID: entries[0].id, setID: entries[0].sets[0].id, in: &entries)
        entries[0].sets[1].values[required.id] = "0"
        entries[0].sets[1].values[optional.id] = "0"
        entries[1].sets[0].values[otherMetric.id] = "8"

        var invalid = entries
        invalid[0].sets[1].values[required.id] = "1.2345"
        if case .success = WorkoutSetDraftEditing.validatedEntries(invalid) { XCTFail("複製後の不正値を拒否") }
        invalid = entries
        invalid[0].sets[1].values[required.id] = ""
        if case .success = WorkoutSetDraftEditing.validatedEntries(invalid) { XCTFail("複製後の必須空欄を拒否") }
        invalid = entries
        invalid[1].sets[0].values[otherMetric.id] = "bad"
        if case .success = WorkoutSetDraftEditing.validatedEntries(invalid) { XCTFail("別セットの不正値があれば全体を拒否") }
        invalid = entries
        invalid[1].sets[0].values[otherMetric.id] = ""
        if case .success = WorkoutSetDraftEditing.validatedEntries(invalid) { XCTFail("別種目の必須空欄があれば全体を拒否") }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 0, "検証失敗した値は永続処理へ渡さない")

        guard case .success(let validated) = WorkoutSetDraftEditing.validatedEntries(entries) else {
            return XCTFail("有効な入力を検証")
        }
        XCTAssertEqual(validated[0].sets.map { $0.parsedValues[required.id] ?? nil }, [1_250, 0])
        XCTAssertNil(validated[0].sets[0].parsedValues[optional.id] ?? nil)
        XCTAssertEqual(validated[0].sets[1].parsedValues[optional.id] ?? nil, 0)
        XCTAssertTrue(entries[0].sets.allSatisfy { $0.parsedValues.isEmpty }, "入力draft自体のキャッシュを汚染しない")

        let records = MainView.workoutRecords(from: validated)
        let workout = Workout(day: .now, records: records)
        context.insert(exercise)
        context.insert(otherExercise)
        context.insert(workout)
        try context.save()
        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let saved = try XCTUnwrap(reopenedContext.fetch(FetchDescriptor<Workout>()).first)
        XCTAssertEqual(saved.records.sorted { $0.sortOrder < $1.sortOrder }.map(\.exerciseName), ["種目", "別種目"])
        XCTAssertEqual(saved.records.map(\.sortOrder).sorted(), [0, 1])
        XCTAssertEqual(Set(saved.records.map(\.id)).count, 2)
        let record = try XCTUnwrap(saved.records.first { $0.exerciseID == exercise.id })
        XCTAssertEqual(record.sets.sorted { $0.sortOrder < $1.sortOrder }.map(\.sortOrder), [1, 2])
        let savedSets = record.sets.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(savedSets.map { $0.values.first { $0.metricID == required.id }?.scaledValue }, [1_250, 0])
        XCTAssertNil(savedSets[0].values.first { $0.metricID == optional.id }?.scaledValue)
        XCTAssertEqual(savedSets[1].values.first { $0.metricID == optional.id }?.scaledValue, 0)
        XCTAssertEqual(Set(savedSets.map(\.id)).count, 2)
        XCTAssertEqual(Set(savedSets.flatMap(\.values).map(\.id)).count, 4)
        XCTAssertEqual(Set(saved.records.flatMap(\.sets).flatMap(\.values).map(\.id)).count, 5)
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<Workout>()).count, 1)
    }

    func testExerciseNameEditingTrimsRejectsEmptyAndAllowsDuplicateNames() throws {
        XCTAssertEqual(ExerciseNameEditing.validatedName("  ベンチプレス \n"), "ベンチプレス")
        XCTAssertNil(ExerciseNameEditing.validatedName(" \n\t"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteExerciseNameEdit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("ExerciseNameEdit", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        let inUseID = UUID()
        let archivedID = UUID()
        let inUseCreatedAt: Date
        let archivedCreatedAt: Date
        let metricID: UUID
        let oldRecordID: UUID

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: false, isRequired: true, sortOrder: 0)
            metricID = metric.id
            let inUse = Exercise(name: "使用中", metrics: [metric])
            inUse.id = inUseID
            inUseCreatedAt = inUse.createdAt
            let archivedMetric = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 0)
            let archived = Exercise(name: "アーカイブ済み", metrics: [archivedMetric])
            archived.id = archivedID
            archived.isArchived = true
            archivedCreatedAt = archived.createdAt
            let oldValue = MetricValue(metric: metric, scaledValue: 50_000)
            let oldSet = SetRecord(sortOrder: 1, values: [oldValue])
            let oldRecord = ExerciseRecord(exercise: inUse, sortOrder: 0, sets: [oldSet])
            oldRecordID = oldRecord.id
            context.insert(inUse)
            context.insert(archived)
            context.insert(Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [oldRecord]))
            try context.save()

            XCTAssertThrowsError(try ExerciseNameEditing.save(" \n", for: inUse) { try context.save() })
            XCTAssertEqual(inUse.name, "使用中", "空白名を拒否してモデル名を維持する")
            XCTAssertNoThrow(try ExerciseNameEditing.save(" 使用中 ", for: archived) { try context.save() })
            XCTAssertNoThrow(try ExerciseNameEditing.save(" 新名称 \n", for: inUse) { try context.save() })
            XCTAssertEqual(inUse.name, "新名称")

            let duplicate = Exercise(name: "重複可", metrics: [])
            context.insert(duplicate)
            try context.save()
            XCTAssertNoThrow(try ExerciseNameEditing.save(" 重複可 ", for: inUse) { try context.save() })
            XCTAssertEqual(inUse.name, duplicate.name, "重複名を許可する")
            try ExerciseNameEditing.save(" 新名称 ", for: inUse) { try context.save() }

            let other = Exercise(name: "別種目", metrics: [])
            context.insert(other)
            try context.save()
            other.name = "他の未保存変更"
            XCTAssertThrowsError(try ExerciseNameEditing.save("保存失敗後", for: inUse) {
                throw NSError(domain: "InjectedSaveFailure", code: 1)
            })
            XCTAssertEqual(inUse.name, "新名称", "失敗時に対象名だけ復元する")
            XCTAssertEqual(other.name, "他の未保存変更", "別モデルの未保存変更を保持する")
            let retainedInput = "保存失敗後"
            XCTAssertNoThrow(try ExerciseNameEditing.save(retainedInput, for: inUse) { try context.save() })
            XCTAssertEqual(inUse.name, retainedInput, "同じ入力で再試行できる")
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let exercises = try reopenedContext.fetch(FetchDescriptor<Exercise>())
        let savedInUse = try XCTUnwrap(exercises.first { $0.id == inUseID })
        let savedArchived = try XCTUnwrap(exercises.first { $0.id == archivedID })
        XCTAssertEqual(savedInUse.name, "保存失敗後")
        XCTAssertEqual(savedInUse.createdAt, inUseCreatedAt)
        XCTAssertFalse(savedInUse.isArchived)
        XCTAssertEqual(savedInUse.metrics.map(\.id), [metricID])
        XCTAssertEqual(savedArchived.name, "使用中")
        XCTAssertEqual(savedArchived.createdAt, archivedCreatedAt)
        XCTAssertTrue(savedArchived.isArchived)
        let workout = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Workout>()).first)
        let oldRecord = try XCTUnwrap(workout.records.first { $0.id == oldRecordID })
        XCTAssertEqual(oldRecord.exerciseName, "使用中", "既存Workoutのスナップショット名を維持する")
        XCTAssertEqual(oldRecord.sets.first?.values.first?.scaledValue, 50_000, "既存Workoutの値を維持する")
        let newRecord = ExerciseRecord(exercise: savedInUse, sortOrder: 1, sets: [])
        XCTAssertEqual(newRecord.exerciseName, "保存失敗後", "新規Workout記録には変更後の名前を使う")
    }

    func testExerciseNameEditingRestoresOnlyTargetNameAfterSaveFailure() throws {
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: false, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "旧名", metrics: [metric])
        exercise.isArchived = true
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [])
        let workout = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [record])
        let other = Exercise(name: "別種目", metrics: [])
        other.name = "未保存の変更"

        XCTAssertThrowsError(try ExerciseNameEditing.save("新名", for: exercise) {
            throw NSError(domain: "InjectedSaveFailure", code: 1)
        })
        XCTAssertEqual(exercise.name, "旧名")
        XCTAssertEqual(other.name, "未保存の変更")
        XCTAssertEqual(exercise.id, record.exerciseID)
        XCTAssertEqual(exercise.isArchived, true)
        XCTAssertEqual(record.exerciseName, "旧名")
        XCTAssertEqual(workout.records.first?.exerciseName, "旧名")
    }

    func testUITestStoreSelectionRequiresValidOwnedPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteIsolationTests-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try Data("Melete UI test root v1".utf8).write(to: root.appendingPathComponent(".melete-ui-test-root"))

        let store = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path)
        try Data(UUID().uuidString.utf8).write(to: store.appendingPathComponent(".melete-ui-test-store"))

        let validArguments = ["--melete-ui-test-root", root.path, "--melete-ui-test-store", store.path]
        XCTAssertNotNil(UITestStoreIsolation.storeURL(arguments: validArguments))
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("MeleteUITest", schema: schema, url: store.appendingPathComponent("Melete.store"), cloudKitDatabase: .none)
        _ = try ModelContainer(for: schema, configurations: [configuration])
        XCTAssertNotNil(UITestStoreIsolation.storeURL(arguments: validArguments), "初回起動後に作成されるストア関連ファイルを許可する")
        XCTAssertTrue(Set(try FileManager.default.contentsOfDirectory(atPath: store.path)).isSubset(of: [".melete-ui-test-store", "Melete.store", "Melete.store-wal", "Melete.store-shm"]))
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: []))
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: ["--melete-ui-test-root", root.path, "--melete-ui-test-store"]))

        try Data("not-a-uuid".utf8).write(to: store.appendingPathComponent(".melete-ui-test-store"))
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: validArguments))
        try Data(UUID().uuidString.utf8).write(to: store.appendingPathComponent(".melete-ui-test-store"))

        let unknown = store.appendingPathComponent("unexpected")
        try Data().write(to: unknown)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: validArguments))
        try FileManager.default.removeItem(at: unknown)

        let storeLink = store.appendingPathComponent("Melete.store-link")
        try FileManager.default.createSymbolicLink(at: storeLink, withDestinationURL: store.appendingPathComponent("Melete.store"))
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: validArguments))
        try FileManager.default.removeItem(at: storeLink)

        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data(UUID().uuidString.utf8).write(to: outside.appendingPathComponent(".melete-ui-test-store"))
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: ["--melete-ui-test-root", root.path, "--melete-ui-test-store", outside.path]))

        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: ["--melete-ui-test-root", root.path, "--melete-ui-test-store", link.path]))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: validArguments))
    }

    func testMetricInputBoundaries() {
        XCTAssertEqual(MetricInput.parse("0", allowsDecimal: false), 0)
        XCTAssertEqual(MetricInput.parse("12", allowsDecimal: false), 12_000)
        XCTAssertNil(MetricInput.parse("1.2", allowsDecimal: false))
        XCTAssertEqual(MetricInput.parse("1.234", allowsDecimal: true), 1_234)
        XCTAssertNil(MetricInput.parse("1.2345", allowsDecimal: true))
        XCTAssertNil(MetricInput.parse("-1", allowsDecimal: true))
        XCTAssertNil(MetricInput.parse("12kg", allowsDecimal: true))
        XCTAssertNil(MetricInput.parse("9223372036854776", allowsDecimal: true))
        XCTAssertNil(MetricInput.parse("", allowsDecimal: true))
    }

    func testWorkoutValueEditingUsesSnapshotRulesAndKeepsDraftsSeparateUntilApply() throws {
        let metric = MetricDefinition(name: "旧重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "アーカイブ済み種目", metrics: [metric])
        exercise.isArchived = true
        let zero = MetricValue(metric: metric, scaledValue: 0)
        let optional = MetricValue(metric: metric, scaledValue: nil)
        let set = SetRecord(sortOrder: 1, values: [zero, optional])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [set])
        let workout = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [record])

        var drafts = WorkoutValueEditing.drafts(for: workout)
        XCTAssertEqual(drafts.map(\.text), ["0", ""])
        XCTAssertTrue(drafts.allSatisfy { $0.name == "旧重量" && $0.unit == "kg" && $0.allowsDecimal && !$0.isRequired })
        drafts[0].text = "12.345"
        drafts[1].text = "0"
        XCTAssertEqual(zero.scaledValue, 0)
        XCTAssertNil(optional.scaledValue)

        guard case let .success(values) = WorkoutValueEditing.validatedValues(from: drafts) else {
            return XCTFail("有効な編集値を受け付ける")
        }
        XCTAssertEqual(values.first { $0.valueID == zero.id }?.scaledValue, 12_345)
        XCTAssertEqual(values.first { $0.valueID == optional.id }?.scaledValue, 0)
        WorkoutValueEditing.apply(values, to: workout)
        XCTAssertEqual(zero.scaledValue, 12_345)
        XCTAssertEqual(optional.scaledValue, 0)

        drafts[0].text = "-1"
        if case .success = WorkoutValueEditing.validatedValues(from: drafts) {
            XCTFail("負数を拒否する")
        }
        var requiredDraft = drafts[0]
        requiredDraft.text = ""
        let requiredValue = WorkoutValueEditDraft(
            valueID: requiredDraft.valueID,
            exerciseName: requiredDraft.exerciseName,
            setOrder: requiredDraft.setOrder,
            name: requiredDraft.name,
            unit: requiredDraft.unit,
            allowsDecimal: requiredDraft.allowsDecimal,
            isRequired: true,
            text: requiredDraft.text
        )
        if case .success = WorkoutValueEditing.validatedValues(from: [requiredValue]) {
            XCTFail("必須項目の空欄を拒否する")
        }
    }

    func testWorkoutValueEditSavePersistsOnlyValuesAndPreservesSnapshotAndHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteWorkoutValueEdit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("WorkoutValueEdit", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        let targetID = UUID()
        let otherWorkoutID = UUID()
        let targetValueID: UUID
        let otherOriginalDay: String
        let targetCreatedAt: Date
        let recordCreatedAt: Date
        var testCalendar = Calendar(identifier: .gregorian)
        testCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let fixedNow = try XCTUnwrap(testCalendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)))
        let editedDay = try XCTUnwrap(testCalendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 18)))
        let editedDayString = Workout.dayString(from: editedDay, calendar: testCalendar)

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let metric = MetricDefinition(name: "旧重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
            let exercise = Exercise(name: "過去の種目名", metrics: [metric])
            exercise.isArchived = true
            metric.name = "現在の項目名"
            metric.unit = "lb"
            let targetValue = MetricValue(metric: metric, scaledValue: 8_000)
            targetValue.name = "旧重量"
            targetValue.unit = "kg"
            targetValue.allowsDecimal = true
            targetValue.isRequired = false
            targetValueID = targetValue.id
            let secondValue = MetricValue(metric: metric, scaledValue: nil)
            secondValue.name = "任意項目"
            secondValue.unit = "回"
            secondValue.allowsDecimal = false
            secondValue.isRequired = false
            let targetSet = SetRecord(sortOrder: 3, values: [targetValue, secondValue])
            let targetRecord = ExerciseRecord(exercise: exercise, sortOrder: 2, sets: [targetSet])
            let precedingRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: 4_000)])])
            let target = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [targetRecord, precedingRecord])
            target.id = targetID
            targetCreatedAt = target.createdAt
            recordCreatedAt = targetSet.createdAt

            let otherValue = MetricValue(metric: metric, scaledValue: 20_000)
            let other = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [otherValue])])])
            other.id = otherWorkoutID
            otherOriginalDay = other.day
            context.insert(exercise)
            context.insert(target)
            context.insert(other)
            try context.save()

            var drafts = WorkoutValueEditing.drafts(for: target)
            drafts[drafts.firstIndex { $0.valueID == targetValueID }!].text = ""
            drafts[drafts.firstIndex { $0.name == "任意項目" }!].text = "0"
            let discardedDraft = WorkoutValueEditing.drafts(for: target)
            XCTAssertEqual(targetValue.scaledValue, 8_000, "draftを作成・破棄してもモデル値を変えない")
            XCTAssertEqual(secondValue.scaledValue, nil)
            if case .failure = WorkoutValueEditing.validatedValues(from: drafts) {
                XCTFail("任意項目の空欄と0を受け付ける")
            }

            var invalidDrafts = drafts
            invalidDrafts[invalidDrafts.firstIndex { $0.valueID == targetValueID }!].text = "1.2345"
            if case .success = WorkoutValueEditing.validatedValues(from: invalidDrafts) {
                XCTFail("小数第4位を拒否する")
            }
            invalidDrafts[invalidDrafts.firstIndex { $0.valueID == targetValueID }!].text = "1.2"
            invalidDrafts[invalidDrafts.firstIndex { $0.name == "任意項目" }!].text = "1.5"
            if case .success = WorkoutValueEditing.validatedValues(from: invalidDrafts) {
                XCTFail("整数項目は小数を拒否")
            }
            XCTAssertEqual(targetValue.scaledValue, 8_000, "入力エラーでは対象のどの値も変更しない")
            XCTAssertNil(secondValue.scaledValue, "入力エラーでは他の項目値も変更しない")

            // 保存失敗を注入し、対象値を戻しつつ他の未保存変更を維持する。
            otherValue.scaledValue = 21_000
            let originalDay = target.day
            XCTAssertThrowsError(try WorkoutValueEditing.save(drafts, day: editedDay, to: target, calendar: testCalendar, now: fixedNow) { throw NSError(domain: "InjectedSaveFailure", code: 1) })
            XCTAssertEqual(targetValue.scaledValue, 8_000)
            XCTAssertNil(secondValue.scaledValue)
            XCTAssertEqual(target.day, originalDay, "保存失敗時は日付も復元する")
            XCTAssertEqual(otherValue.scaledValue, 21_000)
            XCTAssertEqual(drafts.first { $0.valueID == targetValueID }?.text, "", "失敗後も編集入力を保持する")
            XCTAssertEqual(discardedDraft.first { $0.valueID == targetValueID }?.text, "8", "破棄したdraftの値はモデルに反映しない")

            try WorkoutValueEditing.save(drafts, additions: [], day: editedDay, to: target, exercises: [exercise], calendar: testCalendar, now: fixedNow) { try context.save() }
            XCTAssertEqual(target.createdAt, targetCreatedAt)
            XCTAssertEqual(targetSet.createdAt, recordCreatedAt)
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let workouts = try reopenedContext.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(Set(workouts.map(\.id)), [targetID, otherWorkoutID])
        let savedWorkout = try XCTUnwrap(workouts.first { $0.id == targetID })
        XCTAssertEqual(savedWorkout.day, editedDayString)
        XCTAssertEqual(savedWorkout.createdAt, targetCreatedAt)
        XCTAssertEqual(savedWorkout.records.sorted { $0.sortOrder < $1.sortOrder }.map(\.sortOrder), [0, 2])
        let record = try XCTUnwrap(savedWorkout.records.first { $0.sortOrder == 2 })
        XCTAssertEqual(record.exerciseName, "過去の種目名")
        XCTAssertEqual(record.sortOrder, 2)
        let set = try XCTUnwrap(record.sets.first)
        XCTAssertEqual(set.sortOrder, 3)
        XCTAssertEqual(set.createdAt, recordCreatedAt)
        let savedEditedValue = try XCTUnwrap(set.values.first { $0.id == targetValueID })
        XCTAssertNil(savedEditedValue.scaledValue, "任意の既存値を空にする")
        XCTAssertEqual(savedEditedValue.name, "旧重量")
        XCTAssertEqual(savedEditedValue.unit, "kg")
        XCTAssertTrue(savedEditedValue.allowsDecimal)
        XCTAssertFalse(savedEditedValue.isRequired)
        XCTAssertEqual(set.values.first { $0.name == "任意項目" }?.scaledValue, 0, "nilを0にする")
        let otherWorkout = try XCTUnwrap(workouts.first { $0.id == otherWorkoutID })
        XCTAssertEqual(otherWorkout.day, otherOriginalDay, "別Workoutの日付を変更しない")
        XCTAssertEqual(otherWorkout.records.first?.sets.first?.values.first?.scaledValue, 21_000)
        let archivedExercise = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Exercise>()).first)
        XCTAssertTrue(archivedExercise.isArchived)
        XCTAssertEqual(archivedExercise.name, "過去の種目名")
    }

    func testWorkoutValueEditingRejectsInvalidDayOrDraftWithoutPartialChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)))
        let originalDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14)))
        let futureDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "テスト種目", metrics: [metric])
        let value = MetricValue(metric: metric, scaledValue: 5_000)
        let workout = Workout(day: originalDate, records: [ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [value])])], calendar: calendar)
        var drafts = WorkoutValueEditing.drafts(for: workout)
        drafts[0].text = "7"

        XCTAssertThrowsError(try WorkoutValueEditing.save(drafts, day: futureDate, to: workout, calendar: calendar, now: now) {})
        XCTAssertEqual(workout.day, "2026-11-14")
        XCTAssertEqual(value.scaledValue, 5_000)

        workout.day = "2026-02-30"
        XCTAssertThrowsError(try WorkoutValueEditing.save(drafts, day: originalDate, to: workout, calendar: calendar, now: now) {})
        XCTAssertEqual(workout.day, "2026-02-30", "壊れた保存日付は編集で上書きしない")
        XCTAssertEqual(value.scaledValue, 5_000)
        workout.day = "2026-11-14"

        drafts[0].text = "invalid"
        XCTAssertThrowsError(try WorkoutValueEditing.save(drafts, day: originalDate, to: workout, calendar: calendar, now: now) {})
        XCTAssertEqual(workout.day, "2026-11-14")
        XCTAssertEqual(value.scaledValue, 5_000)

        drafts[0].text = ""
        XCTAssertNoThrow(try WorkoutValueEditing.save(drafts, day: originalDate, to: workout, calendar: calendar, now: now) {})
        XCTAssertNil(value.scaledValue, "任意項目を空欄にした場合は値を消し、日付は一緒に扱う")
        XCTAssertEqual(workout.day, "2026-11-14")
    }

    func testWorkoutValueEditingSavesAdditionsAtomicallyAndReopensStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteWorkoutSetAddition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("WorkoutSetAddition", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)))
        let originalDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 28)))
        let editedDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 22)))
        let targetID = UUID()
        let metricID = UUID()
        let optionalMetricID = UUID()
        let oldValueID = UUID()
        let createdWorkoutAt: Date
        let createdRecordAt: Date
        var insertedSetIDs = Set<UUID>()
        let context: ModelContext
        let workout: Workout
        let record: ExerciseRecord
        let exercise: Exercise
        let oldValue: MetricValue

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            context = ModelContext(container)
            let required = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
            required.id = metricID
            let optional = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 1)
            optional.id = optionalMetricID
            exercise = Exercise(name: "種目", metrics: [required, optional])
            oldValue = MetricValue(metric: required, scaledValue: 5_000)
            oldValue.id = oldValueID
            let oldSet = SetRecord(sortOrder: 2, values: [oldValue, MetricValue(metric: optional, scaledValue: nil)])
            record = ExerciseRecord(exercise: exercise, sortOrder: 1, sets: [oldSet])
            workout = Workout(day: originalDay, records: [record], calendar: calendar)
            workout.id = targetID
            createdWorkoutAt = workout.createdAt
            createdRecordAt = oldSet.createdAt
            let other = Workout(day: now, records: [ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [])], calendar: calendar)
            context.insert(exercise)
            context.insert(workout)
            context.insert(other)
            try context.save()
        }

        var edits = WorkoutValueEditing.drafts(for: workout)
        edits[edits.firstIndex { $0.valueID == oldValueID }!].text = "6.25"
        var additions = WorkoutSetAdditionDrafts()
        let firstDraft = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
        let second = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
        additions.append(firstDraft)
        additions.append(second)
        additions.setValue("5", draftID: firstDraft.id, metricID: metricID)
        additions.duplicate(id: firstDraft.id)
        let copiedDraft = try XCTUnwrap(additions.items.first { $0.id != firstDraft.id && $0.recordID == firstDraft.recordID })
        XCTAssertEqual(additions.value(draftID: copiedDraft.id, metricID: metricID), "5", "複製直後にraw入力をコピー")
        additions.setValue("0", draftID: copiedDraft.id, metricID: metricID)
        additions.setValue("", draftID: copiedDraft.id, metricID: optionalMetricID)
        additions.setValue("7.5", draftID: second.id, metricID: metricID)
        additions.setValue("12", draftID: second.id, metricID: optionalMetricID)
        XCTAssertEqual(additions.items.map(\.id), [firstDraft.id, copiedDraft.id, second.id], "画面と同じ複製操作で直後に隣接挿入")
        XCTAssertNotEqual(copiedDraft.id, firstDraft.id)
        XCTAssertEqual(additions.value(draftID: firstDraft.id, metricID: metricID), "5", "複製後の入力変更は元に反映しない")
        additions.cancel(id: firstDraft.id)
        XCTAssertEqual(additions.items.map(\.id), [copiedDraft.id, second.id], "ID指定取消し後は残ったdraftだけ保存")
        XCTAssertEqual(record.sets.count, 1, "保存前はモデルに追加しない。キャンセル時も元のまま")
        XCTAssertEqual(oldValue.scaledValue, 5_000)

        var invalidAddition = copiedDraft
        invalidAddition.values[metricID] = ""
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [invalidAddition], day: editedDay, to: workout, exercises: [exercise], calendar: calendar, now: now) {})
        invalidAddition.values[metricID] = "-1"
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [invalidAddition], day: editedDay, to: workout, exercises: [exercise], calendar: calendar, now: now) {})
        invalidAddition.values[metricID] = "1.2345"
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [invalidAddition], day: editedDay, to: workout, exercises: [exercise], calendar: calendar, now: now) {})
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [copiedDraft, copiedDraft], day: editedDay, to: workout, exercises: [exercise], calendar: calendar, now: now) {}, "追加draft重複を拒否")
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [copiedDraft], day: now.addingTimeInterval(86_400), to: workout, exercises: [exercise], calendar: calendar, now: now) {}, "未来日を拒否")
        XCTAssertEqual(record.sets.count, 1, "入力拒否のどの場合もモデルを変更しない")
        XCTAssertEqual(workout.day, Workout.dayString(from: originalDay, calendar: calendar))
        XCTAssertEqual(oldValue.scaledValue, 5_000)

        let originalStoredDay = workout.day
        var unsavedOtherValue: MetricValue?
        // 他Workoutへの未保存変更も、対象の保存失敗時に巻き戻さない。
        let otherWorkout = try XCTUnwrap(try context.fetch(FetchDescriptor<Workout>()).first { $0.id != targetID })
        let otherMetric = exercise.metrics[0]
        unsavedOtherValue = MetricValue(metric: otherMetric, scaledValue: 99_000)
        let otherRecord = try XCTUnwrap(otherWorkout.records.first)
        let otherSet = SetRecord(sortOrder: 1, values: [unsavedOtherValue!])
        otherRecord.sets.append(otherSet)
        var discarded: [SetRecord] = []
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: additions.items, day: editedDay, to: workout, exercises: [exercise], calendar: calendar, now: now, discard: { set in discarded.append(set); context.delete(set) }) {
            throw NSError(domain: "InjectedSaveFailure", code: 1)
        })
        XCTAssertEqual(workout.day, originalStoredDay)
        XCTAssertEqual(oldValue.scaledValue, 5_000)
        XCTAssertEqual(otherRecord.sets.count, 1, "他の未保存変更は維持")
        XCTAssertEqual(discarded.count, 2)
        XCTAssertTrue(discarded.allSatisfy { $0.values.allSatisfy { $0.setRecord == nil } }, "失敗した新規Valueを孤児として残さない")
        XCTAssertEqual(record.sets.count, 1, "失敗時に追加セットを残さない")

        try WorkoutValueEditing.save(edits, additions: additions.items, day: editedDay, to: workout, exercises: [exercise], calendar: calendar, now: now) { try context.save() }
        XCTAssertEqual(record.sets.sorted { $0.sortOrder < $1.sortOrder }.map(\.sortOrder), [2, 3, 4])
        insertedSetIDs = Set(record.sets.filter { $0.sortOrder > 2 }.map(\.id))
        XCTAssertEqual(record.sets.filter { $0.sortOrder > 2 }.map(\.createdAt).count, 2)
        XCTAssertEqual(workout.createdAt, createdWorkoutAt)
        XCTAssertEqual(record.sets.first { $0.sortOrder == 2 }?.createdAt, createdRecordAt)

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let saved = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Workout>()).first { $0.id == targetID })
        XCTAssertEqual(saved.day, Workout.dayString(from: editedDay, calendar: calendar))
        XCTAssertEqual(saved.createdAt, createdWorkoutAt)
        let savedRecord = try XCTUnwrap(saved.records.first)
        XCTAssertEqual(savedRecord.exerciseName, "種目")
        XCTAssertEqual(savedRecord.sets.map(\.sortOrder).sorted(), [2, 3, 4], "再試行で重複セットを作らない")
        XCTAssertEqual(Set(savedRecord.sets.map(\.id)).count, 3)
        XCTAssertEqual(Set(savedRecord.sets.filter { $0.sortOrder > 2 }.map(\.id)), insertedSetIDs, "生成された永続セットIDを再オープン後も保持")
        XCTAssertEqual(insertedSetIDs.count, 2)
        XCTAssertEqual(savedRecord.sets.first { $0.sortOrder == 2 }?.values.first { $0.id == oldValueID }?.scaledValue, 6_250)
        let addedZero = try XCTUnwrap(savedRecord.sets.first { $0.sortOrder == 3 }?.values.first { $0.metricID == metricID })
        XCTAssertEqual(addedZero.scaledValue, 0, "0とnilを区別")
        XCTAssertNil(savedRecord.sets.first { $0.sortOrder == 3 }?.values.first { $0.name == "回数" }?.scaledValue)
        XCTAssertEqual(savedRecord.sets.first { $0.sortOrder == 4 }?.values.first { $0.name == "回数" }?.scaledValue, 12_000)
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<Workout>()).count, 2)
    }

    func testWorkoutSetAdditionRejectsUnavailableExercisesSnapshotDriftAndOverflow() throws {
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "種目", metrics: [metric])
        let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: nil)])])
        let workout = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [record])
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day))
        let edits = WorkoutValueEditing.drafts(for: workout)
        let baseline = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))

        exercise.isArchived = true
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [baseline], day: day, to: workout, exercises: [exercise]) {})
        XCTAssertEqual(record.sets.count, 1)
        exercise.isArchived = false

        let nonexistent = WorkoutSetAdditionDraft(
            id: UUID(), recordID: baseline.recordID, exerciseID: UUID(),
            exerciseName: baseline.exerciseName, metrics: baseline.metrics, values: baseline.values
        )
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [nonexistent], day: day, to: workout, exercises: [exercise]) {})
        XCTAssertEqual(record.sets.count, 1)

        let changedMetricDraft = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
        for change in 0..<4 {
            let originalName = metric.name
            let originalUnit = metric.unit
            let originalRequired = metric.isRequired
            let originalActive = metric.isActive
            switch change {
            case 0: metric.name = "変更後"
            case 1: metric.unit = "lb"
            case 2: metric.isRequired = true
            default: metric.isActive = false
            }
            let beforeDay = workout.day
            let beforeValue = record.sets[0].values[0].scaledValue
            XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [changedMetricDraft], day: day, to: workout, exercises: [exercise]) {})
            XCTAssertEqual(workout.day, beforeDay)
            XCTAssertEqual(record.sets.count, 1)
            XCTAssertEqual(record.sets[0].values[0].scaledValue, beforeValue)
            metric.name = originalName
            metric.unit = originalUnit
            metric.isRequired = originalRequired
            metric.isActive = originalActive
        }

        record.sets[0].sortOrder = Int.max
        XCTAssertThrowsError(try WorkoutValueEditing.save(edits, additions: [baseline], day: day, to: workout, exercises: [exercise]) { XCTFail("overflow時はpersistしない") }) { error in
            XCTAssertEqual((error as? WorkoutValueEditError)?.errorDescription, WorkoutValueEditError.setOrderOverflow.errorDescription)
        }
        XCTAssertEqual(record.sets.count, 1, "順序overflow時に追加セットを残さない")
    }

    func testWorkoutSetAdditionDraftCancellationTargetsIDsAndSavesOnlyRemainingDrafts() throws {
        let metricA = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let metricB = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0)
        let exerciseA = Exercise(name: "種目A", metrics: [metricA])
        let exerciseB = Exercise(name: "種目B", metrics: [metricB])
        let recordA = ExerciseRecord(exercise: exerciseA, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metricA, scaledValue: 5_000)])])
        let recordB = ExerciseRecord(exercise: exerciseB, sortOrder: 1, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: metricB, scaledValue: 8_000)])])
        let originalDay = Date(timeIntervalSince1970: 1_794_686_400)
        let workout = Workout(day: originalDay, records: [recordA, recordB])
        let originalDayString = workout.day
        let existingValues = [recordA, recordB].flatMap(\.sets).flatMap(\.values)
        var additions = WorkoutSetAdditionDrafts()
        let draftA1 = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: recordA, exercise: exerciseA))
        let draftB1 = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: recordB, exercise: exerciseB))
        let draftA2 = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: recordA, exercise: exerciseA))
        let draftB2 = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: recordB, exercise: exerciseB))
        let draftA3 = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: recordA, exercise: exerciseA))
        [draftA1, draftB1, draftA2, draftB2, draftA3].forEach { additions.append($0) }

        additions.setValue("11.5", draftID: draftA1.id, metricID: metricA.id)
        additions.setValue("12", draftID: draftA2.id, metricID: metricA.id)
        additions.setValue("13", draftID: draftA3.id, metricID: metricA.id)
        additions.setValue("21", draftID: draftB1.id, metricID: metricB.id)
        additions.setValue("22", draftID: draftB2.id, metricID: metricB.id)
        additions.cancel(id: draftA1.id) // 先頭
        additions.cancel(id: draftB1.id) // 別種目の先頭
        additions.cancel(id: draftB2.id) // 残存配列の中間
        additions.setValue("999", draftID: UUID(), metricID: metricA.id)

        XCTAssertEqual(additions.items.map(\.id), [draftA2.id, draftA3.id])
        XCTAssertEqual(additions.value(draftID: draftA2.id, metricID: metricA.id), "12")
        XCTAssertEqual(additions.value(draftID: draftA3.id, metricID: metricA.id), "13")
        XCTAssertEqual(additions.value(draftID: draftA1.id, metricID: metricA.id), "")
        XCTAssertEqual(additions.value(draftID: draftB2.id, metricID: metricB.id), "")
        XCTAssertTrue([recordA, recordB].allSatisfy { $0.sets.count == 1 }, "取消し前のdraftは保存済みセットに触れない")
        XCTAssertEqual(workout.day, originalDayString, "取消しではWorkoutの日付を変更しない")
        XCTAssertEqual(existingValues.map(\.scaledValue), [5_000, 8_000], "取消しでは保存済み値を変更しない")

        let editedDay = Date(timeIntervalSince1970: 1_706_659_200)
        try WorkoutValueEditing.save([], additions: additions.items, day: editedDay, to: workout, exercises: [exerciseA, exerciseB], now: Date(timeIntervalSince1970: 1_800_000_000)) {}
        XCTAssertEqual(workout.records.first { $0.id == recordA.id }?.sets.map(\.sortOrder).sorted(), [1, 2, 3])
        XCTAssertEqual(recordB.sets.map(\.sortOrder), [1], "取り消した種目Bのdraftは追加しない")
        XCTAssertEqual(recordA.sets.first { $0.sortOrder == 2 }?.values.first?.scaledValue, 12_000)
        XCTAssertEqual(recordA.sets.first { $0.sortOrder == 3 }?.values.first?.scaledValue, 13_000)
        XCTAssertEqual(workout.day, Workout.dayString(from: editedDay, calendar: .current), "残ったdraftを保存し、日付変更も反映する")
    }

    func testWorkoutSetAdditionDraftDuplicationCopiesRawValuesAndInsertsByID() {
        let metric = WorkoutSetMetricDraft(id: UUID(), name: "重量", unit: "kg", allowsDecimal: true, isRequired: false)
        let recordA = UUID()
        let recordB = UUID()
        let first = WorkoutSetAdditionDraft(id: UUID(), recordID: recordA, exerciseID: UUID(), exerciseName: "種目A", metrics: [metric], values: [metric.id: " 1.2345 "])
        let otherRecord = WorkoutSetAdditionDraft(id: UUID(), recordID: recordB, exerciseID: UUID(), exerciseName: "種目B", metrics: [metric], values: [:])
        let next = WorkoutSetAdditionDraft(id: UUID(), recordID: recordA, exerciseID: first.exerciseID, exerciseName: first.exerciseName, metrics: first.metrics, values: [metric.id: ""])
        var additions = WorkoutSetAdditionDrafts()
        [first, otherRecord, next].forEach { additions.append($0) }

        additions.duplicate(id: first.id)

        let copy = additions.items[1]
        XCTAssertEqual(additions.items.map(\.id), [first.id, copy.id, otherRecord.id, next.id])
        XCTAssertNotEqual(copy.id, first.id)
        XCTAssertEqual(copy.recordID, first.recordID)
        XCTAssertEqual(copy.exerciseID, first.exerciseID)
        XCTAssertEqual(copy.exerciseName, first.exerciseName)
        XCTAssertEqual(copy.metrics, first.metrics)
        XCTAssertEqual(copy.values, first.values)
        additions.setValue("不正値", draftID: copy.id, metricID: metric.id)
        XCTAssertEqual(additions.value(draftID: first.id, metricID: metric.id), " 1.2345 ")
        XCTAssertEqual(additions.value(draftID: copy.id, metricID: metric.id), "不正値")
        additions.cancel(id: first.id)
        XCTAssertEqual(additions.items.map(\.id), [copy.id, otherRecord.id, next.id])
        additions.duplicate(id: first.id)
        XCTAssertEqual(additions.items.map(\.id), [copy.id, otherRecord.id, next.id])
    }

    func testWorkoutSetAdditionAllowsEmptyOptionalSetAndKeepsZeroDistinct() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteOptionalSet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("OptionalSet", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        let workoutID = UUID()
        let recordID = UUID()
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let metric = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 0)
            let exercise = Exercise(name: "種目", metrics: [metric])
            let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [])
            record.id = recordID
            let workout = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [record])
            workout.id = workoutID
            context.insert(exercise)
            context.insert(workout)
            try context.save()

            let empty = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
            var zero = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: record, exercise: exercise))
            zero.values[metric.id] = "0"
            try WorkoutValueEditing.save([], additions: [empty, zero], day: WorkoutValueEditing.date(from: workout.day)!, to: workout, exercises: [exercise]) { try context.save() }
        }
        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        let savedWorkout = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workoutID })
        let savedRecord = try XCTUnwrap(savedWorkout.records.first { $0.id == recordID })
        let emptySet = try XCTUnwrap(savedRecord.sets.first { $0.sortOrder == 1 })
        let zeroSet = try XCTUnwrap(savedRecord.sets.first { $0.sortOrder == 2 })
        XCTAssertNil(emptySet.values.first?.scaledValue, "未入力はnilのまま保存")
        XCTAssertEqual(zeroSet.values.first?.scaledValue, 0, "入力した0はnilと区別して保存")
    }

    func testWorkoutStoredDayRejectsMalformedAndImpossibleDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        for invalid in ["2024-2-09", "2024-02-30", "2023-02-29", "abcd-01-01", "2024-01-01x"] {
            XCTAssertNil(WorkoutValueEditing.date(from: invalid, calendar: calendar), "不正日付を拒否: \(invalid)")
        }
        let leap = try XCTUnwrap(WorkoutValueEditing.date(from: "2024-02-29", calendar: calendar))
        XCTAssertEqual(Workout.dayString(from: leap, calendar: calendar), "2024-02-29")
    }

    func testWorkoutDayConversionUsesCalendarDaysAcrossZonesDSTLeapDayAndYearEnd() throws {
        let cases: [(String, DateComponents, String)] = [
            ("Asia/Tokyo", DateComponents(year: 2024, month: 2, day: 29, hour: 23), "2024-02-29"),
            ("Pacific/Honolulu", DateComponents(year: 2024, month: 3, day: 10, hour: 23), "2024-03-10"),
            ("America/Los_Angeles", DateComponents(year: 2024, month: 3, day: 10, hour: 3), "2024-03-10"),
            ("Asia/Tokyo", DateComponents(year: 2025, month: 12, day: 31, hour: 23), "2025-12-31"),
            ("Asia/Tokyo", DateComponents(year: 2026, month: 1, day: 1, hour: 0), "2026-01-01")
        ]
        for (zone, components, expected) in cases {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let date = try XCTUnwrap(calendar.date(from: components))
            XCTAssertEqual(Workout.dayString(from: date, calendar: calendar), expected, "\(zone) \(expected)")
            XCTAssertEqual(WorkoutValueEditing.date(from: expected, calendar: calendar).map { Workout.dayString(from: $0, calendar: calendar) }, expected)
        }
    }

    func testWorkoutDayIsStableAcrossTimeZones() {
        let cases: [(String, Int, Int, Int, Int)] = [
            ("Pacific/Kiritimati", 2026, 11, 14, 0),
            ("Asia/Tokyo", 2026, 11, 14, 0),
            ("Pacific/Honolulu", 2026, 11, 14, 0),
            ("Pacific/Kiritimati", 2026, 11, 14, 23),
        ]

        for (timeZoneID, year, month, day, hour) in cases {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneID)!
            let selectedDate = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
            let stored = Workout(day: selectedDate, records: [], calendar: calendar).day
            XCTAssertEqual(stored, "2026-11-14", "\(timeZoneID) の \(hour) 時を選択した場合")
            XCTAssertEqual(Workout.dayFormatter.date(from: stored).map { Workout.dayFormatter.string(from: $0) }, "2026-11-14")
        }
    }

    func testCalendarGridUsesMondayFirstAndLeapFebruary() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = WorkoutCalendarLogic.calendar(timeZone: utc)
        let february = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 19)))
        let grid = WorkoutCalendarLogic.monthGrid(for: february, calendar: calendar)
        XCTAssertEqual(grid.dayCount, 29)
        XCTAssertEqual(grid.weekdayOffset, 3) // 2024-02-01 は木曜日
        XCTAssertEqual(grid.cellCount, 35)
        XCTAssertEqual(WorkoutCalendarLogic.date(day: 1, in: grid, calendar: calendar), try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 1))))
        XCTAssertEqual(WorkoutCalendarLogic.date(day: 29, in: grid, calendar: calendar), try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 29))))
        XCTAssertNil(WorkoutCalendarLogic.date(day: 30, in: grid, calendar: calendar))
    }

    func testCalendarGridHandlesMonthEndAndYearChange() throws {
        let calendar = WorkoutCalendarLogic.calendar(timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        let december = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 12, day: 31)))
        let decemberGrid = WorkoutCalendarLogic.monthGrid(for: december, calendar: calendar)
        XCTAssertEqual(decemberGrid.dayCount, 31)
        XCTAssertEqual(WorkoutCalendarLogic.dayKey(try XCTUnwrap(WorkoutCalendarLogic.date(day: 31, in: decemberGrid, calendar: calendar)), calendar: calendar), "2024-12-31")
        let january = try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: decemberGrid.start))
        let januaryGrid = WorkoutCalendarLogic.monthGrid(for: january, calendar: calendar)
        XCTAssertEqual(calendar.component(.year, from: januaryGrid.start), 2025)
        XCTAssertEqual(calendar.component(.month, from: januaryGrid.start), 1)
        XCTAssertEqual(januaryGrid.dayCount, 31)
    }

    func testDateKeysInTokyoHonoluluAndAcrossDaylightSavingBoundary() throws {
        let tokyo = WorkoutCalendarLogic.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo")))
        let honolulu = WorkoutCalendarLogic.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu")))
        let instant = Date(timeIntervalSince1970: 1_710_000_000) // 固定時刻: 2024-03-09 UTC
        XCTAssertEqual(WorkoutCalendarLogic.dayKey(instant, calendar: tokyo), "2024-03-10")
        XCTAssertEqual(WorkoutCalendarLogic.dayKey(instant, calendar: honolulu), "2024-03-09")

        let losAngeles = WorkoutCalendarLogic.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")))
        let beforeDST = Date(timeIntervalSince1970: 1_710_064_799) // 2024-03-10 01:59:59 PST
        let afterDST = Date(timeIntervalSince1970: 1_710_064_800) // 2024-03-10 03:00:00 PDT
        XCTAssertEqual(WorkoutCalendarLogic.dayKey(beforeDST, calendar: losAngeles), "2024-03-10")
        XCTAssertEqual(WorkoutCalendarLogic.dayKey(afterDST, calendar: losAngeles), "2024-03-10")
    }

    func testWorkoutCalendarSelectionAndAddAvailabilityAtFixedNow() throws {
        let tokyo = WorkoutCalendarLogic.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo")))
        let honolulu = WorkoutCalendarLogic.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu")))
        let fixedNow = try XCTUnwrap(tokyo.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)))
        let today = try XCTUnwrap(WorkoutValueEditing.date(from: "2026-11-15", calendar: tokyo))
        let past = try XCTUnwrap(WorkoutValueEditing.date(from: "2024-02-29", calendar: tokyo))
        let future = try XCTUnwrap(WorkoutValueEditing.date(from: "2026-11-16", calendar: tokyo))

        XCTAssertEqual(WorkoutCalendarLogic.initialWorkoutDay(selectedDay: nil, now: fixedNow, calendar: tokyo), tokyo.startOfDay(for: fixedNow))
        XCTAssertEqual(WorkoutCalendarLogic.initialWorkoutDay(selectedDay: "2026-11-15", now: fixedNow, calendar: tokyo), tokyo.startOfDay(for: today))
        XCTAssertEqual(WorkoutCalendarLogic.initialWorkoutDay(selectedDay: "2024-02-29", now: fixedNow, calendar: tokyo), tokyo.startOfDay(for: past))
        XCTAssertEqual(WorkoutCalendarLogic.initialWorkoutDay(selectedDay: "2026-11-16", now: fixedNow, calendar: tokyo), tokyo.startOfDay(for: future))
        XCTAssertNil(WorkoutCalendarLogic.initialWorkoutDay(selectedDay: "2026-02-30", now: fixedNow, calendar: tokyo), "不正選択を今日にfallbackしない")

        XCTAssertTrue(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 1, selectedDay: nil, now: fixedNow, calendar: tokyo).isEmpty)
        XCTAssertTrue(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 1, selectedDay: "2026-11-15", now: fixedNow, calendar: tokyo).isEmpty)
        XCTAssertTrue(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 1, selectedDay: "2024-02-29", now: fixedNow, calendar: tokyo).isEmpty)
        XCTAssertEqual(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 1, selectedDay: "2026-11-16", now: fixedNow, calendar: tokyo), [.futureDay])
        XCTAssertEqual(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 0, selectedDay: nil, now: fixedNow, calendar: tokyo), [.noActiveExercises])
        XCTAssertEqual(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 0, selectedDay: "2026-11-16", now: fixedNow, calendar: tokyo), [.noActiveExercises, .futureDay])
        XCTAssertEqual(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 0, selectedDay: "2026-02-30", now: fixedNow, calendar: tokyo), [.noActiveExercises, .invalidSelectedDay])
        XCTAssertEqual(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 1, selectedDay: "2026-02-30", now: fixedNow, calendar: tokyo), [.invalidSelectedDay])
        XCTAssertTrue(WorkoutCalendarLogic.addWorkoutBlocks(activeExerciseCount: 1, selectedDay: nil, now: fixedNow, calendar: honolulu).isEmpty, "全履歴に戻すと未来日ブロックを解除")

        let timezoneCases: [(Calendar, String, String)] = [
            (tokyo, "2024-02-29", "2024-02-29"),
            (honolulu, "2024-03-10", "2024-03-10"),
            (tokyo, "2025-12-31", "2025-12-31"),
            (honolulu, "2026-01-01", "2026-01-01")
        ]
        for (calendar, key, expected) in timezoneCases {
            let date = try XCTUnwrap(WorkoutCalendarLogic.initialWorkoutDay(selectedDay: key, now: fixedNow, calendar: calendar))
            XCTAssertEqual(Workout.dayString(from: date, calendar: calendar), expected, "独立した期待日: \(key)")
        }
    }

    func testWorkoutFilterReturnsSameDayRecordsOrAllHistory() {
        let first = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [])
        let sameDay = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [])
        let otherDay = Workout(day: Date(timeIntervalSince1970: 1_700_086_400), records: [])
        let workouts = [first, sameDay, otherDay]
        XCTAssertEqual(WorkoutCalendarLogic.workouts(on: first.day, from: workouts).map(\.id), [first.id, sameDay.id])
        XCTAssertEqual(WorkoutCalendarLogic.workouts(on: nil, from: workouts).map(\.id), workouts.map(\.id))
        XCTAssertTrue(WorkoutCalendarLogic.workouts(on: "2099-01-01", from: workouts).isEmpty)
    }

    func testArchiveAndFileStoreRoundTripPreserveHistoryAndSetOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("Test", schema: schema, url: url, cloudKitDatabase: .none)

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
            let exercise = Exercise(name: "テスト種目", metrics: [metric])
            let sets = [1_000, 2_500, 3_000].enumerated().map { index, value in
                SetRecord(sortOrder: index + 1, values: [MetricValue(metric: metric, scaledValue: Int64(value))])
            }
            let record = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: sets)
            let workout = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [record])
            exercise.isArchived = true
            context.insert(exercise)
            context.insert(workout)
            try context.save()
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(reopened)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let workouts = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(exercises.count, 1)
        XCTAssertTrue(exercises[0].isArchived)
        XCTAssertEqual(workouts.count, 1)
        let orderedSets = workouts[0].records[0].sets.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(orderedSets.map(\.sortOrder), [1, 2, 3])
        XCTAssertEqual(orderedSets.compactMap { $0.values.first?.scaledValue }, [1_000, 2_500, 3_000])
    }

    func testDeletingWorkoutRemovesOnlyTargetAndCascadesWithoutRemovingExercise() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeleteDeleteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("DeleteTest", schema: schema, url: url, cloudKitDatabase: .none)
        let targetID = UUID()
        let otherID = UUID()
        let exerciseID: UUID

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: false, isRequired: true, sortOrder: 0)
            let exercise = Exercise(name: "テスト種目", metrics: [metric])
            exerciseID = exercise.id
            let targetSet = SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: 10_000)])
            let targetRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [targetSet])
            let target = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [targetRecord])
            target.id = targetID
            let otherSet = SetRecord(sortOrder: 1, values: [MetricValue(metric: metric, scaledValue: 20_000)])
            let otherRecord = ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [otherSet])
            let other = Workout(day: Date(timeIntervalSince1970: 1_794_686_400), records: [otherRecord])
            other.id = otherID
            context.insert(exercise)
            context.insert(target)
            context.insert(other)
            try context.save()

            try WorkoutDeletion.delete(workoutID: targetID, in: context)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).map(\.id), [otherID])
            XCTAssertTrue(try context.fetch(FetchDescriptor<ExerciseRecord>()).allSatisfy { $0.workout?.id == otherID })
            XCTAssertEqual(try context.fetch(FetchDescriptor<SetRecord>()).count, 1)
            XCTAssertEqual(try context.fetch(FetchDescriptor<MetricValue>()).count, 1)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Exercise>()).map(\.id), [exerciseID])
            try context.save()
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = ModelContext(reopened)
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<Workout>()).map(\.id), [otherID])
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<Exercise>()).map(\.id), [exerciseID])
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<ExerciseRecord>()).count, 1)
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<SetRecord>()).count, 1)
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<MetricValue>()).count, 1)
    }
}
