import XCTest
@testable import Melete

// 未保存の追加行の取消を検証する。ModelContainerやストアを使わず、メモリ上の合成オブジェクトだけで完結させる。
final class MetricDefinitionDraftCancellationTests: XCTestCase {
    func testCancellingAddedEmptyDraftAllowsSavingExistingToggle() throws {
        let existing = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [existing])
        var drafts = MetricDefinitionEditing.draft(for: exercise)
        drafts[0].isActive = false
        let emptyDraft = MetricDefinitionDraft(name: "", unit: "", allowsDecimal: false, isRequired: false)
        drafts.append(emptyDraft)

        // 空行は保存時に黙って無視されず、入力エラーになる前提を先に確認する。
        XCTAssertThrowsError(try MetricDefinitionEditing.save(drafts, for: exercise) {}) { error in
            XCTAssertEqual((error as? MetricDefinitionEditingError)?.errorDescription, MetricDefinitionEditingError.invalid.errorDescription)
        }
        XCTAssertTrue(existing.isActive)
        XCTAssertEqual(exercise.metrics.map(\.id), [existing.id])

        let remaining = MetricDefinitionEditing.removeUnsavedDraft(id: emptyDraft.id, from: drafts)

        XCTAssertEqual(remaining.map(\.id), [existing.id])
        XCTAssertNoThrow(try MetricDefinitionEditing.save(remaining, for: exercise) {})
        XCTAssertFalse(existing.isActive)
        XCTAssertEqual(exercise.metrics.map(\.id), [existing.id])
    }

    func testRemovingWithExistingDraftIDKeepsSavedItem() throws {
        let existing = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [existing])
        var drafts = MetricDefinitionEditing.draft(for: exercise)
        let added = MetricDefinitionDraft(name: "回数", unit: "回", allowsDecimal: false, isRequired: false)
        drafts.append(added)

        let remaining = MetricDefinitionEditing.removeUnsavedDraft(id: existing.id, from: drafts)

        // 保存済み項目のIDを指定しても削除せず、内容と順序もそのまま残る。
        XCTAssertEqual(remaining.map(\.id), [existing.id, added.id])
        XCTAssertEqual(remaining.first?.original, MetricDefinitionSnapshot(existing))
        XCTAssertEqual(exercise.metrics.map(\.id), [existing.id])
        XCTAssertTrue(existing.isActive)
    }

    func testRemovingOneOfSeveralAddedDraftsRemovesOnlyThatDraft() throws {
        let existing = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [existing])
        var drafts = MetricDefinitionEditing.draft(for: exercise)
        let first = MetricDefinitionDraft(name: "回数", unit: "回", allowsDecimal: false, isRequired: false)
        let second = MetricDefinitionDraft(name: "", unit: "", allowsDecimal: false, isRequired: false)
        let third = MetricDefinitionDraft(name: "距離", unit: "m", allowsDecimal: true, isRequired: false)
        drafts.append(contentsOf: [first, second, third])

        let remaining = MetricDefinitionEditing.removeUnsavedDraft(id: second.id, from: drafts)

        // 指定した行だけが消え、ほかの行の順序と入力内容は変わらない。
        XCTAssertEqual(remaining.map(\.id), [existing.id, first.id, third.id])
        XCTAssertEqual(remaining.map(\.name), ["重量", "回数", "距離"])
        XCTAssertEqual(exercise.metrics.map(\.id), [existing.id])
    }
}
