import XCTest
import SwiftData
@testable import Melete

// MainView.saveExerciseが使う種目新規作成境界(ExerciseCreationInContext)を、
// 合成データのインメモリストアだけで検証する。通常ストアには触れない。
@MainActor
final class ExerciseCreationSafetyTests: XCTestCase {
    // dirty contextでの作成を拒否し、無関係な未保存変更をsaveに巻き込まない(dirty guard導入前はRED)。
    func testDirtyContextCreationIsRejectedWithoutPersistingAndKeepsUnrelatedChange() throws {
        for schemaType in schemaTypes {
            let label = "\(schemaType)"
            let fixture = try makeFixture(schemaType)
            fixture.existing.name = "無関係な未保存変更"
            XCTAssertTrue(fixture.context.hasChanges, "\(label): 前提: contextに無関係な未保存変更がある")

            var persistCallCount = 0
            XCTAssertThrowsError(try ExerciseCreationInContext.save(name: "新しい種目", metrics: sampleDrafts, in: fixture.context) {
                persistCallCount += 1
                try $0.save()
            }, "\(label): dirty contextでは無関係な変更を巻き込まないよう作成を拒否する") { error in
                XCTAssertEqual(error as? ExerciseCreationInContextError, .unsavedContext, "\(label): 未保存変更による拒否として返す")
            }

            XCTAssertEqual(persistCallCount, 0, "\(label): 拒否時はpersist(context.save)を実行しない")
            XCTAssertEqual(fixture.existing.name, "無関係な未保存変更", "\(label): 拒否時はrollbackせず無関係な未保存変更を保持する")
            XCTAssertTrue(fixture.context.hasChanges, "\(label): 無関係な未保存変更を保存・破棄せず保持する")
            let pending = try fixture.context.fetch(FetchDescriptor<Exercise>())
            XCTAssertFalse(pending.contains { $0.name == "新しい種目" }, "\(label): 拒否時は新しい種目をcontextに挿入しない")
            // 別contextから読み、ストアが作成前と同じであることを確認する。
            let stored = try storedExercises(in: fixture.container)
            XCTAssertEqual(stored.count, 1, "\(label): 新しい種目を永続化しない")
            XCTAssertEqual(stored.first?.id, fixture.existingID, "\(label): 既存種目だけが残る")
            XCTAssertEqual(stored.first?.name, "既存種目", "\(label): 無関係な未保存変更を永続化しない")
            XCTAssertEqual(sortedMetrics(of: stored.first).map(\.name), ["重量"], "\(label): 既存の項目定義は変わらない")
            XCTAssertEqual(try storedMetricDefinitionCount(in: fixture.container), 1, "\(label): 新しい項目定義を永続化しない")
        }
    }

    // positive control: clean contextでの作成は現行どおり保存され、項目の各値と順序を維持する。
    func testCleanContextCreationPersistsMetricValuesInOrder() throws {
        for schemaType in schemaTypes {
            let label = "\(schemaType)"
            let fixture = try makeFixture(schemaType)
            XCTAssertFalse(fixture.context.hasChanges, "\(label): 前提: 作成前のcontextはclean")

            var persistCallCount = 0
            let created = try ExerciseCreationInContext.save(name: "新しい種目", metrics: sampleDrafts, in: fixture.context) {
                persistCallCount += 1
                try $0.save()
            }

            XCTAssertEqual(persistCallCount, 1, "\(label): persistを1回実行する")
            XCTAssertFalse(fixture.context.hasChanges, "\(label): 保存後のcontextはclean")
            assertStoredCreation(createdID: created.id, fixture: fixture, label: label)
        }
    }

    // positive control: persist省略時(MainViewと同じ呼び方)はcontext.saveで保存される。
    func testDefaultPersistSavesCleanCreation() throws {
        for schemaType in schemaTypes {
            let label = "\(schemaType)"
            let fixture = try makeFixture(schemaType)

            let created = try ExerciseCreationInContext.save(name: "新しい種目", metrics: sampleDrafts, in: fixture.context)

            XCTAssertFalse(fixture.context.hasChanges, "\(label): 既定persistで保存後のcontextはclean")
            assertStoredCreation(createdID: created.id, fixture: fixture, label: label)
        }
    }

    // cleanから開始してpersistが保存前に失敗した場合、挿入物だけを取り消してcleanに戻り、同じ入力で再試行できる。
    func testInjectedPersistFailureDiscardsInsertionLeavesContextCleanAndAllowsRetry() throws {
        for schemaType in schemaTypes {
            let label = "\(schemaType)"
            let fixture = try makeFixture(schemaType)

            var persistCallCount = 0
            XCTAssertThrowsError(try ExerciseCreationInContext.save(name: "新しい種目", metrics: sampleDrafts, in: fixture.context) { context in
                persistCallCount += 1
                // persist時点では新しい種目が挿入済みであることを確認してから、保存せずに失敗させる。
                XCTAssertTrue(context.hasChanges, "\(label): persist前に新しい種目が挿入されている")
                throw InjectedPersistFailure()
            }) { error in
                XCTAssertTrue(error is InjectedPersistFailure, "\(label): persistのエラーをそのまま再送出する")
            }

            XCTAssertEqual(persistCallCount, 1, "\(label): persistまで到達する")
            XCTAssertFalse(fixture.context.hasChanges, "\(label): 失敗後のcontextはclean")
            let pending = try fixture.context.fetch(FetchDescriptor<Exercise>())
            XCTAssertFalse(pending.contains { $0.name == "新しい種目" }, "\(label): 失敗した種目はcontextに残らない")
            XCTAssertEqual(fixture.existing.name, "既存種目", "\(label): 既存種目のモデルは変わらない")
            // 別contextから読み、作成対象外の既存種目と項目定義だけが残ることを確認する。
            let stored = try storedExercises(in: fixture.container)
            XCTAssertEqual(stored.map(\.id), [fixture.existingID], "\(label): 失敗した種目を永続化しない")
            XCTAssertEqual(stored.first?.name, "既存種目", "\(label): 既存種目の保存済み名前を維持する")
            XCTAssertEqual(sortedMetrics(of: stored.first).map(\.name), ["重量"], "\(label): 既存の項目定義を維持する")
            XCTAssertEqual(try storedMetricDefinitionCount(in: fixture.container), 1, "\(label): 新しい項目定義を永続化しない")

            // cleanに戻っているため、同じ入力と既定persistで再試行できる。
            let created = try ExerciseCreationInContext.save(name: "新しい種目", metrics: sampleDrafts, in: fixture.context)

            XCTAssertFalse(fixture.context.hasChanges, "\(label): 再試行後のcontextはclean")
            assertStoredCreation(createdID: created.id, fixture: fixture, label: label)
        }
    }

    private struct InjectedPersistFailure: Error {}

    // 別contextから読んだ内容で、作成した種目と既存種目を照合する。
    private func assertStoredCreation(createdID: UUID, fixture: Fixture, label: String) {
        do {
            let stored = try storedExercises(in: fixture.container)
            XCTAssertEqual(stored.count, 2, "\(label): 既存種目と新しい種目の2件になる")
            let createdStored = stored.first { $0.id == createdID }
            XCTAssertEqual(createdStored?.name, "新しい種目", "\(label)")
            XCTAssertEqual(createdStored?.isArchived, false, "\(label): 新しい種目はアーカイブされていない")

            let metrics = sortedMetrics(of: createdStored)
            XCTAssertEqual(metrics.map(\.name), sampleDrafts.map(\.name), "\(label): 項目名を入力順で保存する")
            XCTAssertEqual(metrics.map(\.unit), sampleDrafts.map(\.unit), "\(label): 単位を入力順で保存する")
            XCTAssertEqual(metrics.map(\.allowsDecimal), sampleDrafts.map(\.allowsDecimal), "\(label): 小数可否を入力順で保存する")
            XCTAssertEqual(metrics.map(\.isRequired), sampleDrafts.map(\.isRequired), "\(label): 必須/任意を入力順で保存する")
            XCTAssertEqual(metrics.map(\.isActive), [true, true, true], "\(label): 新しい項目は有効")
            XCTAssertEqual(metrics.map(\.sortOrder), [0, 1, 2], "\(label): 入力順をsortOrderにする")
            XCTAssertTrue(metrics.allSatisfy { $0.exercise?.id == createdID }, "\(label): 項目定義は新しい種目に属する")

            let existingStored = stored.first { $0.id == fixture.existingID }
            XCTAssertEqual(existingStored?.name, "既存種目", "\(label): 既存種目は変わらない")
            XCTAssertEqual(sortedMetrics(of: existingStored).map(\.name), ["重量"], "\(label): 既存の項目定義は変わらない")
            XCTAssertEqual(try storedMetricDefinitionCount(in: fixture.container), 4, "\(label): 既存1件+新規3件の項目定義")
        } catch {
            XCTFail("\(label): ストアの読み出しに失敗: \(error)")
        }
    }

    // 各値と順序の取り違えを検出できるよう、項目ごとに値を変えた合成入力。
    private var sampleDrafts: [MetricDraft] {
        [
            MetricDraft(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true),
            MetricDraft(name: "回数", unit: "回", allowsDecimal: false, isRequired: true),
            MetricDraft(name: "休憩", unit: "秒", allowsDecimal: false, isRequired: false),
        ]
    }

    // 通常V1と隔離V2の両スキーマで、同じ境界が使えることを確認する。
    private var schemaTypes: [any VersionedSchema.Type] { [MeleteSchemaV1.self, MeleteSchemaV2.self] }

    private func sortedMetrics(of exercise: Exercise?) -> [MetricDefinition] {
        (exercise?.metrics ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    // 別contextでfetchし、ストアに実際に保存された内容だけを確認する。
    private func storedExercises(in container: ModelContainer) throws -> [Exercise] {
        let readContext = ModelContext(container)
        readContext.autosaveEnabled = false
        return try readContext.fetch(FetchDescriptor<Exercise>())
    }

    private func storedMetricDefinitionCount(in container: ModelContainer) throws -> Int {
        let readContext = ModelContext(container)
        readContext.autosaveEnabled = false
        return try readContext.fetchCount(FetchDescriptor<MetricDefinition>())
    }

    private func makeFixture(_ schemaType: any VersionedSchema.Type) throws -> Fixture {
        let schema = Schema(versionedSchema: schemaType)
        let configuration = ModelConfiguration(
            "MeleteExerciseCreationSafety-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let existing = Exercise(name: "既存種目", metrics: [
            MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        ])
        context.insert(existing)
        try context.save()

        return Fixture(container: container, context: context, existing: existing, existingID: existing.id)
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let existing: Exercise
        let existingID: UUID
    }
}
