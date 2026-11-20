import XCTest
import SwiftData
@testable import Melete

#if DEBUG
/// 通常V1の項目管理保存境界が、FR-WR-05「対象データに限定して永続化する」を
/// 満たすかを合成V1ストアで確認する。
///
/// 監査で見つかった問題: 以前のV1分岐は `MetricDefinitionEditing.save(...) { try context.save() }` を直接呼び、
/// 同じModelContextに無関係なWorkoutの未保存変更があると、項目管理の保存でまとめてディスクへ書かれ得た。
///
/// テストはMainViewの分岐を写さず、MainViewが呼ぶ本番V1境界を直接実行する。
///
/// アプリのMainViewは自動保存が有効なmainContextを使うが、ここでは保存の境界だけを決定的に確認するため
/// `ModelContext(container)` を自動保存無効で使う（自動保存のタイミングに結果を依存させない）。
///
/// fixtureはscratch直下の新規 `MeleteMetricDefinitionV1Safety-<UUID>` だけに作り、システム一時ディレクトリは使わない。
/// テストは削除・移動・上書き・後片付けを一切行わない（作成物はscratch直下に残る）。
final class MetricDefinitionEditingV1ScratchSafetyTests: XCTestCase {
    private static let fixturePrefix = "MeleteMetricDefinitionV1Safety-"
    /// 2023-11-14 22:13:20 UTC
    private static let workoutDay = Date(timeIntervalSince1970: 1_700_000_000)
    private static let addedMetricName = "合成距離"

    /// 項目管理の保存呼び出しの形。persistは本来 `context.save()` を呼ぶ処理で、テストから呼び出し回数を数え、失敗を注入する
    private typealias SaveCall = @MainActor ([MetricDefinitionDraft], Exercise, ModelContext, () throws -> Void) throws -> Void

    /// MainViewが利用する本番V1保存境界を直接呼ぶ。
    @MainActor private static func v1Boundary(_ drafts: [MetricDefinitionDraft], for exercise: Exercise, in context: ModelContext, persist: () throws -> Void) throws {
        try MetricDefinitionEditingV1.save(drafts, for: exercise, in: context) { _ in try persist() }
    }

    private struct Fixture {
        let schema: Schema
        let configuration: ModelConfiguration
        let calendar: Calendar
        /// 項目管理の対象種目（重量・回数）
        let targetExerciseID: UUID
        let weightMetricID: UUID
        let repsMetricID: UUID
        /// 対象とは別の種目（時間）と、その種目だけを含む別日のWorkout
        let unrelatedExerciseID: UUID
        let unrelatedWorkoutID: UUID
        /// 無関係なWorkoutの保存済み値（時間 90秒）
        let unrelatedValueID: UUID
        /// fixture作成直後に別containerで読んだストアの状態
        let initialState: StoredState
    }

    /// テストで加える、項目管理と無関係な未保存変更
    private enum UnrelatedChange {
        /// 保存済みの無関係なWorkoutの値を書き換える（90秒→95秒）
        case editedWorkoutValue
        /// 無関係な種目のWorkoutを新規挿入する（未保存）
        case insertedWorkout
    }

    /// 加えた未保存変更への参照。確認時にどの変更かを区別する
    private struct AppliedChange {
        let kind: UnrelatedChange
        let editedValue: MetricValue?
        let insertedWorkout: Workout?
    }

    private var scratchBase: URL!

    override func setUpWithError() throws {
        guard let base = UITestStoreIsolation.trustedScratchBase() else {
            let reason = "scratch領域が存在しないか、所有者・権限・symlinkの安全条件を満たしません"
#if MELETE_SCRATCH_ISOLATION
            XCTFail(reason)
            throw MetricDefinitionV1SafetyFixtureError.scratchUnavailable
#else
            throw XCTSkip(reason)
#endif
        }
        scratchBase = base
    }

    // MARK: - 無関係な未保存変更があるcontext

    @MainActor func testDirtyContextWithEditedUnrelatedWorkoutValueIsRejectedBeforeAnyChange() throws {
        try assertDirtyContextIsRejected(by: Self.v1Boundary, unrelatedChange: .editedWorkoutValue)
    }

    @MainActor func testDirtyContextWithInsertedUnrelatedWorkoutIsRejectedBeforeAnyChange() throws {
        try assertDirtyContextIsRejected(by: Self.v1Boundary, unrelatedChange: .insertedWorkout)
    }

    // MARK: - 正常系（cleanなcontextでの保存を修正で壊していないこと）

    @MainActor func testCleanContextPersistsOnlyTargetDefinitionChanges() throws {
        let fixture = try makeFixture()
        let context = try makeContext(fixture)
        let exercise = try fetchExercise(fixture.targetExerciseID, in: context)
        XCTAssertFalse(context.hasChanges, "前提: 保存前のcontextはclean")

        var persistCount = 0
        try Self.v1Boundary(try editedDrafts(for: exercise, fixture: fixture), for: exercise, in: context) {
            persistCount += 1
            try context.save()
        }
        XCTAssertEqual(persistCount, 1, "cleanなcontextでは1回だけ保存する")
        XCTAssertFalse(context.hasChanges, "保存後のcontextはclean")

        let state = try readStoredState(fixture)
        try assertTargetEditPersisted(state, fixture: fixture)
        XCTAssertEqual(state.workoutDays, fixture.initialState.workoutDays, "Workoutは増減しない")
        XCTAssertEqual(state.values, fixture.initialState.values, "保存済み値のスナップショットと数値は変わらない")
    }

    @MainActor func testExerciseOwnedByAnotherContextIsRejectedBeforeMutation() throws {
        let fixture = try makeFixture()
        let ownerContext = try makeContext(fixture)
        let otherContext = try makeContext(fixture)
        let exercise = try fetchExercise(fixture.targetExerciseID, in: ownerContext)
        let drafts = try editedDrafts(for: exercise, fixture: fixture)
        let metricsBefore = sortedSnapshots(exercise.metrics)
        var persistCount = 0

        XCTAssertThrowsError(try Self.v1Boundary(drafts, for: exercise, in: otherContext) {
            persistCount += 1
        }) { error in
            XCTAssertEqual(error as? MetricDefinitionEditingV1Error, .wrongContext)
        }
        XCTAssertEqual(persistCount, 0, "所有者不一致ならpersistを呼ばない")
        XCTAssertEqual(sortedSnapshots(exercise.metrics), metricsBefore, "所有者不一致なら対象を変更しない")
        XCTAssertFalse(ownerContext.hasChanges)
        XCTAssertFalse(otherContext.hasChanges)
        XCTAssertEqual(try readStoredState(fixture), fixture.initialState)
    }

    // MARK: - 保存失敗の注入と再試行

    @MainActor func testInjectedSaveFailureLeavesStoreUnchangedAndSameDraftsCanBeRetried() throws {
        let fixture = try makeFixture()
        let context = try makeContext(fixture)
        let exercise = try fetchExercise(fixture.targetExerciseID, in: context)
        let drafts = try editedDrafts(for: exercise, fixture: fixture)
        let metricsBefore = sortedSnapshots(exercise.metrics)

        var persistCount = 0
        XCTAssertThrowsError(try Self.v1Boundary(drafts, for: exercise, in: context) {
            persistCount += 1
            // context.save() を呼ぶ前に失敗させ、ディスクには何も書かれない状況を作る
            throw MetricDefinitionV1InjectedSaveFailure.expected
        }) { error in
            XCTAssertTrue(error is MetricDefinitionV1InjectedSaveFailure, "注入した保存失敗をそのまま返す: \(error)")
        }
        XCTAssertEqual(persistCount, 1)
        XCTAssertFalse(context.hasChanges, "失敗時のsnapshot復元とrollback後、contextはclean")
        XCTAssertEqual(sortedSnapshots(exercise.metrics), metricsBefore, "失敗時は対象種目の項目定義をメモリ上でも元に戻す")
        XCTAssertEqual(try readStoredState(fixture), fixture.initialState, "失敗時はディスクに部分的な定義変更を残さない")

        // 失敗後に、同じ下書きで再試行できる
        try Self.v1Boundary(drafts, for: exercise, in: context) { try context.save() }
        XCTAssertFalse(context.hasChanges, "再試行の保存後のcontextはclean")
        let state = try readStoredState(fixture)
        // 失敗時に破棄した追加項目が、再試行の保存で一緒に書かれていないこと（件数で取り残しを確認する）
        try assertTargetEditPersisted(state, fixture: fixture)
        XCTAssertEqual(state.workoutDays, fixture.initialState.workoutDays)
        XCTAssertEqual(state.values, fixture.initialState.values)
    }

    // MARK: - 拒否後の再試行

    /// 無関係な未保存変更があるcontextで項目管理を保存したときの期待:
    /// - 項目定義を変更する前にV1境界固有のdirty-contextエラーで拒否する
    /// - persistを呼ばない
    /// - 無関係な未保存変更を保存・破棄・rollbackせずに残す
    /// - 対象種目の項目定義をメモリ上でも変更しない
    /// - 別containerで開き直したディスクの状態がfixture作成直後と同じ
    /// - 無関係な変更が別の経路で確定した後は、同じ下書きで再試行できる
    @MainActor private func assertDirtyContextIsRejected(by save: SaveCall, unrelatedChange: UnrelatedChange, file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = try makeFixture()
        let context = try makeContext(fixture)
        let exercise = try fetchExercise(fixture.targetExerciseID, in: context)
        // MetricDefinitionEditFormのV1初期値と同じく、変更を加える前に下書きを作る
        let drafts = try editedDrafts(for: exercise, fixture: fixture)
        let applied = try applyUnrelatedChange(unrelatedChange, in: context, fixture: fixture)
        XCTAssertTrue(context.hasChanges, "前提: contextに無関係な未保存変更がある", file: file, line: line)
        try assertUnrelatedChangeIsPending(applied, in: context, label: "前提", file: file, line: line)
        let metricsBefore = sortedSnapshots(exercise.metrics)

        var persistCount = 0
        var rejection: Error?
        do {
            try save(drafts, exercise, context) {
                persistCount += 1
                try context.save()
            }
        } catch {
            rejection = error
        }

        XCTAssertTrue(rejection is MetricDefinitionEditingV1Error, "V1境界のエラー型で拒否する: \(String(describing: rejection))", file: file, line: line)
        XCTAssertEqual(rejection as? MetricDefinitionEditingV1Error, .unsavedContext, "dirty-context専用の拒否理由", file: file, line: line)
        XCTAssertEqual(persistCount, 0, "拒否時はpersistを呼ばない", file: file, line: line)
        XCTAssertTrue(context.hasChanges, "無関係な未保存変更を保存・破棄しない", file: file, line: line)
        try assertUnrelatedChangeIsPending(applied, in: context, label: "拒否後", file: file, line: line)
        XCTAssertEqual(sortedSnapshots(exercise.metrics), metricsBefore, "対象種目の項目定義をメモリ上でも変更しない", file: file, line: line)

        let stored = try readStoredState(fixture)
        // ストアの全体snapshotで、無関係な変更も対象の変更も保存されていないことを確認する。
        switch unrelatedChange {
        case .editedWorkoutValue:
            XCTAssertEqual(stored.values.first { $0.id == fixture.unrelatedValueID }?.scaledValue, 90_000,
                           "無関係なWorkoutの値はディスク上で変わらない", file: file, line: line)
        case .insertedWorkout:
            let insertedID = try XCTUnwrap(applied.insertedWorkout?.id, file: file, line: line)
            XCTAssertNil(stored.workoutDays[insertedID], "未保存のWorkoutはディスクへ書かれない", file: file, line: line)
        }
        XCTAssertFalse(stored.metricDefinitions.contains { $0.name == Self.addedMetricName }, "対象の項目追加もディスクへ書かない", file: file, line: line)
        XCTAssertEqual(stored, fixture.initialState, "拒否時はディスクの状態を一切変えない", file: file, line: line)

        // 拒否されなかった場合は既にまとめて保存されているため、再試行の確認は意味を持たない
        guard rejection != nil else { return }

        // 無関係な変更が、その変更を始めた画面の保存で確定した状況を再現する（項目管理側では確定しない）
        try context.save()
        XCTAssertFalse(context.hasChanges, "前提: 無関係な変更の確定後のcontextはclean", file: file, line: line)

        // 同じ下書きで再試行すると、対象の変更だけが保存される
        var retryPersistCount = 0
        try save(drafts, exercise, context) {
            retryPersistCount += 1
            try context.save()
        }
        XCTAssertEqual(retryPersistCount, 1, "cleanになった後の再試行では保存する", file: file, line: line)
        let retried = try readStoredState(fixture)
        try assertTargetEditPersisted(retried, fixture: fixture, file: file, line: line)
        switch unrelatedChange {
        case .editedWorkoutValue:
            XCTAssertEqual(retried.values.first { $0.id == fixture.unrelatedValueID }?.scaledValue, 95_000, "無関係な変更は自身の保存で確定している", file: file, line: line)
        case .insertedWorkout:
            let insertedID = try XCTUnwrap(applied.insertedWorkout?.id, file: file, line: line)
            XCTAssertNotNil(retried.workoutDays[insertedID], "無関係なWorkoutは自身の保存で確定している", file: file, line: line)
        }
    }

    // MARK: - 共通の操作と確認

    /// V1フォームで可能な操作だけを使った下書き: 既存の「重量」を入力欄から外し、新しい項目を1つ追加する
    @MainActor private func editedDrafts(for exercise: Exercise, fixture: Fixture) throws -> [MetricDefinitionDraft] {
        var drafts = MetricDefinitionEditing.draft(for: exercise)
        XCTAssertEqual(Set(drafts.map(\.id)), [fixture.weightMetricID, fixture.repsMetricID], "前提: 下書きは対象種目の項目だけを含む")
        let weightIndex = try XCTUnwrap(drafts.firstIndex { $0.id == fixture.weightMetricID })
        drafts[weightIndex].isActive = false
        drafts.append(MetricDefinitionDraft(name: Self.addedMetricName, unit: "m", allowsDecimal: true, isRequired: false))
        return drafts
    }

    @MainActor private func applyUnrelatedChange(_ kind: UnrelatedChange, in context: ModelContext, fixture: Fixture) throws -> AppliedChange {
        switch kind {
        case .editedWorkoutValue:
            let valueID = fixture.unrelatedValueID
            let value = try XCTUnwrap(try context.fetch(FetchDescriptor<MetricValue>(predicate: #Predicate { $0.id == valueID })).first)
            XCTAssertEqual(value.scaledValue, 90_000, "前提: 無関係なWorkoutの保存済み値")
            value.scaledValue = 95_000
            return AppliedChange(kind: kind, editedValue: value, insertedWorkout: nil)
        case .insertedWorkout:
            let unrelatedExercise = try fetchExercise(fixture.unrelatedExerciseID, in: context)
            let duration = try XCTUnwrap(unrelatedExercise.metrics.first)
            let workout = Workout(
                day: Self.workoutDay.addingTimeInterval(2 * 86_400),
                records: [ExerciseRecord(exercise: unrelatedExercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [MetricValue(metric: duration, scaledValue: 120_000)])])],
                calendar: fixture.calendar
            )
            context.insert(workout)
            return AppliedChange(kind: kind, editedValue: nil, insertedWorkout: workout)
        }
    }

    /// 無関係な変更が、まだ未保存のままcontextに残っていることを確認する
    @MainActor private func assertUnrelatedChangeIsPending(_ applied: AppliedChange, in context: ModelContext, label: String, file: StaticString, line: UInt) throws {
        switch applied.kind {
        case .editedWorkoutValue:
            let value = try XCTUnwrap(applied.editedValue, file: file, line: line)
            XCTAssertEqual(value.scaledValue, 95_000, "\(label): 無関係な値の変更をメモリ上で保つ", file: file, line: line)
            XCTAssertTrue(context.changedModelsArray.contains { $0.persistentModelID == value.persistentModelID },
                          "\(label): 無関係な値の変更は未保存のまま残る", file: file, line: line)
        case .insertedWorkout:
            let workout = try XCTUnwrap(applied.insertedWorkout, file: file, line: line)
            XCTAssertTrue(workout.modelContext === context, "\(label): 挿入したWorkoutはcontextに残る", file: file, line: line)
            XCTAssertTrue(context.insertedModelsArray.contains { $0.persistentModelID == workout.persistentModelID },
                          "\(label): 挿入したWorkoutは未保存のまま残る", file: file, line: line)
        }
    }

    /// 対象種目の定義変更だけが保存されていることを、別containerで読んだ状態から確認する
    private func assertTargetEditPersisted(_ state: StoredState, fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let initialTarget = try XCTUnwrap(fixture.initialState.exercises.first { $0.id == fixture.targetExerciseID }, file: file, line: line)
        let target = try XCTUnwrap(state.exercises.first { $0.id == fixture.targetExerciseID }, file: file, line: line)
        XCTAssertEqual(target.name, initialTarget.name, file: file, line: line)
        XCTAssertEqual(target.metrics.count, 3, "既存2項目＋追加1項目", file: file, line: line)

        let weight = try XCTUnwrap(target.metrics.first { $0.id == fixture.weightMetricID }, file: file, line: line)
        let initialWeight = try XCTUnwrap(initialTarget.metrics.first { $0.id == fixture.weightMetricID }, file: file, line: line)
        XCTAssertFalse(weight.isActive, "重量は入力欄から外れている", file: file, line: line)
        XCTAssertEqual([weight.name, weight.unit], [initialWeight.name, initialWeight.unit], file: file, line: line)
        XCTAssertEqual(weight.sortOrder, initialWeight.sortOrder, file: file, line: line)
        XCTAssertEqual(target.metrics.first { $0.id == fixture.repsMetricID },
                       initialTarget.metrics.first { $0.id == fixture.repsMetricID }, "回数は変わらない", file: file, line: line)

        let added = try XCTUnwrap(target.metrics.first { $0.name == Self.addedMetricName }, file: file, line: line)
        XCTAssertEqual(added.unit, "m", file: file, line: line)
        XCTAssertTrue(added.allowsDecimal, file: file, line: line)
        XCTAssertFalse(added.isRequired, file: file, line: line)
        XCTAssertTrue(added.isActive, file: file, line: line)
        XCTAssertEqual(added.sortOrder, 2, "既存の最大sortOrderの次", file: file, line: line)

        // 親のない項目定義が取り残されていないこと（全件は初期＋追加1件だけ）
        XCTAssertEqual(state.metricDefinitions.count, fixture.initialState.metricDefinitions.count + 1, "項目定義の取り残しや重複がない", file: file, line: line)
        XCTAssertEqual(state.exercises.first { $0.id == fixture.unrelatedExerciseID },
                       fixture.initialState.exercises.first { $0.id == fixture.unrelatedExerciseID }, "無関係な種目は変わらない", file: file, line: line)
    }

    @MainActor private func makeContext(_ fixture: Fixture) throws -> ModelContext {
        // アプリのV1隔離ストアと同じく、移行計画なしでV1スキーマを開く
        let container = try ModelContainer(for: fixture.schema, configurations: [fixture.configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    @MainActor private func fetchExercise(_ id: UUID, in context: ModelContext) throws -> Exercise {
        let matches = try context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == id }))
        XCTAssertEqual(matches.count, 1)
        return try XCTUnwrap(matches.first)
    }

    private func sortedSnapshots(_ metrics: [MetricDefinition]) -> [MetricDefinitionSnapshot] {
        metrics.map(MetricDefinitionSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    // MARK: - ディスクの状態

    fileprivate struct StoredExercise: Equatable {
        let id: UUID
        let name: String
        let isArchived: Bool
        /// id順
        let metrics: [MetricDefinitionSnapshot]
    }

    fileprivate struct StoredValue: Equatable {
        let id: UUID
        let metricID: UUID
        let name: String
        let unit: String
        let allowsDecimal: Bool
        let isRequired: Bool
        let scaledValue: Int64?
    }

    fileprivate struct StoredState: Equatable {
        /// id順
        let exercises: [StoredExercise]
        /// 親の有無に関係なく全件をid順で持つ（取り残しの検出用）
        let metricDefinitions: [MetricDefinitionSnapshot]
        let workoutDays: [UUID: String]
        let recordIDs: Set<UUID>
        let setIDs: Set<UUID>
        /// id順
        let values: [StoredValue]
    }

    /// 新しいcontainerで開き直し、ディスクに保存されている状態を読む（テスト中のcontextの未保存変更は見えない）
    @MainActor private func readStoredState(_ fixture: Fixture) throws -> StoredState {
        let reopened = try ModelContainer(for: fixture.schema, configurations: [fixture.configuration])
        return try readStoredState(in: ModelContext(reopened))
    }

    @MainActor private func readStoredState(in context: ModelContext) throws -> StoredState {
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
            .map { StoredExercise(id: $0.id, name: $0.name, isArchived: $0.isArchived, metrics: sortedSnapshots($0.metrics)) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let metricDefinitions = sortedSnapshots(try context.fetch(FetchDescriptor<MetricDefinition>()))
        let workouts = try context.fetch(FetchDescriptor<Workout>())
        let values = try context.fetch(FetchDescriptor<MetricValue>())
            .map { StoredValue(id: $0.id, metricID: $0.metricID, name: $0.name, unit: $0.unit, allowsDecimal: $0.allowsDecimal, isRequired: $0.isRequired, scaledValue: $0.scaledValue) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return StoredState(
            exercises: exercises,
            metricDefinitions: metricDefinitions,
            workoutDays: Dictionary(uniqueKeysWithValues: workouts.map { ($0.id, $0.day) }),
            recordIDs: Set(try context.fetch(FetchDescriptor<ExerciseRecord>()).map(\.id)),
            setIDs: Set(try context.fetch(FetchDescriptor<SetRecord>()).map(\.id)),
            values: values
        )
    }

    // MARK: - fixture

    /// 新規ユニークなscratch fixtureに、合成V1データを作る。
    /// - 対象種目「合成ベンチプレス」（重量 kg 小数可・必須、回数 回 整数・必須）と、その1セットのWorkout
    /// - 無関係な種目「合成ローイング」（時間 秒）と、その種目だけの別日のWorkout（90秒）
    /// 種目はMainView.saveExercise、WorkoutはMainView.saveWorkoutと同じくモデルを挿入してsaveする
    @MainActor private func makeFixture() throws -> Fixture {
        let storeURL = try makeFreshStoreDirectory().appendingPathComponent("Melete.store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path), "既存ストアを再利用しない")
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("MeleteMetricDefinitionV1Safety", schema: schema, url: storeURL, cloudKitDatabase: .none)
        XCTAssertEqual(configuration.url.standardizedFileURL, storeURL.standardizedFileURL, "fixture以外のストアへfallbackしない")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        XCTAssertTrue(try context.fetch(FetchDescriptor<Exercise>()).isEmpty, "新規fixtureは空のストアから始まる")

        let weight = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let reps = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 1)
        let target = Exercise(name: "合成ベンチプレス", metrics: [weight, reps])
        let duration = MetricDefinition(name: "時間", unit: "秒", allowsDecimal: false, isRequired: true, sortOrder: 0)
        let unrelated = Exercise(name: "合成ローイング", metrics: [duration])
        context.insert(target)
        context.insert(unrelated)
        try context.save()

        let targetWorkout = Workout(
            day: Self.workoutDay,
            records: [ExerciseRecord(exercise: target, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [
                MetricValue(metric: weight, scaledValue: 60_500),
                MetricValue(metric: reps, scaledValue: 8_000),
            ])])],
            calendar: calendar
        )
        let unrelatedValue = MetricValue(metric: duration, scaledValue: 90_000)
        let unrelatedWorkout = Workout(
            day: Self.workoutDay.addingTimeInterval(86_400),
            records: [ExerciseRecord(exercise: unrelated, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [unrelatedValue])])],
            calendar: calendar
        )
        context.insert(targetWorkout)
        context.insert(unrelatedWorkout)
        try context.save()
        XCTAssertFalse(context.hasChanges)

        let initialState = try readStoredState(in: ModelContext(try ModelContainer(for: schema, configurations: [configuration])))
        XCTAssertEqual(initialState.exercises.count, 2)
        XCTAssertEqual(initialState.metricDefinitions.count, 3)
        XCTAssertEqual(initialState.workoutDays.count, 2)
        XCTAssertEqual(initialState.values.count, 3)
        XCTAssertEqual(initialState.values.first { $0.id == unrelatedValue.id }?.scaledValue, 90_000)
        return Fixture(
            schema: schema, configuration: configuration, calendar: calendar,
            targetExerciseID: target.id, weightMetricID: weight.id, repsMetricID: reps.id,
            unrelatedExerciseID: unrelated.id, unrelatedWorkoutID: unrelatedWorkout.id, unrelatedValueID: unrelatedValue.id,
            initialState: initialState
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
            throw MetricDefinitionV1SafetyFixtureError.untrustedFixture
        }
        return directory.standardizedFileURL
    }
}

private enum MetricDefinitionV1InjectedSaveFailure: Error {
    case expected
}

private enum MetricDefinitionV1SafetyFixtureError: Error {
    case scratchUnavailable
    case untrustedFixture
}
#endif
