import XCTest
import SwiftData
@testable import Melete

// MainViewのアーカイブ/復帰ボタンが使う切替境界(ExerciseArchiveToggleInContext)を、
// 合成データのインメモリストアだけで検証する。通常ストアには触れない。
@MainActor
final class ExerciseArchiveToggleSafetyTests: XCTestCase {
    // dirty contextでの切替を拒否し、無関係な未保存変更をsaveに巻き込まない(修正前はRED)。
    func testDirtyContextToggleIsRejectedWithoutPersistingAndKeepsUnrelatedChange() throws {
        for schemaType in schemaTypes {
            // アーカイブ(false→true)と復帰(true→false)の両方向で確認する。
            for targetArchived in [false, true] {
                let label = "\(schemaType) targetArchived=\(targetArchived)"
                let fixture = try makeFixture(schemaType, targetArchived: targetArchived)
                fixture.unrelated.name = "無関係な未保存変更"
                XCTAssertTrue(fixture.context.hasChanges, "\(label): 前提: contextに無関係な未保存変更がある")

                var persistCallCount = 0
                XCTAssertThrowsError(try ExerciseArchiveToggleInContext.toggle(fixture.target, in: fixture.context) {
                    persistCallCount += 1
                    try $0.save()
                }, "\(label): dirty contextでは無関係な変更を巻き込まないよう切替を拒否する") { error in
                    XCTAssertEqual(error as? ExerciseArchiveToggleInContextError, .unsavedContext, "\(label)")
                    XCTAssertEqual(
                        error.localizedDescription,
                        "未保存の変更があるため、アーカイブ状態を切り替えられません。先に変更を保存するか、画面を開き直してください。",
                        "\(label)"
                    )
                }

                XCTAssertEqual(persistCallCount, 0, "\(label): 拒否時はpersist(context.save)を実行しない")
                XCTAssertEqual(fixture.target.isArchived, targetArchived, "\(label): 拒否時は対象のアーカイブ状態を変更しない")
                XCTAssertEqual(fixture.unrelated.name, "無関係な未保存変更", "\(label): 拒否時はrollbackせず無関係な未保存変更を保持する")
                XCTAssertTrue(fixture.context.hasChanges, "\(label): 無関係な未保存変更を保存・破棄せず保持する")
                // 別contextから読み、ストアに何も保存されていないことを確認する。
                let stored = try storedExercises(in: fixture.container)
                XCTAssertEqual(stored[fixture.targetID]?.isArchived, targetArchived, "\(label): 対象のアーカイブ状態を永続化しない")
                XCTAssertEqual(stored[fixture.unrelatedID]?.name, "無関係な種目", "\(label): 無関係な未保存変更を永続化しない")
                XCTAssertEqual(stored[fixture.unrelatedID]?.isArchived, false, "\(label): 無関係な種目のアーカイブ状態は変わらない")
            }
        }
    }

    // positive control: clean contextでのアーカイブ→復帰は現行どおり保存される。
    func testCleanContextArchiveAndUnarchivePersist() throws {
        for schemaType in schemaTypes {
            let label = "\(schemaType)"
            let fixture = try makeFixture(schemaType, targetArchived: false)
            XCTAssertFalse(fixture.context.hasChanges, "\(label): 前提: 切替前のcontextはclean")

            var persistCallCount = 0
            let countingPersist: (ModelContext) throws -> Void = {
                persistCallCount += 1
                try $0.save()
            }

            // アーカイブ
            XCTAssertNoThrow(try ExerciseArchiveToggleInContext.toggle(fixture.target, in: fixture.context, persist: countingPersist))
            XCTAssertEqual(persistCallCount, 1, "\(label): アーカイブでpersistを1回実行する")
            XCTAssertTrue(fixture.target.isArchived, "\(label): 対象をアーカイブする")
            XCTAssertFalse(fixture.context.hasChanges, "\(label): アーカイブ保存後のcontextはclean")
            var stored = try storedExercises(in: fixture.container)
            XCTAssertEqual(stored[fixture.targetID]?.isArchived, true, "\(label): アーカイブを永続化する")
            XCTAssertEqual(stored[fixture.targetID]?.name, "対象種目", "\(label): 対象の名前は変わらない")
            XCTAssertEqual(stored[fixture.unrelatedID]?.isArchived, false, "\(label): 無関係な種目は変わらない")
            XCTAssertEqual(stored[fixture.unrelatedID]?.name, "無関係な種目", "\(label): 無関係な種目名は変わらない")

            // 復帰
            XCTAssertNoThrow(try ExerciseArchiveToggleInContext.toggle(fixture.target, in: fixture.context, persist: countingPersist))
            XCTAssertEqual(persistCallCount, 2, "\(label): 復帰でpersistを1回実行する")
            XCTAssertFalse(fixture.target.isArchived, "\(label): 対象を復帰する")
            XCTAssertFalse(fixture.context.hasChanges, "\(label): 復帰保存後のcontextはclean")
            stored = try storedExercises(in: fixture.container)
            XCTAssertEqual(stored[fixture.targetID]?.isArchived, false, "\(label): 復帰を永続化する")
            XCTAssertEqual(stored[fixture.unrelatedID]?.isArchived, false, "\(label): 無関係な種目は変わらない")
        }
    }

    // positive control: persist省略時(MainViewと同じ呼び方)はcontext.saveで保存される。
    func testDefaultPersistSavesContextForArchiveAndUnarchive() throws {
        for schemaType in schemaTypes {
            let label = "\(schemaType)"
            let fixture = try makeFixture(schemaType, targetArchived: false)

            XCTAssertNoThrow(try ExerciseArchiveToggleInContext.toggle(fixture.target, in: fixture.context))
            XCTAssertFalse(fixture.context.hasChanges, "\(label)")
            XCTAssertEqual(try storedExercises(in: fixture.container)[fixture.targetID]?.isArchived, true, "\(label): 既定persistでアーカイブを永続化する")

            XCTAssertNoThrow(try ExerciseArchiveToggleInContext.toggle(fixture.target, in: fixture.context))
            XCTAssertFalse(fixture.context.hasChanges, "\(label)")
            XCTAssertEqual(try storedExercises(in: fixture.container)[fixture.targetID]?.isArchived, false, "\(label): 既定persistで復帰を永続化する")
        }
    }

    func testTargetOwnedByAnotherContextIsRejected() throws {
        for schemaType in schemaTypes {
            for targetArchived in [false, true] {
                let label = "\(schemaType) targetArchived=\(targetArchived)"
                let fixture = try makeFixture(schemaType, targetArchived: targetArchived)
                // 同じストアでも別contextが所有する種目は、画面のcontextでは切り替えない。
                let otherContext = ModelContext(fixture.container)
                otherContext.autosaveEnabled = false
                let targetID = fixture.targetID
                let foreignTarget = try XCTUnwrap(
                    otherContext.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == targetID })).first
                )
                XCTAssertTrue(foreignTarget.modelContext === otherContext, "\(label): 前提: 対象は別contextが所有する")

                var persistCallCount = 0
                XCTAssertThrowsError(try ExerciseArchiveToggleInContext.toggle(foreignTarget, in: fixture.context) {
                    persistCallCount += 1
                    try $0.save()
                }) { error in
                    XCTAssertEqual(error as? ExerciseArchiveToggleInContextError, .wrongContext, "\(label)")
                    XCTAssertEqual(
                        error.localizedDescription,
                        "アーカイブ切替の対象が現在のデータ画面に属していません。画面を開き直してください。",
                        "\(label)"
                    )
                }

                XCTAssertEqual(persistCallCount, 0, "\(label): 拒否時はpersistを実行しない")
                XCTAssertEqual(foreignTarget.isArchived, targetArchived, "\(label): 別context所有の対象を変更しない")
                XCTAssertEqual(fixture.target.isArchived, targetArchived, "\(label): 画面context側の対象も変更しない")
                XCTAssertFalse(otherContext.hasChanges, "\(label)")
                XCTAssertFalse(fixture.context.hasChanges, "\(label)")
                let stored = try storedExercises(in: fixture.container)
                XCTAssertEqual(stored[fixture.targetID]?.isArchived, targetArchived, "\(label): ストアの対象は変わらない")
                XCTAssertEqual(stored[fixture.unrelatedID]?.isArchived, false, "\(label): 無関係な種目は変わらない")
            }
        }
    }

    func testDetachedTargetIsRejected() throws {
        for schemaType in schemaTypes {
            let label = "\(schemaType)"
            let fixture = try makeFixture(schemaType, targetArchived: false)
            // どのcontextにも挿入していない種目。
            let detached = Exercise(name: "未挿入", metrics: [])
            XCTAssertNil(detached.modelContext, "\(label): 前提: 対象は未挿入")

            XCTAssertThrowsError(try ExerciseArchiveToggleInContext.toggle(detached, in: fixture.context) { _ in
                XCTFail("\(label): 未挿入の種目ではpersistを実行しない")
            }) { error in
                XCTAssertEqual(error as? ExerciseArchiveToggleInContextError, .wrongContext, "\(label)")
            }

            XCTAssertFalse(detached.isArchived, "\(label): 未挿入の種目を変更しない")
            XCTAssertNil(detached.modelContext, "\(label): 拒否時に挿入しない")
            XCTAssertFalse(fixture.context.hasChanges, "\(label)")
            let stored = try storedExercises(in: fixture.container)
            XCTAssertEqual(stored.count, 2, "\(label): 未挿入の種目を永続化しない")
            XCTAssertEqual(stored[fixture.targetID]?.isArchived, false, "\(label)")
            XCTAssertEqual(stored[fixture.unrelatedID]?.isArchived, false, "\(label)")
        }
    }

    func testInjectedPersistFailureRestoresValueLeavesContextCleanAndAllowsRetry() throws {
        for schemaType in schemaTypes {
            for targetArchived in [false, true] {
                let label = "\(schemaType) targetArchived=\(targetArchived)"
                let fixture = try makeFixture(schemaType, targetArchived: targetArchived)

                var persistCallCount = 0
                XCTAssertThrowsError(try ExerciseArchiveToggleInContext.toggle(fixture.target, in: fixture.context) { _ in
                    persistCallCount += 1
                    // persist時点では切替済みであることを確認してから失敗させる。
                    XCTAssertEqual(fixture.target.isArchived, !targetArchived, "\(label): persist前に切り替わっている")
                    throw InjectedPersistFailure()
                }) { error in
                    XCTAssertTrue(error is InjectedPersistFailure, "\(label): persistのエラーをそのまま再送出する")
                }

                XCTAssertEqual(persistCallCount, 1, "\(label)")
                XCTAssertEqual(fixture.target.isArchived, targetArchived, "\(label): 失敗時は元のアーカイブ状態に戻す")
                XCTAssertFalse(fixture.context.hasChanges, "\(label): 失敗後のcontextはclean")
                var stored = try storedExercises(in: fixture.container)
                XCTAssertEqual(stored[fixture.targetID]?.isArchived, targetArchived, "\(label): 失敗した切替を永続化しない")
                XCTAssertEqual(stored[fixture.targetID]?.name, "対象種目", "\(label): 対象の保存済み名前を維持する")
                XCTAssertEqual(stored[fixture.targetID]?.metrics.map(\.name), ["重量"], "\(label): 対象の保存済み項目定義を維持する")
                XCTAssertEqual(stored[fixture.unrelatedID]?.name, "無関係な種目", "\(label): 他の保存済み値を維持する")
                XCTAssertEqual(stored[fixture.unrelatedID]?.isArchived, false, "\(label)")
                XCTAssertEqual(stored[fixture.unrelatedID]?.metrics.map(\.name), ["回数"], "\(label): 他の保存済み項目定義を維持する")

                // cleanに戻っているため、既定persistで再試行できる。
                XCTAssertNoThrow(try ExerciseArchiveToggleInContext.toggle(fixture.target, in: fixture.context), "\(label)")

                XCTAssertEqual(fixture.target.isArchived, !targetArchived, "\(label): 再試行で切り替わる")
                XCTAssertFalse(fixture.context.hasChanges, "\(label)")
                stored = try storedExercises(in: fixture.container)
                XCTAssertEqual(stored[fixture.targetID]?.isArchived, !targetArchived, "\(label): 再試行で切替を永続化する")
                XCTAssertEqual(stored[fixture.targetID]?.metrics.map(\.name), ["重量"], "\(label)")
                XCTAssertEqual(stored[fixture.unrelatedID]?.isArchived, false, "\(label): 再試行後も無関係な種目は変わらない")
                XCTAssertEqual(stored[fixture.unrelatedID]?.name, "無関係な種目", "\(label)")
            }
        }
    }

    private struct InjectedPersistFailure: Error {}

    // 通常V1と隔離V2の両スキーマで、同じ境界が使えることを確認する。
    private var schemaTypes: [any VersionedSchema.Type] { [MeleteSchemaV1.self, MeleteSchemaV2.self] }

    // 別contextでfetchし、ストアに実際に保存された内容だけを確認する。
    private func storedExercises(in container: ModelContainer) throws -> [UUID: Exercise] {
        let readContext = ModelContext(container)
        readContext.autosaveEnabled = false
        let exercises = try readContext.fetch(FetchDescriptor<Exercise>())
        return Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
    }

    private func makeFixture(_ schemaType: any VersionedSchema.Type, targetArchived: Bool) throws -> Fixture {
        let schema = Schema(versionedSchema: schemaType)
        let configuration = ModelConfiguration(
            "MeleteExerciseArchiveToggleSafety-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let target = Exercise(name: "対象種目", metrics: [
            MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        ])
        target.isArchived = targetArchived
        let unrelated = Exercise(name: "無関係な種目", metrics: [
            MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0)
        ])
        context.insert(target)
        context.insert(unrelated)
        try context.save()

        return Fixture(
            container: container, context: context,
            target: target, unrelated: unrelated,
            targetID: target.id, unrelatedID: unrelated.id
        )
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let target: Exercise
        let unrelated: Exercise
        let targetID: UUID
        let unrelatedID: UUID
    }
}
