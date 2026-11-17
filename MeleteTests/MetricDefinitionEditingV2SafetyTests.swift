import XCTest
import SwiftData
@testable import Melete

@MainActor
final class MetricDefinitionEditingV2SafetyTests: XCTestCase {
    func testExperimentalV2SelectionRequiresValidOwnedIsolationAndRejectsInvalidMarker() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("MeleteV2IsolationSafety-\(UUID().uuidString)", isDirectory: true)
        let storeDirectory = root.appendingPathComponent("store", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try manager.createDirectory(at: storeDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDirectory.path)
        try Data("Melete UI test root v1".utf8).write(to: root.appendingPathComponent(UITestStoreIsolation.rootMarker))
        try Data(UUID().uuidString.utf8).write(to: storeDirectory.appendingPathComponent(UITestStoreIsolation.storeMarker))

        let validArguments = ["--melete-ui-test-root", root.path, "--melete-ui-test-store", storeDirectory.path]
        let experimentalArguments = validArguments + ["--melete-v2-experimental"]
        let isolatedURL = try XCTUnwrap(UITestStoreIsolation.storeURL(arguments: experimentalArguments))
        XCTAssertEqual(isolatedURL, storeDirectory.appendingPathComponent("Melete.store"))
        let isolationIsValid = UITestStoreIsolation.storeURL(arguments: experimentalArguments) != nil
        XCTAssertEqual(
            StartupRouteSelection.select(arguments: experimentalArguments, isDebug: true, isolationIsValid: isolationIsValid),
            .isolatedV2
        )

        XCTAssertEqual(
            StartupRouteSelection.select(arguments: ["--melete-v2-experimental"], isDebug: true, isolationIsValid: false),
            .error,
            "V2フラグ単独では通常ストアを選択しない"
        )
        XCTAssertEqual(
            StartupRouteSelection.select(arguments: validArguments + ["--melete-v2-experimental", "--melete-v2-experimental"], isDebug: true, isolationIsValid: true),
            .error,
            "重複フラグを拒否する"
        )
        XCTAssertEqual(
            StartupRouteSelection.select(arguments: ["--melete-ui-test-root", root.path, "--melete-v2-experimental"], isDebug: true, isolationIsValid: false),
            .error,
            "store引数がない場合は拒否する"
        )
        XCTAssertEqual(
            StartupRouteSelection.select(arguments: ["--melete-ui-test-store", storeDirectory.path, "--melete-v2-experimental"], isDebug: true, isolationIsValid: false),
            .error,
            "root引数がない場合は拒否する"
        )
        XCTAssertEqual(
            StartupRouteSelection.select(arguments: experimentalArguments, isDebug: false, isolationIsValid: true),
            .error,
            "DEBUG以外では拒否する"
        )

        try Data("not-a-uuid".utf8).write(to: storeDirectory.appendingPathComponent(UITestStoreIsolation.storeMarker))
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: experimentalArguments))
        XCTAssertEqual(
            StartupRouteSelection.select(
                arguments: experimentalArguments,
                isDebug: true,
                isolationIsValid: UITestStoreIsolation.storeURL(arguments: experimentalArguments) != nil
            ),
            .error,
            "無効markerでは通常ストアへfallbackしない"
        )
    }

    func testUITestStoreIsolationRejectsHardLinkedStoreFilesAndAcceptsRegularStore() throws {
        for name in ["Melete.store", "Melete.store-wal", "Melete.store-shm"] {
            let fixture = try makeHardLinkIsolationFixture(fileName: name)
            XCTAssertNil(
                UITestStoreIsolation.storeURL(arguments: fixture.arguments),
                "\(name) がroot外の合成ファイルへのhard linkなら拒否する"
            )
        }

        let regularFixture = try makeHardLinkIsolationFixture(fileName: "Melete.store", createHardLink: false)
        XCTAssertEqual(
            UITestStoreIsolation.storeURL(arguments: regularFixture.arguments),
            regularFixture.storeDirectory.appendingPathComponent("Melete.store"),
            "hard linkでない通常ファイルの隔離ストアは受理する"
        )

        for linkedMarker in [UITestStoreIsolation.rootMarker, UITestStoreIsolation.storeMarker] {
            let fixture = try makeHardLinkIsolationFixture(fileName: "Melete.store", linkedMarker: linkedMarker)
            XCTAssertNil(UITestStoreIsolation.storeURL(arguments: fixture.arguments), "\(linkedMarker) がroot外の合成ファイルへのhard linkなら拒否する")
        }

        let outsideTemporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("MeleteOutsideTemporaryRoot-\(UUID().uuidString)", isDirectory: true)
        let outsideFixture = try makeHardLinkIsolationFixture(fileName: "Melete.store", createHardLink: false, rootURL: outsideTemporaryRoot)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: outsideFixture.arguments), "NSTemporaryDirectory外の正規rootを拒否する")
    }

    private func makeHardLinkIsolationFixture(
        fileName: String,
        createHardLink: Bool = true,
        linkedMarker: String? = nil,
        rootURL: URL? = nil
    ) throws -> (arguments: [String], storeDirectory: URL) {
        let manager = FileManager.default
        let temporaryDirectory = manager.temporaryDirectory
        let fixtureID = UUID().uuidString
        let root = rootURL ?? temporaryDirectory
            .appendingPathComponent("MeleteHardLinkIsolation-\(fixtureID)", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let storeDirectory = root.appendingPathComponent("store", isDirectory: true)

        try manager.createDirectory(at: storeDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let rootMarkerURL = root.appendingPathComponent(UITestStoreIsolation.rootMarker)
        let storeMarkerURL = storeDirectory.appendingPathComponent(UITestStoreIsolation.storeMarker)
        let rootMarkerContents = Data("Melete UI test root v1".utf8)
        let storeMarkerContents = Data(UUID().uuidString.utf8)
        if linkedMarker == UITestStoreIsolation.rootMarker {
            let target = temporaryDirectory.appendingPathComponent("MeleteHardLinkTarget-\(fixtureID)-root-marker")
            guard manager.createFile(atPath: target.path, contents: rootMarkerContents), manager.createFile(atPath: storeMarkerURL.path, contents: storeMarkerContents) else { throw IsolationFixtureError.cannotCreateMarkers }
            try manager.linkItem(at: target, to: rootMarkerURL)
        } else if linkedMarker == UITestStoreIsolation.storeMarker {
            let target = temporaryDirectory.appendingPathComponent("MeleteHardLinkTarget-\(fixtureID)-store-marker")
            guard manager.createFile(atPath: target.path, contents: storeMarkerContents), manager.createFile(atPath: rootMarkerURL.path, contents: rootMarkerContents) else { throw IsolationFixtureError.cannotCreateMarkers }
            try manager.linkItem(at: target, to: storeMarkerURL)
        } else {
            guard manager.createFile(atPath: rootMarkerURL.path, contents: rootMarkerContents), manager.createFile(atPath: storeMarkerURL.path, contents: storeMarkerContents) else { throw IsolationFixtureError.cannotCreateMarkers }
        }

        let storeFile = storeDirectory.appendingPathComponent(fileName)
        if linkedMarker != nil {
            // このケースではマーカーだけを検証するため、store本体は通常ファイルにする。
            guard manager.createFile(atPath: storeFile.path, contents: Data("合成通常store".utf8)) else { throw IsolationFixtureError.cannotCreateRegularStore }
        } else if createHardLink {
            let externalFile = temporaryDirectory.appendingPathComponent("MeleteHardLinkTarget-\(fixtureID)")
            guard manager.createFile(atPath: externalFile.path, contents: Data("合成hard link対象".utf8)) else {
                throw IsolationFixtureError.cannotCreateHardLinkTarget
            }
            try manager.linkItem(at: externalFile, to: storeFile)
        } else {
            guard manager.createFile(atPath: storeFile.path, contents: Data("合成通常store".utf8)) else {
                throw IsolationFixtureError.cannotCreateRegularStore
            }
        }

        return (
            ["--melete-ui-test-root", root.path, "--melete-ui-test-store", storeDirectory.path],
            storeDirectory
        )
    }

    private enum IsolationFixtureError: Error {
        case cannotCreateMarkers
        case cannotCreateHardLinkTarget
        case cannotCreateRegularStore
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let exercise: Exercise
        let metric: MetricDefinition
        let storeURL: URL
    }

    private enum InjectedFailure: Error { case expected }

    private func makeFixture(name: String = "重量", unit: String = "kg", withHistory: Bool = true) throws -> Fixture {
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteMetricDefinitionEditingV2Safety-\(UUID().uuidString).sqlite")
        let configuration = ModelConfiguration("MeleteMetricDefinitionEditingV2Safety", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let metric = MetricDefinition(name: name, unit: unit, allowsDecimal: true, isRequired: false, sortOrder: 0)
        let exercise = Exercise(name: "合成種目", metrics: [metric])
        context.insert(exercise)
        if withHistory {
            context.insert(MetricDefinitionRevision(metricID: metric.id, revision: 1, name: name, unit: unit, allowsDecimal: true, isRequired: false, sortOrder: 0))
        }
        try context.save()
        return Fixture(container: container, context: context, exercise: exercise, metric: metric, storeURL: url)
    }

    private func revisedDraft(for exercise: Exercise, in context: ModelContext, name: String? = nil, unit: String? = nil) throws -> [MetricDefinitionDraft] {
        var drafts = try MetricDefinitionEditingV2.draft(for: exercise, in: context)
        drafts[0].name = name ?? drafts[0].name
        drafts[0].unit = unit ?? drafts[0].unit
        return drafts
    }

    private func assertMetricAndRevisionsUnchanged(_ fixture: Fixture, metricID: UUID, snapshot: MetricDefinitionSnapshot, revisionsBefore: [(UUID, UUID, Int, String, String)]) throws {
        XCTAssertEqual(MetricDefinitionSnapshot(try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<MetricDefinition>()).first { $0.id == metricID })), snapshot)
        let revisions = try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>())
            .map { ($0.id, $0.seriesID, $0.revision, $0.name, $0.unit) }
            .sorted { $0.0.uuidString < $1.0.uuidString }
        let expected = revisionsBefore.sorted { $0.0.uuidString < $1.0.uuidString }
        XCTAssertEqual(revisions.map { $0.0 }, expected.map { $0.0 })
        XCTAssertEqual(revisions.map { $0.1 }, expected.map { $0.1 })
        XCTAssertEqual(revisions.map { $0.2 }, expected.map { $0.2 })
        XCTAssertEqual(revisions.map { $0.3 }, expected.map { $0.3 })
        XCTAssertEqual(revisions.map { $0.4 }, expected.map { $0.4 })
    }

    func testDirtyContextRejectsWithoutTouchingTargetOrUnrelatedUnsavedEdit() throws {
        let fixture = try makeFixture()
        let before = MetricDefinitionSnapshot(fixture.metric)
        let drafts = try revisedDraft(for: fixture.exercise, in: fixture.context, unit: "lb")
        let unrelated = Exercise(name: "未保存", metrics: [])
        fixture.context.insert(unrelated)

        XCTAssertThrowsError(try MetricDefinitionEditingV2.save(drafts, for: fixture.exercise, in: fixture.context)) { error in
            guard case MetricDefinitionEditingV2Error.unsavedContext = error else { return XCTFail("unsavedContext型が必要: \(error)") }
        }
        XCTAssertTrue(fixture.context.hasChanges)
        XCTAssertEqual(MetricDefinitionSnapshot(fixture.metric), before)
        XCTAssertEqual(fixture.metric.name, "重量")
        XCTAssertEqual(fixture.metric.unit, "kg")
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).count, 1)
        XCTAssertEqual(drafts[0].unit, "lb")
        XCTAssertEqual(unrelated.name, "未保存")
    }

    func testStaleDraftIsRejectedAfterSameContextChangeWasSaved() throws {
        let fixture = try makeFixture()
        let staleDrafts = try MetricDefinitionEditingV2.draft(for: fixture.exercise, in: fixture.context)
        fixture.metric.name = "別の名前"
        try fixture.context.save()
        let before = MetricDefinitionSnapshot(fixture.metric)
        let revisionsBefore = try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map { ($0.id, $0.seriesID, $0.revision, $0.name, $0.unit) }

        XCTAssertThrowsError(try MetricDefinitionEditingV2.save(staleDrafts, for: fixture.exercise, in: fixture.context)) { error in
            guard case MetricDefinitionEditingV2Error.changed = error else { return XCTFail("changed型が必要: \(error)") }
        }
        XCTAssertFalse(fixture.context.hasChanges)
        try assertMetricAndRevisionsUnchanged(fixture, metricID: fixture.metric.id, snapshot: before, revisionsBefore: revisionsBefore)
    }

    func testStaleDraftFromSeparateContextCannotOverwriteNewerDefinitionRevisionOrLinkedValue() throws {
        let fixture = try makeFixture()
        let metricID = fixture.metric.id
        let originalRevision = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).first)
        let oldValue = MetricValue(metric: fixture.metric, scaledValue: 12_500)
        let workout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [
            ExerciseRecord(exercise: fixture.exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [oldValue])])
        ])
        fixture.context.insert(workout)
        let oldLink = try MetricValueRevisionLinking.register(value: oldValue, revision: originalRevision, in: fixture.context)
        try fixture.context.save()

        let staleDrafts = try MetricDefinitionEditingV2.draft(for: fixture.exercise, in: fixture.context)
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteMetricDefinitionEditingV2SafetyConcurrent", schema: schema, url: fixture.storeURL, cloudKitDatabase: .none)
        let secondContainer = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(secondContainer)
        let exerciseB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == fixture.exercise.id })
        var latestDrafts = try MetricDefinitionEditingV2.draft(for: exerciseB, in: contextB)
        latestDrafts[0].unit = "lb"
        try MetricDefinitionEditingV2.save(latestDrafts, for: exerciseB, in: contextB)

        var staleOunceDrafts = staleDrafts
        staleOunceDrafts[0].unit = "oz"
        XCTAssertThrowsError(try MetricDefinitionEditingV2.save(staleOunceDrafts, for: fixture.exercise, in: fixture.context)) { error in
            switch error {
            case MetricDefinitionEditingV2Error.changed, MetricValueRevisionLinkingError.snapshotMismatch:
                break
            default:
                XCTFail("staleまたはrevision snapshot不一致として拒否する必要: \(error)")
            }
        }
        XCTAssertFalse(fixture.context.hasChanges)

        let verificationContainer = try ModelContainer(for: schema, configurations: [configuration])
        let verificationContext = ModelContext(verificationContainer)
        let savedExercise = try XCTUnwrap(try verificationContext.fetch(FetchDescriptor<Exercise>()).first { $0.id == fixture.exercise.id })
        let savedMetric = try XCTUnwrap(savedExercise.metrics.first { $0.id == metricID })
        XCTAssertEqual(savedMetric.unit, "lb")
        let revisions = try verificationContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
            .filter { $0.metricID == metricID }.sorted { $0.revision < $1.revision }
        XCTAssertEqual(revisions.map(\.revision), [1, 2])
        XCTAssertEqual(revisions.map(\.unit), ["kg", "lb"])
        XCTAssertEqual(revisions[0].id, originalRevision.id)
        let savedValue = try XCTUnwrap(try verificationContext.fetch(FetchDescriptor<MetricValue>()).first { $0.id == oldValue.id })
        XCTAssertEqual(WorkoutValueSnapshot(savedValue), WorkoutValueSnapshot(oldValue))
        let savedLinks = try verificationContext.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(savedLinks.map(\.id), [oldLink.id])
        XCTAssertEqual(savedLinks.first?.valueID, oldValue.id)
        XCTAssertEqual(savedLinks.first?.revisionID, originalRevision.id)
    }

    func testNoHistoryBaselineRejectsRevisionCreatedByAnotherContext() throws {
        let fixture = try makeFixture(withHistory: false)
        let staleDrafts = try MetricDefinitionEditingV2.draft(for: fixture.exercise, in: fixture.context)
        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteMetricDefinitionEditingV2NoHistoryConcurrent", schema: schema, url: fixture.storeURL, cloudKitDatabase: .none)
        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let exerciseB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == fixture.exercise.id })
        var firstRevisionDraft = try MetricDefinitionEditingV2.draft(for: exerciseB, in: contextB)
        firstRevisionDraft[0].unit = "lb"
        try MetricDefinitionEditingV2.save(firstRevisionDraft, for: exerciseB, in: contextB)

        var staleChange = staleDrafts
        staleChange[0].unit = "oz"
        XCTAssertThrowsError(try MetricDefinitionEditingV2.save(staleChange, for: fixture.exercise, in: fixture.context)) { error in
            guard case MetricDefinitionEditingV2Error.changed = error else { return XCTFail("履歴なしbaseline後の他context初回改訂を拒否する必要: \(error)") }
        }
        XCTAssertFalse(fixture.context.hasChanges)

        let verifyContainer = try ModelContainer(for: schema, configurations: [configuration])
        let verifyContext = ModelContext(verifyContainer)
        let revisions = try verifyContext.fetch(FetchDescriptor<MetricDefinitionRevision>()).sorted { $0.revision < $1.revision }
        XCTAssertEqual(revisions.map(\.revision), [1, 2])
        XCTAssertEqual(revisions.map(\.unit), ["kg", "lb"])
        let savedExercise = try XCTUnwrap(try verifyContext.fetch(FetchDescriptor<Exercise>()).first { $0.id == fixture.exercise.id })
        XCTAssertEqual(savedExercise.metrics.first?.unit, "lb")
    }

    func testNoHistoryBaselineRejectsWorkoutCreationRevisionWithoutMetricSnapshotChange() throws {
        let fixture = try makeFixture(name: "重量", unit: "kg", withHistory: false)
        let metricID = fixture.metric.id
        let exerciseID = fixture.exercise.id
        let definitionBefore = MetricDefinitionSnapshot(fixture.metric)
        let drafts = try MetricDefinitionEditingV2.draft(for: fixture.exercise, in: fixture.context)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].historyBaseline, .noHistory)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).isEmpty)

        let schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let configuration = ModelConfiguration("MeleteMetricDefinitionEditingV2WorkoutNoHistoryBaseline", schema: schema, url: fixture.storeURL, cloudKitDatabase: .none)
        let containerB = try ModelContainer(for: schema, configurations: [configuration])
        let contextB = ModelContext(containerB)
        let exerciseB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseID })
        XCTAssertEqual(MetricDefinitionSnapshot(try XCTUnwrap(exerciseB.metrics.first { $0.id == metricID })), definitionBefore)

        var entry = WorkoutEntryDraft(exercise: exerciseB)
        entry.sets[0].values[metricID] = "42.5"
        let workoutB = try WorkoutCreationV2.save(day: .now, entries: [entry], in: contextB)
        let recordB = try XCTUnwrap(workoutB.records.first)
        let setB = try XCTUnwrap(recordB.sets.first)
        let valueB = try XCTUnwrap(setB.values.first { $0.metricID == metricID })
        let revisionB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<MetricDefinitionRevision>()).first { $0.metricID == metricID })
        let linkB = try XCTUnwrap(try contextB.fetch(FetchDescriptor<MetricValueRevisionLink>()).first { $0.valueID == valueB.id })
        XCTAssertEqual(revisionB.revision, 1)
        XCTAssertEqual(revisionB.name, definitionBefore.name)
        XCTAssertEqual(revisionB.unit, definitionBefore.unit)
        XCTAssertEqual(linkB.revisionID, revisionB.id)
        XCTAssertEqual(valueB.scaledValue, 42_500)

        let snapshotContext = ModelContext(containerB)
        let currentExercise = try XCTUnwrap(try snapshotContext.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseID })
        let currentMetric = try XCTUnwrap(currentExercise.metrics.first { $0.id == metricID })
        XCTAssertEqual(MetricDefinitionSnapshot(currentMetric), MetricDefinitionSnapshot(fixture.metric), "保存直前の別contextでmetric snapshotがAのdraftと一致する")

        var changedDrafts = drafts
        changedDrafts[0].unit = "lb"
        XCTAssertThrowsError(try MetricDefinitionEditingV2.save(changedDrafts, for: fixture.exercise, in: fixture.context)) { error in
            guard case MetricDefinitionEditingV2Error.changed = error else { return XCTFail("snapshot一致時もnoHistory baseline後の初回revisionを拒否する必要: \(error)") }
        }
        XCTAssertFalse(fixture.context.hasChanges)

        let verificationContainer = try ModelContainer(for: schema, configurations: [configuration])
        let verificationContext = ModelContext(verificationContainer)
        let savedExercise = try XCTUnwrap(try verificationContext.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseID })
        let savedMetric = try XCTUnwrap(savedExercise.metrics.first { $0.id == metricID })
        XCTAssertEqual(MetricDefinitionSnapshot(savedMetric), definitionBefore)
        let revisions = try verificationContext.fetch(FetchDescriptor<MetricDefinitionRevision>()).filter { $0.metricID == metricID }
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions.first?.id, revisionB.id)
        XCTAssertEqual(revisions.first?.revision, 1)
        XCTAssertEqual(revisions.first?.name, definitionBefore.name)
        XCTAssertEqual(revisions.first?.unit, definitionBefore.unit)
        let savedWorkout = try XCTUnwrap(try verificationContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workoutB.id })
        XCTAssertEqual(savedWorkout.records.map(\.id), [recordB.id])
        XCTAssertEqual(savedWorkout.records.first?.sets.map(\.id), [setB.id])
        let savedValue = try XCTUnwrap(try verificationContext.fetch(FetchDescriptor<MetricValue>()).first { $0.id == valueB.id })
        XCTAssertEqual(WorkoutValueSnapshot(savedValue), WorkoutValueSnapshot(valueB))
        let links = try verificationContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).filter { $0.valueID == valueB.id }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.id, linkB.id)
        XCTAssertEqual(links.first?.revisionID, revisionB.id)
    }

    func testPersistFailureRollsBackCompletelyAndSameDraftCanRetryAfterReopen() throws {
        let fixture = try makeFixture()
        let metricID = fixture.metric.id
        let before = MetricDefinitionSnapshot(fixture.metric)
        let revisionBefore = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).first)
        let value = MetricValue(metric: fixture.metric, scaledValue: 12_500)
        fixture.context.insert(value)
        try fixture.context.save()
        let link = MetricValueRevisionLink(valueID: value.id, revisionID: revisionBefore.id)
        fixture.context.insert(link)
        try fixture.context.save()
        let oldValueSnapshot = (value.name, value.unit, value.scaledValue)
        let drafts = try revisedDraft(for: fixture.exercise, in: fixture.context, name: "負荷", unit: "lb")

        XCTAssertThrowsError(try MetricDefinitionEditingV2.save(drafts, for: fixture.exercise, in: fixture.context) { _ in throw InjectedFailure.expected }) { error in
            guard case InjectedFailure.expected = error else { return XCTFail("注入したエラー型が伝播する必要: \(error)") }
        }
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(MetricDefinitionSnapshot(fixture.metric), before)
        XCTAssertEqual(value.name, oldValueSnapshot.0)
        XCTAssertEqual(value.unit, oldValueSnapshot.1)
        XCTAssertEqual(value.scaledValue, oldValueSnapshot.2)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.revisionID), [revisionBefore.id])
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [revisionBefore.id])

        try fixture.context.save()
        let reopened = ModelContext(fixture.container)
        XCTAssertEqual(try XCTUnwrap(try reopened.fetch(FetchDescriptor<MetricDefinition>()).first { $0.id == metricID }).unit, "kg")
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [revisionBefore.id])

        try MetricDefinitionEditingV2.save(drafts, for: fixture.exercise, in: fixture.context)
        let saved = ModelContext(fixture.container)
        let metricAfterRetry = try XCTUnwrap(try saved.fetch(FetchDescriptor<MetricDefinition>()).first { $0.id == metricID })
        XCTAssertEqual(metricAfterRetry.name, "負荷")
        XCTAssertEqual(metricAfterRetry.unit, "lb")
        let revisions = try saved.fetch(FetchDescriptor<MetricDefinitionRevision>()).sorted { $0.revision < $1.revision }
        XCTAssertEqual(revisions.map(\.revision), [1, 2])
        XCTAssertEqual(revisions.map(\.name), ["重量", "負荷"])
        XCTAssertEqual(try saved.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.revisionID), [revisionBefore.id])
        XCTAssertEqual(try XCTUnwrap(try saved.fetch(FetchDescriptor<MetricValue>()).first { $0.id == value.id }).name, "重量")
    }

    func testInvalidDraftAndCorruptHistoryAreRejectedWithoutMutation() throws {
        let invalidInputs: [(String, String, MetricDefinitionEditingError?)] = [
            ("   ", "kg", .invalid),
            ("重量", " \n", .invalid),
            ("重量", "kg", .invalid)
        ]
        for (index, input) in invalidInputs.enumerated() {
            let fixture = try makeFixture()
            var drafts = try revisedDraft(for: fixture.exercise, in: fixture.context, name: input.0, unit: input.1)
            if index == 2 {
                let second = MetricDefinition(name: "回数", unit: "回", allowsDecimal: false, isRequired: false, sortOrder: 1)
                fixture.exercise.metrics.append(second)
                try fixture.context.save()
                drafts = try MetricDefinitionEditingV2.draft(for: fixture.exercise, in: fixture.context)
                drafts[1].name = "重量"
            }
            let before = fixture.exercise.metrics.map(MetricDefinitionSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
            XCTAssertThrowsError(try MetricDefinitionEditingV2.save(drafts, for: fixture.exercise, in: fixture.context)) { error in
                guard case MetricDefinitionEditingError.invalid = error else { return XCTFail("invalid型が必要: \(error)") }
            }
            XCTAssertFalse(fixture.context.hasChanges)
            XCTAssertEqual(fixture.exercise.metrics.map(MetricDefinitionSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }, before)
            XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.revision), [1])
        }

        for corruption in ["duplicateID", "duplicateRevision", "overflow", "snapshotMismatch"] {
            let fixture = try makeFixture()
            var drafts = try MetricDefinitionEditingV2.draft(for: fixture.exercise, in: fixture.context)
            drafts[0].unit = "lb"
            let existing = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).first)
            switch corruption {
            case "duplicateID":
                fixture.context.insert(MetricDefinitionRevision(id: existing.id, metricID: existing.metricID, revision: 1, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0))
            case "duplicateRevision":
                fixture.context.insert(MetricDefinitionRevision(metricID: existing.metricID, seriesID: existing.seriesID, revision: 1, name: "重量", unit: "kg", allowsDecimal: true, isRequired: false, sortOrder: 0))
            case "overflow": existing.revision = Int.max
            default: existing.name = "履歴と異なる"
            }
            try fixture.context.save()
            let historyBefore = try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>())
                .map { ($0.id, $0.seriesID, $0.revision, $0.name, $0.unit) }
            let metricBefore = MetricDefinitionSnapshot(fixture.metric)
            XCTAssertThrowsError(try MetricDefinitionEditingV2.save(drafts, for: fixture.exercise, in: fixture.context)) { error in
                switch corruption {
                case "duplicateID", "duplicateRevision":
                    guard case MetricValueRevisionLinkingError.duplicateRevision = error else { return XCTFail("duplicateRevision型が必要: \(error)") }
                case "overflow":
                    guard case MetricDefinitionEditingV2Error.revisionOverflow = error else { return XCTFail("revisionOverflow型が必要: \(error)") }
                default:
                    guard case MetricValueRevisionLinkingError.snapshotMismatch = error else { return XCTFail("snapshotMismatch型が必要: \(error)") }
                }
            }
            XCTAssertFalse(fixture.context.hasChanges)
            XCTAssertEqual(MetricDefinitionSnapshot(fixture.metric), metricBefore)
            let after = try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map { ($0.id, $0.seriesID, $0.revision, $0.name, $0.unit) }
                .sorted { $0.0.uuidString < $1.0.uuidString }
            let expected = historyBefore.sorted { $0.0.uuidString < $1.0.uuidString }
            XCTAssertEqual(after.map { $0.0 }, expected.map { $0.0 })
            XCTAssertEqual(after.map { $0.1 }, expected.map { $0.1 })
            XCTAssertEqual(after.map { $0.2 }, expected.map { $0.2 })
            XCTAssertEqual(after.map { $0.3 }, expected.map { $0.3 })
            XCTAssertEqual(after.map { $0.4 }, expected.map { $0.4 })
        }
    }

    func testLegacyMetricWithoutHistoryGetsInitialAndRevisedRevisionWhileOldValueStaysUnlinked() throws {
        let fixture = try makeFixture(withHistory: false)
        let value = MetricValue(metric: fixture.metric, scaledValue: 12_500)
        fixture.context.insert(value)
        try fixture.context.save()
        let drafts = try revisedDraft(for: fixture.exercise, in: fixture.context, name: "負荷", unit: "lb")
        try MetricDefinitionEditingV2.save(drafts, for: fixture.exercise, in: fixture.context)

        let reopened = ModelContext(fixture.container)
        let revisions = try reopened.fetch(FetchDescriptor<MetricDefinitionRevision>()).sorted { $0.revision < $1.revision }
        XCTAssertEqual(revisions.map(\.revision), [1, 2])
        XCTAssertEqual(revisions.map(\.name), ["重量", "負荷"])
        XCTAssertEqual(revisions.map(\.unit), ["kg", "lb"])
        XCTAssertEqual(revisions[0].metricID, fixture.metric.id)
        XCTAssertEqual(revisions[1].metricID, fixture.metric.id)
        XCTAssertNotEqual(revisions[0].seriesID, revisions[1].seriesID)
        XCTAssertTrue(try reopened.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)
        let oldValue = try XCTUnwrap(try reopened.fetch(FetchDescriptor<MetricValue>()).first { $0.id == value.id })
        XCTAssertEqual(oldValue.name, "重量")
        XCTAssertEqual(oldValue.unit, "kg")
        XCTAssertEqual(oldValue.scaledValue, 12_500)

        var entry = WorkoutEntryDraft(exercise: try XCTUnwrap(try reopened.fetch(FetchDescriptor<Exercise>()).first))
        entry.sets[0].values[fixture.metric.id] = "8.5"
        let workout = try WorkoutCreationV2.save(day: .now, entries: [entry], in: reopened)
        let newValue = try XCTUnwrap(workout.records.first?.sets.first?.values.first)
        let newLink = try XCTUnwrap(try reopened.fetch(FetchDescriptor<MetricValueRevisionLink>()).first { $0.valueID == newValue.id })
        XCTAssertEqual(newLink.revisionID, revisions[1].id)
        XCTAssertEqual(newValue.name, "負荷")
        XCTAssertEqual(newValue.unit, "lb")

        let reopenedAgain = ModelContext(fixture.container)
        let persistedLink = try XCTUnwrap(try reopenedAgain.fetch(FetchDescriptor<MetricValueRevisionLink>()).first { $0.valueID == newValue.id })
        XCTAssertEqual(persistedLink.revisionID, revisions[1].id)
        let persistedValue = try XCTUnwrap(try reopenedAgain.fetch(FetchDescriptor<MetricValue>()).first { $0.id == newValue.id })
        XCTAssertEqual(persistedValue.name, "負荷")
        XCTAssertEqual(persistedValue.unit, "lb")
    }

    func testV2SaveAddsMetricAndDeactivatesThenRestoresItWithoutChangingLegacyValues() throws {
        let fixture = try makeFixture()
        let originalMetricID = fixture.metric.id
        let originalRevision = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).first)
        let legacyValue = MetricValue(metric: fixture.metric, scaledValue: 72_500)
        let legacySet = SetRecord(sortOrder: 3, values: [legacyValue])
        let legacyRecord = ExerciseRecord(exercise: fixture.exercise, sortOrder: 2, sets: [legacySet])
        let workout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [legacyRecord])
        fixture.context.insert(workout)
        let legacyLink = try MetricValueRevisionLinking.register(value: legacyValue, revision: originalRevision, in: fixture.context)
        try fixture.context.save()
        let legacySnapshot = WorkoutValueSnapshot(legacyValue)

        var drafts = try MetricDefinitionEditingV2.draft(for: fixture.exercise, in: fixture.context)
        drafts[0].isActive = false
        let addedDraft = MetricDefinitionDraft(name: "回数", unit: "回", allowsDecimal: false, isRequired: true)
        drafts.append(addedDraft)
        try MetricDefinitionEditingV2.save(drafts, for: fixture.exercise, in: fixture.context)

        let reopened = ModelContext(fixture.container)
        let savedExercise = try XCTUnwrap(try reopened.fetch(FetchDescriptor<Exercise>()).first { $0.id == fixture.exercise.id })
        var metrics = savedExercise.metrics.sorted { $0.sortOrder < $1.sortOrder }
        let addedMetric = try XCTUnwrap(metrics.first { $0.name == "回数" })
        let addedMetricID = addedMetric.id
        XCTAssertEqual(metrics.map(\.id), [originalMetricID, addedMetricID])
        XCTAssertEqual(metrics.map(\.sortOrder), [0, 1])
        XCTAssertEqual(metrics.map(\.isActive), [false, true])
        XCTAssertEqual(metrics.map(\.name), ["重量", "回数"])
        let savedLegacyValue = try XCTUnwrap(try reopened.fetch(FetchDescriptor<MetricValue>()).first { $0.id == legacyValue.id })
        XCTAssertEqual(WorkoutValueSnapshot(savedLegacyValue), legacySnapshot)
        let preservedRevision = try XCTUnwrap(try reopened.fetch(FetchDescriptor<MetricDefinitionRevision>()).first { $0.id == originalRevision.id })
        XCTAssertEqual(preservedRevision.metricID, originalMetricID)
        XCTAssertEqual(preservedRevision.seriesID, originalRevision.seriesID)
        XCTAssertEqual(preservedRevision.revision, 1)
        XCTAssertEqual(preservedRevision.name, "重量")
        XCTAssertEqual(preservedRevision.unit, "kg")
        XCTAssertEqual(preservedRevision.sortOrder, 0)
        let preservedLink = try XCTUnwrap(try reopened.fetch(FetchDescriptor<MetricValueRevisionLink>()).first { $0.id == legacyLink.id })
        XCTAssertEqual(preservedLink.valueID, legacyValue.id)
        XCTAssertEqual(preservedLink.revisionID, originalRevision.id)
        XCTAssertFalse(try reopened.fetch(FetchDescriptor<MetricValue>()).contains { $0.metricID == addedMetricID }, "既存Workoutへ新しい項目値を後付けしない")

        var restoreDrafts = try MetricDefinitionEditingV2.draft(for: savedExercise, in: reopened)
        let restoreIndex = try XCTUnwrap(restoreDrafts.firstIndex { $0.id == originalMetricID })
        restoreDrafts[restoreIndex].isActive = true
        try MetricDefinitionEditingV2.save(restoreDrafts, for: savedExercise, in: reopened)
        let restoredContext = ModelContext(fixture.container)
        let restoredExercise = try XCTUnwrap(try restoredContext.fetch(FetchDescriptor<Exercise>()).first { $0.id == fixture.exercise.id })
        metrics = restoredExercise.metrics.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(metrics.filter(\.isActive).map(\.id).sorted { $0.uuidString < $1.uuidString }, [originalMetricID, addedMetricID].sorted { $0.uuidString < $1.uuidString })

        let savedWorkout = try XCTUnwrap(try restoredContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workout.id })
        let addition = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: savedWorkout.records[0], exercise: restoredExercise))
        var filledAddition = addition
        filledAddition.values[originalMetricID] = "80"
        filledAddition.values[addedMetricID] = "8"
        try WorkoutValueEditingV2.save([], additions: [filledAddition], day: try XCTUnwrap(WorkoutValueEditing.date(from: savedWorkout.day)), to: savedWorkout, exercises: [restoredExercise], in: restoredContext)

        let finalContext = ModelContext(fixture.container)
        let finalWorkout = try XCTUnwrap(try finalContext.fetch(FetchDescriptor<Workout>()).first { $0.id == workout.id })
        let newValues = finalWorkout.records.flatMap(\.sets).flatMap(\.values).filter { $0.id != legacyValue.id }
            .sorted { $0.metricID.uuidString < $1.metricID.uuidString }
        XCTAssertEqual(newValues.map(\.metricID), [originalMetricID, addedMetricID].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(newValues.first { $0.metricID == originalMetricID }?.scaledValue, 80_000)
        XCTAssertEqual(newValues.first { $0.metricID == addedMetricID }?.scaledValue, 8_000)
        let links = try finalContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).sorted { $0.valueID.uuidString < $1.valueID.uuidString }
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links.first { $0.valueID == legacyValue.id }?.id, legacyLink.id)
        let revisions = try finalContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
        XCTAssertEqual(revisions.count, 2)
        XCTAssertEqual(Set(links.filter { $0.valueID != legacyValue.id }.map(\.revisionID)), Set(revisions.map(\.id)))
        XCTAssertFalse(links.contains { $0.valueID == legacyValue.id && $0.revisionID != originalRevision.id })
    }

    func testV2AddAndActiveTogglePersistFailureKeepsContextCleanAndSameDraftCanRetryAfterReopen() throws {
        let fixture = try makeFixture()
        let metricID = fixture.metric.id
        let originalRevision = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).first)
        let legacyValue = MetricValue(metric: fixture.metric, scaledValue: 31_000)
        let workout = Workout(day: Date(timeIntervalSince1970: 1_700_000_100), records: [
            ExerciseRecord(exercise: fixture.exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [legacyValue])])
        ])
        fixture.context.insert(workout)
        let legacyLink = try MetricValueRevisionLinking.register(value: legacyValue, revision: originalRevision, in: fixture.context)
        try fixture.context.save()
        let metricBefore = MetricDefinitionSnapshot(fixture.metric)
        let valueBefore = WorkoutValueSnapshot(legacyValue)
        let draftMetric = MetricDefinitionDraft(name: "時間", unit: "秒", allowsDecimal: true, isRequired: false)
        var drafts = try MetricDefinitionEditingV2.draft(for: fixture.exercise, in: fixture.context)
        drafts[0].isActive = false
        drafts.append(draftMetric)

        XCTAssertThrowsError(try MetricDefinitionEditingV2.save(drafts, for: fixture.exercise, in: fixture.context) { _ in
            throw InjectedFailure.expected
        }) { error in
            guard case InjectedFailure.expected = error else { return XCTFail("注入したエラー型が伝播する必要: \(error)") }
        }
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(MetricDefinitionSnapshot(fixture.metric), metricBefore)
        XCTAssertEqual(WorkoutValueSnapshot(legacyValue), valueBefore)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<MetricDefinition>()).map(\.id).sorted { $0.uuidString < $1.uuidString }, [metricID].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [originalRevision.id])
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.id), [legacyLink.id])

        let afterFailure = ModelContext(fixture.container)
        let persistedExercise = try XCTUnwrap(try afterFailure.fetch(FetchDescriptor<Exercise>()).first { $0.id == fixture.exercise.id })
        XCTAssertEqual(persistedExercise.metrics.map(\.id), [metricID])
        XCTAssertEqual(try afterFailure.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [originalRevision.id])
        XCTAssertEqual(try afterFailure.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.id), [legacyLink.id])

        try MetricDefinitionEditingV2.save(drafts, for: fixture.exercise, in: fixture.context)
        XCTAssertFalse(fixture.context.hasChanges)
        let afterRetry = ModelContext(fixture.container)
        let retriedExercise = try XCTUnwrap(try afterRetry.fetch(FetchDescriptor<Exercise>()).first { $0.id == fixture.exercise.id })
        let retriedMetrics = retriedExercise.metrics.sorted { $0.sortOrder < $1.sortOrder }
        let retriedAddedMetric = try XCTUnwrap(retriedMetrics.first { $0.name == "時間" })
        XCTAssertEqual(retriedMetrics.count, 2)
        XCTAssertNotEqual(retriedAddedMetric.id, metricID)
        XCTAssertEqual(retriedMetrics.map(\.id).sorted { $0.uuidString < $1.uuidString }, [metricID, retriedAddedMetric.id].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(retriedMetrics.map(\.sortOrder), [0, 1])
        XCTAssertEqual(retriedMetrics.map(\.isActive), [false, true])
        XCTAssertEqual(retriedMetrics.first { $0.name == "時間" }?.unit, "秒")
        XCTAssertEqual(try afterRetry.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), [originalRevision.id])
        XCTAssertEqual(try afterRetry.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.id), [legacyLink.id])
        XCTAssertEqual(WorkoutValueSnapshot(try XCTUnwrap(try afterRetry.fetch(FetchDescriptor<MetricValue>()).first { $0.id == legacyValue.id })), valueBefore)
    }

    func testUnchangedDraftDoesNotCreateRevisionOrLinkForExistingOrLegacyHistory() throws {
        let withHistory = try makeFixture()
        let existingRevision = try XCTUnwrap(try withHistory.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).first)
        existingRevision.revision = Int.max
        try withHistory.context.save()
        let unchangedMetric = MetricDefinitionSnapshot(withHistory.metric)
        let unchangedRevision = (existingRevision.id, existingRevision.seriesID, existingRevision.revision, existingRevision.name, existingRevision.unit)

        XCTAssertNoThrow(try MetricDefinitionEditingV2.save(try MetricDefinitionEditingV2.draft(for: withHistory.exercise, in: withHistory.context), for: withHistory.exercise, in: withHistory.context))
        XCTAssertFalse(withHistory.context.hasChanges)
        XCTAssertEqual(MetricDefinitionSnapshot(withHistory.metric), unchangedMetric)
        let unchangedHistory = try withHistory.context.fetch(FetchDescriptor<MetricDefinitionRevision>())
        XCTAssertEqual(unchangedHistory.map(\.id), [unchangedRevision.0])
        XCTAssertEqual(unchangedHistory.first?.seriesID, unchangedRevision.1)
        XCTAssertEqual(unchangedHistory.first?.revision, unchangedRevision.2)
        XCTAssertEqual(unchangedHistory.first?.name, unchangedRevision.3)
        XCTAssertEqual(unchangedHistory.first?.unit, unchangedRevision.4)
        XCTAssertTrue(try withHistory.context.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)

        let legacy = try makeFixture(name: "距離", unit: "m", withHistory: false)
        let value = MetricValue(metric: legacy.metric, scaledValue: 4_200)
        legacy.context.insert(value)
        try legacy.context.save()
        let legacyMetricBefore = MetricDefinitionSnapshot(legacy.metric)
        XCTAssertNoThrow(try MetricDefinitionEditingV2.save(try MetricDefinitionEditingV2.draft(for: legacy.exercise, in: legacy.context), for: legacy.exercise, in: legacy.context))
        XCTAssertFalse(legacy.context.hasChanges)
        XCTAssertEqual(MetricDefinitionSnapshot(legacy.metric), legacyMetricBefore)
        XCTAssertTrue(try legacy.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).isEmpty)
        XCTAssertTrue(try legacy.context.fetch(FetchDescriptor<MetricValueRevisionLink>()).isEmpty)

        var changedDrafts = try MetricDefinitionEditingV2.draft(for: withHistory.exercise, in: withHistory.context)
        changedDrafts[0].unit = "lb"
        XCTAssertThrowsError(try MetricDefinitionEditingV2.save(changedDrafts, for: withHistory.exercise, in: withHistory.context)) { error in
            guard case MetricDefinitionEditingV2Error.revisionOverflow = error else { return XCTFail("revisionOverflow型が必要: \(error)") }
        }
        XCTAssertEqual(MetricDefinitionSnapshot(withHistory.metric).unit, "kg")
        XCTAssertEqual(try withHistory.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.revision).sorted(), [Int.max])
        XCTAssertFalse(withHistory.context.hasChanges)
    }

    func testDefinitionChangeAndAddAndDeactivateAreSavedTogetherAndSurviveSQLiteReopen() throws {
        let fixture = try makeFixture(name: "負荷", unit: "kg")
        let metricID = fixture.metric.id
        let oldRevision = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).first)
        let oldValue = MetricValue(metric: fixture.metric, scaledValue: 63_250)
        let expectedOldValue = WorkoutValueSnapshot(oldValue)
        fixture.context.insert(oldValue)
        let oldLink = try MetricValueRevisionLinking.register(value: oldValue, revision: oldRevision, in: fixture.context)
        try fixture.context.save()

        var drafts = try MetricDefinitionEditingV2.draft(for: fixture.exercise, in: fixture.context)
        drafts[0].name = "出力"
        drafts[0].unit = "W"
        drafts[0].isActive = false
        drafts.append(MetricDefinitionDraft(name: "時間", unit: "秒", allowsDecimal: false, isRequired: true))
        try MetricDefinitionEditingV2.save(drafts, for: fixture.exercise, in: fixture.context)

        let reopened = ModelContext(fixture.container)
        let savedExercise = try XCTUnwrap(try reopened.fetch(FetchDescriptor<Exercise>()).first { $0.id == fixture.exercise.id })
        let metrics = savedExercise.metrics.sorted { $0.sortOrder < $1.sortOrder }
        let added = try XCTUnwrap(metrics.first { $0.name == "時間" })
        XCTAssertEqual(metrics.count, 2)
        XCTAssertEqual(metrics.map(\.sortOrder), [0, 1])
        XCTAssertEqual(metrics.map(\.id).first, metricID)
        XCTAssertEqual(metrics.map(\.isActive), [false, true])
        XCTAssertEqual((metrics.first { $0.id == metricID })?.unit, "W")
        XCTAssertEqual(added.unit, "秒")

        let revisions = try reopened.fetch(FetchDescriptor<MetricDefinitionRevision>()).sorted { $0.revision < $1.revision }
        XCTAssertEqual(revisions.count, 2)
        let revised = try XCTUnwrap(revisions.first { $0.metricID == metricID && $0.revision == 2 })
        XCTAssertEqual(revised.name, "出力")
        XCTAssertEqual(revised.unit, "W")
        XCTAssertNotEqual(revised.seriesID, oldRevision.seriesID)
        XCTAssertNotEqual(revised.id, oldRevision.id)
        XCTAssertFalse(revisions.contains { $0.metricID == added.id }, "新規項目に既存値用revisionを作らない")

        let storedValue = try XCTUnwrap(try reopened.fetch(FetchDescriptor<MetricValue>()).first { $0.id == oldValue.id })
        XCTAssertEqual(WorkoutValueSnapshot(storedValue), expectedOldValue)
        let links = try reopened.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(links.map(\.id), [oldLink.id])
        XCTAssertEqual(links.first?.revisionID, oldRevision.id)
    }

    func testSortOrderOverflowIsRejectedWithoutSideEffects() throws {
        let overflow = try makeFixture()
        overflow.metric.sortOrder = Int.max
        try overflow.context.save()
        var overflowDrafts = try MetricDefinitionEditingV2.draft(for: overflow.exercise, in: overflow.context)
        overflowDrafts.append(MetricDefinitionDraft(name: "回数", unit: "回", allowsDecimal: false, isRequired: false))
        let overflowSnapshot = MetricDefinitionSnapshot(overflow.metric)
        let revisionsBefore = try overflow.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id)
        XCTAssertThrowsError(try MetricDefinitionEditingV2.save(overflowDrafts, for: overflow.exercise, in: overflow.context)) { error in
            guard case MetricDefinitionEditingError.sortOrderOverflow = error else { return XCTFail("sortOrderOverflow型が必要: \(error)") }
        }
        XCTAssertFalse(overflow.context.hasChanges)
        XCTAssertEqual(MetricDefinitionSnapshot(overflow.metric), overflowSnapshot)
        XCTAssertEqual(try overflow.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), revisionsBefore)
        XCTAssertEqual(overflow.exercise.metrics.count, 1)
    }

    func testEmptyDraftsAreInvalidWhenExerciseHasNoMetricsWithoutSideEffects() throws {
        let empty = try makeFixture()
        let emptyExercise = Exercise(name: "空の種目", metrics: [])
        let revisionsBefore = try empty.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id)
        let linksBefore = try empty.context.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.id)
        empty.context.insert(emptyExercise)
        try empty.context.save()
        XCTAssertThrowsError(try MetricDefinitionEditingV2.save([], for: emptyExercise, in: empty.context)) { error in
            guard case MetricDefinitionEditingError.invalid = error else { return XCTFail("invalid型が必要: \(error)") }
        }
        XCTAssertFalse(empty.context.hasChanges)
        XCTAssertTrue(emptyExercise.metrics.isEmpty)
        XCTAssertEqual(try empty.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id), revisionsBefore)
        XCTAssertEqual(try empty.context.fetch(FetchDescriptor<MetricValueRevisionLink>()).map(\.id), linksBefore)
    }

    func testEmptyDraftMissingExistingMetricIsChangedWithoutSideEffects() throws {
        let existing = try makeFixture()
        let metricBefore = MetricDefinitionSnapshot(existing.metric)
        let revisionsBefore = try existing.context.fetch(FetchDescriptor<MetricDefinitionRevision>())
            .map { ($0.id, $0.seriesID, $0.revision, $0.name, $0.unit) }
        XCTAssertThrowsError(try MetricDefinitionEditingV2.save([], for: existing.exercise, in: existing.context)) { error in
            guard case MetricDefinitionEditingV2Error.changed = error else { return XCTFail("changed型が必要: \(error)") }
        }
        XCTAssertFalse(existing.context.hasChanges)
        XCTAssertEqual(MetricDefinitionSnapshot(existing.metric), metricBefore)
        let revisionsAfter = try existing.context.fetch(FetchDescriptor<MetricDefinitionRevision>())
            .map { ($0.id, $0.seriesID, $0.revision, $0.name, $0.unit) }
        XCTAssertEqual(revisionsAfter.map { $0.0 }, revisionsBefore.map { $0.0 })
        XCTAssertEqual(revisionsAfter.map { $0.1 }, revisionsBefore.map { $0.1 })
        XCTAssertEqual(revisionsAfter.map { $0.2 }, revisionsBefore.map { $0.2 })
        XCTAssertEqual(revisionsAfter.map { $0.3 }, revisionsBefore.map { $0.3 })
        XCTAssertEqual(revisionsAfter.map { $0.4 }, revisionsBefore.map { $0.4 })
        XCTAssertEqual(existing.exercise.metrics.map(\.id), [existing.metric.id])
    }

    func testDuplicateExistingDraftIDIsRejectedWithoutChangingDefinitionsValuesOrLinks() throws {
        let fixture = try makeFixture()
        let revision = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).first)
        let value = MetricValue(metric: fixture.metric, scaledValue: 27_500)
        fixture.context.insert(value)
        try fixture.context.save()
        let link = MetricValueRevisionLink(valueID: value.id, revisionID: revision.id)
        fixture.context.insert(link)
        try fixture.context.save()

        let metricBefore = MetricDefinitionSnapshot(fixture.metric)
        let valueBefore = WorkoutValueSnapshot(value)
        let revisionBefore = (revision.id, revision.seriesID, revision.revision, revision.name, revision.unit)
        let linkBefore = (link.id, link.valueID, link.revisionID)
        let drafts = [MetricDefinitionDraft(existing: fixture.metric), MetricDefinitionDraft(existing: fixture.metric)]
        var changedDrafts = drafts
        changedDrafts[0].name = "変更案"

        XCTAssertThrowsError(try MetricDefinitionEditingV2.save(changedDrafts, for: fixture.exercise, in: fixture.context)) { error in
            guard case MetricDefinitionEditingV2Error.changed = error else { return XCTFail("changed型が必要: \(error)") }
        }
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(MetricDefinitionSnapshot(fixture.metric), metricBefore)
        XCTAssertEqual(WorkoutValueSnapshot(value), valueBefore)
        let revisionsAfter = try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>())
        XCTAssertEqual(revisionsAfter.map(\.id), [revisionBefore.0])
        XCTAssertEqual(revisionsAfter.first?.seriesID, revisionBefore.1)
        XCTAssertEqual(revisionsAfter.first?.revision, revisionBefore.2)
        XCTAssertEqual(revisionsAfter.first?.name, revisionBefore.3)
        XCTAssertEqual(revisionsAfter.first?.unit, revisionBefore.4)
        let linksAfter = try fixture.context.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(linksAfter.map(\.id), [linkBefore.0])
        XCTAssertEqual(linksAfter.first?.valueID, linkBefore.1)
        XCTAssertEqual(linksAfter.first?.revisionID, linkBefore.2)

        let reopened = ModelContext(fixture.container)
        let savedExercise = try XCTUnwrap(try reopened.fetch(FetchDescriptor<Exercise>()).first { $0.id == fixture.exercise.id })
        XCTAssertEqual(savedExercise.metrics.map(MetricDefinitionSnapshot.init), [metricBefore])
        XCTAssertEqual(WorkoutValueSnapshot(try XCTUnwrap(try reopened.fetch(FetchDescriptor<MetricValue>()).first { $0.id == value.id })), valueBefore)
        let reopenedRevisions = try reopened.fetch(FetchDescriptor<MetricDefinitionRevision>())
        XCTAssertEqual(reopenedRevisions.map(\.id), [revisionBefore.0])
        XCTAssertEqual(reopenedRevisions.first?.seriesID, revisionBefore.1)
        XCTAssertEqual(reopenedRevisions.first?.revision, revisionBefore.2)
        XCTAssertEqual(reopenedRevisions.first?.name, revisionBefore.3)
        XCTAssertEqual(reopenedRevisions.first?.unit, revisionBefore.4)
        let reopenedLinks = try reopened.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(reopenedLinks.map(\.id), [linkBefore.0])
        XCTAssertEqual(reopenedLinks.first?.valueID, linkBefore.1)
        XCTAssertEqual(reopenedLinks.first?.revisionID, linkBefore.2)
    }

    func testDuplicateStoredMetricIDsAreRejectedWithoutChangingDefinitionsValuesOrLinks() throws {
        let fixture = try makeFixture()
        let revision = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>()).first)
        let value = MetricValue(metric: fixture.metric, scaledValue: 41_000)
        fixture.context.insert(value)
        try fixture.context.save()
        let link = MetricValueRevisionLink(valueID: value.id, revisionID: revision.id)
        fixture.context.insert(link)
        try fixture.context.save()

        var drafts = try MetricDefinitionEditingV2.draft(for: fixture.exercise, in: fixture.context)
        let valueBefore = WorkoutValueSnapshot(value)
        let revisionBefore = (revision.id, revision.seriesID, revision.revision, revision.name, revision.unit)
        let linkBefore = (link.id, link.valueID, link.revisionID)
        let duplicateMetric = MetricDefinition(name: "別定義", unit: "回", allowsDecimal: false, isRequired: true, sortOrder: 1)
        duplicateMetric.id = fixture.metric.id
        fixture.exercise.metrics.append(duplicateMetric)
        try fixture.context.save()
        let metricsBefore = fixture.exercise.metrics.map(MetricDefinitionSnapshot.init).sorted { $0.sortOrder < $1.sortOrder }
        drafts[0].unit = "lb"

        XCTAssertThrowsError(try MetricDefinitionEditingV2.save(drafts, for: fixture.exercise, in: fixture.context)) { error in
            guard case MetricDefinitionEditingV2Error.changed = error else { return XCTFail("changed型が必要: \(error)") }
        }
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(fixture.exercise.metrics.map(MetricDefinitionSnapshot.init).sorted { $0.sortOrder < $1.sortOrder }, metricsBefore)
        XCTAssertEqual(WorkoutValueSnapshot(value), valueBefore)
        let revisionsAfter = try fixture.context.fetch(FetchDescriptor<MetricDefinitionRevision>())
        XCTAssertEqual(revisionsAfter.map(\.id), [revisionBefore.0])
        XCTAssertEqual(revisionsAfter.first?.seriesID, revisionBefore.1)
        XCTAssertEqual(revisionsAfter.first?.revision, revisionBefore.2)
        XCTAssertEqual(revisionsAfter.first?.name, revisionBefore.3)
        XCTAssertEqual(revisionsAfter.first?.unit, revisionBefore.4)
        let linksAfter = try fixture.context.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(linksAfter.map(\.id), [linkBefore.0])
        XCTAssertEqual(linksAfter.first?.valueID, linkBefore.1)
        XCTAssertEqual(linksAfter.first?.revisionID, linkBefore.2)

        let reopened = ModelContext(fixture.container)
        let savedExercise = try XCTUnwrap(try reopened.fetch(FetchDescriptor<Exercise>()).first { $0.id == fixture.exercise.id })
        XCTAssertEqual(savedExercise.metrics.map(MetricDefinitionSnapshot.init).sorted { $0.sortOrder < $1.sortOrder }, metricsBefore)
        XCTAssertEqual(WorkoutValueSnapshot(try XCTUnwrap(try reopened.fetch(FetchDescriptor<MetricValue>()).first { $0.id == value.id })), valueBefore)
        let reopenedRevisions = try reopened.fetch(FetchDescriptor<MetricDefinitionRevision>())
        XCTAssertEqual(reopenedRevisions.map(\.id), [revisionBefore.0])
        XCTAssertEqual(reopenedRevisions.first?.seriesID, revisionBefore.1)
        XCTAssertEqual(reopenedRevisions.first?.revision, revisionBefore.2)
        XCTAssertEqual(reopenedRevisions.first?.name, revisionBefore.3)
        XCTAssertEqual(reopenedRevisions.first?.unit, revisionBefore.4)
        let reopenedLinks = try reopened.fetch(FetchDescriptor<MetricValueRevisionLink>())
        XCTAssertEqual(reopenedLinks.map(\.id), [linkBefore.0])
        XCTAssertEqual(reopenedLinks.first?.valueID, linkBefore.1)
        XCTAssertEqual(reopenedLinks.first?.revisionID, linkBefore.2)
    }

    func testProductionV2MigrationPreservesMultiWorkoutLegacyMetricSnapshotsAfterReopen() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteMetricDefinitionEditingV2Migration-\(UUID().uuidString).sqlite")
        let v1Schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let v1Configuration = ModelConfiguration("MeleteMetricDefinitionEditingV2MigrationV1", schema: v1Schema, url: storeURL, cloudKitDatabase: .none)

        let exerciseIDs = [UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, UUID(uuidString: "10000000-0000-0000-0000-000000000002")!]
        let metricIDs = [
            UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
        ]
        let workoutIDs = [UUID(uuidString: "30000000-0000-0000-0000-000000000001")!, UUID(uuidString: "30000000-0000-0000-0000-000000000002")!]
        let recordIDs = [
            UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "40000000-0000-0000-0000-000000000003")!
        ]
        let setIDs = (1...4).map { UUID(uuidString: String(format: "50000000-0000-0000-0000-%012d", $0))! }
        let valueIDs = (1...7).map { UUID(uuidString: String(format: "60000000-0000-0000-0000-%012d", $0))! }
        let exerciseDates = [Date(timeIntervalSince1970: 1_700_000_001.125), Date(timeIntervalSince1970: 1_700_000_002.25)]
        let workoutDates = [Date(timeIntervalSince1970: 1_700_000_010.5), Date(timeIntervalSince1970: 1_700_000_020.75)]
        let setDates = (1...4).map { Date(timeIntervalSince1970: 1_700_000_100 + Double($0) + 0.125) }

        do {
            let container = try ModelContainer(for: v1Schema, configurations: [v1Configuration])
            let context = ModelContext(container)
            let load = MetricDefinition(name: "現行負荷", unit: "kg", allowsDecimal: false, isRequired: true, sortOrder: 8)
            load.id = metricIDs[0]
            let reps = MetricDefinition(name: "現行回数", unit: "回", allowsDecimal: true, isRequired: true, sortOrder: 2)
            reps.id = metricIDs[1]
            let duration = MetricDefinition(name: "現行時間", unit: "秒", allowsDecimal: true, isRequired: false, sortOrder: 5)
            duration.id = metricIDs[2]
            let archivedExercise = Exercise(name: "旧種目A", metrics: [load, reps])
            archivedExercise.id = exerciseIDs[0]
            archivedExercise.createdAt = exerciseDates[0]
            archivedExercise.isArchived = true
            let activeExercise = Exercise(name: "旧種目B", metrics: [duration])
            activeExercise.id = exerciseIDs[1]
            activeExercise.createdAt = exerciseDates[1]

            let oldLoad = MetricValue(metric: load, scaledValue: 82_500)
            oldLoad.id = valueIDs[0]; oldLoad.name = "記録時負荷"; oldLoad.unit = "lb"; oldLoad.allowsDecimal = true; oldLoad.isRequired = false
            let oldRepsNil = MetricValue(metric: reps, scaledValue: nil)
            oldRepsNil.id = valueIDs[1]; oldRepsNil.name = "記録時回数"; oldRepsNil.unit = "回"; oldRepsNil.allowsDecimal = false; oldRepsNil.isRequired = false
            let setA1 = SetRecord(sortOrder: 9, values: [oldRepsNil, oldLoad])
            setA1.id = setIDs[0]; setA1.createdAt = setDates[0]
            let recordA1 = ExerciseRecord(exercise: archivedExercise, sortOrder: 7, sets: [setA1])
            recordA1.id = recordIDs[0]

            let oldLoadZero = MetricValue(metric: load, scaledValue: 0)
            oldLoadZero.id = valueIDs[2]; oldLoadZero.name = "記録時負荷"; oldLoadZero.unit = "lb"; oldLoadZero.allowsDecimal = true; oldLoadZero.isRequired = false
            let oldRepsValue = MetricValue(metric: reps, scaledValue: 12_000)
            oldRepsValue.id = valueIDs[3]; oldRepsValue.name = "記録時回数"; oldRepsValue.unit = "回"; oldRepsValue.allowsDecimal = false; oldRepsValue.isRequired = false
            let setA2 = SetRecord(sortOrder: 3, values: [oldLoadZero, oldRepsValue])
            setA2.id = setIDs[1]; setA2.createdAt = setDates[1]
            let recordA2 = ExerciseRecord(exercise: archivedExercise, sortOrder: 2, sets: [setA2])
            recordA2.id = recordIDs[1]

            let oldDuration = MetricValue(metric: duration, scaledValue: 0)
            oldDuration.id = valueIDs[4]; oldDuration.name = "記録時時間"; oldDuration.unit = "分"; oldDuration.allowsDecimal = false; oldDuration.isRequired = true
            let setB = SetRecord(sortOrder: 6, values: [oldDuration])
            setB.id = setIDs[2]; setB.createdAt = setDates[2]
            let recordB = ExerciseRecord(exercise: activeExercise, sortOrder: 4, sets: [setB])
            recordB.id = recordIDs[2]

            let anotherLoadNil = MetricValue(metric: load, scaledValue: nil)
            anotherLoadNil.id = valueIDs[5]; anotherLoadNil.name = "記録時負荷"; anotherLoadNil.unit = "lb"; anotherLoadNil.allowsDecimal = true; anotherLoadNil.isRequired = false
            let anotherReps = MetricValue(metric: reps, scaledValue: 8_000)
            anotherReps.id = valueIDs[6]; anotherReps.name = "記録時回数"; anotherReps.unit = "回"; anotherReps.allowsDecimal = false; anotherReps.isRequired = false
            let setA3 = SetRecord(sortOrder: 1, values: [anotherLoadNil, anotherReps])
            setA3.id = setIDs[3]; setA3.createdAt = setDates[3]
            let recordA3 = ExerciseRecord(exercise: archivedExercise, sortOrder: 1, sets: [setA3])
            recordA3.id = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!

            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let workoutA = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [recordA1, recordA2], calendar: utc)
            workoutA.id = workoutIDs[0]; workoutA.createdAt = workoutDates[0]
            let workoutB = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [recordB, recordA3], calendar: utc)
            workoutB.id = workoutIDs[1]; workoutB.createdAt = workoutDates[1]
            context.insert(archivedExercise); context.insert(activeExercise)
            context.insert(workoutA); context.insert(workoutB)
            try context.save()
        }

        let v2Schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let v2Configuration = ModelConfiguration("MeleteMetricDefinitionEditingV2MigrationV2", schema: v2Schema, url: storeURL, cloudKitDatabase: .none)
        let migrated = try ModelContainer(for: v2Schema, migrationPlan: MeleteMigrationPlan.self, configurations: [v2Configuration])

        let verify: (ModelContext) throws -> Void = { context in
            XCTAssertEqual(try context.fetch(FetchDescriptor<MetricDefinitionRevision>()).count, 0)
            XCTAssertEqual(try context.fetch(FetchDescriptor<MetricValueRevisionLink>()).count, 0)
            let exercises = try context.fetch(FetchDescriptor<Exercise>())
            XCTAssertEqual(Set(exercises.map(\.id)), Set(exerciseIDs))
            let byExercise = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
            let archived = try XCTUnwrap(byExercise[exerciseIDs[0]])
            XCTAssertEqual(archived.name, "旧種目A"); XCTAssertEqual(archived.createdAt, exerciseDates[0]); XCTAssertTrue(archived.isArchived)
            let active = try XCTUnwrap(byExercise[exerciseIDs[1]])
            XCTAssertEqual(active.name, "旧種目B"); XCTAssertEqual(active.createdAt, exerciseDates[1]); XCTAssertFalse(active.isArchived)
            let definitions = Dictionary(uniqueKeysWithValues: exercises.flatMap(\.metrics).map { ($0.id, $0) })
            XCTAssertEqual(Set(definitions.keys), Set(metricIDs))
            XCTAssertEqual(definitions[metricIDs[0]]?.name, "現行負荷"); XCTAssertEqual(definitions[metricIDs[0]]?.unit, "kg")
            XCTAssertFalse(definitions[metricIDs[0]]?.allowsDecimal ?? true); XCTAssertTrue(definitions[metricIDs[0]]?.isRequired ?? false)
            XCTAssertEqual(definitions[metricIDs[0]]?.sortOrder, 8); XCTAssertTrue(definitions[metricIDs[0]]?.isActive ?? false)
            XCTAssertEqual(definitions[metricIDs[1]]?.name, "現行回数"); XCTAssertEqual(definitions[metricIDs[1]]?.unit, "回")
            XCTAssertTrue(definitions[metricIDs[1]]?.allowsDecimal ?? false); XCTAssertTrue(definitions[metricIDs[1]]?.isRequired ?? false)
            XCTAssertEqual(definitions[metricIDs[1]]?.sortOrder, 2); XCTAssertTrue(definitions[metricIDs[1]]?.isActive ?? false)
            XCTAssertEqual(definitions[metricIDs[2]]?.name, "現行時間"); XCTAssertEqual(definitions[metricIDs[2]]?.unit, "秒")
            XCTAssertTrue(definitions[metricIDs[2]]?.allowsDecimal ?? false); XCTAssertFalse(definitions[metricIDs[2]]?.isRequired ?? true)
            XCTAssertEqual(definitions[metricIDs[2]]?.sortOrder, 5); XCTAssertTrue(definitions[metricIDs[2]]?.isActive ?? false)
            XCTAssertEqual(definitions[metricIDs[0]]?.exercise?.id, exerciseIDs[0]); XCTAssertEqual(definitions[metricIDs[1]]?.exercise?.id, exerciseIDs[0])
            XCTAssertEqual(definitions[metricIDs[2]]?.exercise?.id, exerciseIDs[1])
            XCTAssertEqual(archived.metrics.sorted { $0.sortOrder < $1.sortOrder }.map(\.id), [metricIDs[1], metricIDs[0]])
            XCTAssertEqual(active.metrics.sorted { $0.sortOrder < $1.sortOrder }.map(\.id), [metricIDs[2]])

            let workouts = try context.fetch(FetchDescriptor<Workout>())
            XCTAssertEqual(Set(workouts.map(\.id)), Set(workoutIDs))
            let byWorkout = Dictionary(uniqueKeysWithValues: workouts.map { ($0.id, $0) })
            XCTAssertEqual(byWorkout[workoutIDs[0]]?.day, "2023-11-14"); XCTAssertEqual(byWorkout[workoutIDs[0]]?.createdAt, workoutDates[0])
            XCTAssertEqual(byWorkout[workoutIDs[1]]?.day, "2023-11-03"); XCTAssertEqual(byWorkout[workoutIDs[1]]?.createdAt, workoutDates[1])
            XCTAssertEqual(byWorkout[workoutIDs[0]]?.records.sorted { $0.sortOrder < $1.sortOrder }.map(\.id), [recordIDs[1], recordIDs[0]])
            XCTAssertEqual(byWorkout[workoutIDs[1]]?.records.sorted { $0.sortOrder < $1.sortOrder }.map(\.id), [UUID(uuidString: "40000000-0000-0000-0000-000000000004")!, recordIDs[2]])
            let expectedRecords: [(UUID, UUID, String, Int, UUID)] = [
                (recordIDs[0], workoutIDs[0], "旧種目A", 7, setIDs[0]), (recordIDs[1], workoutIDs[0], "旧種目A", 2, setIDs[1]),
                (recordIDs[2], workoutIDs[1], "旧種目B", 4, setIDs[2]),
                (UUID(uuidString: "40000000-0000-0000-0000-000000000004")!, workoutIDs[1], "旧種目A", 1, setIDs[3])
            ]
            let allRecords = workouts.flatMap(\.records)
            XCTAssertEqual(Set(allRecords.map(\.id)), Set(expectedRecords.map(\.0)))
            for (recordID, workoutID, name, order, setID) in expectedRecords {
                let record = try XCTUnwrap(allRecords.first { $0.id == recordID })
                XCTAssertEqual(record.workout?.id, workoutID); XCTAssertEqual(record.exerciseName, name)
                XCTAssertEqual(record.exerciseID, name == "旧種目A" ? exerciseIDs[0] : exerciseIDs[1]); XCTAssertEqual(record.sortOrder, order)
                XCTAssertEqual(record.sets.map(\.id).sorted { $0.uuidString < $1.uuidString }, [setID])
                let set = try XCTUnwrap(record.sets.first)
                XCTAssertEqual(set.exerciseRecord?.id, recordID)
                let expectedSetIndex = setIDs.firstIndex(of: setID)!
                XCTAssertEqual(set.sortOrder, [9, 3, 6, 1][expectedSetIndex]); XCTAssertEqual(set.createdAt, setDates[expectedSetIndex])
                let expectedValueIDs: [[UUID]] = [[valueIDs[0], valueIDs[1]], [valueIDs[2], valueIDs[3]], [valueIDs[4]], [valueIDs[5], valueIDs[6]]]
                XCTAssertEqual(set.values.map(\.id).sorted { $0.uuidString < $1.uuidString }, expectedValueIDs[expectedSetIndex].sorted { $0.uuidString < $1.uuidString })
            }
            let allValues = workouts.flatMap(\.records).flatMap(\.sets).flatMap(\.values)
            XCTAssertEqual(Set(allValues.map(\.id)), Set(valueIDs))
            let byValue = Dictionary(uniqueKeysWithValues: allValues.map { ($0.id, $0) })
            let legacySnapshots: [(UUID, UUID, UUID, String, String, Bool, Bool)] = [
                (valueIDs[0], metricIDs[0], setIDs[0], "記録時負荷", "lb", true, false), (valueIDs[1], metricIDs[1], setIDs[0], "記録時回数", "回", false, false),
                (valueIDs[2], metricIDs[0], setIDs[1], "記録時負荷", "lb", true, false), (valueIDs[3], metricIDs[1], setIDs[1], "記録時回数", "回", false, false),
                (valueIDs[4], metricIDs[2], setIDs[2], "記録時時間", "分", false, true), (valueIDs[5], metricIDs[0], setIDs[3], "記録時負荷", "lb", true, false),
                (valueIDs[6], metricIDs[1], setIDs[3], "記録時回数", "回", false, false)
            ]
            for (valueID, metricID, setID, name, unit, decimals, required) in legacySnapshots {
                let value = try XCTUnwrap(byValue[valueID])
                XCTAssertEqual(value.metricID, metricID); XCTAssertEqual(value.name, name); XCTAssertEqual(value.unit, unit)
                XCTAssertEqual(value.allowsDecimal, decimals); XCTAssertEqual(value.isRequired, required)
                XCTAssertEqual(value.setRecord?.id, setID)
            }
            XCTAssertEqual(byValue[valueIDs[0]]?.scaledValue, 82_500)
            XCTAssertNil(byValue[valueIDs[1]]?.scaledValue)
            XCTAssertEqual(byValue[valueIDs[2]]?.scaledValue, 0)
            XCTAssertEqual(byValue[valueIDs[3]]?.scaledValue, 12_000)
            XCTAssertEqual(byValue[valueIDs[4]]?.scaledValue, 0)
            XCTAssertNil(byValue[valueIDs[5]]?.scaledValue)
            XCTAssertEqual(byValue[valueIDs[6]]?.scaledValue, 8_000)
        }
        try verify(ModelContext(migrated))
        let reopened = try ModelContainer(for: v2Schema, migrationPlan: MeleteMigrationPlan.self, configurations: [v2Configuration])
        try verify(ModelContext(reopened))
    }

    func testProductionMigrationThenAllWorkoutWritesThroughV2ServiceAndReopen() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeleteV2ServiceVerticalSlice-\(UUID().uuidString).sqlite")
        let v1Schema = Schema(versionedSchema: MeleteSchemaV1.self)
        let v1Configuration = ModelConfiguration("MeleteV2ServiceVerticalSliceV1", schema: v1Schema, url: storeURL, cloudKitDatabase: .none)
        let exerciseID = UUID()
        let metricID = UUID()
        let oldWorkoutID = UUID()
        let unaffectedWorkoutID = UUID()
        let oldValueSnapshots: [WorkoutValueSnapshot]

        do {
            let v1 = try ModelContainer(for: v1Schema, configurations: [v1Configuration])
            let context = ModelContext(v1)
            let metric = MetricDefinition(name: "重量", unit: "kg", allowsDecimal: false, isRequired: false, sortOrder: 0)
            metric.id = metricID
            let exercise = Exercise(name: "合成種目", metrics: [metric])
            exercise.id = exerciseID
            let firstValue = MetricValue(metric: metric, scaledValue: 12_000)
            firstValue.name = "記録当時の重量"
            firstValue.unit = "lb"
            let secondValue = MetricValue(metric: metric, scaledValue: 15_000)
            let oldWorkout = Workout(day: Date(timeIntervalSince1970: 1_700_000_000), records: [
                ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [
                    SetRecord(sortOrder: 1, values: [firstValue]),
                    SetRecord(sortOrder: 2, values: [secondValue])
                ])
            ])
            oldWorkout.id = oldWorkoutID
            let unaffectedValue = MetricValue(metric: metric, scaledValue: 7_000)
            let unaffectedWorkout = Workout(day: Date(timeIntervalSince1970: 1_699_000_000), records: [
                ExerciseRecord(exercise: exercise, sortOrder: 0, sets: [SetRecord(sortOrder: 1, values: [unaffectedValue])])
            ])
            unaffectedWorkout.id = unaffectedWorkoutID
            oldValueSnapshots = [firstValue, secondValue, unaffectedValue].map(WorkoutValueSnapshot.init)
            context.insert(exercise)
            context.insert(oldWorkout)
            context.insert(unaffectedWorkout)
            try context.save()
        }

        let v2Schema = Schema(versionedSchema: MeleteSchemaV2.self)
        let v2Configuration = ModelConfiguration("MeleteV2ServiceVerticalSliceV2", schema: v2Schema, url: storeURL, cloudKitDatabase: .none)
        let migrated = try ModelContainer(for: v2Schema, migrationPlan: MeleteMigrationPlan.self, configurations: [v2Configuration])
        let context = ModelContext(migrated)
        let service = WorkoutWritingServiceV2(context: context)
        let exercise = try XCTUnwrap(try context.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseID })
        let metric = try XCTUnwrap(exercise.metrics.first { $0.id == metricID })
        var definitionDrafts = try MetricDefinitionEditingV2.draft(for: exercise, in: context)
        definitionDrafts[0].name = "出力"
        definitionDrafts[0].unit = "W"
        definitionDrafts[0].allowsDecimal = true
        definitionDrafts[0].isRequired = true

        // スタブで明示的に失敗する。実装後は同じservice APIの全操作が通る縦切りとなる。
        try service.saveMetricDefinitions(definitionDrafts, for: exercise)

        var entry = WorkoutEntryDraft(exercise: exercise)
        entry.sets[0].values[metricID] = "2.5"
        let newWorkout = try service.createWorkout(day: Date(timeIntervalSince1970: 1_700_100_000), entries: [entry])

        let oldWorkout = try XCTUnwrap(try context.fetch(FetchDescriptor<Workout>()).first { $0.id == oldWorkoutID })
        let oldRecord = try XCTUnwrap(oldWorkout.records.first)
        let addition = try XCTUnwrap(WorkoutValueEditing.appendSetDraft(for: oldRecord, exercise: exercise))
        var filledAddition = addition
        filledAddition.values[metricID] = "3.5"
        let existingValueDrafts = WorkoutValueEditing.drafts(for: oldWorkout)
        try service.saveWorkoutEdits(existingValueDrafts, additions: [filledAddition], day: try XCTUnwrap(WorkoutValueEditing.date(from: oldWorkout.day)), to: oldWorkout, exercises: [exercise])

        let targetSet = try XCTUnwrap(oldRecord.sets.first { $0.sortOrder == 3 })
        let partiallyDeletedValueID = try XCTUnwrap(targetSet.values.first).id
        let deletionTarget = try service.captureSetDeletionTarget(workout: oldWorkout, record: oldRecord, set: targetSet)
        try service.deleteSet(deletionTarget)

        let reopened = try ModelContainer(for: v2Schema, migrationPlan: MeleteMigrationPlan.self, configurations: [v2Configuration])
        let reopenedContext = ModelContext(reopened)
        XCTAssertNotNil(try reopenedContext.fetch(FetchDescriptor<Workout>()).first { $0.id == oldWorkoutID })
        XCTAssertNotNil(try reopenedContext.fetch(FetchDescriptor<Workout>()).first { $0.id == newWorkout.id })
        let unaffectedWorkout = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Workout>()).first { $0.id == unaffectedWorkoutID })
        XCTAssertEqual(unaffectedWorkout.records.flatMap(\.sets).flatMap(\.values).map(WorkoutValueSnapshot.init), [oldValueSnapshots[2]])

        let savedMetric = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<MetricDefinition>()).first { $0.id == metricID })
        XCTAssertEqual(savedMetric.name, "出力")
        XCTAssertEqual(savedMetric.unit, "W")
        XCTAssertTrue(savedMetric.allowsDecimal)
        XCTAssertTrue(savedMetric.isRequired)
        let oldValues = try reopenedContext.fetch(FetchDescriptor<MetricValue>()).filter { $0.id == oldValueSnapshots[0].id || $0.id == oldValueSnapshots[1].id }
        XCTAssertEqual(oldValues.map(WorkoutValueSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }, Array(oldValueSnapshots.prefix(2)).sorted { $0.id.uuidString < $1.id.uuidString })
        XCTAssertFalse(try reopenedContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).contains { $0.valueID == partiallyDeletedValueID })
        XCTAssertTrue(try reopenedContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).allSatisfy { link in
            !oldValues.contains { $0.id == link.valueID }
        })
        let revisions = try reopenedContext.fetch(FetchDescriptor<MetricDefinitionRevision>())
        let currentRevision = try XCTUnwrap(revisions.first { $0.metricID == metricID && $0.revision == 2 })
        XCTAssertEqual(currentRevision.name, "出力")
        XCTAssertEqual(currentRevision.unit, "W")
        let newWorkoutValues = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<Workout>()).first { $0.id == newWorkout.id })
            .records.flatMap(\.sets).flatMap(\.values)
        let newWorkoutValue = try XCTUnwrap(newWorkoutValues.first)
        XCTAssertEqual(newWorkoutValue.name, "出力")
        XCTAssertEqual(newWorkoutValue.unit, "W")
        let newWorkoutLink = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<MetricValueRevisionLink>()).first { $0.valueID == newWorkoutValue.id })
        XCTAssertEqual(newWorkoutLink.revisionID, currentRevision.id)

        let reopenedService = WorkoutWritingServiceV2(context: reopenedContext)
        try reopenedService.deleteWorkout(try reopenedService.captureWorkoutDeletionTarget(workout: newWorkout))
        let afterDeletion = ModelContext(reopened)
        XCTAssertNil(try afterDeletion.fetch(FetchDescriptor<Workout>()).first { $0.id == newWorkout.id })
        XCTAssertFalse(try afterDeletion.fetch(FetchDescriptor<MetricValueRevisionLink>()).contains { $0.valueID == newWorkoutValue.id })
        XCTAssertEqual(Set(try afterDeletion.fetch(FetchDescriptor<MetricDefinitionRevision>()).map(\.id)), Set([currentRevision.id, try XCTUnwrap(revisions.first { $0.metricID == metricID && $0.revision == 1 }).id]))
    }
}
