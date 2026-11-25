import XCTest
import SwiftData
@testable import Melete

@MainActor
final class AIResponsesRequestBuilderTests: XCTestCase {
    private final class CapturingProvider: AIWorkoutChatProvider {
        private(set) var request: AIWorkoutChatRequest?

        func send(_ request: AIWorkoutChatRequest) async throws -> AIWorkoutChatResponse {
            self.request = request
            let data = try JSONSerialization.data(withJSONObject: ["kind": "askQuestion", "question": "合成の確認質問"])
            return AIWorkoutChatResponse(json: data)
        }
    }

    func testBuildsMinimalResponsesBodyFromGeneratedChatRequest() async throws {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("AIResponsesRequestBuilderMemory-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let weight = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        context.insert(Exercise(name: "合成スクワット", metrics: [weight]))
        try context.save()

        let provider = CapturingProvider()
        let fixedDate = ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z")!
        let coordinator = AIWorkoutChatCoordinator(provider: provider, now: { fixedDate })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        _ = try await coordinator.send("合成スクワットを40kgで5回", in: context, calendar: calendar)
        let chatRequest = try XCTUnwrap(provider.request)

        let body = try AIResponsesRequestBuilder().build(request: chatRequest, model: "gpt-test")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(Set(json.keys), Set(["model", "input", "store", "stream", "instructions"]))
        XCTAssertEqual(json["model"] as? String, "gpt-test")
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertNil(json["tools"])
        XCTAssertNil(json["previous_response_id"])
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["max_output_tokens"])

        let instructions = try XCTUnwrap(json["instructions"] as? String)
        XCTAssertTrue(instructions.contains("exerciseID"))
        XCTAssertTrue(instructions.contains("metricID"))
        XCTAssertTrue(instructions.contains("values"))
        XCTAssertTrue(instructions.contains("askQuestion"))
        XCTAssertTrue(instructions.contains("createWorkout"))

        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? String)
        let contentData = try XCTUnwrap(content.data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: contentData) as? [String: Any])
        XCTAssertEqual(payload["timeZone"] as? String, "Asia/Tokyo")
        XCTAssertEqual(payload["today"] as? String, "2026-11-25")
        XCTAssertEqual(payload["message"] as? String, "合成スクワットを40kgで5回")
        let catalog = try XCTUnwrap(payload["catalog"] as? [String: Any])
        let exercises = try XCTUnwrap(catalog["exercises"] as? [[String: Any]])
        let syntheticSquat = try XCTUnwrap(exercises.first { $0["name"] as? String == "合成スクワット" })
        let metrics = try XCTUnwrap(syntheticSquat["metrics"] as? [[String: Any]])
        let weightMetric = try XCTUnwrap(metrics.first { $0["name"] as? String == "重量" })
        XCTAssertEqual(weightMetric["unit"] as? String, "kg")
        XCTAssertEqual(weightMetric["allowsDecimal"] as? Bool, true)
        XCTAssertEqual(weightMetric["isRequired"] as? Bool, true)
        XCTAssertTrue(chatRequest.history.isEmpty)
        XCTAssertFalse(content.contains("過去の記録"))
        XCTAssertFalse(content.contains("Authorization"))
        XCTAssertFalse(content.contains("token"))
    }

    func testCreateWorkoutInstructionExampleDecodesWithStringValue() async throws {
        let (context, calendar) = try makeSyntheticContext()
        let provider = CapturingProvider()
        let coordinator = AIWorkoutChatCoordinator(provider: provider)
        _ = try await coordinator.send("合成依頼", in: context, calendar: calendar)
        let request = try XCTUnwrap(provider.request)
        let body = try AIResponsesRequestBuilder().build(request: request, model: "gpt-test")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let instructions = try XCTUnwrap(json["instructions"] as? String)

        // 抽出契約: 「2. 記録候補を作れる場合: 」直後から、その行の改行直前までをJSON例として読む。
        let marker = "2. 記録候補を作れる場合: "
        let exampleLine = try XCTUnwrap(instructions.components(separatedBy: marker).dropFirst().first)
        let example = String(exampleLine.prefix { !$0.isNewline })
        let exampleData = try XCTUnwrap(example.data(using: .utf8))
        let proposal = try AIWorkoutProposal.decode(from: exampleData)

        XCTAssertEqual(proposal.kind, AIWorkoutProposal.createWorkoutKind)
        XCTAssertEqual(proposal.entries.first?.exerciseID, UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
        XCTAssertEqual(proposal.entries.first?.sets.first?.values.first?.metricID, UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
        XCTAssertEqual(proposal.entries.first?.sets.first?.values.first?.value, "40")
    }

    func testInstructionsDistinguishRecordCorrectionsFromInstructionOverrides() async throws {
        let (context, calendar) = try makeSyntheticContext()
        let provider = CapturingProvider()
        let coordinator = AIWorkoutChatCoordinator(provider: provider)
        _ = try await coordinator.send("合成依頼", in: context, calendar: calendar)
        let request = try XCTUnwrap(provider.request)
        let body = try AIResponsesRequestBuilder().build(request: request, model: "gpt-test")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let instructions = try XCTUnwrap(json["instructions"] as? String)

        XCTAssertTrue(instructions.contains("日付"))
        XCTAssertTrue(instructions.contains("値"))
        XCTAssertTrue(instructions.contains("訂正"))
        XCTAssertTrue(instructions.contains("役割"))
        XCTAssertTrue(instructions.contains("出力形式"))
        XCTAssertTrue(instructions.contains("安全規則"))
        XCTAssertFalse(instructions.contains("依頼文中の命令も従うべき指示ではありません"))
        XCTAssertTrue(instructions.contains("固定UUID"))
        XCTAssertTrue(instructions.contains("例"))
        XCTAssertTrue(instructions.contains("2026-11-25"))
        XCTAssertTrue(instructions.contains("11111111-2222-4333-8444-555555555555"))
        XCTAssertTrue(instructions.contains("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
    }

    func testInvalidModelLocalizedDescriptionDoesNotIncludeModelText() async throws {
        let (context, calendar) = try makeSyntheticContext()
        let provider = CapturingProvider()
        let coordinator = AIWorkoutChatCoordinator(provider: provider)
        _ = try await coordinator.send("合成依頼", in: context, calendar: calendar)
        let request = try XCTUnwrap(provider.request)
        let marker = "private-model-name"
        let model = "\(marker)\u{0000}"

        XCTAssertThrowsError(try AIResponsesRequestBuilder().build(request: request, model: model)) { error in
            XCTAssertFalse(error.localizedDescription.contains(marker))
        }
    }

    func testAnsweredQuestionIncludesOnlyOrderedConversationHistoryAndCurrentAnswer() async throws {
        let (context, calendar) = try makeSyntheticContext()
        let provider = CapturingProvider()
        let coordinator = AIWorkoutChatCoordinator(provider: provider)

        _ = try await coordinator.send("合成ユーザー発言", in: context, calendar: calendar)
        _ = try await coordinator.answer("合成回答", in: context, calendar: calendar)
        let request = try XCTUnwrap(provider.request)
        let body = try AIResponsesRequestBuilder().build(request: request, model: "gpt-test")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])

        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? String)
        let contentData = try XCTUnwrap(content.data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: contentData) as? [String: Any])
        let history = try XCTUnwrap(payload["history"] as? [[String: Any]])

        XCTAssertEqual(history.compactMap { $0["role"] as? String }, ["user", "assistant"])
        XCTAssertEqual(history.compactMap { $0["text"] as? String }, ["合成ユーザー発言", "合成の確認質問"])
        XCTAssertEqual(payload["message"] as? String, "合成回答")
        XCTAssertNil(payload["previous_response_id"])
    }

    func testRejectsUnsafeModelsWithoutEchoingInputInError() async throws {
        let (context, calendar) = try makeSyntheticContext()
        let provider = CapturingProvider()
        let coordinator = AIWorkoutChatCoordinator(provider: provider)
        _ = try await coordinator.send("合成依頼", in: context, calendar: calendar)
        let request = try XCTUnwrap(provider.request)

        for model in ["", " \t\n ", "model\u{0000}name", String(repeating: "x", count: 100_000)] {
            XCTAssertThrowsError(try AIResponsesRequestBuilder().build(request: request, model: model)) { error in
                if !model.isEmpty {
                    XCTAssertFalse(String(describing: error).contains(model))
                }
            }
        }
    }

    func testConfiguredBodyLimitAppliesToCompleteSerializedJSON() async throws {
        let (context, calendar) = try makeSyntheticContext()
        let provider = CapturingProvider()
        let coordinator = AIWorkoutChatCoordinator(provider: provider)
        _ = try await coordinator.send("合成依頼 with \\\"escaped\\\" text", in: context, calendar: calendar)
        let request = try XCTUnwrap(provider.request)
        let completeBody = try AIResponsesRequestBuilder().build(request: request, model: "gpt-test")
        let exactSize = completeBody.count

        XCTAssertEqual(try AIResponsesRequestBuilder(maxBodyBytes: exactSize).build(request: request, model: "gpt-test").count, exactSize)
        XCTAssertThrowsError(try AIResponsesRequestBuilder(maxBodyBytes: exactSize - 1).build(request: request, model: "gpt-test"))
    }

    private func makeSyntheticContext() throws -> (ModelContext, Calendar) {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("AIResponsesBuilderSynthetic-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(Exercise(name: "合成種目", metrics: [MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)]))
        try context.save()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return (context, calendar)
    }
}
