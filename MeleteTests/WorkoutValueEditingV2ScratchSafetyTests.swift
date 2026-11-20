import XCTest
import SwiftData
@testable import Melete

#if DEBUG
/// 既存運動記録の値編集（WorkoutWritingServiceV2.saveWorkoutEdits）の安全性を、合成V2ストアで確認する。
/// - 保存済みMetricValueと食い違うname/unit/allowsDecimal/isRequiredを持つdraftを、storedValueMismatchで拒否すること
/// - 別のModelContextが所有する、またはcontext無しのWorkoutを、workoutContextMismatchで入口拒否すること
/// 現行UIはdraftを保存済み値から作り、Workoutも同じ環境contextの@Queryから渡すため、これらはUI操作からは起きない想定。
/// ここではサービスを直接呼ぶ呼び出し側の誤用に対する防御を確認する。
/// V1/V2共有のWorkoutValueEditing.saveは、scratch不要の WorkoutValueEditingSharedSaveSafetyTests で確認する。
/// fixtureはscratch直下の新規 `MeleteWorkoutEditSafety-<UUID>` だけに作り、削除・移動・後片付けは行わない。
final class WorkoutValueEditingV2ScratchSafetyTests: XCTestCase {
    private static let fixturePrefix = "MeleteWorkoutEditSafety-"
    /// 2023-11-14 22:13:20 UTC
    private static let workoutDay = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Fixture {
        let schema: Schema
        let configuration: ModelConfiguration
        let calendar: Calendar
        let workoutID: UUID
        /// 小数可・任意の「重量」の保存済み値ID（60.5kg）
        let weightValueID: UUID
        /// 整数のみ・必須の「回数」の保存済み値ID（8回）
        let repsValueID: UUID
    }

    private var scratchBase: URL!

    override func setUpWithError() throws {
        guard let base = UITestStoreIsolation.trustedScratchBase() else {
            let reason = "scratch領域が存在しないか、所有者・権限・symlinkの安全条件を満たしません"
#if MELETE_SCRATCH_ISOLATION
            XCTFail(reason)
            throw EditSafetyFixtureError.scratchUnavailable
#else
            throw XCTSkip(reason)
#endif
        }
        scratchBase = base
    }

    // MARK: - draftの項目設定の改変

    @MainActor func testDraftClaimingDecimalForStoredIntegerValueIsRejected() throws {
        let fixture = try makeFixture()
        try assertTamperedDraftIsRejected(fixture, label: "整数のみの値に小数可を主張するdraft") { draft in
            WorkoutValueEditDraft(
                valueID: draft.valueID, exerciseName: draft.exerciseName, setOrder: draft.setOrder,
                name: draft.name, unit: draft.unit,
                allowsDecimal: true, isRequired: draft.isRequired, text: "8.5"
            )
        }
    }

    @MainActor func testDraftClaimingOptionalForStoredRequiredValueIsRejected() throws {
        let fixture = try makeFixture()
        try assertTamperedDraftIsRejected(fixture, label: "必須の値に任意を主張するdraft") { draft in
            WorkoutValueEditDraft(
                valueID: draft.valueID, exerciseName: draft.exerciseName, setOrder: draft.setOrder,
                name: draft.name, unit: draft.unit,
                allowsDecimal: draft.allowsDecimal, isRequired: false, text: ""
            )
        }
    }

    @MainActor func testDraftRenamingStoredValueIsRejected() throws {
        let fixture = try makeFixture()
        try assertTamperedDraftIsRejected(fixture, label: "保存済み値と異なる項目名のdraft") { draft in
            WorkoutValueEditDraft(
                valueID: draft.valueID, exerciseName: draft.exerciseName, setOrder: draft.setOrder,
                name: "偽装回数", unit: draft.unit,
                allowsDecimal: draft.allowsDecimal, isRequired: draft.isRequired, text: "9"
            )
        }
    }

    @MainActor func testDraftChangingStoredUnitIsRejected() throws {
        let fixture = try makeFixture()
        try assertTamperedDraftIsRejected(fixture, label: "保存済み値と異なる単位のdraft") { draft in
            WorkoutValueEditDraft(
                valueID: draft.valueID, exerciseName: draft.exerciseName, setOrder: draft.setOrder,
                name: draft.name, unit: "セット",
                allowsDecimal: draft.allowsDecimal, isRequired: draft.isRequired, text: "9"
            )
        }
    }

    // MARK: - 別contextが所有するWorkout

    @MainActor func testWorkoutOwnedByAnotherContextIsRejectedWithoutSilentLoss() throws {
        let fixture = try makeFixture()
        let container = try ModelContainer(for: fixture.schema, migrationPlan: MeleteMigrationPlan.self, configurations: [fixture.configuration])
        // 同じcontainerから2つのcontextを作る。Workoutはowner側、serviceは別のcontextを持つ
        let ownerContext = ModelContext(container)
        let serviceContext = ModelContext(container)
        let workout = try fetchWorkout(fixture.workoutID, in: ownerContext)
        XCTAssertTrue(workout.modelContext === ownerContext, "前提: Workoutはowner contextが所有する")

        var drafts = WorkoutValueEditing.drafts(for: workout)
        let weightIndex = try XCTUnwrap(drafts.firstIndex { $0.valueID == fixture.weightValueID })
        drafts[weightIndex].text = "70"
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day, calendar: fixture.calendar))

        var saveReportedSuccess = false
        do {
            try WorkoutWritingServiceV2(context: serviceContext).saveWorkoutEdits(
                drafts, additions: [], day: day, to: workout, exercises: [], calendar: fixture.calendar
            )
            saveReportedSuccess = true
        } catch {
            assertContextMismatch(error)
        }
        XCTAssertFalse(saveReportedSuccess, "別contextのWorkoutは保存できないので、成功扱いにしない")
        XCTAssertFalse(ownerContext.hasChanges, "拒否時はowner contextに未保存変更を残さない")
        XCTAssertFalse(serviceContext.hasChanges)
        XCTAssertEqual(try value(fixture.weightValueID, in: workout)?.scaledValue, 60_500, "owner側のモデルも書き換えない")

        try assertStoredValues(fixture, weight: 60_500, reps: 8_000)

        // 拒否後も、所有contextを持つserviceからは同じWorkoutを通常どおり保存できる
        try WorkoutWritingServiceV2(context: ownerContext).saveWorkoutEdits(
            drafts, additions: [], day: day, to: workout, exercises: [], calendar: fixture.calendar
        )
        XCTAssertFalse(ownerContext.hasChanges)
        try assertStoredValues(fixture, weight: 70_000, reps: 8_000)
    }

    @MainActor func testWorkoutWithoutContextIsRejected() throws {
        let fixture = try makeFixture()
        let container = try ModelContainer(for: fixture.schema, migrationPlan: MeleteMigrationPlan.self, configurations: [fixture.configuration])
        let context = ModelContext(container)
        // どのcontextにも挿入していない合成Workout
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let detachedValue = MetricValue(metric: metric, scaledValue: 1_000)
        let detachedExercise = Exercise(name: "合成未登録種目", metrics: [metric])
        let detached = Workout(
            day: Self.workoutDay,
            records: [ExerciseRecord(exercise: detachedExercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [detachedValue])])],
            calendar: fixture.calendar
        )
        XCTAssertNil(detached.modelContext, "前提: Workoutはcontextに属さない")
        var drafts = WorkoutValueEditing.drafts(for: detached)
        drafts[0].text = "2"
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: detached.day, calendar: fixture.calendar))

        XCTAssertThrowsError(try WorkoutWritingServiceV2(context: context).saveWorkoutEdits(
            drafts, additions: [], day: day, to: detached, exercises: [], calendar: fixture.calendar
        )) { error in
            self.assertContextMismatch(error)
        }
        XCTAssertFalse(context.hasChanges, "拒否後のcontextはclean")
        XCTAssertNil(detached.modelContext, "拒否時にcontextへ挿入しない")
        XCTAssertEqual(detachedValue.scaledValue, 1_000, "context無しWorkoutのモデルも書き換えない")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).map(\.id), [fixture.workoutID], "Workoutを追加しない")

        try assertStoredValues(fixture, weight: 60_500, reps: 8_000)
    }

    // MARK: - 正常系（修正で通常の編集を壊していないこと）

    @MainActor func testSameContextValidEditIsPersisted() throws {
        let fixture = try makeFixture()
        let container = try ModelContainer(for: fixture.schema, migrationPlan: MeleteMigrationPlan.self, configurations: [fixture.configuration])
        let context = ModelContext(container)
        let workout = try fetchWorkout(fixture.workoutID, in: context)

        var drafts = WorkoutValueEditing.drafts(for: workout)
        let weightIndex = try XCTUnwrap(drafts.firstIndex { $0.valueID == fixture.weightValueID })
        let repsIndex = try XCTUnwrap(drafts.firstIndex { $0.valueID == fixture.repsValueID })
        drafts[weightIndex].text = "62.25"
        drafts[repsIndex].text = "10"
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day, calendar: fixture.calendar))

        try WorkoutWritingServiceV2(context: context).saveWorkoutEdits(
            drafts, additions: [], day: day, to: workout, exercises: [], calendar: fixture.calendar
        )
        XCTAssertFalse(context.hasChanges)
        try assertStoredValues(fixture, weight: 62_250, reps: 10_000)
    }

    // MARK: - V2入口での照合順序

    /// 改変draftと、V2入口の追加セット検証で拒否される追加（履歴baseline欠落）を同時に渡す。
    /// V2入口のverifyStoredSnapshotsが追加セット検証・revision挿入より前にあれば storedValueMismatch になる。
    /// 入口の照合を削除すると、追加セット検証が先に metricsChanged を投げるため、このテストは失敗する。
    @MainActor func testV2EntryRejectsTamperedDraftBeforeValidatingAdditions() throws {
        let fixture = try makeFixture()
        let container = try ModelContainer(for: fixture.schema, migrationPlan: MeleteMigrationPlan.self, configurations: [fixture.configuration])
        let context = ModelContext(container)
        // 保存先とは別に、同じストアを読む観測用context。拒否後に未保存変更や値の変化が見えないことを確認する
        let observerContext = ModelContext(container)
        let workout = try fetchWorkout(fixture.workoutID, in: context)
        let observedWorkout = try fetchWorkout(fixture.workoutID, in: observerContext)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let record = try XCTUnwrap(workout.records.first)
        let exercise = try XCTUnwrap(exercises.first { $0.id == record.exerciseID })
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day, calendar: fixture.calendar))

        // 追加セット: 値は正しいが、V2で必須の履歴baselineを欠落させる（V2入口の追加セット検証で metricsChanged になる条件）
        var addition = try XCTUnwrap(WorkoutWritingServiceV2(context: context).appendSetDraft(for: record, exercise: exercise))
        XCTAssertNotNil(addition.historyBaselines, "前提: V2の追加draftはbaselineを持つ")
        for metric in addition.metrics {
            addition.values[metric.id] = metric.allowsDecimal ? "65.5" : "6"
        }
        addition.historyBaselines = nil

        let originalDrafts = WorkoutValueEditing.drafts(for: workout)
        let repsIndex = try XCTUnwrap(originalDrafts.firstIndex { $0.valueID == fixture.repsValueID })

        // 対照: 改変していないdraftと同じ追加を渡すと、追加セット検証が metricsChanged で拒否する。
        // これにより、下の storedValueMismatch が追加側の不正ではなく入口の照合から来ることを区別できる
        XCTAssertThrowsError(try WorkoutWritingServiceV2(context: context).saveWorkoutEdits(
            originalDrafts, additions: [addition], day: day, to: workout, exercises: exercises, calendar: fixture.calendar
        )) { error in
            guard case WorkoutValueEditError.metricsChanged = error else {
                return XCTFail("前提: baseline欠落の追加は metricsChanged で拒否される: \(error)")
            }
        }
        XCTAssertFalse(context.hasChanges, "対照の拒否後も保存先contextはclean")
        XCTAssertFalse(observerContext.hasChanges, "対照の拒否後も観測contextはclean")

        // 本題: 整数のみの値に小数可を主張する改変draft + baseline欠落の追加
        var tamperedDrafts = originalDrafts
        let reps = tamperedDrafts[repsIndex]
        tamperedDrafts[repsIndex] = WorkoutValueEditDraft(
            valueID: reps.valueID, exerciseName: reps.exerciseName, setOrder: reps.setOrder,
            name: reps.name, unit: reps.unit,
            allowsDecimal: true, isRequired: reps.isRequired, text: "8.5"
        )
        var saveReportedSuccess = false
        do {
            try WorkoutWritingServiceV2(context: context).saveWorkoutEdits(
                tamperedDrafts, additions: [addition], day: day, to: workout, exercises: exercises, calendar: fixture.calendar
            )
            saveReportedSuccess = true
        } catch {
            // metricsChanged が返る場合、入口の照合が追加セット検証より後ろに移動・削除されている
            assertStaleValueDraft(error, label: "改変draftとbaseline欠落の追加の組み合わせ")
        }
        XCTAssertFalse(saveReportedSuccess, "改変draftを含む保存は成功扱いにしない")
        XCTAssertFalse(context.hasChanges, "拒否後の保存先contextはclean")
        XCTAssertFalse(observerContext.hasChanges, "拒否後の観測contextはclean")
        XCTAssertEqual(record.sets.count, 1, "追加セットをメモリ上でも挿入しない")
        XCTAssertEqual(try value(fixture.repsValueID, in: workout)?.scaledValue, 8_000, "保存先のメモリ上の値も書き換えない")
        XCTAssertEqual(try value(fixture.repsValueID, in: observedWorkout)?.scaledValue, 8_000, "観測contextの値も変わらない")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SetRecord>()).count, 1, "保存先contextのセット数は変わらない")
        XCTAssertEqual(try observerContext.fetch(FetchDescriptor<SetRecord>()).count, 1, "観測contextのセット数は変わらない")

        // 別containerで開き直し、値・link・revisionの件数が変わっていないことを確認する
        try assertStoredValues(fixture, weight: 60_500, reps: 8_000)
    }

    // MARK: - 共通の確認

    @MainActor private func assertTamperedDraftIsRejected(_ fixture: Fixture, label: String, tamper: (WorkoutValueEditDraft) -> WorkoutValueEditDraft) throws {
        let container = try ModelContainer(for: fixture.schema, migrationPlan: MeleteMigrationPlan.self, configurations: [fixture.configuration])
        let context = ModelContext(container)
        let workout = try fetchWorkout(fixture.workoutID, in: context)

        var drafts = WorkoutValueEditing.drafts(for: workout)
        let repsIndex = try XCTUnwrap(drafts.firstIndex { $0.valueID == fixture.repsValueID })
        // 前提: 保存済み値から作ったdraftは、整数のみ・必須を正しく写している
        XCTAssertFalse(drafts[repsIndex].allowsDecimal)
        XCTAssertTrue(drafts[repsIndex].isRequired)
        drafts[repsIndex] = tamper(drafts[repsIndex])
        // 改変後のdraftはdraft自身の設定だけで見ると検証を通ってしまう（これが穴の前提条件）
        guard case .success = WorkoutValueEditing.validatedValues(from: drafts) else {
            return XCTFail("\(label): 前提としてdraft単体の検証は通る")
        }
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day, calendar: fixture.calendar))

        var saveReportedSuccess = false
        do {
            try WorkoutWritingServiceV2(context: context).saveWorkoutEdits(
                drafts, additions: [], day: day, to: workout, exercises: [], calendar: fixture.calendar
            )
            saveReportedSuccess = true
        } catch {
            assertStaleValueDraft(error, label: label)
        }
        XCTAssertFalse(saveReportedSuccess, "\(label): 保存済み値の設定と食い違うdraftは拒否する")
        XCTAssertFalse(context.hasChanges, "\(label): 拒否後のcontextはclean")
        XCTAssertEqual(try value(fixture.repsValueID, in: workout)?.scaledValue, 8_000, "\(label): メモリ上の値も書き換えない")

        try assertStoredValues(fixture, weight: 60_500, reps: 8_000)
    }

    /// 別containerで開き直し、ストアに残っている値と項目設定を確認する
    @MainActor private func assertStoredValues(_ fixture: Fixture, weight: Int64?, reps: Int64?, file: StaticString = #filePath, line: UInt = #line) throws {
        let reopened = try ModelContainer(for: fixture.schema, migrationPlan: MeleteMigrationPlan.self, configurations: [fixture.configuration])
        let context = ModelContext(reopened)
        let values = try context.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(Set(values.map(\.id)), [fixture.weightValueID, fixture.repsValueID], "値の件数は変わらない", file: file, line: line)
        let storedWeight = try XCTUnwrap(values.first { $0.id == fixture.weightValueID }, file: file, line: line)
        let storedReps = try XCTUnwrap(values.first { $0.id == fixture.repsValueID }, file: file, line: line)
        XCTAssertEqual(storedWeight.scaledValue, weight, "重量", file: file, line: line)
        XCTAssertEqual(storedReps.scaledValue, reps, "回数", file: file, line: line)
        // 保存済みsnapshotの項目設定は編集で変わらない
        XCTAssertTrue(storedWeight.allowsDecimal, file: file, line: line)
        XCTAssertFalse(storedWeight.isRequired, file: file, line: line)
        XCTAssertFalse(storedReps.allowsDecimal, file: file, line: line)
        XCTAssertTrue(storedReps.isRequired, file: file, line: line)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).count, 2, "既存linkは増減しない", file: file, line: line)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).count, 2, "revisionは増減しない", file: file, line: line)
    }

    private func assertContextMismatch(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case WorkoutValueEditingV2Error.workoutContextMismatch = error else {
            return XCTFail("workoutContextMismatchが必要: \(error)", file: file, line: line)
        }
        XCTAssertEqual(error.localizedDescription, WorkoutValueEditingV2Error.workoutContextMismatch.errorDescription, file: file, line: line)
    }

    @MainActor private func fetchWorkout(_ id: UUID, in context: ModelContext) throws -> Workout {
        let matches = try context.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.id == id }))
        XCTAssertEqual(matches.count, 1)
        return try XCTUnwrap(matches.first)
    }

    @MainActor private func value(_ id: UUID, in workout: Workout) throws -> MetricValue? {
        workout.records.flatMap(\.sets).flatMap(\.values).first { $0.id == id }
    }

    // MARK: - fixture

    /// 新規ユニークなscratch fixtureに、種目1件と運動記録1件（1セット・2項目）を合成データで作る。
    /// 種目はMainView.saveExerciseの保存コードを再現し、運動記録はWorkoutWritingServiceV2.createWorkoutで作る
    @MainActor private func makeFixture() throws -> Fixture {
        let storeURL = try makeFreshStoreDirectory().appendingPathComponent("Melete.store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path), "既存ストアを再利用しない")
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteUITestV2", schema: schema, url: storeURL, cloudKitDatabase: .none)
        XCTAssertEqual(configuration.url.standardizedFileURL, storeURL.standardizedFileURL, "fixture以外のストアへfallbackしない")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let container = try ModelContainer(for: schema, migrationPlan: MeleteMigrationPlan.self, configurations: [configuration])
        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Exercise>()).isEmpty, "新規fixtureは空のストアから始まる")

        let weight = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let reps = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 1)
        let exercise = Exercise(name: "合成スクワット", metrics: [weight, reps])
        context.insert(exercise)
        try context.save()

        let service = WorkoutWritingServiceV2(context: context)
        var entry = try service.makeWorkoutEntryDraft(for: exercise)
        XCTAssertEqual(entry.sets.count, 1)
        entry.sets[0].values[weight.id] = "60.5"
        entry.sets[0].values[reps.id] = "8"
        let workout = try service.createWorkout(day: Self.workoutDay, entries: [entry], calendar: calendar)
        XCTAssertFalse(context.hasChanges)

        let values = workout.records.flatMap(\.sets).flatMap(\.values)
        let weightValue = try XCTUnwrap(values.first { $0.metricID == weight.id })
        let repsValue = try XCTUnwrap(values.first { $0.metricID == reps.id })
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(weightValue.scaledValue, 60_500)
        XCTAssertEqual(repsValue.scaledValue, 8_000)
        return Fixture(
            schema: schema, configuration: configuration, calendar: calendar,
            workoutID: workout.id, weightValueID: weightValue.id, repsValueID: repsValue.id
        )
    }

    /// scratch直下に新規ユニーク名のディレクトリを作る。既に存在すれば失敗する（上書き・再利用しない）
    private func makeFreshStoreDirectory() throws -> URL {
        let manager = FileManager.default
        let directory = scratchBase.appendingPathComponent(Self.fixturePrefix + UUID().uuidString, isDirectory: true)
        // withIntermediateDirectories: false なので、既存項目があれば失敗する
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // umaskの影響を受けないよう、作成後に明示的に設定する（変更するのはこの新規ディレクトリだけ）
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard directory.deletingLastPathComponent().standardizedFileURL.path == scratchBase.path,
              UITestStoreIsolation.isTrustedDirectory(directory, manager: manager),
              try manager.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw EditSafetyFixtureError.untrustedFixture
        }
        return directory.standardizedFileURL
    }
}

/// V1/V2共有の保存境界（WorkoutValueEditing.save）を、ストアを開かずどのcontextにも挿入しない合成モデルだけで確認する。
/// ファイルを作らないためscratchを必要とせず、scratch未準備の通常Debug環境でもskipせず必ず実行する。
/// （scratch必須のsetUpを持つWorkoutValueEditingV2ScratchSafetyTestsとクラスを分けているのはこのため）
final class WorkoutValueEditingSharedSaveSafetyTests: XCTestCase {
    /// 2023-11-14 22:13:20 UTC
    private static let workoutDay = Date(timeIntervalSince1970: 1_700_000_000)

    func testSharedSaveAcceptsDraftsMatchingStoredValues() throws {
        let (workout, weight, reps) = try makeDetachedWorkout()
        var drafts = WorkoutValueEditing.drafts(for: workout)
        drafts[try XCTUnwrap(drafts.firstIndex { $0.valueID == weight.id })].text = "61.5"
        drafts[try XCTUnwrap(drafts.firstIndex { $0.valueID == reps.id })].text = "12"
        let day = try XCTUnwrap(WorkoutValueEditing.date(from: workout.day, calendar: detachedCalendar))
        var persistCount = 0
        try WorkoutValueEditing.save(drafts, day: day, to: workout, calendar: detachedCalendar, now: Self.workoutDay) { persistCount += 1 }
        XCTAssertEqual(persistCount, 1)
        XCTAssertEqual(weight.scaledValue, 61_500)
        XCTAssertEqual(reps.scaledValue, 12_000)
        // 保存済みsnapshotの項目設定は編集で変わらない
        XCTAssertEqual([reps.name, reps.unit], ["回数", "回"])
        XCTAssertFalse(reps.allowsDecimal)
        XCTAssertTrue(reps.isRequired)
    }

    func testSharedSaveRejectsDraftsNotMatchingStoredValuesBeforeChangingModels() throws {
        let cases: [(String, (WorkoutValueEditDraft) -> WorkoutValueEditDraft)] = [
            ("項目名", { WorkoutValueEditDraft(valueID: $0.valueID, exerciseName: $0.exerciseName, setOrder: $0.setOrder, name: "偽装回数", unit: $0.unit, allowsDecimal: $0.allowsDecimal, isRequired: $0.isRequired, text: "9") }),
            ("単位", { WorkoutValueEditDraft(valueID: $0.valueID, exerciseName: $0.exerciseName, setOrder: $0.setOrder, name: $0.name, unit: "セット", allowsDecimal: $0.allowsDecimal, isRequired: $0.isRequired, text: "9") }),
            ("小数可", { WorkoutValueEditDraft(valueID: $0.valueID, exerciseName: $0.exerciseName, setOrder: $0.setOrder, name: $0.name, unit: $0.unit, allowsDecimal: true, isRequired: $0.isRequired, text: "8.5") }),
            ("必須", { WorkoutValueEditDraft(valueID: $0.valueID, exerciseName: $0.exerciseName, setOrder: $0.setOrder, name: $0.name, unit: $0.unit, allowsDecimal: $0.allowsDecimal, isRequired: false, text: "") }),
            ("対象外のvalueID", { WorkoutValueEditDraft(valueID: UUID(), exerciseName: $0.exerciseName, setOrder: $0.setOrder, name: $0.name, unit: $0.unit, allowsDecimal: $0.allowsDecimal, isRequired: $0.isRequired, text: "9") }),
        ]
        for (label, tamper) in cases {
            let (workout, weight, reps) = try makeDetachedWorkout()
            var drafts = WorkoutValueEditing.drafts(for: workout)
            let repsIndex = try XCTUnwrap(drafts.firstIndex { $0.valueID == reps.id })
            drafts[try XCTUnwrap(drafts.firstIndex { $0.valueID == weight.id })].text = "70"
            drafts[repsIndex] = tamper(drafts[repsIndex])
            try assertSharedSaveRejected(drafts, workout: workout, weight: weight, reps: reps, label: label)
        }

        // 同じvalueIDのdraftが重複すると、どちらを保存するか確定できない
        let (workout, weight, reps) = try makeDetachedWorkout()
        var drafts = WorkoutValueEditing.drafts(for: workout)
        var duplicated = try XCTUnwrap(drafts.first { $0.valueID == reps.id })
        duplicated.text = "9"
        drafts.append(duplicated)
        try assertSharedSaveRejected(drafts, workout: workout, weight: weight, reps: reps, label: "重複したvalueID")
    }

    private var detachedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func assertSharedSaveRejected(_ drafts: [WorkoutValueEditDraft], workout: Workout, weight: MetricValue, reps: MetricValue, label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let originalDay = workout.day
        // 日付も変えて送り、拒否時に日付も含めて変更しないことを確認する
        let editedDay = Self.workoutDay.addingTimeInterval(-86_400)
        XCTAssertThrowsError(try WorkoutValueEditing.save(drafts, day: editedDay, to: workout, calendar: detachedCalendar, now: Self.workoutDay) {
            XCTFail("\(label): 拒否時はpersistしない", file: file, line: line)
        }, file: file, line: line) { error in
            assertStaleValueDraft(error, label: label, file: file, line: line)
        }
        XCTAssertEqual(workout.day, originalDay, "\(label): 日付を変更しない", file: file, line: line)
        XCTAssertEqual(weight.scaledValue, 60_500, "\(label): 他の値も変更しない", file: file, line: line)
        XCTAssertEqual(reps.scaledValue, 8_000, "\(label): 対象値を変更しない", file: file, line: line)
    }

    /// どのcontextにも挿入しない合成Workout（1セット・重量60.5kgと回数8回）
    private func makeDetachedWorkout() throws -> (Workout, MetricValue, MetricValue) {
        let weightMetric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let repsMetric = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 1)
        let exercise = Exercise(name: "合成スクワット", metrics: [weightMetric, repsMetric])
        let weight = MetricValue(metric: weightMetric, scaledValue: 60_500)
        let reps = MetricValue(metric: repsMetric, scaledValue: 8_000)
        let workout = Workout(
            day: Self.workoutDay,
            records: [ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [weight, reps])])],
            calendar: detachedCalendar
        )
        return (workout, weight, reps)
    }
}

/// 両クラス共通: storedValueMismatchで拒否されたことを確認する
private func assertStaleValueDraft(_ error: Error, label: String, file: StaticString = #filePath, line: UInt = #line) {
    guard case WorkoutValueEditError.storedValueMismatch = error else {
        return XCTFail("\(label): storedValueMismatchが必要: \(error)", file: file, line: line)
    }
    XCTAssertEqual(error.localizedDescription, WorkoutValueEditError.storedValueMismatch.errorDescription, file: file, line: line)
}

private enum EditSafetyFixtureError: Error {
    case scratchUnavailable
    case untrustedFixture
}
#endif
