import XCTest
import SwiftData
@testable import Melete

// MainView.saveExerciseNameが使う保存境界(ExerciseNameEditingInContext)を、
// 合成データのインメモリストアだけで検証する。通常ストアには触れない。
@MainActor
final class ExerciseNameEditingSafetyTests: XCTestCase {
    private struct InjectedSaveFailure: Error {}

    func testCleanContextRenameSucceedsAndPersists() throws {
        for schemaType in schemaTypes {
            let fixture = try makeFixture(schemaType)
            XCTAssertFalse(fixture.context.hasChanges, "前提: 保存前のcontextはclean")

            var persistCallCount = 0
            XCTAssertNoThrow(try ExerciseNameEditingInContext.save(" 新しい名前 \n", for: fixture.target, in: fixture.context) {
                persistCallCount += 1
                try $0.save()
            })

            XCTAssertEqual(persistCallCount, 1, "clean contextではpersistを1回実行する")
            XCTAssertEqual(fixture.target.name, "新しい名前", "前後の空白を除去して保存する")
            XCTAssertFalse(fixture.context.hasChanges, "保存後のcontextはclean")
            let stored = try storedExercises(in: fixture.container)
            XCTAssertEqual(stored[fixture.targetID]?.name, "新しい名前", "対象の名前変更を永続化する")
            XCTAssertEqual(stored[fixture.unrelatedID]?.name, "無関係な種目", "無関係な種目は変わらない")
        }
    }

    func testDefaultPersistSavesContext() throws {
        for schemaType in schemaTypes {
            let fixture = try makeFixture(schemaType)

            XCTAssertNoThrow(try ExerciseNameEditingInContext.save("既定保存", for: fixture.target, in: fixture.context))

            XCTAssertFalse(fixture.context.hasChanges)
            XCTAssertEqual(try storedExercises(in: fixture.container)[fixture.targetID]?.name, "既定保存")
        }
    }

    func testEmptyNameIsRejectedWithoutPersistingAndKeepsContextClean() throws {
        let fixture = try makeFixture(MeleteSchemaV1.self)

        var persistCallCount = 0
        XCTAssertThrowsError(try ExerciseNameEditingInContext.save(" \n\t", for: fixture.target, in: fixture.context) { _ in
            persistCallCount += 1
        }) { error in
            XCTAssertTrue(error is ExerciseNameEditError)
        }

        XCTAssertEqual(persistCallCount, 0)
        XCTAssertEqual(fixture.target.name, "対象種目")
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testDirtyContextRenameIsRejectedWithoutPersistingAndKeepsUnrelatedChange() throws {
        for schemaType in schemaTypes {
            let fixture = try makeFixture(schemaType)
            fixture.unrelated.name = "無関係な未保存変更"
            XCTAssertTrue(fixture.context.hasChanges, "前提: contextに無関係な未保存変更がある")

            var persistCallCount = 0
            XCTAssertThrowsError(try ExerciseNameEditingInContext.save("新しい名前", for: fixture.target, in: fixture.context) {
                persistCallCount += 1
                try $0.save()
            }, "dirty contextでは無関係な変更を巻き込まないよう名前変更を拒否する") { error in
                XCTAssertEqual(error as? ExerciseNameEditingInContextError, .unsavedContext)
                XCTAssertEqual(
                    error.localizedDescription,
                    "未保存の変更があるため、種目名を保存できません。先に変更を保存するか、画面を開き直してください。"
                )
            }

            XCTAssertEqual(persistCallCount, 0, "拒否時はpersist(context.save)を実行しない")
            XCTAssertEqual(fixture.target.name, "対象種目", "拒否時は対象の名前を変更しない")
            XCTAssertEqual(fixture.unrelated.name, "無関係な未保存変更", "拒否時はrollbackせず無関係な未保存変更を保持する")
            XCTAssertTrue(fixture.context.hasChanges, "無関係な未保存変更を保存・破棄せず保持する")
            let stored = try storedExercises(in: fixture.container)
            XCTAssertEqual(stored[fixture.targetID]?.name, "対象種目", "対象の名前変更を永続化しない")
            XCTAssertEqual(stored[fixture.unrelatedID]?.name, "無関係な種目", "無関係な未保存変更を永続化しない")
        }
    }

    func testTargetOwnedByAnotherContextIsRejected() throws {
        for schemaType in schemaTypes {
            let fixture = try makeFixture(schemaType)
            // 同じストアでも別contextが所有する種目は、画面のcontextでは保存しない。
            let otherContext = ModelContext(fixture.container)
            otherContext.autosaveEnabled = false
            let targetID = fixture.targetID
            let foreignTarget = try XCTUnwrap(
                otherContext.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == targetID })).first
            )
            XCTAssertTrue(foreignTarget.modelContext === otherContext, "前提: 対象は別contextが所有する")

            var persistCallCount = 0
            XCTAssertThrowsError(try ExerciseNameEditingInContext.save("別context", for: foreignTarget, in: fixture.context) {
                persistCallCount += 1
                try $0.save()
            }) { error in
                XCTAssertEqual(error as? ExerciseNameEditingInContextError, .wrongContext)
                XCTAssertEqual(
                    error.localizedDescription,
                    "種目名の保存対象が現在のデータ画面に属していません。画面を開き直してください。"
                )
            }

            XCTAssertEqual(persistCallCount, 0)
            XCTAssertEqual(foreignTarget.name, "対象種目", "別context所有の対象を変更しない")
            XCTAssertFalse(otherContext.hasChanges)
            XCTAssertFalse(fixture.context.hasChanges)
            XCTAssertEqual(try storedExercises(in: fixture.container)[fixture.targetID]?.name, "対象種目")
        }
    }

    func testDetachedTargetIsRejected() throws {
        let fixture = try makeFixture(MeleteSchemaV1.self)
        let detached = Exercise(name: "未挿入", metrics: [])

        XCTAssertThrowsError(try ExerciseNameEditingInContext.save("新名", for: detached, in: fixture.context) { _ in
            XCTFail("未挿入の種目ではpersistを実行しない")
        }) { error in
            XCTAssertEqual(error as? ExerciseNameEditingInContextError, .wrongContext)
        }

        XCTAssertEqual(detached.name, "未挿入")
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testInjectedSaveFailureLeavesContextCleanAllowsRetryAndKeepsOtherSavedValues() throws {
        for schemaType in schemaTypes {
            let fixture = try makeFixture(schemaType)

            XCTAssertThrowsError(try ExerciseNameEditingInContext.save("失敗する名前", for: fixture.target, in: fixture.context) { _ in
                throw InjectedSaveFailure()
            }) { error in
                XCTAssertTrue(error is InjectedSaveFailure, "persistのエラーをそのまま再送出する")
            }

            XCTAssertEqual(fixture.target.name, "対象種目", "失敗時は対象の名前を元に戻す")
            XCTAssertFalse(fixture.context.hasChanges, "失敗後のcontextはclean")
            var stored = try storedExercises(in: fixture.container)
            XCTAssertEqual(stored[fixture.targetID]?.name, "対象種目")
            XCTAssertEqual(stored[fixture.unrelatedID]?.name, "無関係な種目", "他の保存済み値を維持する")
            XCTAssertEqual(stored[fixture.unrelatedID]?.metrics.map(\.name), ["回数"], "他の保存済み項目定義を維持する")

            // cleanに戻っているため、同じ入力で再試行できる。
            XCTAssertNoThrow(try ExerciseNameEditingInContext.save(" 再試行の名前 ", for: fixture.target, in: fixture.context))

            XCTAssertEqual(fixture.target.name, "再試行の名前")
            XCTAssertFalse(fixture.context.hasChanges)
            stored = try storedExercises(in: fixture.container)
            XCTAssertEqual(stored[fixture.targetID]?.name, "再試行の名前", "再試行で名前変更を永続化する")
            XCTAssertEqual(stored[fixture.targetID]?.metrics.map(\.name), ["重量"], "対象の項目定義を維持する")
            XCTAssertEqual(stored[fixture.unrelatedID]?.name, "無関係な種目", "再試行後も他の保存済み値を維持する")
        }
    }

    // 通常V1と隔離V2の両スキーマで、同じ境界が使えることを確認する。
    private var schemaTypes: [any VersionedSchema.Type] { [MeleteSchemaV1.self, MeleteSchemaV2.self] }

    // 別contextでfetchし、ストアに実際に保存された内容だけを確認する。
    private func storedExercises(in container: ModelContainer) throws -> [UUID: Exercise] {
        let readContext = ModelContext(container)
        readContext.autosaveEnabled = false
        let exercises = try readContext.fetch(FetchDescriptor<Exercise>())
        return Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
    }

    private func makeFixture(_ schemaType: any VersionedSchema.Type) throws -> Fixture {
        let schema = Schema(versionedSchema: schemaType)
        let configuration = ModelConfiguration(
            "MeleteExerciseNameEditingSafety-\(UUID().uuidString)",
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
