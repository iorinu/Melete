import XCTest
import SwiftData
@testable import Melete

#if DEBUG
/// NFR-WR-01: 本番候補 MeleteSchemaV1 → MeleteSchemaV2 / MeleteMigrationPlan の網羅合成fixture移行テスト。
/// 試作スキーマ（MeleteRevisionSpike*）は使わない。
/// 期待値はモデルから読み戻さず、リテラルで書いたfixture仕様（FixtureSpec）を唯一の正とする。
/// fixtureはscratch直下の新規 `MeleteV1V2MigrationCoverage-<UUID>` だけに作り、システム一時ディレクトリは使わない。
/// scratchが存在しない・安全条件を満たさない環境では、通常DEBUGはスキップし、scratch検証ビルドは失敗にする。
/// テストは削除・上書き・移動・後片付けを一切行わない（作成物はscratch直下に残る）。
final class V1V2MigrationScratchCoverageTests: XCTestCase {
    private static let fixturePrefix = "MeleteV1V2MigrationCoverage-"
    private static let storeFileName = "Melete.store"

    // MARK: - fixture仕様（モデルとは独立した値型）

    private struct MetricSpec {
        let id: UUID
        let name: String
        let unit: String
        let allowsDecimal: Bool
        let isRequired: Bool
        let isActive: Bool
        let sortOrder: Int
    }

    private struct ExerciseSpec {
        let id: UUID
        let name: String
        let isArchived: Bool
        let createdAt: Date
        let metrics: [MetricSpec]
    }

    /// 記録時点の項目スナップショット。現在の項目定義と異なってよい
    private struct ValueSpec {
        let id: UUID
        let metricID: UUID
        let name: String
        let unit: String
        let allowsDecimal: Bool
        let isRequired: Bool
        /// nilは未入力で、0とは区別する
        let scaledValue: Int64?
    }

    private struct SetSpec {
        let id: UUID
        let sortOrder: Int
        let createdAt: Date
        let values: [ValueSpec]
    }

    private struct RecordSpec {
        let id: UUID
        let exerciseID: UUID
        /// 記録時点の種目名スナップショット。現在の種目名と異なってよい
        let exerciseName: String
        let sortOrder: Int
        let sets: [SetSpec]
    }

    private struct WorkoutSpec {
        let id: UUID
        let day: String
        let createdAt: Date
        let records: [RecordSpec]
    }

    private struct FixtureSpec {
        let exercises: [ExerciseSpec]
        let workouts: [WorkoutSpec]

        var metrics: [MetricSpec] { exercises.flatMap(\.metrics) }
        var records: [RecordSpec] { workouts.flatMap(\.records) }
        var sets: [SetSpec] { records.flatMap(\.sets) }
        var values: [ValueSpec] { sets.flatMap(\.values) }
    }

    /// 合成データだけを使う。IDは実行ごとに新規UUIDにする。
    /// 複数種目（アーカイブ・active・項目なし）、無効項目、非連続sortOrder、
    /// 現在定義と異なる古いsnapshot、nilと0、複数Workout/record/set、記録なしWorkoutを含める
    private static func makeSpec() -> FixtureSpec {
        let bench = UUID(), oldRun = UUID(), unused = UUID()
        let weight = UUID(), reps = UUID(), rpe = UUID(), distance = UUID(), duration = UUID()
        return FixtureSpec(
            exercises: [
                ExerciseSpec(id: bench, name: "合成ベンチプレス", isArchived: false, createdAt: Date(timeIntervalSince1970: 1_700_000_100.125), metrics: [
                    MetricSpec(id: weight, name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, isActive: true, sortOrder: 0),
                    MetricSpec(id: reps, name: "回数", unit: "回", allowsDecimal: false, isRequired: true, isActive: true, sortOrder: 1),
                    MetricSpec(id: rpe, name: "RPE", unit: "点", allowsDecimal: true, isRequired: false, isActive: false, sortOrder: 7),
                ]),
                ExerciseSpec(id: oldRun, name: "合成旧ラン", isArchived: true, createdAt: Date(timeIntervalSince1970: 1_690_000_000.5), metrics: [
                    MetricSpec(id: distance, name: "距離", unit: "km", allowsDecimal: true, isRequired: false, isActive: true, sortOrder: 3),
                    MetricSpec(id: duration, name: "時間", unit: "分", allowsDecimal: false, isRequired: true, isActive: true, sortOrder: 0),
                ]),
                ExerciseSpec(id: unused, name: "合成未使用種目", isArchived: false, createdAt: Date(timeIntervalSince1970: 1_710_000_000.25), metrics: []),
            ],
            workouts: [
                WorkoutSpec(id: UUID(), day: "2023-11-14", createdAt: Date(timeIntervalSince1970: 1_700_000_200.25), records: [
                    RecordSpec(id: UUID(), exerciseID: bench, exerciseName: "合成ベンチプレス", sortOrder: 0, sets: [
                        SetSpec(id: UUID(), sortOrder: 1, createdAt: Date(timeIntervalSince1970: 1_700_000_210.5), values: [
                            ValueSpec(id: UUID(), metricID: weight, name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, scaledValue: 82_500),
                            ValueSpec(id: UUID(), metricID: reps, name: "回数", unit: "回", allowsDecimal: false, isRequired: true, scaledValue: 0),
                            ValueSpec(id: UUID(), metricID: rpe, name: "RPE", unit: "点", allowsDecimal: true, isRequired: false, scaledValue: nil),
                        ]),
                        // 同じ項目IDでも名称・単位・入力条件が現在定義と異なる古いsnapshot
                        SetSpec(id: UUID(), sortOrder: 4, createdAt: Date(timeIntervalSince1970: 1_700_000_220.125), values: [
                            ValueSpec(id: UUID(), metricID: weight, name: "旧重量", unit: "lb", allowsDecimal: false, isRequired: false, scaledValue: 0),
                            ValueSpec(id: UUID(), metricID: reps, name: "レップ", unit: "rep", allowsDecimal: true, isRequired: false, scaledValue: nil),
                        ]),
                    ]),
                    RecordSpec(id: UUID(), exerciseID: oldRun, exerciseName: "合成旧ラン", sortOrder: 2, sets: [
                        SetSpec(id: UUID(), sortOrder: 1, createdAt: Date(timeIntervalSince1970: 1_700_000_230.25), values: [
                            ValueSpec(id: UUID(), metricID: distance, name: "距離", unit: "mi", allowsDecimal: true, isRequired: true, scaledValue: 3_100),
                            ValueSpec(id: UUID(), metricID: duration, name: "時間", unit: "分", allowsDecimal: false, isRequired: true, scaledValue: 25_000),
                        ]),
                    ]),
                ]),
                WorkoutSpec(id: UUID(), day: "2023-11-03", createdAt: Date(timeIntervalSince1970: 1_699_000_000.5), records: [
                    // 種目名snapshotは記録時点の旧名
                    RecordSpec(id: UUID(), exerciseID: bench, exerciseName: "旧ベンチプレス名", sortOrder: 0, sets: [
                        SetSpec(id: UUID(), sortOrder: 2, createdAt: Date(timeIntervalSince1970: 1_699_000_010.125), values: [
                            ValueSpec(id: UUID(), metricID: weight, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, scaledValue: 0),
                        ]),
                        SetSpec(id: UUID(), sortOrder: 1, createdAt: Date(timeIntervalSince1970: 1_699_000_020.5), values: [
                            ValueSpec(id: UUID(), metricID: weight, name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, scaledValue: nil),
                            ValueSpec(id: UUID(), metricID: rpe, name: "旧RPE", unit: "", allowsDecimal: false, isRequired: true, scaledValue: 7_000),
                        ]),
                    ]),
                ]),
                WorkoutSpec(id: UUID(), day: "2024-02-29", createdAt: Date(timeIntervalSince1970: 1_709_164_800.25), records: []),
            ]
        )
    }

    private var scratchBase: URL!

    override func setUpWithError() throws {
        guard let base = UITestStoreIsolation.trustedScratchBase() else {
            let reason = "scratch領域が存在しないか、所有者・権限・symlinkの安全条件を満たしません"
#if MELETE_SCRATCH_ISOLATION
            // scratch検証ビルドではscratchが前提なので、スキップで成功扱いにならないよう失敗にする
            XCTFail(reason)
            throw MigrationFixtureError.scratchUnavailable
#else
            // 通常DEBUGではscratchが無い環境もあり得るのでスキップする
            throw XCTSkip(reason)
#endif
        }
        scratchBase = base
    }

    // MARK: - テスト本体

    @MainActor func testProductionV1StoreMigratesToV2PreservingAllEntitiesWithoutInventingRevisionsAcrossReopen() throws {
        let spec = Self.makeSpec()
        // fixture定義の網羅性を先に確認し、fixtureが弱くなって「何も確かめずに成功」にならないようにする
        try Self.validateSpec(spec)

        let directory = try makeFreshFixtureDirectory()
        let storeURL = directory.appendingPathComponent(Self.storeFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path), "既存ストアを再利用しない")
        try assertInsideFixture(storeURL, directory: directory)

        // V1は本番Models.swiftのMeleteSchemaV1そのもの
        let v1Schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let v1Configuration = ModelConfiguration("MeleteV1V2MigrationCoverageV1", schema: v1Schema, url: storeURL, cloudKitDatabase: .none)
        XCTAssertEqual(v1Configuration.url.standardizedFileURL, storeURL.standardizedFileURL, "fixture以外のストアへfallbackしない")

        // 1. V1でfixtureを書き込む（containerは関数内に閉じ込め、以降はspecだけを渡す）
        try writeV1Fixture(spec, schema: v1Schema, configuration: v1Configuration)
        try assertStoreFilesStayInFixture(directory)

        // 2. 移行前にV1で開き直し、fixture自体が正しく書けていることを確認する（移行起因の差分と切り分けるため）
        try verifyV1Store(spec, schema: v1Schema, configuration: v1Configuration)

        // 3. 本番候補V2 + MeleteMigrationPlanで開いて移行する（アプリの隔離V2経路と同じ構成）
        let v2Schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let v2Configuration = ModelConfiguration("MeleteV1V2MigrationCoverageV2", schema: v2Schema, url: storeURL, cloudKitDatabase: .none)
        XCTAssertEqual(v2Configuration.url.standardizedFileURL, storeURL.standardizedFileURL, "fixture以外のストアへfallbackしない")
        try verifyV2Store(spec, schema: v2Schema, configuration: v2Configuration, phase: "移行直後")
        try assertStoreFilesStayInFixture(directory)

        // 4. 新しいcontainerで再openし、移行後の永続値をもう一度全件照合する
        try verifyV2Store(spec, schema: v2Schema, configuration: v2Configuration, phase: "再open後")
        try assertStoreFilesStayInFixture(directory)
    }

    // MARK: - V1書き込み

    @MainActor
    private func writeV1Fixture(_ spec: FixtureSpec, schema: Schema, configuration: ModelConfiguration) throws {
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Exercise>()).isEmpty, "新規fixtureは空のストアから始まる")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>()).isEmpty)

        var definitions: [UUID: MetricDefinition] = [:]
        var exercises: [UUID: Exercise] = [:]
        for exerciseSpec in spec.exercises {
            let metrics = exerciseSpec.metrics.map { metricSpec in
                let metric = MetricDefinition(name: metricSpec.name, unit: metricSpec.unit, allowsDecimal: metricSpec.allowsDecimal, isRequired: metricSpec.isRequired, sortOrder: metricSpec.sortOrder)
                // initが自動で決める値（id・isActive）はspecで上書きする
                metric.id = metricSpec.id
                metric.isActive = metricSpec.isActive
                definitions[metricSpec.id] = metric
                return metric
            }
            let exercise = Exercise(name: exerciseSpec.name, metrics: metrics)
            exercise.id = exerciseSpec.id
            exercise.isArchived = exerciseSpec.isArchived
            exercise.createdAt = exerciseSpec.createdAt
            exercises[exerciseSpec.id] = exercise
            context.insert(exercise)
        }

        // dayはCalendarに依存させず、文字列をspecどおりに直接書く
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        for workoutSpec in spec.workouts {
            var records: [ExerciseRecord] = []
            for recordSpec in workoutSpec.records {
                let exercise = try XCTUnwrap(exercises[recordSpec.exerciseID], "recordの参照先種目がfixtureにある")
                var sets: [SetRecord] = []
                for setSpec in recordSpec.sets {
                    var values: [MetricValue] = []
                    for valueSpec in setSpec.values {
                        let definition = try XCTUnwrap(definitions[valueSpec.metricID], "値の参照先項目がfixtureにある")
                        let value = MetricValue(metric: definition, scaledValue: valueSpec.scaledValue)
                        // 現在定義からコピーされたsnapshotを、記録時点の値で上書きする
                        value.id = valueSpec.id
                        value.metricID = valueSpec.metricID
                        value.name = valueSpec.name
                        value.unit = valueSpec.unit
                        value.allowsDecimal = valueSpec.allowsDecimal
                        value.isRequired = valueSpec.isRequired
                        values.append(value)
                    }
                    let set = SetRecord(sortOrder: setSpec.sortOrder, values: values)
                    set.id = setSpec.id
                    set.createdAt = setSpec.createdAt
                    sets.append(set)
                }
                let record = ExerciseRecord(exercise: exercise, sortOrder: recordSpec.sortOrder, sets: sets)
                record.id = recordSpec.id
                record.exerciseID = recordSpec.exerciseID
                record.exerciseName = recordSpec.exerciseName
                records.append(record)
            }
            let workout = Workout(day: Date(timeIntervalSince1970: 0), records: records, calendar: utcCalendar)
            workout.id = workoutSpec.id
            workout.day = workoutSpec.day
            workout.createdAt = workoutSpec.createdAt
            context.insert(workout)
        }
        try context.save()
        XCTAssertFalse(context.hasChanges, "V1 fixtureの保存後はclean")
    }

    // MARK: - 検証

    @MainActor
    private func verifyV1Store(_ spec: FixtureSpec, schema: Schema, configuration: ModelConfiguration) throws {
        // V1スキーマにはrevision/link型が無いのでfetchしない
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        try verifyLegacyEntities(spec, in: context, phase: "移行前V1")
        XCTAssertFalse(context.hasChanges, "移行前V1の確認では書き込まない")
    }

    @MainActor
    private func verifyV2Store(_ spec: FixtureSpec, schema: Schema, configuration: ModelConfiguration, phase: String) throws {
        let container = try ModelContainer(for: schema, migrationPlan: MeleteMigrationPlan.self, configurations: [configuration])
        let context = ModelContext(container)

        // legacy値にrevision/linkを捏造しない（V1にはrevision情報が無く、推測で断定しない）
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).count, 0, "\(phase): revisionを合成しない")
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).count, 0, "\(phase): linkを合成しない")

        try verifyLegacyEntities(spec, in: context, phase: phase)

        // 移行後のlegacy種目からdraftを作ると、履歴なし（noHistory）として扱われる（保存はしない）
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        for exerciseSpec in spec.exercises where !exerciseSpec.isArchived {
            let exercise = try XCTUnwrap(exercises.first { $0.id == exerciseSpec.id }, "\(phase): \(exerciseSpec.name)")
            let draft = try WorkoutCreationV2.makeEntryDraft(for: exercise, in: context)
            let expected = Dictionary(uniqueKeysWithValues: exerciseSpec.metrics.filter(\.isActive).map { ($0.id, MetricDefinitionHistoryBaseline.noHistory) })
            XCTAssertEqual(draft.historyBaseline?.history, expected, "\(phase): \(exerciseSpec.name)の有効項目はすべて履歴なし")
        }
        XCTAssertFalse(context.hasChanges, "\(phase): 確認では書き込まない")
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).count, 0, "\(phase): draft作成後もrevisionは増えない")
        XCTAssertEqual(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).count, 0, "\(phase): draft作成後もlinkは増えない")
    }

    /// V1/V2共通の6型を、件数・全ID・全属性・双方向の関連でspecと照合する
    @MainActor
    private func verifyLegacyEntities(_ spec: FixtureSpec, in context: ModelContext, phase: String) throws {
        // fixture仕様から独立に数えた期待件数（validateSpecと二重に固定する）
        XCTAssertEqual(spec.exercises.count, 3)
        XCTAssertEqual(spec.metrics.count, 5)
        XCTAssertEqual(spec.workouts.count, 3)
        XCTAssertEqual(spec.records.count, 3)
        XCTAssertEqual(spec.sets.count, 5)
        XCTAssertEqual(spec.values.count, 10)

        // 子→親の期待対応表（孤立・付け替わりの検出用）
        var metricParent: [UUID: UUID] = [:]
        for exercise in spec.exercises { for metric in exercise.metrics { metricParent[metric.id] = exercise.id } }
        var recordParent: [UUID: UUID] = [:], setParent: [UUID: UUID] = [:], valueParent: [UUID: UUID] = [:]
        for workout in spec.workouts {
            for record in workout.records {
                recordParent[record.id] = workout.id
                for set in record.sets {
                    setParent[set.id] = record.id
                    for value in set.values { valueParent[value.id] = set.id }
                }
            }
        }

        // 種目
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(exercises.count, spec.exercises.count, "\(phase): 種目の件数")
        let exercisesByID = uniqueByID(exercises, id: \.id, "\(phase): 種目")
        XCTAssertEqual(Set(exercisesByID.keys), Set(spec.exercises.map(\.id)), "\(phase): 種目ID")
        for expected in spec.exercises {
            guard let stored = exercisesByID[expected.id] else { XCTFail("\(phase): 種目\(expected.name)が無い"); continue }
            let label = "\(phase): 種目\(expected.name)"
            XCTAssertEqual(stored.name, expected.name, label)
            XCTAssertEqual(stored.isArchived, expected.isArchived, "\(label): アーカイブ状態")
            XCTAssertEqual(stored.createdAt, expected.createdAt, "\(label): createdAt")
            XCTAssertEqual(stored.metrics.count, expected.metrics.count, "\(label): 項目数")
            XCTAssertEqual(Set(stored.metrics.map(\.id)), Set(expected.metrics.map(\.id)), "\(label): 項目ID")
        }

        // 項目定義（全件fetchで孤立・重複も検出する）
        let definitions = try context.fetch(FetchDescriptor<MetricDefinition>())
        XCTAssertEqual(definitions.count, spec.metrics.count, "\(phase): 項目定義の件数")
        let definitionsByID = uniqueByID(definitions, id: \.id, "\(phase): 項目定義")
        XCTAssertEqual(Set(definitionsByID.keys), Set(spec.metrics.map(\.id)), "\(phase): 項目定義ID")
        for expected in spec.metrics {
            guard let stored = definitionsByID[expected.id] else { XCTFail("\(phase): 項目\(expected.name)が無い"); continue }
            let label = "\(phase): 項目\(expected.name)"
            XCTAssertEqual(stored.name, expected.name, label)
            XCTAssertEqual(stored.unit, expected.unit, "\(label): 単位")
            XCTAssertEqual(stored.allowsDecimal, expected.allowsDecimal, "\(label): 小数可否")
            XCTAssertEqual(stored.isRequired, expected.isRequired, "\(label): 必須")
            XCTAssertEqual(stored.isActive, expected.isActive, "\(label): 有効状態")
            XCTAssertEqual(stored.sortOrder, expected.sortOrder, "\(label): sortOrder")
            XCTAssertEqual(stored.exercise?.id, metricParent[expected.id], "\(label): 親種目")
        }

        // 運動記録
        let workouts = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(workouts.count, spec.workouts.count, "\(phase): 運動記録の件数")
        let workoutsByID = uniqueByID(workouts, id: \.id, "\(phase): 運動記録")
        XCTAssertEqual(Set(workoutsByID.keys), Set(spec.workouts.map(\.id)), "\(phase): 運動記録ID")
        for expected in spec.workouts {
            guard let stored = workoutsByID[expected.id] else { XCTFail("\(phase): 運動記録\(expected.day)が無い"); continue }
            let label = "\(phase): 運動記録\(expected.day)"
            XCTAssertEqual(stored.day, expected.day, "\(label): 日付")
            XCTAssertEqual(stored.createdAt, expected.createdAt, "\(label): createdAt")
            XCTAssertEqual(stored.records.count, expected.records.count, "\(label): 種目別記録数")
            XCTAssertEqual(Set(stored.records.map(\.id)), Set(expected.records.map(\.id)), "\(label): 種目別記録ID")
        }

        // 種目別記録
        let records = try context.fetch(FetchDescriptor<ExerciseRecord>())
        XCTAssertEqual(records.count, spec.records.count, "\(phase): 種目別記録の件数")
        let recordsByID = uniqueByID(records, id: \.id, "\(phase): 種目別記録")
        XCTAssertEqual(Set(recordsByID.keys), Set(spec.records.map(\.id)), "\(phase): 種目別記録ID")
        for expected in spec.records {
            guard let stored = recordsByID[expected.id] else { XCTFail("\(phase): 種目別記録\(expected.exerciseName)が無い"); continue }
            let label = "\(phase): 種目別記録\(expected.exerciseName)"
            XCTAssertEqual(stored.exerciseID, expected.exerciseID, "\(label): 種目ID")
            XCTAssertEqual(stored.exerciseName, expected.exerciseName, "\(label): 種目名snapshot")
            XCTAssertEqual(stored.sortOrder, expected.sortOrder, "\(label): sortOrder")
            XCTAssertEqual(stored.workout?.id, recordParent[expected.id], "\(label): 親運動記録")
            XCTAssertEqual(stored.sets.count, expected.sets.count, "\(label): セット数")
            XCTAssertEqual(Set(stored.sets.map(\.id)), Set(expected.sets.map(\.id)), "\(label): セットID")
        }

        // セット
        let sets = try context.fetch(FetchDescriptor<SetRecord>())
        XCTAssertEqual(sets.count, spec.sets.count, "\(phase): セットの件数")
        let setsByID = uniqueByID(sets, id: \.id, "\(phase): セット")
        XCTAssertEqual(Set(setsByID.keys), Set(spec.sets.map(\.id)), "\(phase): セットID")
        for expected in spec.sets {
            guard let stored = setsByID[expected.id] else { XCTFail("\(phase): セット\(expected.sortOrder)が無い"); continue }
            let label = "\(phase): セット\(expected.sortOrder)(\(expected.id))"
            XCTAssertEqual(stored.sortOrder, expected.sortOrder, "\(label): sortOrder")
            XCTAssertEqual(stored.createdAt, expected.createdAt, "\(label): createdAt")
            XCTAssertEqual(stored.exerciseRecord?.id, setParent[expected.id], "\(label): 親種目別記録")
            XCTAssertEqual(stored.values.count, expected.values.count, "\(label): 値の数")
            XCTAssertEqual(Set(stored.values.map(\.id)), Set(expected.values.map(\.id)), "\(label): 値ID")
        }

        // 値（記録時点のsnapshotとnil/0の区別）
        let values = try context.fetch(FetchDescriptor<MetricValue>())
        XCTAssertEqual(values.count, spec.values.count, "\(phase): 値の件数")
        let valuesByID = uniqueByID(values, id: \.id, "\(phase): 値")
        XCTAssertEqual(Set(valuesByID.keys), Set(spec.values.map(\.id)), "\(phase): 値ID")
        for expected in spec.values {
            guard let stored = valuesByID[expected.id] else { XCTFail("\(phase): 値\(expected.name)が無い"); continue }
            let label = "\(phase): 値\(expected.name)(\(expected.id))"
            XCTAssertEqual(stored.metricID, expected.metricID, "\(label): 項目ID")
            XCTAssertEqual(stored.name, expected.name, "\(label): 名称snapshot")
            XCTAssertEqual(stored.unit, expected.unit, "\(label): 単位snapshot")
            XCTAssertEqual(stored.allowsDecimal, expected.allowsDecimal, "\(label): 小数可否snapshot")
            XCTAssertEqual(stored.isRequired, expected.isRequired, "\(label): 必須snapshot")
            // Optional同士の比較なので、nilと0は別の値として扱われる
            XCTAssertEqual(stored.scaledValue, expected.scaledValue, "\(label): nilと0を区別して保持する")
            XCTAssertEqual(stored.setRecord?.id, valueParent[expected.id], "\(label): 親セット")
        }
        // nilと0がそれぞれ消えたり入れ替わったりしていないことを件数でも固定する
        XCTAssertEqual(values.filter { $0.scaledValue == nil }.count, 3, "\(phase): nilの値")
        XCTAssertEqual(values.filter { $0.scaledValue == 0 }.count, 3, "\(phase): 0の値")
    }

    /// 同じIDが複数件あれば失敗にし、IDごとに1件へまとめる
    private func uniqueByID<T>(_ items: [T], id: (T) -> UUID, _ label: String) -> [UUID: T] {
        let grouped = Dictionary(grouping: items, by: id)
        for (key, group) in grouped where group.count != 1 {
            XCTFail("\(label): ID \(key) が\(group.count)件ある")
        }
        return grouped.compactMapValues(\.first)
    }

    // MARK: - fixture

    /// fixture仕様が要件の網羅条件を満たすか確認する。空や単調なfixtureで検証が素通りしないようにする
    private static func validateSpec(_ spec: FixtureSpec) throws {
        var problems: [String] = []
        let allIDs = spec.exercises.map(\.id) + spec.metrics.map(\.id) + spec.workouts.map(\.id)
            + spec.records.map(\.id) + spec.sets.map(\.id) + spec.values.map(\.id)
        if Set(allIDs).count != allIDs.count { problems.append("IDが重複") }
        let metricsByID = Dictionary(grouping: spec.metrics, by: \.id).compactMapValues(\.first)
        let exerciseIDs = Set(spec.exercises.map(\.id))
        if spec.workouts.filter({ !$0.records.isEmpty }).count < 2 { problems.append("記録ありWorkoutが2件未満") }
        if !spec.workouts.contains(where: { $0.records.isEmpty }) { problems.append("記録なしWorkoutが無い") }
        if Set(spec.workouts.map(\.day)).count != spec.workouts.count { problems.append("Workoutの日付が重複") }
        if spec.records.count < 2 { problems.append("recordが2件未満") }
        if !spec.records.contains(where: { $0.sets.count >= 2 }) { problems.append("複数セットのrecordが無い") }
        if !spec.exercises.contains(where: \.isArchived) { problems.append("アーカイブ種目が無い") }
        if !spec.exercises.contains(where: { !$0.isArchived }) { problems.append("active種目が無い") }
        if !spec.metrics.contains(where: { !$0.isActive }) { problems.append("無効項目が無い") }
        if !spec.values.contains(where: { $0.scaledValue == nil }) { problems.append("nilの値が無い") }
        if !spec.values.contains(where: { $0.scaledValue == 0 }) { problems.append("0の値が無い") }
        if spec.records.contains(where: { !exerciseIDs.contains($0.exerciseID) }) { problems.append("recordの参照先種目が無い") }
        if spec.values.contains(where: { metricsByID[$0.metricID] == nil }) { problems.append("値の参照先項目が無い") }
        // 現在の項目定義と名称・単位・小数可否・必須のいずれかが異なる古いsnapshot
        let staleValues = spec.values.filter { value in
            guard let metric = metricsByID[value.metricID] else { return false }
            return value.name != metric.name || value.unit != metric.unit
                || value.allowsDecimal != metric.allowsDecimal || value.isRequired != metric.isRequired
        }
        if staleValues.isEmpty { problems.append("古いsnapshotが無い") }
        // 同じ項目に対して内容の異なるsnapshotが複数ある（snapshotごとに個別保持されることの確認用）
        let snapshotsPerMetric = Dictionary(grouping: spec.values, by: \.metricID).mapValues { values in
            Set(values.map { "\($0.name)|\($0.unit)|\($0.allowsDecimal)|\($0.isRequired)" }).count
        }
        if !snapshotsPerMetric.values.contains(where: { $0 >= 3 }) { problems.append("同一項目で3種類以上のsnapshotが無い") }
        // 種目名snapshotが現在名と異なるrecord
        let exerciseNames = Dictionary(grouping: spec.exercises, by: \.id).compactMapValues(\.first?.name)
        if !spec.records.contains(where: { exerciseNames[$0.exerciseID] != $0.exerciseName }) { problems.append("旧種目名snapshotが無い") }
        guard problems.isEmpty else {
            XCTFail("fixture定義が不整合: " + problems.joined(separator: ", "))
            throw MigrationFixtureError.inconsistentFixture
        }
    }

    /// scratch直下に新規ユニーク名のディレクトリを作る。既に存在すれば失敗する（上書き・再利用しない）
    private func makeFreshFixtureDirectory() throws -> URL {
        let manager = FileManager.default
        let directory = scratchBase.appendingPathComponent(Self.fixturePrefix + UUID().uuidString, isDirectory: true)
        // withIntermediateDirectories: false なので、既存項目があれば失敗する
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // umaskの影響を受けないよう、作成後に明示的に設定する（変更するのはこの新規ディレクトリだけ）
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard directory.deletingLastPathComponent().standardizedFileURL.path == scratchBase.path,
              UITestStoreIsolation.isTrustedDirectory(directory, manager: manager),
              try manager.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw MigrationFixtureError.untrustedFixture
        }
        return directory.standardizedFileURL
    }

    /// ストアURLがfixtureディレクトリ直下で、システム一時ディレクトリ外であることを確認する（パスの比較だけで何も作らない）
    private func assertInsideFixture(_ storeURL: URL, directory: URL) throws {
        let standardized = storeURL.standardizedFileURL
        let temporaryPath = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard standardized.deletingLastPathComponent().path == directory.path,
              standardized.path.hasPrefix(scratchBase.path + "/"),
              !standardized.resolvingSymlinksInPath().path.hasPrefix(temporaryPath) else {
            XCTFail("ストアがscratch fixture外を指している")
            throw MigrationFixtureError.untrustedFixture
        }
    }

    /// fixtureディレクトリにはSQLiteストア本体と付随ファイルだけがあり、ストア本体が移動・削除されていないこと
    private func assertStoreFilesStayInFixture(_ directory: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(contents.contains(Self.storeFileName), "ストア本体はfixture内に残る")
        XCTAssertTrue(contents.allSatisfy { $0.hasPrefix(Self.storeFileName) }, "fixture内にストア以外のファイルを作らない: \(contents.sorted())")
    }
}

private enum MigrationFixtureError: Error {
    case scratchUnavailable
    case untrustedFixture
    case inconsistentFixture
}
#endif
