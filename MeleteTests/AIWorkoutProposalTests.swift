import XCTest
import SwiftData
@testable import Melete

// AI会話から記録する第1段階（構造化候補・検証・確認用draft・承認後保存）の合成in-memoryテスト。
// 実データ・通常ストア・ネットワークは一切使わない。
@MainActor
final class AIWorkoutProposalTests: XCTestCase {
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let exercise: Exercise
        let weight: MetricDefinition
        let reps: MetricDefinition
        let memo: MetricDefinition
    }

    // テストの日付解釈を固定するためのカレンダー（実行環境のタイムゾーンに依存させない）
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        return calendar
    }

    private let pastDay = "2026-01-15"

    private func makeFixture() throws -> Fixture {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("AIWorkoutProposalMemory-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let weight = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0)
        let reps = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 1)
        let memo = MetricDefinition(name: "補助", unit: "段階", allowsDecimal: false, isRequired: false, sortOrder: 2)
        let exercise = Exercise(name: "合成種目A", metrics: [weight, reps, memo])
        context.insert(exercise)
        try context.save()
        return Fixture(container: container, context: context, exercise: exercise, weight: weight, reps: reps, memo: memo)
    }

    private func value(_ metric: MetricDefinition, _ text: String, unit: String? = nil) -> [String: Any] {
        ["metricID": metric.id.uuidString, "value": text, "unit": unit ?? metric.unit]
    }

    private func standardSets(_ fixture: Fixture, count: Int = 3) -> [[String: Any]] {
        Array(repeating: ["values": [value(fixture.weight, "60"), value(fixture.reps, "10")]], count: count)
    }

    private func proposalData(kind: String = "createWorkout", day: String? = nil, entries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["kind": kind, "day": day ?? pastDay, "entries": entries])
    }

    private func standardProposal(_ fixture: Fixture) throws -> AIWorkoutProposal {
        try AIWorkoutProposal.decode(from: proposalData(entries: [["exerciseID": fixture.exercise.id.uuidString, "sets": standardSets(fixture)]]))
    }

    // coordinatorと、そこで始めた1つのリクエストの組。
    // AIWorkoutProposalValidation.makeReview と review.approve は fileprivate で、テストからは呼べない（呼ぶとコンパイルエラー）。
    // そのためテストのreview作成・承認は、UIと同じくすべてこの組を通して coordinator の公開APIで行う
    @MainActor private struct CoordinatedRequest {
        let coordinator: AIWorkoutProposalCoordinator
        let request: AIWorkoutProposalCoordinator.Request

        var id: UUID { request.id }
        var catalog: AIWorkoutCatalog { request.catalog }

        init(in context: ModelContext) throws {
            let coordinator = AIWorkoutProposalCoordinator()
            self.request = try coordinator.beginRequest(in: context)
            self.coordinator = coordinator
        }

        func review(_ proposal: AIWorkoutProposal, in context: ModelContext, calendar: Calendar, now: Date = .now) throws -> AIWorkoutProposalReview {
            try coordinator.review(for: request.id, proposal: proposal, in: context, calendar: calendar, now: now)
        }

        @discardableResult
        func approve(in context: ModelContext, persist: (ModelContext) throws -> Void = { try $0.save() }) throws -> Workout {
            try coordinator.approve(request.id, in: context, persist: persist)
        }

        var status: AIWorkoutProposalCoordinator.Status? { coordinator.status(of: request.id) }
    }

    // coordinatorを通してreviewを作る。request を渡さなければ、その場で新しいリクエストを始める（カタログもその時点で作られる）
    private func makeReview(_ fixture: Fixture, proposal: AIWorkoutProposal? = nil, request: CoordinatedRequest? = nil) throws -> (request: CoordinatedRequest, review: AIWorkoutProposalReview) {
        let request = try request ?? CoordinatedRequest(in: fixture.context)
        let review = try request.review(proposal ?? standardProposal(fixture), in: fixture.context, calendar: calendar)
        return (request, review)
    }

    private func workoutCount(_ fixture: Fixture) throws -> Int {
        try ModelContext(fixture.container).fetchCount(FetchDescriptor<Workout>())
    }

    // coordinatorを通した検証が expected で失敗し、reviewが作られず（応答待ちのまま）、storeも変わらないことを確かめる
    private func assertRejected(
        _ fixture: Fixture,
        _ expected: AIWorkoutProposalError,
        request: CoordinatedRequest? = nil,
        now: Date = .now,
        file: StaticString = #filePath,
        line: UInt = #line,
        data: () throws -> Data
    ) throws {
        let request = try request ?? CoordinatedRequest(in: fixture.context)
        XCTAssertThrowsError(try request.review(AIWorkoutProposal.decode(from: data()), in: fixture.context, calendar: calendar, now: now), file: file, line: line) { error in
            XCTAssertEqual(error as? AIWorkoutProposalError, expected, "\(error)", file: file, line: line)
        }
        XCTAssertEqual(request.status, .awaitingResponse, file: file, line: line)
        XCTAssertFalse(fixture.context.hasChanges, file: file, line: line)
        XCTAssertEqual(try workoutCount(fixture), 0, file: file, line: line)
    }

    // MARK: - 送信用カタログ

    func testCatalogContainsOnlyExerciseNamesAndActiveMetricDefinitionsWithoutRecords() throws {
        let fixture = try makeFixture()
        let inactive = MetricDefinition(name: "無効項目", unit: "m", allowsDecimal: true, isRequired: false, sortOrder: 3)
        inactive.isActive = false
        fixture.exercise.metrics.append(inactive)
        let archived = Exercise(name: "合成アーカイブ種目", metrics: [MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0)])
        archived.isArchived = true
        fixture.context.insert(archived)
        try fixture.context.save()
        // 既存の記録があってもカタログには含まれないことを確かめる
        var entry = WorkoutEntryDraft(exercise: fixture.exercise)
        entry.sets[0].values = [fixture.weight.id: "123.5", fixture.reps.id: "7"]
        _ = try WorkoutCreationV1.save(day: .now, entries: [entry], in: fixture.context)

        let catalog = try AIWorkoutCatalog.make(in: fixture.context)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: catalog.requestPayloadJSON()) as? [String: Any])

        XCTAssertEqual(Set(json.keys), ["exercises"])
        let exercises = try XCTUnwrap(json["exercises"] as? [[String: Any]])
        XCTAssertEqual(exercises.count, 1)
        let exercise = try XCTUnwrap(exercises.first)
        XCTAssertEqual(Set(exercise.keys), ["id", "name", "metrics"])
        XCTAssertEqual(exercise["name"] as? String, "合成種目A")
        XCTAssertEqual(exercise["id"] as? String, fixture.exercise.id.uuidString)
        let metrics = try XCTUnwrap(exercise["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.map { $0["name"] as? String }, ["重量", "回数", "補助"])
        for metric in metrics {
            XCTAssertEqual(Set(metric.keys), ["id", "name", "unit", "allowsDecimal", "isRequired"])
        }
        let text = try XCTUnwrap(String(data: catalog.requestPayloadJSON(), encoding: .utf8))
        XCTAssertFalse(text.contains("123.5"))
        XCTAssertFalse(text.contains("無効項目"))
        XCTAssertFalse(text.contains("合成アーカイブ種目"))
    }

    func testCatalogRefusesContextWithUnsavedChanges() throws {
        let fixture = try makeFixture()
        fixture.exercise.name = "未保存の名前"
        XCTAssertThrowsError(try AIWorkoutCatalog.make(in: fixture.context)) { error in
            XCTAssertEqual(error as? AIWorkoutProposalError, .unsavedContext)
        }
    }

    func testCatalogExcludesExerciseWithoutActiveMetrics() throws {
        let fixture = try makeFixture()
        for metric in fixture.exercise.metrics { metric.isActive = false }
        try fixture.context.save()
        XCTAssertTrue(try AIWorkoutCatalog.make(in: fixture.context).exercises.isEmpty)
    }

    // 別contextで保存された変更の後でも、古い名前・単位やアーカイブ済み種目をカタログに入れない。
    // 呼び出し元contextが変更を反映していればすべての種目を新しい定義で送り、反映していなければカタログ全体を明示エラーにする。
    // どちらの場合も、変更していない種目だけが黙って残る・黙って消えるような一部だけのカタログは返さない
    func testCatalogNeverSendsDefinitionOutdatedByAnotherContext() throws {
        let mutations: [(label: String, mutate: (Exercise, ModelContext) throws -> Void)] = [
            ("アーカイブ", { exercise, context in exercise.isArchived = true; try context.save() }),
            ("名前変更", { exercise, context in exercise.name = "合成種目A改"; try context.save() }),
            ("単位変更", { exercise, context in exercise.metrics.first(where: { $0.name == "回数" })?.unit = "レップ"; try context.save() }),
        ]
        for (label, mutate) in mutations {
            let fixture = try makeFixture()
            let unrelated = try XCTUnwrap(addExercises(fixture, count: 1).first)
            let (persisted, other) = try fetchInOtherContext(fixture)
            try mutate(persisted, other)

            let catalog: AIWorkoutCatalog
            do {
                catalog = try AIWorkoutCatalog.make(in: fixture.context)
            } catch let error as AIWorkoutProposalError where error == .catalogDefinitionInconsistent {
                // 呼び出し元contextが古いまま: 全体が失敗し、一部だけのカタログは返らない
                XCTAssertFalse(fixture.context.hasChanges, label)
                continue
            }
            // カタログが作れた場合: 無関係な種目は失われず、変更した種目はアーカイブ時だけ外れ、それ以外は最新の定義で入る
            XCTAssertEqual(catalog.exercise(id: unrelated.id)?.name, unrelated.name, label)
            let sent = catalog.exercise(id: persisted.id)
            if persisted.isArchived {
                XCTAssertNil(sent, label)
                XCTAssertEqual(catalog.exercises.map(\.id), [unrelated.id], label)
            } else {
                XCTAssertEqual(Set(catalog.exercises.map(\.id)), [persisted.id, unrelated.id], label)
                XCTAssertEqual(sent?.name, persisted.name, label)
                XCTAssertEqual(sent?.metricSnapshots, WorkoutEntryDraft(exercise: persisted).metricSnapshots, label)
            }
        }
    }

    // 別contextから保存済みの種目を取り出す（contextも返すのは、保存までcontextを生かしておくため）
    private func fetchInOtherContext(_ fixture: Fixture) throws -> (exercise: Exercise, context: ModelContext) {
        let other = ModelContext(fixture.container)
        let exerciseID = fixture.exercise.id
        let exercise = try XCTUnwrap(other.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID })).first)
        return (exercise, other)
    }

    // カタログ作成と同じく、指定したcontextでfixtureの種目をfetchする（呼び出し元contextではcached定義が返る）
    private func fetchFixtureExercise(_ fixture: Fixture, in context: ModelContext) throws -> Exercise {
        let exerciseID = fixture.exercise.id
        return try XCTUnwrap(context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID })).first)
    }

    // localのcached定義が古い種目があるとき、カタログ作成全体が明示エラーになり、一部の種目だけのカタログも返らないことを確かめる。
    // 未保存の変更・上限超過とは原因が違うので、それらのエラーでは代用させず、定義の食い違い専用のケースで表す
    // （利用者に誤った対処を示さないため）。種目名は記録内容に近い情報なので、メッセージに含まれないことも確かめる
    private func assertCatalogFailsWholeForOutdatedLocalDefinition(
        _ fixture: Fixture,
        forbiddenTexts: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var catalog: AIWorkoutCatalog?
        XCTAssertThrowsError(catalog = try AIWorkoutCatalog.make(in: fixture.context), "古い定義の種目を黙って外さず、カタログ作成全体を失敗させること", file: file, line: line) { error in
            guard let proposalError = error as? AIWorkoutProposalError else {
                return XCTFail("AIWorkoutProposalErrorで失敗すること: \(error)", file: file, line: line)
            }
            XCTAssertNotEqual(proposalError, .unsavedContext, file: file, line: line)
            if case .catalogExerciseOverLimit = proposalError {
                XCTFail("上限超過のエラーで代用しないこと: \(proposalError)", file: file, line: line)
            }
            XCTAssertEqual(proposalError, .catalogDefinitionInconsistent, file: file, line: line)
            let message = proposalError.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty, file: file, line: line)
            for text in forbiddenTexts {
                XCTAssertFalse(message.contains(text), message, file: file, line: line)
            }
        }
        XCTAssertNil(catalog, file: file, line: line)
        XCTAssertFalse(fixture.context.hasChanges, file: file, line: line)
    }

    // 正常な種目と、別contextで名前を変えて保存した種目が共存するとき。
    // 呼び出し元contextのcached名がSwiftDataにより新しい名前へ更新されるかは環境に依存するので、両方の場合を条件で確かめる:
    // 更新されていれば両種目が最新の定義で入り、古いままならカタログ全体を明示エラーにする（一部だけのカタログは返さない）
    func testCatalogFailsWholeWhenLocalNameIsOutdatedByAnotherContext() throws {
        let fixture = try makeFixture()
        let normal = try XCTUnwrap(addExercises(fixture, count: 1).first)
        // 前提: 変更前は両方の種目が送れる（正常な種目そのものはエラーの原因にならない）
        XCTAssertEqual(try Set(AIWorkoutCatalog.make(in: fixture.context).exercises.map(\.id)), [fixture.exercise.id, normal.id])

        let (persisted, other) = try fetchInOtherContext(fixture)
        persisted.name = "合成種目A改"
        try other.save()

        // 前提: 保存済みの定義は新しい名前になっている
        XCTAssertEqual(try fetchFixtureExercise(fixture, in: ModelContext(fixture.container)).name, "合成種目A改")

        switch try fetchFixtureExercise(fixture, in: fixture.context).name {
        case "合成種目A改":
            // 呼び出し元contextも最新: 両方の種目が最新の定義で入る
            let catalog = try AIWorkoutCatalog.make(in: fixture.context)
            XCTAssertEqual(Set(catalog.exercises.map(\.id)), [fixture.exercise.id, normal.id])
            XCTAssertEqual(catalog.exercise(id: fixture.exercise.id)?.name, "合成種目A改")
            XCTAssertEqual(catalog.exercise(id: fixture.exercise.id)?.metricSnapshots, WorkoutEntryDraft(exercise: persisted).metricSnapshots)
            XCTAssertEqual(catalog.exercise(id: normal.id)?.name, normal.name)
        case "合成種目A":
            // 呼び出し元contextが古いまま: 全体が明示エラーになる
            assertCatalogFailsWholeForOutdatedLocalDefinition(fixture, forbiddenTexts: ["合成種目A", "合成種目A改", normal.name])
        case let name:
            XCTFail("前提: 呼び出し元contextの名前は変更前か変更後のどちらかであること: \(name)")
        }
    }

    // 正常な種目と、別contextで単位を変えて保存した（localのcached単位が古い）種目が共存するときは、カタログ全体を明示エラーにする
    func testCatalogFailsWholeWhenLocalUnitIsOutdatedByAnotherContext() throws {
        let fixture = try makeFixture()
        let normal = try XCTUnwrap(addExercises(fixture, count: 1).first)
        // 前提: 変更前は両方の種目が送れる（正常な種目そのものはエラーの原因にならない）
        XCTAssertEqual(try Set(AIWorkoutCatalog.make(in: fixture.context).exercises.map(\.id)), [fixture.exercise.id, normal.id])

        let (persisted, other) = try fetchInOtherContext(fixture)
        let persistedReps = try XCTUnwrap(persisted.metrics.first { $0.id == fixture.reps.id })
        persistedReps.unit = "レップ"
        try other.save()

        // 前提: 保存済みの定義は新しい単位で、呼び出し元contextのcached定義は古い単位のまま。
        // 前提が崩れたら古い定義の経路を確かめられないので、黙って通さず失敗させる
        let stored = try fetchFixtureExercise(fixture, in: ModelContext(fixture.container))
        XCTAssertEqual(stored.metrics.first { $0.id == fixture.reps.id }?.unit, "レップ")
        let local = try fetchFixtureExercise(fixture, in: fixture.context)
        guard local.metrics.first(where: { $0.id == fixture.reps.id })?.unit == "回" else {
            return XCTFail("前提: 呼び出し元contextのcached単位が古いままであること")
        }

        assertCatalogFailsWholeForOutdatedLocalDefinition(fixture, forbiddenTexts: ["合成種目A", normal.name])
    }

    // MARK: - 厳格なデコード

    func testDecodeRejectsUnknownFieldsAtEveryLevel() throws {
        let fixture = try makeFixture()
        let id = fixture.exercise.id.uuidString
        var extraValue = value(fixture.weight, "60")
        extraValue["note"] = "x"
        let cases: [[String: Any]] = [
            ["kind": "createWorkout", "day": pastDay, "entries": [["exerciseID": id, "sets": standardSets(fixture)]], "delete": true],
            ["kind": "createWorkout", "day": pastDay, "entries": [["exerciseID": id, "sets": standardSets(fixture), "exerciseName": "合成種目A"]]],
            ["kind": "createWorkout", "day": pastDay, "entries": [["exerciseID": id, "sets": [["values": [value(fixture.reps, "10")], "rest": 60]]]]],
            ["kind": "createWorkout", "day": pastDay, "entries": [["exerciseID": id, "sets": [["values": [extraValue, value(fixture.reps, "10")]]]]]],
        ]
        for object in cases {
            XCTAssertThrowsError(try AIWorkoutProposal.decode(from: JSONSerialization.data(withJSONObject: object))) { error in
                XCTAssertEqual(error as? AIWorkoutProposalError, .malformed)
            }
        }
    }

    func testDecodeRejectsWrongTypesMissingFieldsAndInvalidIDs() throws {
        let fixture = try makeFixture()
        let id = fixture.exercise.id.uuidString
        let numericValue: [String: Any] = ["metricID": fixture.weight.id.uuidString, "value": 60, "unit": "kg"]
        let cases: [Any] = [
            ["kind": "createWorkout", "day": pastDay, "entries": [["exerciseID": id, "sets": [["values": [numericValue]]]]]],
            ["kind": "createWorkout", "entries": [["exerciseID": id, "sets": standardSets(fixture)]]],
            ["kind": "createWorkout", "day": pastDay, "entries": [["exerciseID": "not-a-uuid", "sets": standardSets(fixture)]]],
            ["kind": "createWorkout", "day": pastDay, "entries": [["exerciseID": id, "sets": [["values": [["metricID": fixture.weight.id.uuidString, "value": "60"]]]]]]],
            [["kind": "createWorkout"]],
        ]
        for object in cases {
            XCTAssertThrowsError(try AIWorkoutProposal.decode(from: JSONSerialization.data(withJSONObject: object))) { error in
                XCTAssertEqual(error as? AIWorkoutProposalError, .malformed)
            }
        }
        XCTAssertThrowsError(try AIWorkoutProposal.decode(from: Data("今日ベンチプレス".utf8))) { error in
            XCTAssertEqual(error as? AIWorkoutProposalError, .malformed)
        }
    }

    // MARK: - 実装上の安全上限

    // 上限検証用に、2つの必須項目（小数可の重量・整数の回数）を持つ合成種目を追加する
    private func addExercises(_ fixture: Fixture, count: Int) throws -> [Exercise] {
        let exercises = (0..<count).map { index in
            Exercise(name: "合成上限種目\(index)", metrics: [
                MetricDefinition(name: "重量", unit: "kg", allowsDecimal: true, isRequired: true, sortOrder: 0),
                MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 1),
            ])
        }
        for exercise in exercises { fixture.context.insert(exercise) }
        try fixture.context.save()
        return exercises
    }

    private func sortedMetrics(_ exercise: Exercise) -> [MetricDefinition] {
        exercise.metrics.sorted { $0.sortOrder < $1.sortOrder }
    }

    private func randomValue(_ text: String = "1", unit: String = "kg") -> [String: Any] {
        ["metricID": UUID().uuidString, "value": text, "unit": unit]
    }

    func testProposalAtEveryCountLimitBecomesReview() throws {
        let fixture = try makeFixture()
        let others = try addExercises(fixture, count: AIWorkoutProposalLimits.maxEntries - 1)
        // 20種目×50セット×2項目 = 値の総数の上限ちょうど
        var entries: [[String: Any]] = [["exerciseID": fixture.exercise.id.uuidString, "sets": standardSets(fixture, count: AIWorkoutProposalLimits.maxSetsPerEntry)]]
        for exercise in others {
            let metrics = sortedMetrics(exercise)
            let set: [String: Any] = ["values": [value(metrics[0], "60"), value(metrics[1], "10")]]
            entries.append(["exerciseID": exercise.id.uuidString, "sets": Array(repeating: set, count: AIWorkoutProposalLimits.maxSetsPerEntry)])
        }
        XCTAssertEqual(entries.count * AIWorkoutProposalLimits.maxSetsPerEntry * 2, AIWorkoutProposalLimits.maxTotalValues)

        let review = try makeReview(fixture, proposal: AIWorkoutProposal.decode(from: proposalData(entries: entries))).review

        XCTAssertEqual(review.entries.count, AIWorkoutProposalLimits.maxEntries)
        XCTAssertTrue(review.entries.allSatisfy { $0.sets.count == AIWorkoutProposalLimits.maxSetsPerEntry })
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture), 0)
    }

    func testRejectsCountsOverLimitsAsRecoverableError() throws {
        let fixture = try makeFixture()
        let id = fixture.exercise.id.uuidString
        let oneSet = standardSets(fixture, count: 1)

        try assertRejected(fixture, .limitExceeded(.entries)) {
            try proposalData(entries: (0...AIWorkoutProposalLimits.maxEntries).map { _ in ["exerciseID": UUID().uuidString, "sets": oneSet] })
        }
        try assertRejected(fixture, .limitExceeded(.setsPerEntry)) {
            try proposalData(entries: [["exerciseID": id, "sets": standardSets(fixture, count: AIWorkoutProposalLimits.maxSetsPerEntry + 1)]])
        }
        try assertRejected(fixture, .limitExceeded(.valuesPerSet)) {
            try proposalData(entries: [["exerciseID": id, "sets": [["values": (0...AIWorkoutProposalLimits.maxValuesPerSet).map { _ in randomValue() }]]]])
        }
        // 各配列は上限内でも、値の総数が上限を1つ超える候補
        var entries: [[String: Any]] = (0..<AIWorkoutProposalLimits.maxEntries).map { _ in
            ["exerciseID": UUID().uuidString, "sets": Array(repeating: ["values": [randomValue(), randomValue()]], count: AIWorkoutProposalLimits.maxSetsPerEntry)]
        }
        var sets = try XCTUnwrap(entries[0]["sets"] as? [[String: Any]])
        sets[0] = ["values": [randomValue(), randomValue(), randomValue()]]
        entries[0]["sets"] = sets
        try assertRejected(fixture, .limitExceeded(.totalValues)) { try proposalData(entries: entries) }

        // 上限超過は失敗のまま止まらず、上限内の候補で依頼し直せば確認用draftを作れる
        XCTAssertEqual(try makeReview(fixture).review.state, .pending)
    }

    func testValueAndUnitLengthLimits() throws {
        let fixture = try makeFixture()
        let id = fixture.exercise.id.uuidString
        let atLimit = String(repeating: "0", count: AIWorkoutProposalLimits.maxValueBytes - 2) + "60"
        let review = try makeReview(fixture, proposal: AIWorkoutProposal.decode(from: proposalData(entries: [["exerciseID": id, "sets": [["values": [value(fixture.weight, atLimit), value(fixture.reps, "10")]]]]]))).review
        XCTAssertEqual(review.entries.first?.sets.first?.values[fixture.weight.id], atLimit)

        try assertRejected(fixture, .limitExceeded(.valueLength)) {
            try proposalData(entries: [["exerciseID": id, "sets": [["values": [value(fixture.weight, "0" + atLimit), value(fixture.reps, "10")]]]]])
        }
        // マルチバイト文字はUTF-8のバイト数で数える（"あ"は3バイト）
        let longUnit = String(repeating: "あ", count: 21) + "xx"
        XCTAssertEqual(longUnit.utf8.count, AIWorkoutProposalLimits.maxUnitBytes + 1)
        try assertRejected(fixture, .limitExceeded(.unitLength)) {
            try proposalData(entries: [["exerciseID": id, "sets": [["values": [value(fixture.weight, "60", unit: longUnit), value(fixture.reps, "10")]]]]])
        }
    }

    // 上限ちょうど（UTF-8で64バイト）の単位。"あ"は3バイト
    private let unitAtLimit = String(repeating: "あ", count: 21) + "x"

    private func makeMetrics(_ count: Int) -> [MetricDefinition] {
        (0..<count).map { MetricDefinition(name: "項目\($0)", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: $0) }
    }

    // 上限ちょうどの種目はカタログに入り、送った種目の正しい候補が上限で拒否されない
    func testCatalogSendsExercisesAtLimitsAndTheyAreRecordable() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(unitAtLimit.utf8.count, AIWorkoutProposalLimits.maxUnitBytes)
        let manyAtLimit = Exercise(name: "合成項目上限", metrics: makeMetrics(AIWorkoutProposalLimits.maxValuesPerSet))
        let longUnit = Exercise(name: "合成単位上限", metrics: [MetricDefinition(name: "量", unit: unitAtLimit, allowsDecimal: false, isRequired: true, sortOrder: 0)])
        for exercise in [manyAtLimit, longUnit] { fixture.context.insert(exercise) }
        try fixture.context.save()

        // リクエストを始めると、その時点のカタログがIDに固定される
        let request = try CoordinatedRequest(in: fixture.context)
        XCTAssertEqual(Set(request.catalog.exercises.map(\.id)), [fixture.exercise.id, manyAtLimit.id, longUnit.id])

        // 上限ちょうどの種目は候補として記録できる
        let allValues = sortedMetrics(manyAtLimit).map { value($0, "1") }
        let unitMetric = try XCTUnwrap(longUnit.metrics.first)
        let proposal = try AIWorkoutProposal.decode(from: proposalData(entries: [
            ["exerciseID": manyAtLimit.id.uuidString, "sets": [["values": allValues]]],
            ["exerciseID": longUnit.id.uuidString, "sets": [["values": [value(unitMetric, "3")]]]],
        ]))
        let review = try makeReview(fixture, proposal: proposal, request: request).review
        XCTAssertEqual(review.entries.count, 2)
    }

    // カタログ作成が上限超過の明示エラーになり、一部の種目だけのカタログも返らないことを確かめる
    private func assertCatalogOverLimit(
        _ fixture: Fixture,
        exerciseIDs: [UUID],
        items: Set<AIWorkoutProposalLimits.Item>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var catalog: AIWorkoutCatalog?
        XCTAssertThrowsError(catalog = try AIWorkoutCatalog.make(in: fixture.context), file: file, line: line) { error in
            // IDは実装と同じくuuidString順に並ぶ
            let expected = AIWorkoutProposalError.catalogExerciseOverLimit(exerciseIDs: exerciseIDs.sorted { $0.uuidString < $1.uuidString }, items: items)
            XCTAssertEqual(error as? AIWorkoutProposalError, expected, "\(error)", file: file, line: line)
            // メッセージには件数と超えた上限の値だけが入り、超えていない上限の説明は入らない
            let message = (error as? AIWorkoutProposalError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("\(exerciseIDs.count)件"), message, file: file, line: line)
            XCTAssertEqual(message.contains("\(AIWorkoutProposalLimits.maxValuesPerSet)個を超える"), items.contains(.valuesPerSet), message, file: file, line: line)
            XCTAssertEqual(message.contains("\(AIWorkoutProposalLimits.maxUnitBytes)バイトを超える"), items.contains(.unitLength), message, file: file, line: line)
        }
        XCTAssertNil(catalog, file: file, line: line)
        XCTAssertFalse(fixture.context.hasChanges, file: file, line: line)
    }

    // 正常な種目が複数あっても、有効な記録項目が上限+1個の種目が1つあれば一覧全体を失敗させる
    func testCatalogFailsWholeWhenOneExerciseHasTooManyMetrics() throws {
        let fixture = try makeFixture()
        _ = try addExercises(fixture, count: 2)
        let tooMany = Exercise(name: "合成項目超過", metrics: makeMetrics(AIWorkoutProposalLimits.maxValuesPerSet + 1))
        fixture.context.insert(tooMany)
        try fixture.context.save()

        assertCatalogOverLimit(fixture, exerciseIDs: [tooMany.id], items: [.valuesPerSet])
    }

    // 正常な種目が複数あっても、UTF-8で上限+1バイトの単位を持つ種目が1つあれば一覧全体を失敗させる
    func testCatalogFailsWholeWhenOneExerciseHasTooLongUnit() throws {
        let fixture = try makeFixture()
        _ = try addExercises(fixture, count: 2)
        let overUnit = unitAtLimit + "x"
        XCTAssertEqual(overUnit.utf8.count, AIWorkoutProposalLimits.maxUnitBytes + 1)
        let longUnit = Exercise(name: "合成単位超過", metrics: [
            MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0),
            MetricDefinition(name: "量", unit: overUnit, allowsDecimal: false, isRequired: false, sortOrder: 1),
        ])
        fixture.context.insert(longUnit)
        try fixture.context.save()

        assertCatalogOverLimit(fixture, exerciseIDs: [longUnit.id], items: [.unitLength])
    }

    // 種類の違う超過が別々の種目にあれば、両方のIDと両方の上限をまとめて返す
    func testCatalogReportsAllOverLimitExercisesAndItems() throws {
        let fixture = try makeFixture()
        _ = try addExercises(fixture, count: 2)
        let tooMany = Exercise(name: "合成項目超過", metrics: makeMetrics(AIWorkoutProposalLimits.maxValuesPerSet + 1))
        let longUnit = Exercise(name: "合成単位超過", metrics: [MetricDefinition(name: "量", unit: unitAtLimit + "x", allowsDecimal: false, isRequired: true, sortOrder: 0)])
        for exercise in [tooMany, longUnit] { fixture.context.insert(exercise) }
        try fixture.context.save()

        assertCatalogOverLimit(fixture, exerciseIDs: [tooMany.id, longUnit.id], items: [.valuesPerSet, .unitLength])
    }

    // 複数の正常な種目と並べても、上限ちょうど（16項目・64バイトの単位）の種目では一覧作成に成功する
    func testCatalogWithMultipleExercisesSucceedsAtExactLimits() throws {
        let fixture = try makeFixture()
        let others = try addExercises(fixture, count: 2)
        let manyAtLimit = Exercise(name: "合成項目上限", metrics: makeMetrics(AIWorkoutProposalLimits.maxValuesPerSet))
        let longUnit = Exercise(name: "合成単位上限", metrics: [
            MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0),
            MetricDefinition(name: "量", unit: unitAtLimit, allowsDecimal: false, isRequired: false, sortOrder: 1),
        ])
        for exercise in [manyAtLimit, longUnit] { fixture.context.insert(exercise) }
        try fixture.context.save()

        let catalog = try AIWorkoutCatalog.make(in: fixture.context)

        XCTAssertEqual(Set(catalog.exercises.map(\.id)), Set([fixture.exercise.id, manyAtLimit.id, longUnit.id] + others.map(\.id)))
        XCTAssertEqual(catalog.exercise(id: manyAtLimit.id)?.metrics.count, AIWorkoutProposalLimits.maxValuesPerSet)
        XCTAssertEqual(catalog.exercise(id: longUnit.id)?.metrics.map(\.unit), ["回", unitAtLimit])
    }

    func testRawResponseOverByteLimitIsRejectedBeforeParsing() throws {
        let fixture = try makeFixture()
        let base = try proposalData(entries: [["exerciseID": fixture.exercise.id.uuidString, "sets": standardSets(fixture)]])
        // JSONとして正しい候補を空白で埋めて、大きさだけで判定されることを確かめる
        let padded = { (size: Int) in base + Data(repeating: UInt8(ascii: " "), count: size - base.count) }

        XCTAssertNoThrow(try AIWorkoutProposal.decode(from: padded(AIWorkoutProposalLimits.maxResponseBytes)))
        try assertRejected(fixture, .limitExceeded(.responseSize)) { padded(AIWorkoutProposalLimits.maxResponseBytes + 1) }
        // JSONでもない巨大なデータも、解析エラー(malformed)ではなく大きさの上限で拒否する
        try assertRejected(fixture, .limitExceeded(.responseSize)) { Data(repeating: UInt8(ascii: "["), count: AIWorkoutProposalLimits.maxResponseBytes + 1) }
    }

    // バイト数の上限が他の上限と整合していること: 各上限いっぱいの候補を整形・\uXXXXエスケープ付きで書いても収まる
    func testWorstCaseProposalWithinCountLimitsFitsByteLimit() throws {
        let longestValue = "1234567890123456.123"
        XCTAssertEqual(longestValue.utf8.count, AIWorkoutProposalLimits.maxValueBytes)
        let unit = String(repeating: "あ", count: AIWorkoutProposalLimits.maxUnitBytes / 3)
        let set: [String: Any] = ["values": [randomValue(longestValue, unit: unit), randomValue(longestValue, unit: unit)]]
        let entries: [[String: Any]] = (0..<AIWorkoutProposalLimits.maxEntries).map { _ in
            ["exerciseID": UUID().uuidString, "sets": Array(repeating: set, count: AIWorkoutProposalLimits.maxSetsPerEntry)]
        }
        let pretty = try JSONSerialization.data(withJSONObject: ["kind": "createWorkout", "day": pastDay, "entries": entries], options: [.prettyPrinted])
        let escaped = Data(try XCTUnwrap(String(data: pretty, encoding: .utf8)).replacingOccurrences(of: "あ", with: "\\u3042").utf8)

        XCTAssertLessThanOrEqual(escaped.count, AIWorkoutProposalLimits.maxResponseBytes)
        let proposal = try AIWorkoutProposal.decode(from: escaped)
        XCTAssertEqual(proposal.entries.flatMap(\.sets).flatMap(\.values).count, AIWorkoutProposalLimits.maxTotalValues)
        XCTAssertEqual(proposal.entries.first?.sets.first?.values.first?.unit, unit)
    }

    // MARK: - 検証と確認用draft

    func testValidProposalBecomesPendingReviewWithoutTouchingStore() throws {
        let fixture = try makeFixture()
        let (request, review) = try makeReview(fixture)

        XCTAssertEqual(review.state, .pending)
        XCTAssertEqual(request.status, .reviewing)
        XCTAssertEqual(review.dayString, pastDay)
        XCTAssertEqual(review.entries.count, 1)
        let entry = try XCTUnwrap(review.entries.first)
        XCTAssertEqual(entry.exerciseID, fixture.exercise.id)
        XCTAssertEqual(entry.exerciseName, "合成種目A")
        XCTAssertEqual(entry.sets.count, 3)
        for set in entry.sets {
            XCTAssertEqual(set.values[fixture.weight.id], "60")
            XCTAssertEqual(set.values[fixture.reps.id], "10")
            XCTAssertNil(set.values[fixture.memo.id])
        }
        XCTAssertNil(review.validationMessage())
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture), 0)
    }

    func testRejectsUnsupportedKind() throws {
        let fixture = try makeFixture()
        try assertRejected(fixture, .unsupportedKind) {
            try proposalData(kind: "deleteWorkout", entries: [["exerciseID": fixture.exercise.id.uuidString, "sets": standardSets(fixture)]])
        }
    }

    func testRejectsInvalidAndFutureDays() throws {
        let fixture = try makeFixture()
        let id = fixture.exercise.id.uuidString
        for day in ["2026-02-30", "2026-1-15", "20260115", "2026-01-15T00:00:00", " 2026-01-15", "今日"] {
            try assertRejected(fixture, .invalidDay) {
                try proposalData(day: day, entries: [["exerciseID": id, "sets": standardSets(fixture)]])
            }
        }
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 23)))
        try assertRejected(fixture, .futureDay, now: now) {
            try proposalData(day: "2026-01-16", entries: [["exerciseID": id, "sets": standardSets(fixture)]])
        }
    }

    func testRejectsEmptyEntriesDuplicateExerciseAndEmptySets() throws {
        let fixture = try makeFixture()
        let id = fixture.exercise.id.uuidString
        try assertRejected(fixture, .emptyEntries) { try proposalData(entries: []) }
        try assertRejected(fixture, .duplicateExercise) {
            try proposalData(entries: [["exerciseID": id, "sets": standardSets(fixture)], ["exerciseID": id, "sets": standardSets(fixture)]])
        }
        try assertRejected(fixture, .emptySets) { try proposalData(entries: [["exerciseID": id, "sets": []]]) }
    }

    func testRejectsUnknownExerciseAndExerciseOutsideCatalog() throws {
        let fixture = try makeFixture()
        try assertRejected(fixture, .unknownExercise) {
            try proposalData(entries: [["exerciseID": UUID().uuidString, "sets": standardSets(fixture)]])
        }
        // カタログ送信（リクエスト開始）後に作られた種目は、AIへ送っていないため拒否する
        let request = try CoordinatedRequest(in: fixture.context)
        let later = Exercise(name: "合成種目B", metrics: [MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 0)])
        fixture.context.insert(later)
        try fixture.context.save()
        let laterMetric = try XCTUnwrap(later.metrics.first)
        try assertRejected(fixture, .unknownExercise, request: request) {
            try proposalData(entries: [["exerciseID": later.id.uuidString, "sets": [["values": [value(laterMetric, "5")]]]]])
        }
    }

    func testRejectsUnknownMetricInactiveMetricAndDuplicateMetric() throws {
        let fixture = try makeFixture()
        let id = fixture.exercise.id.uuidString
        let foreign: [String: Any] = ["metricID": UUID().uuidString, "value": "1", "unit": "kg"]
        try assertRejected(fixture, .unknownMetric) {
            try proposalData(entries: [["exerciseID": id, "sets": [["values": [value(fixture.weight, "60"), value(fixture.reps, "10"), foreign]]]]])
        }
        try assertRejected(fixture, .duplicateMetric) {
            try proposalData(entries: [["exerciseID": id, "sets": [["values": [value(fixture.weight, "60"), value(fixture.weight, "70"), value(fixture.reps, "10")]]]]])
        }
        // 別種目の項目IDを流用した候補も未知項目として拒否する
        let other = Exercise(name: "合成種目C", metrics: [MetricDefinition(name: "距離", unit: "km", allowsDecimal: true, isRequired: false, sortOrder: 0)])
        fixture.context.insert(other)
        try fixture.context.save()
        let otherMetric = try XCTUnwrap(other.metrics.first)
        try assertRejected(fixture, .unknownMetric) {
            try proposalData(entries: [["exerciseID": id, "sets": [["values": [value(fixture.weight, "60"), value(fixture.reps, "10"), value(otherMetric, "1")]]]]])
        }
    }

    func testRejectsUnitMismatchWithoutConversion() throws {
        let fixture = try makeFixture()
        try assertRejected(fixture, .unitMismatch) {
            try proposalData(entries: [["exerciseID": fixture.exercise.id.uuidString, "sets": [["values": [value(fixture.weight, "135", unit: "lb"), value(fixture.reps, "10")]]]]])
        }
    }

    func testRejectsInvalidValuesWithoutRounding() throws {
        let fixture = try makeFixture()
        let id = fixture.exercise.id.uuidString
        let invalid: [(MetricDefinition, String)] = [
            (fixture.weight, "-1"), (fixture.weight, "60.1234"), (fixture.weight, ""), (fixture.weight, " 60"),
            (fixture.weight, "1e2"), (fixture.weight, "６０"), (fixture.reps, "10.5"), (fixture.reps, "abc"),
        ]
        for (metric, text) in invalid {
            let other = metric === fixture.weight ? value(fixture.reps, "10") : value(fixture.weight, "60")
            try assertRejected(fixture, .invalidValue) {
                try proposalData(entries: [["exerciseID": id, "sets": [["values": [value(metric, text), other]]]]])
            }
        }
    }

    func testRejectsMissingRequiredValueButAllowsOmittedOptionalValue() throws {
        let fixture = try makeFixture()
        let id = fixture.exercise.id.uuidString
        try assertRejected(fixture, .missingRequiredValue) {
            try proposalData(entries: [["exerciseID": id, "sets": [["values": [value(fixture.weight, "60")]]]]])
        }
        let proposal = try AIWorkoutProposal.decode(from: proposalData(entries: [["exerciseID": id, "sets": [["values": [value(fixture.weight, "0"), value(fixture.reps, "0"), value(fixture.memo, "2")]]]]]))
        let review = try makeReview(fixture, proposal: proposal).review
        XCTAssertEqual(review.entries.first?.sets.first?.values[fixture.memo.id], "2")
    }

    func testRejectsArchivedOrChangedDefinitionAfterCatalogWasSent() throws {
        let mutations: [(Exercise, ModelContext) throws -> Void] = [
            { exercise, context in exercise.isArchived = true; try context.save() },
            { exercise, context in exercise.name = "合成種目A改"; try context.save() },
            { exercise, context in exercise.metrics.first(where: { $0.name == "回数" })?.unit = "レップ"; try context.save() },
            { exercise, context in exercise.metrics.first(where: { $0.name == "補助" })?.isRequired = true; try context.save() },
            { exercise, context in exercise.metrics.first(where: { $0.name == "補助" })?.isActive = false; try context.save() },
            { exercise, context in context.delete(exercise); try context.save() },
        ]
        for mutate in mutations {
            let fixture = try makeFixture()
            let request = try CoordinatedRequest(in: fixture.context)
            let other = ModelContext(fixture.container)
            let exerciseID = fixture.exercise.id
            let persisted = try XCTUnwrap(other.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID })).first)
            try mutate(persisted, other)
            try assertRejected(fixture, .staleDefinition, request: request) {
                try proposalData(entries: [["exerciseID": exerciseID.uuidString, "sets": standardSets(fixture)]])
            }
        }
    }

    func testValidationRefusesContextWithUnsavedChanges() throws {
        let fixture = try makeFixture()
        let request = try CoordinatedRequest(in: fixture.context)
        let proposal = try standardProposal(fixture)
        fixture.exercise.name = "未保存の名前"
        XCTAssertThrowsError(try request.review(proposal, in: fixture.context, calendar: calendar)) { error in
            XCTAssertEqual(error as? AIWorkoutProposalError, .unsavedContext)
        }
        XCTAssertEqual(request.status, .awaitingResponse)
        XCTAssertEqual(fixture.exercise.name, "未保存の名前")
    }

    // MARK: - 承認・キャンセル・二重保存
    // 承認はすべて coordinator.approve を通す（review.approve は fileprivate でテストから呼べない）

    func testApproveSavesThroughV1BoundaryExactlyOnce() throws {
        let fixture = try makeFixture()
        let (request, review) = try makeReview(fixture)

        let workout = try request.approve(in: fixture.context)

        XCTAssertEqual(review.state, .saved(workoutID: workout.id))
        XCTAssertEqual(request.status, .saved(workoutID: workout.id))
        let saved = try XCTUnwrap(ModelContext(fixture.container).fetch(FetchDescriptor<Workout>()).first)
        XCTAssertEqual(saved.id, workout.id)
        XCTAssertEqual(saved.day, pastDay)
        let record = try XCTUnwrap(saved.records.first)
        XCTAssertEqual(record.exerciseID, fixture.exercise.id)
        XCTAssertEqual(record.sets.count, 3)
        for set in record.sets {
            XCTAssertEqual(set.values.first { $0.metricID == fixture.weight.id }?.scaledValue, 60_000)
            XCTAssertEqual(set.values.first { $0.metricID == fixture.reps.id }?.scaledValue, 10_000)
            let memo = try XCTUnwrap(set.values.first { $0.metricID == fixture.memo.id })
            XCTAssertNil(memo.scaledValue)
        }

        assertCoordinatorError(.alreadySaved(workoutID: workout.id)) { try request.approve(in: fixture.context) }
        XCTAssertEqual(review.state, .saved(workoutID: workout.id))
        XCTAssertEqual(try workoutCount(fixture), 1)
    }

    func testReentrantApproveDuringSaveIsRejected() throws {
        let fixture = try makeFixture()
        let (request, review) = try makeReview(fixture)
        var nestedError: Error?

        try request.approve(in: fixture.context) { context in
            // 保存処理中の連打を想定して、persistの中から再度承認する
            XCTAssertEqual(review.state, .saving)
            XCTAssertThrowsError(try request.approve(in: context)) { nestedError = $0 }
            try context.save()
        }

        XCTAssertEqual(nestedError as? AIWorkoutProposalReviewError, .inProgress)
        XCTAssertEqual(try workoutCount(fixture), 1)
    }

    // reviewの cancel は確認画面から直接呼べる（保存はしないため公開している）。キャンセル後は coordinator からの承認も通らない
    func testCancelLeavesStoreUnchangedAndBlocksLaterApproval() throws {
        let fixture = try makeFixture()
        let (request, review) = try makeReview(fixture)

        try review.cancel()

        XCTAssertEqual(review.state, .cancelled)
        XCTAssertEqual(request.status, .cancelled)
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture), 0)
        assertCoordinatorError(.cancelled) { try request.approve(in: fixture.context) }
        XCTAssertThrowsError(try review.setValue("70", exerciseID: fixture.exercise.id, setID: review.entries[0].sets[0].id, metricID: fixture.weight.id)) { error in
            XCTAssertEqual(error as? AIWorkoutProposalReviewError, .notEditable)
        }
        XCTAssertEqual(try workoutCount(fixture), 0)
    }

    func testCancelAfterSaveIsRejectedAndKeepsSavedState() throws {
        let fixture = try makeFixture()
        let (request, review) = try makeReview(fixture)
        let workout = try request.approve(in: fixture.context)

        XCTAssertThrowsError(try review.cancel()) { error in
            XCTAssertEqual(error as? AIWorkoutProposalReviewError, .notEditable)
        }
        XCTAssertEqual(review.state, .saved(workoutID: workout.id))
        XCTAssertEqual(request.status, .saved(workoutID: workout.id))
        XCTAssertEqual(try workoutCount(fixture), 1)
    }

    // 確認画面での値の修正（reviewの setValue）は公開したまま。修正後の値が coordinator 経由の承認で保存される
    func testEditedValuesAreRevalidatedAndSaved() throws {
        let fixture = try makeFixture()
        let (request, review) = try makeReview(fixture)
        let setIDs = review.entries[0].sets.map(\.id)

        try review.setValue("62.5", exerciseID: fixture.exercise.id, setID: setIDs[1], metricID: fixture.weight.id)
        try review.setValue("3", exerciseID: fixture.exercise.id, setID: setIDs[2], metricID: fixture.memo.id)
        XCTAssertNil(review.validationMessage())
        let workout = try request.approve(in: fixture.context)

        let saved = try XCTUnwrap(ModelContext(fixture.container).fetch(FetchDescriptor<Workout>()).first { $0.id == workout.id })
        let sets = try XCTUnwrap(saved.records.first?.sets.sorted { $0.sortOrder < $1.sortOrder })
        XCTAssertEqual(sets.map { set in set.values.first { $0.metricID == fixture.weight.id }?.scaledValue }, [60_000, 62_500, 60_000])
        XCTAssertEqual(sets[2].values.first { $0.metricID == fixture.memo.id }?.scaledValue, 3_000)
    }

    func testInvalidEditIsRejectedOnApprovalAndCanBeFixed() throws {
        let fixture = try makeFixture()
        let (request, review) = try makeReview(fixture)
        let setID = review.entries[0].sets[0].id

        for invalid in ["-5", "10.5", ""] {
            try review.setValue(invalid, exerciseID: fixture.exercise.id, setID: setID, metricID: fixture.reps.id)
            XCTAssertNotNil(review.validationMessage())
            XCTAssertThrowsError(try request.approve(in: fixture.context)) { error in
                guard case WorkoutCreationV1Error.invalidEntries = error else { return XCTFail("invalidEntriesで拒否されること: \(error)") }
            }
            XCTAssertEqual(review.state, .pending)
            XCTAssertEqual(request.status, .reviewing)
            XCTAssertFalse(fixture.context.hasChanges)
            XCTAssertEqual(try workoutCount(fixture), 0)
        }

        try review.setValue("8", exerciseID: fixture.exercise.id, setID: setID, metricID: fixture.reps.id)
        try request.approve(in: fixture.context)
        XCTAssertEqual(try workoutCount(fixture), 1)
    }

    func testEditingUnknownTargetsIsRejected() throws {
        let fixture = try makeFixture()
        let review = try makeReview(fixture).review
        let setID = review.entries[0].sets[0].id
        let attempts: [(UUID, UUID, UUID)] = [
            (UUID(), setID, fixture.weight.id),
            (fixture.exercise.id, UUID(), fixture.weight.id),
            (fixture.exercise.id, setID, UUID()),
        ]
        for (exerciseID, targetSetID, metricID) in attempts {
            XCTAssertThrowsError(try review.setValue("1", exerciseID: exerciseID, setID: targetSetID, metricID: metricID)) { error in
                XCTAssertEqual(error as? AIWorkoutProposalReviewError, .unknownField)
            }
        }
        XCTAssertEqual(review.entries[0].sets[0].values[fixture.weight.id], "60")
    }

    func testDefinitionChangeDuringReviewRejectsApproval() throws {
        let fixture = try makeFixture()
        let (request, review) = try makeReview(fixture)
        let other = ModelContext(fixture.container)
        let exerciseID = fixture.exercise.id
        let persisted = try XCTUnwrap(other.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID })).first)
        persisted.metrics.append(MetricDefinition(name: "距離", unit: "m", allowsDecimal: true, isRequired: true, sortOrder: 3))
        try other.save()

        XCTAssertThrowsError(try request.approve(in: fixture.context)) { error in
            guard case WorkoutCreationV1Error.staleDefinition = error else { return XCTFail("staleDefinitionで拒否されること: \(error)") }
        }
        XCTAssertEqual(review.state, .pending)
        XCTAssertEqual(try workoutCount(fixture), 0)
    }

    func testPersistFailureRollsBackAndAllowsSingleRetry() throws {
        let fixture = try makeFixture()
        let (request, review) = try makeReview(fixture)
        enum InjectedPersistenceError: Error { case expected }

        XCTAssertThrowsError(try request.approve(in: fixture.context) { _ in throw InjectedPersistenceError.expected }) { error in
            guard case InjectedPersistenceError.expected = error else { return XCTFail("注入した永続化エラーが返ること: \(error)") }
        }
        XCTAssertEqual(review.state, .pending)
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture), 0)

        let workout = try request.approve(in: fixture.context)
        assertCoordinatorError(.alreadySaved(workoutID: workout.id)) { try request.approve(in: fixture.context) }
        XCTAssertEqual(try workoutCount(fixture), 1)
    }

    // MARK: - リクエスト単位の一元管理（coordinator）

    private func standardData(_ fixture: Fixture, day: String? = nil) throws -> Data {
        try proposalData(day: day, entries: [["exerciseID": fixture.exercise.id.uuidString, "sets": standardSets(fixture)]])
    }

    private func coordinatedReview(_ coordinator: AIWorkoutProposalCoordinator, _ requestID: UUID, _ fixture: Fixture, data: Data) throws -> AIWorkoutProposalReview {
        try coordinator.review(for: requestID, proposal: AIWorkoutProposal.decode(from: data), in: fixture.context, calendar: calendar)
    }

    private func assertCoordinatorError<T>(_ expected: AIWorkoutProposalCoordinatorError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? AIWorkoutProposalCoordinatorError, expected, "\(error)", file: file, line: line)
        }
    }

    // 同じIDに同じ応答が再送されても同じreviewを返し、保存成功後は再生成も再承認もできない
    func testCoordinatorReturnsSameReviewAndBlocksResaveForSameRequest() throws {
        let fixture = try makeFixture()
        let coordinator = AIWorkoutProposalCoordinator()
        let request = try coordinator.beginRequest(in: fixture.context)
        XCTAssertEqual(coordinator.status(of: request.id), .awaitingResponse)
        let data = try standardData(fixture)

        let first = try coordinatedReview(coordinator, request.id, fixture, data: data)
        // 確認中の修正は、同じ応答が再送されても失われない
        try first.setValue("62.5", exerciseID: fixture.exercise.id, setID: first.entries[0].sets[0].id, metricID: fixture.weight.id)
        let resent = try coordinatedReview(coordinator, request.id, fixture, data: data)
        XCTAssertTrue(first === resent)
        XCTAssertEqual(resent.entries[0].sets[0].values[fixture.weight.id], "62.5")
        XCTAssertEqual(coordinator.status(of: request.id), .reviewing)

        let workout = try coordinator.approve(request.id, in: fixture.context)
        XCTAssertEqual(coordinator.status(of: request.id), .saved(workoutID: workout.id))

        assertCoordinatorError(.alreadySaved(workoutID: workout.id)) { try coordinatedReview(coordinator, request.id, fixture, data: data) }
        assertCoordinatorError(.alreadySaved(workoutID: workout.id)) { try coordinator.approve(request.id, in: fixture.context) }
        assertCoordinatorError(.alreadySaved(workoutID: workout.id)) { try coordinator.cancel(request.id) }
        XCTAssertEqual(try workoutCount(fixture), 1)
    }

    // 異なるリクエストIDは、応答の内容が同じでも別の依頼として独立に記録できる
    func testCoordinatorRecordsSameContentIndependentlyForDifferentRequests() throws {
        let fixture = try makeFixture()
        let coordinator = AIWorkoutProposalCoordinator()
        let data = try standardData(fixture)
        let firstRequest = try coordinator.beginRequest(in: fixture.context)
        let secondRequest = try coordinator.beginRequest(in: fixture.context)
        XCTAssertNotEqual(firstRequest.id, secondRequest.id)

        let firstReview = try coordinatedReview(coordinator, firstRequest.id, fixture, data: data)
        let secondReview = try coordinatedReview(coordinator, secondRequest.id, fixture, data: data)
        XCTAssertFalse(firstReview === secondReview)

        let firstWorkout = try coordinator.approve(firstRequest.id, in: fixture.context)
        XCTAssertEqual(coordinator.status(of: secondRequest.id), .reviewing)
        let secondWorkout = try coordinator.approve(secondRequest.id, in: fixture.context)

        XCTAssertNotEqual(firstWorkout.id, secondWorkout.id)
        XCTAssertEqual(try workoutCount(fixture), 2)
    }

    // 同じIDに異なる応答が渡されたら、reviewの作成前・作成後・検証失敗後のいずれでも拒否する
    func testCoordinatorRejectsDifferentResponseForSameRequest() throws {
        let fixture = try makeFixture()
        let coordinator = AIWorkoutProposalCoordinator()
        let data = try standardData(fixture)
        let otherDay = try standardData(fixture, day: "2026-01-14")

        // reviewの作成後
        let request = try coordinator.beginRequest(in: fixture.context)
        let review = try coordinatedReview(coordinator, request.id, fixture, data: data)
        assertCoordinatorError(.conflictingResponse) { try coordinatedReview(coordinator, request.id, fixture, data: otherDay) }
        XCTAssertTrue(try coordinatedReview(coordinator, request.id, fixture, data: data) === review)

        // 検証に失敗した後も、最初の応答に固定されて差し替えられない
        let failed = try coordinator.beginRequest(in: fixture.context)
        let mismatched = try proposalData(entries: [["exerciseID": fixture.exercise.id.uuidString, "sets": [["values": [value(fixture.weight, "135", unit: "lb"), value(fixture.reps, "10")]]]]])
        XCTAssertThrowsError(try coordinatedReview(coordinator, failed.id, fixture, data: mismatched)) { error in
            XCTAssertEqual(error as? AIWorkoutProposalError, .unitMismatch)
        }
        XCTAssertEqual(coordinator.status(of: failed.id), .awaitingResponse)
        assertCoordinatorError(.conflictingResponse) { try coordinatedReview(coordinator, failed.id, fixture, data: data) }

        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture), 0)
    }

    // 検証の失敗後は、同じ応答で試し直せる
    func testCoordinatorAllowsRetryWithSameResponseAfterValidationFailure() throws {
        let fixture = try makeFixture()
        let coordinator = AIWorkoutProposalCoordinator()
        let request = try coordinator.beginRequest(in: fixture.context)
        let data = try standardData(fixture)

        // 実施日(2026-01-15)より前の「今日」で検証して未来日として失敗させ、その後に本来の今日で試し直す
        let earlier = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 14, hour: 12)))
        XCTAssertThrowsError(try coordinator.review(for: request.id, proposal: AIWorkoutProposal.decode(from: data), in: fixture.context, calendar: calendar, now: earlier)) { error in
            XCTAssertEqual(error as? AIWorkoutProposalError, .futureDay)
        }
        XCTAssertEqual(coordinator.status(of: request.id), .awaitingResponse)

        let review = try coordinatedReview(coordinator, request.id, fixture, data: data)
        XCTAssertEqual(review.state, .pending)
        _ = try coordinator.approve(request.id, in: fixture.context)
        XCTAssertEqual(try workoutCount(fixture), 1)
    }

    // 保存の失敗後は確認中に戻って同じreviewで再試行でき、成功は1回だけ
    func testCoordinatorPersistFailureAllowsRetryAndSavesOnce() throws {
        let fixture = try makeFixture()
        let coordinator = AIWorkoutProposalCoordinator()
        let request = try coordinator.beginRequest(in: fixture.context)
        let data = try standardData(fixture)
        let review = try coordinatedReview(coordinator, request.id, fixture, data: data)
        enum InjectedPersistenceError: Error { case expected }

        XCTAssertThrowsError(try coordinator.approve(request.id, in: fixture.context) { _ in throw InjectedPersistenceError.expected }) { error in
            guard case InjectedPersistenceError.expected = error else { return XCTFail("注入した永続化エラーが返ること: \(error)") }
        }
        XCTAssertEqual(coordinator.status(of: request.id), .reviewing)
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture), 0)
        // 失敗後に再送されても作り直さない
        XCTAssertTrue(try coordinatedReview(coordinator, request.id, fixture, data: data) === review)

        let workout = try coordinator.approve(request.id, in: fixture.context)
        XCTAssertEqual(coordinator.status(of: request.id), .saved(workoutID: workout.id))
        assertCoordinatorError(.alreadySaved(workoutID: workout.id)) { try coordinator.approve(request.id, in: fixture.context) }
        XCTAssertEqual(try workoutCount(fixture), 1)
    }

    // 保存処理中の連打・再送は、同じreviewのまま inProgress で拒否される
    func testCoordinatorReentrantApproveAndResendDuringSave() throws {
        let fixture = try makeFixture()
        let coordinator = AIWorkoutProposalCoordinator()
        let request = try coordinator.beginRequest(in: fixture.context)
        let data = try standardData(fixture)
        let review = try coordinatedReview(coordinator, request.id, fixture, data: data)
        var nestedError: Error?
        var nestedReview: AIWorkoutProposalReview?

        _ = try coordinator.approve(request.id, in: fixture.context) { context in
            nestedReview = try self.coordinatedReview(coordinator, request.id, fixture, data: data)
            XCTAssertThrowsError(try coordinator.approve(request.id, in: context)) { nestedError = $0 }
            XCTAssertThrowsError(try coordinator.cancel(request.id)) { error in
                XCTAssertEqual(error as? AIWorkoutProposalReviewError, .notEditable)
            }
            try context.save()
        }

        XCTAssertTrue(nestedReview === review)
        XCTAssertEqual(nestedError as? AIWorkoutProposalReviewError, .inProgress)
        XCTAssertEqual(try workoutCount(fixture), 1)
    }

    // キャンセルしたIDは、応答の前後どちらでも終了し、後からの応答・承認を受け付けない
    func testCoordinatorCancelEndsRequestBeforeAndAfterResponse() throws {
        let fixture = try makeFixture()
        let coordinator = AIWorkoutProposalCoordinator()
        let data = try standardData(fixture)

        // 応答前のキャンセル
        let early = try coordinator.beginRequest(in: fixture.context)
        try coordinator.cancel(early.id)
        XCTAssertEqual(coordinator.status(of: early.id), .cancelled)
        assertCoordinatorError(.cancelled) { try coordinatedReview(coordinator, early.id, fixture, data: data) }
        assertCoordinatorError(.cancelled) { try coordinator.approve(early.id, in: fixture.context) }

        // 確認中のキャンセル。何度呼んでもよい
        let late = try coordinator.beginRequest(in: fixture.context)
        let review = try coordinatedReview(coordinator, late.id, fixture, data: data)
        try coordinator.cancel(late.id)
        try coordinator.cancel(late.id)
        XCTAssertEqual(review.state, .cancelled)
        XCTAssertEqual(coordinator.status(of: late.id), .cancelled)
        assertCoordinatorError(.cancelled) { try coordinatedReview(coordinator, late.id, fixture, data: data) }
        assertCoordinatorError(.cancelled) { try coordinator.approve(late.id, in: fixture.context) }

        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture), 0)
    }

    // リクエスト後に別contextで定義が変わったら、review作成時・承認時のどちらでも保存しない。
    // 再試行しても通らないが、キャンセルしてそのIDを終了させることはできる
    func testCoordinatorDefinitionConflictBlocksSaveAndCanBeCancelled() throws {
        let changeUnit: (Fixture) throws -> Void = { fixture in
            let (persisted, other) = try self.fetchInOtherContext(fixture)
            let repsID = fixture.reps.id
            persisted.metrics.first(where: { $0.id == repsID })?.unit = "レップ"
            try other.save()
        }

        // review作成前に変わった場合: IDに固定されたカタログと食い違うので、同じ応答で試し直しても拒否される
        let before = try makeFixture()
        let beforeCoordinator = AIWorkoutProposalCoordinator()
        let beforeRequest = try beforeCoordinator.beginRequest(in: before.context)
        try changeUnit(before)
        let data = try standardData(before)
        for _ in 0..<2 {
            XCTAssertThrowsError(try coordinatedReview(beforeCoordinator, beforeRequest.id, before, data: data)) { error in
                XCTAssertEqual(error as? AIWorkoutProposalError, .staleDefinition)
            }
        }
        try beforeCoordinator.cancel(beforeRequest.id)
        XCTAssertEqual(beforeCoordinator.status(of: beforeRequest.id), .cancelled)
        XCTAssertEqual(try workoutCount(before), 0)

        // 確認中に変わった場合: 承認は拒否され、確認中のまま残る
        let during = try makeFixture()
        let duringCoordinator = AIWorkoutProposalCoordinator()
        let duringRequest = try duringCoordinator.beginRequest(in: during.context)
        _ = try coordinatedReview(duringCoordinator, duringRequest.id, during, data: standardData(during))
        try changeUnit(during)
        XCTAssertThrowsError(try duringCoordinator.approve(duringRequest.id, in: during.context)) { error in
            guard case WorkoutCreationV1Error.staleDefinition = error else { return XCTFail("staleDefinitionで拒否されること: \(error)") }
        }
        XCTAssertEqual(duringCoordinator.status(of: duringRequest.id), .reviewing)
        try duringCoordinator.cancel(duringRequest.id)
        XCTAssertEqual(duringCoordinator.status(of: duringRequest.id), .cancelled)
        XCTAssertEqual(try workoutCount(during), 0)
    }

    // 発行していないID・reviewのないIDは拒否する。別のcoordinatorのIDも知らないIDとして扱う（管理は共有されない）
    func testCoordinatorRejectsUnknownRequestAndApprovalWithoutReview() throws {
        let fixture = try makeFixture()
        let coordinator = AIWorkoutProposalCoordinator()
        let data = try standardData(fixture)
        let unknown = UUID()

        XCTAssertNil(coordinator.status(of: unknown))
        assertCoordinatorError(.unknownRequest) { try coordinatedReview(coordinator, unknown, fixture, data: data) }
        assertCoordinatorError(.unknownRequest) { try coordinator.approve(unknown, in: fixture.context) }
        assertCoordinatorError(.unknownRequest) { try coordinator.cancel(unknown) }

        let request = try coordinator.beginRequest(in: fixture.context)
        assertCoordinatorError(.noReview) { try coordinator.approve(request.id, in: fixture.context) }
        assertCoordinatorError(.unknownRequest) { try coordinatedReview(AIWorkoutProposalCoordinator(), request.id, fixture, data: data) }
        XCTAssertEqual(try workoutCount(fixture), 0)
    }

    // reviewの承認は coordinator.approve からしかできない（review.approve は fileprivate）。
    // 外から直接呼べる review.cancel の結果は coordinator の状態に反映され、そのIDでは作り直しも承認もできない
    func testCoordinatorTreatsDirectReviewCancelAsCancelled() throws {
        let fixture = try makeFixture()
        let coordinator = AIWorkoutProposalCoordinator()
        let request = try coordinator.beginRequest(in: fixture.context)
        let data = try standardData(fixture)
        let review = try coordinatedReview(coordinator, request.id, fixture, data: data)

        try review.cancel()

        XCTAssertEqual(coordinator.status(of: request.id), .cancelled)
        assertCoordinatorError(.cancelled) { try coordinatedReview(coordinator, request.id, fixture, data: data) }
        assertCoordinatorError(.cancelled) { try coordinator.approve(request.id, in: fixture.context) }
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture), 0)
    }

    // MARK: - リクエストとstore（container）の結び付き

    // fixtureとは別のin-memory containerに、種目・項目のIDと定義がまったく同じ合成種目を作る。
    // 定義の比較だけでは見分けられない「別のstore」を用意して、containerの取り違えを確かめるため
    private func makeTwinFixture(of fixture: Fixture) throws -> Fixture {
        let schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let configuration = ModelConfiguration("AIWorkoutProposalTwinMemory-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let twinMetrics = [fixture.weight, fixture.reps, fixture.memo].map { source in
            let metric = MetricDefinition(name: source.name, unit: source.unit, allowsDecimal: source.allowsDecimal, isRequired: source.isRequired, sortOrder: source.sortOrder)
            metric.id = source.id
            return metric
        }
        let exercise = Exercise(name: fixture.exercise.name, metrics: twinMetrics)
        exercise.id = fixture.exercise.id
        context.insert(exercise)
        try context.save()
        return Fixture(container: container, context: context, exercise: exercise, weight: twinMetrics[0], reps: twinMetrics[1], memo: twinMetrics[2])
    }

    // 前提: 2つのstoreは別のcontainerで、どちらから作ってもカタログは同じ（定義の比較では取り違えに気付けない）。
    // 前提が崩れたら、containerの検査ではなく定義の食い違いで拒否されてしまうので、黙って通さず失敗させる
    private func assertTwinIsIndistinguishableByDefinition(_ fixture: Fixture, _ twin: Fixture, catalog: AIWorkoutCatalog, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(fixture.container === twin.container, "前提: 別のcontainerであること", file: file, line: line)
        XCTAssertEqual(twin.exercise.id, fixture.exercise.id, file: file, line: line)
        XCTAssertEqual(try AIWorkoutCatalog.make(in: twin.context), catalog, "前提: 別storeのカタログが同じ内容であること", file: file, line: line)
    }

    // 別のstoreのcontextを渡したときに、他のケース（未発行ID・応答の食い違い・保存済み・review未作成など）で代用されず、
    // 明示エラー storeMismatch で拒否されることを確かめる
    private func assertRejectedAsDifferentStore<T>(file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), "リクエストを始めたstoreとは別のstoreのcontextを拒否すること", file: file, line: line) { error in
            XCTAssertEqual(error as? AIWorkoutProposalCoordinatorError, .storeMismatch, "\(error)", file: file, line: line)
        }
        XCTAssertFalse((AIWorkoutProposalCoordinatorError.storeMismatch.errorDescription ?? "").isEmpty, file: file, line: line)
    }

    // beginRequestとは別のstoreのcontextでreviewを求めたら、IDと定義が同じでも拒否し、reviewを作らない。
    // 拒否の後も、リクエストを始めたstoreでは同じ応答から通常どおりreviewを作って保存できる
    func testCoordinatorRejectsReviewInDifferentStoreWithSameIDs() throws {
        let fixture = try makeFixture()
        let twin = try makeTwinFixture(of: fixture)
        let coordinator = AIWorkoutProposalCoordinator()
        let request = try coordinator.beginRequest(in: fixture.context)
        try assertTwinIsIndistinguishableByDefinition(fixture, twin, catalog: request.catalog)
        let data = try standardData(fixture)

        assertRejectedAsDifferentStore { try coordinatedReview(coordinator, request.id, twin, data: data) }

        // 提案（review）は作られず、どちらのstoreにも何も挿入・保存されない
        XCTAssertEqual(coordinator.status(of: request.id), .awaitingResponse)
        XCTAssertFalse(twin.context.hasChanges)
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try workoutCount(twin), 0)
        XCTAssertEqual(try workoutCount(fixture), 0)
        // 承認もreview未作成のまま拒否される（別storeで作られたreviewが残っていない）
        assertCoordinatorError(.noReview) { try coordinator.approve(request.id, in: fixture.context) }

        // 正しいstoreでは同じ応答で試し直せ、保存先もそのstoreだけになる
        let review = try coordinatedReview(coordinator, request.id, fixture, data: data)
        XCTAssertEqual(review.state, .pending)
        let workout = try coordinator.approve(request.id, in: fixture.context)
        XCTAssertEqual(coordinator.status(of: request.id), .saved(workoutID: workout.id))
        XCTAssertEqual(try workoutCount(fixture), 1)
        XCTAssertEqual(try workoutCount(twin), 0)
    }

    // review作成後に別のstoreのcontextで承認しようとしたら、IDと定義が同じでも拒否し、どちらのstoreにも保存しない。
    // reviewは確認中のまま残り、リクエストを始めたstoreでは1回だけ保存できる
    func testCoordinatorRejectsApprovalInDifferentStoreWithSameIDs() throws {
        let fixture = try makeFixture()
        let twin = try makeTwinFixture(of: fixture)
        let coordinator = AIWorkoutProposalCoordinator()
        let request = try coordinator.beginRequest(in: fixture.context)
        try assertTwinIsIndistinguishableByDefinition(fixture, twin, catalog: request.catalog)
        let review = try coordinatedReview(coordinator, request.id, fixture, data: standardData(fixture))

        // 保存処理(persist)まで進んだら取り違えを見逃しているので、呼ばれたこと自体を記録する
        var persistCalled = false
        assertRejectedAsDifferentStore {
            try coordinator.approve(request.id, in: twin.context) { context in
                persistCalled = true
                try context.save()
            }
        }

        XCTAssertFalse(persistCalled, "別storeへの保存処理を始めないこと")
        XCTAssertEqual(review.state, .pending)
        XCTAssertEqual(coordinator.status(of: request.id), .reviewing)
        XCTAssertFalse(twin.context.hasChanges)
        XCTAssertEqual(try workoutCount(twin), 0)
        XCTAssertEqual(try workoutCount(fixture), 0)

        // 正しいstoreでは保存でき、別storeには何も残らない
        let workout = try coordinator.approve(request.id, in: fixture.context)
        XCTAssertEqual(coordinator.status(of: request.id), .saved(workoutID: workout.id))
        XCTAssertEqual(try workoutCount(fixture), 1)
        XCTAssertEqual(try workoutCount(twin), 0)
        // 保存後に別storeから承認しても拒否され、二重に保存されない
        // （containerの照合は状態の確認より先に行うので、保存済みでも storeMismatch になる）
        assertRejectedAsDifferentStore { try coordinator.approve(request.id, in: twin.context) }
        XCTAssertEqual(try workoutCount(twin), 0)
    }

    // 同じcontainerであれば、beginRequest・review・approveをそれぞれ別のcontextで行ってもよい。
    // 未保存の変更があるcontextを拒否する既存の規則は、同じcontainerの別contextでもそのまま働く
    func testCoordinatorAllowsDifferentContextsOfSameContainerAndKeepsDirtyGuard() throws {
        let fixture = try makeFixture()
        let coordinator = AIWorkoutProposalCoordinator()
        let request = try coordinator.beginRequest(in: fixture.context)
        let proposal = try AIWorkoutProposal.decode(from: standardData(fixture))

        // 未保存の変更がある別context（同じcontainer）では、review作成を unsavedContext で拒否する
        let dirtyReviewContext = ModelContext(fixture.container)
        dirtyReviewContext.insert(Exercise(name: "合成未保存種目", metrics: []))
        XCTAssertThrowsError(try coordinator.review(for: request.id, proposal: proposal, in: dirtyReviewContext, calendar: calendar)) { error in
            XCTAssertEqual(error as? AIWorkoutProposalError, .unsavedContext, "\(error)")
        }
        XCTAssertEqual(coordinator.status(of: request.id), .awaitingResponse)

        // 未保存の変更がない別context（同じcontainer）では、reviewを作れる
        let reviewContext = ModelContext(fixture.container)
        let review = try coordinator.review(for: request.id, proposal: proposal, in: reviewContext, calendar: calendar)
        XCTAssertEqual(review.state, .pending)
        XCTAssertTrue(try coordinator.review(for: request.id, proposal: proposal, in: fixture.context, calendar: calendar) === review)

        // 未保存の変更がある別context（同じcontainer）では、承認をV1保存境界の unsavedContext で拒否する
        let dirtyApproveContext = ModelContext(fixture.container)
        dirtyApproveContext.insert(Exercise(name: "合成未保存種目", metrics: []))
        XCTAssertThrowsError(try coordinator.approve(request.id, in: dirtyApproveContext)) { error in
            guard case WorkoutCreationV1Error.unsavedContext = error else { return XCTFail("unsavedContextで拒否されること: \(error)") }
        }
        XCTAssertEqual(review.state, .pending)
        XCTAssertEqual(try workoutCount(fixture), 0)

        // 未保存の変更がない3つ目のcontext（同じcontainer）で承認でき、1件だけ保存される
        let approveContext = ModelContext(fixture.container)
        let workout = try coordinator.approve(request.id, in: approveContext)
        XCTAssertEqual(coordinator.status(of: request.id), .saved(workoutID: workout.id))
        XCTAssertEqual(try workoutCount(fixture), 1)
        XCTAssertFalse(fixture.context.hasChanges)
    }

    // MARK: - coordinatorを迂回できないことと、その範囲
    //
    // 受け入れ条件はコンパイルで表す: AIWorkoutProposalValidation.makeReview と AIWorkoutProposalReview.approve は
    // fileprivate なので、@testable import していてもこのテストファイル（や UI のファイル）から呼ぶとコンパイルエラーになる。
    // そのため「coordinatorを通さずにreviewを作る・承認する」テストはもう書けず、以下では公開API（coordinator）だけで
    // 二重作成と別storeの拒否を確かめる。
    // 範囲外（防げないこと）: coordinatorを複数作った場合の互いの重複と、アプリ再起動後の同じ応答の再送は防げない
    // （別coordinatorのIDが unknownRequest になることは testCoordinatorRejectsUnknownRequestAndApprovalWithoutReview で確かめている）

    // 同じcoordinatorで、IDと定義がまったく同じ2つのstoreにそれぞれリクエストを始めても、各IDは自分のstoreにだけ結び付く。
    // review作成・承認のどちらでも、相手のstoreのcontextは保存処理を始める前に拒否され、各storeにちょうど1件ずつ保存される
    func testEachRequestIsBoundToItsOwnStoreEvenWithIdenticalIDs() throws {
        let fixture = try makeFixture()
        let twin = try makeTwinFixture(of: fixture)
        let coordinator = AIWorkoutProposalCoordinator()
        let fixtureRequest = try coordinator.beginRequest(in: fixture.context)
        let twinRequest = try coordinator.beginRequest(in: twin.context)
        try assertTwinIsIndistinguishableByDefinition(fixture, twin, catalog: fixtureRequest.catalog)
        XCTAssertEqual(twinRequest.catalog, fixtureRequest.catalog, "前提: 2つのリクエストのカタログが同じ内容であること")
        let data = try standardData(fixture)

        // review作成: 相手のstoreのcontextでは作れない
        assertRejectedAsDifferentStore { try coordinatedReview(coordinator, fixtureRequest.id, twin, data: data) }
        assertRejectedAsDifferentStore { try coordinatedReview(coordinator, twinRequest.id, fixture, data: data) }
        XCTAssertEqual(coordinator.status(of: fixtureRequest.id), .awaitingResponse)
        XCTAssertEqual(coordinator.status(of: twinRequest.id), .awaitingResponse)

        let fixtureReview = try coordinatedReview(coordinator, fixtureRequest.id, fixture, data: data)
        let twinReview = try coordinatedReview(coordinator, twinRequest.id, twin, data: data)
        XCTAssertFalse(fixtureReview === twinReview)

        // 承認: 相手のstoreのcontextでは、保存処理(persist)に進まずに拒否される
        var persistCalled = false
        assertRejectedAsDifferentStore {
            try coordinator.approve(fixtureRequest.id, in: twin.context) { context in
                persistCalled = true
                try context.save()
            }
        }
        assertRejectedAsDifferentStore {
            try coordinator.approve(twinRequest.id, in: fixture.context) { context in
                persistCalled = true
                try context.save()
            }
        }
        XCTAssertFalse(persistCalled, "別storeへの保存処理を始めないこと")
        XCTAssertEqual(fixtureReview.state, .pending)
        XCTAssertEqual(twinReview.state, .pending)
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertFalse(twin.context.hasChanges)
        XCTAssertEqual(try workoutCount(fixture), 0)
        XCTAssertEqual(try workoutCount(twin), 0)

        // それぞれ自分のstoreでは1回ずつ保存できる
        let fixtureWorkout = try coordinator.approve(fixtureRequest.id, in: fixture.context)
        let twinWorkout = try coordinator.approve(twinRequest.id, in: twin.context)
        XCTAssertEqual(coordinator.status(of: fixtureRequest.id), .saved(workoutID: fixtureWorkout.id))
        XCTAssertEqual(coordinator.status(of: twinRequest.id), .saved(workoutID: twinWorkout.id))
        XCTAssertEqual(try workoutCount(fixture), 1)
        XCTAssertEqual(try workoutCount(twin), 1)

        // 保存後に相手のstoreから承認しても拒否され、どちらも2件目は保存されない
        assertRejectedAsDifferentStore { try coordinator.approve(fixtureRequest.id, in: twin.context) }
        assertRejectedAsDifferentStore { try coordinator.approve(twinRequest.id, in: fixture.context) }
        XCTAssertEqual(try workoutCount(fixture), 1)
        XCTAssertEqual(try workoutCount(twin), 1)
    }

    // 同じstoreの別々のcontext（例: 別の画面）から同じリクエストに同じ応答を渡しても、reviewは1つだけ作られ、保存も1件だけ。
    // 保存後は、どのcontextから応答を再送・承認しても alreadySaved で拒否される
    func testSameRequestFromSeveralContextsOfSameStoreCreatesOneReviewAndSavesOnce() throws {
        let fixture = try makeFixture()
        let coordinator = AIWorkoutProposalCoordinator()
        let request = try coordinator.beginRequest(in: fixture.context)
        let data = try standardData(fixture)
        let firstContext = ModelContext(fixture.container)
        let secondContext = ModelContext(fixture.container)

        let fromFirst = try coordinator.review(for: request.id, proposal: AIWorkoutProposal.decode(from: data), in: firstContext, calendar: calendar)
        let fromSecond = try coordinator.review(for: request.id, proposal: AIWorkoutProposal.decode(from: data), in: secondContext, calendar: calendar)
        XCTAssertTrue(fromFirst === fromSecond, "同じリクエストではcontextが違ってもreviewを作り直さないこと")

        let workout = try coordinator.approve(request.id, in: firstContext)
        XCTAssertEqual(try workoutCount(fixture), 1)

        for context in [firstContext, secondContext, fixture.context] {
            assertCoordinatorError(.alreadySaved(workoutID: workout.id)) {
                try coordinator.review(for: request.id, proposal: AIWorkoutProposal.decode(from: data), in: context, calendar: calendar)
            }
            assertCoordinatorError(.alreadySaved(workoutID: workout.id)) { try coordinator.approve(request.id, in: context) }
        }
        XCTAssertEqual(fromFirst.state, .saved(workoutID: workout.id))
        XCTAssertEqual(coordinator.status(of: request.id), .saved(workoutID: workout.id))
        XCTAssertEqual(try workoutCount(fixture), 1)
        XCTAssertFalse(secondContext.hasChanges)
        XCTAssertFalse(fixture.context.hasChanges)
    }

    // 同じ応答が何度も届く（再送・再生成で同じ内容が返る）たびに、それぞれ別に読み込んでreviewを求め、そのたびに承認を試みても、
    // reviewは最初の1つだけで、保存はちょうど1件。2回目以降の承認は、エラーの種類まで決めて拒否されることを確かめる
    func testRepeatedSameResponseForOneRequestCreatesOneReviewAndSavesOnce() throws {
        let fixture = try makeFixture()
        let coordinator = AIWorkoutProposalCoordinator()
        let request = try coordinator.beginRequest(in: fixture.context)
        let data = try standardData(fixture)

        // 1回目: reviewを作って承認する
        let first = try coordinatedReview(coordinator, request.id, fixture, data: data)
        // 承認前の再送は同じreviewを返す（作り直さない）
        XCTAssertTrue(try coordinatedReview(coordinator, request.id, fixture, data: data) === first)
        let workout = try coordinator.approve(request.id, in: fixture.context)

        // 2回目・3回目: 同じ応答が届いても、reviewの作成も承認も alreadySaved で拒否される
        for _ in 0..<2 {
            assertCoordinatorError(.alreadySaved(workoutID: workout.id)) { try coordinatedReview(coordinator, request.id, fixture, data: data) }
            assertCoordinatorError(.alreadySaved(workoutID: workout.id)) { try coordinator.approve(request.id, in: fixture.context) }
        }

        XCTAssertEqual(first.state, .saved(workoutID: workout.id))
        XCTAssertEqual(coordinator.status(of: request.id), .saved(workoutID: workout.id))
        XCTAssertEqual(try workoutCount(fixture), 1)
        XCTAssertFalse(fixture.context.hasChanges)
    }
}
