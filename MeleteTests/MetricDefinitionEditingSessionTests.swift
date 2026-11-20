import XCTest
@testable import Melete

final class MetricDefinitionEditingSessionTests: XCTestCase {
    func testV1SessionCreatesExistingDraftsWithoutV2Baseline() throws {
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "ベンチプレス", metrics: [metric])

        let session = MetricDefinitionEditingSession.v1(exercise: exercise)

        XCTAssertEqual(session.mode, .v1)
        XCTAssertTrue(session.exercise === exercise)
        XCTAssertEqual(session.drafts.map(\.id), [metric.id])
        XCTAssertNil(session.drafts.first?.historyBaseline)
    }

    func testV2SessionRetainsProvidedBaselineAndGetsNewIdentityWhenReopened() throws {
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "ベンチプレス", metrics: [metric])
        var draft = MetricDefinitionDraft(existing: metric)
        let baseline = MetricDefinitionHistoryBaseline.latestRevision(UUID())
        draft.historyBaseline = baseline

        let firstSession = try MetricDefinitionEditingSession.v2(exercise: exercise, drafts: [draft])
        let reopenedSession = try MetricDefinitionEditingSession.v2(exercise: exercise, drafts: [draft])

        XCTAssertEqual(firstSession.mode, .v2)
        XCTAssertEqual(firstSession.drafts.first?.historyBaseline, baseline)
        XCTAssertNotEqual(firstSession.id, reopenedSession.id)
        XCTAssertEqual(reopenedSession.drafts.first?.historyBaseline, baseline)
    }

    func testV2SessionRejectsMissingBaselineForExistingDraft() throws {
        let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "ベンチプレス", metrics: [metric])
        let draft = MetricDefinitionDraft(existing: metric)

        XCTAssertThrowsError(try MetricDefinitionEditingSession.v2(exercise: exercise, drafts: [draft])) { error in
            XCTAssertEqual(error as? MetricDefinitionEditingSessionError, .missingBaseline)
        }
        XCTAssertThrowsError(try MetricDefinitionEditingSession.validateV2Drafts([draft])) { error in
            XCTAssertEqual(error as? MetricDefinitionEditingSessionError, .missingBaseline)
        }
    }

    func testV2SessionAllowsNewDraftWithoutHistoryBaseline() throws {
        let exercise = Exercise(name: "ベンチプレス", metrics: [])
        let draft = MetricDefinitionDraft(name: "回数", unit: "回", allowsDecimal: false, isRequired: true)

        let session = try MetricDefinitionEditingSession.v2(exercise: exercise, drafts: [draft])

        XCTAssertNil(session.drafts.first?.original)
        XCTAssertNil(session.drafts.first?.historyBaseline)
    }
}
