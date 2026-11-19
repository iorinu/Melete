import XCTest
@testable import Melete

#if DEBUG
/// scratch隔離領域の安全性テスト。
/// 合成fixtureはscratch直下の `MeleteScratchIsolation-<UUID>` だけに作り、システム一時ディレクトリは使わない。
/// scratchが存在しない・安全条件を満たさない環境では、通常DEBUGはスキップし、scratch検証ビルドは失敗にする（scratch自体は作成・変更しない）。
/// テストは削除・後片付けを一切行わない。各fixtureは必要なmarkerの種類・内容・有無を最初から指定して新規作成し、
/// 既存ファイルの上書き・削除はしない（作成物はscratch直下に残る）。
final class ScratchStoreIsolationSafetyTests: XCTestCase {
    private static let fixturePrefix = "MeleteScratchIsolation-"
    private static let validRootMarkerContents = "Melete UI test root v1"
    /// root からの相対パス
    private static let rootMarkerPath = UITestStoreIsolation.rootMarker
    private static let storeMarkerPath = "store/" + UITestStoreIsolation.storeMarker
    private var scratchBase: URL!

    private struct Fixture {
        let root: URL
        let store: URL
        var arguments: [String] { ["--melete-ui-test-root", root.path, "--melete-ui-test-store", store.path] }
    }

    /// fixture内に作る項目。パスはすべてrootからの相対パスで、配列の順に新規作成する
    private enum Entry {
        case file(String, contents: String)
        case directory(String)
        /// destinationもrootからの相対パス
        case symlink(String, destination: String)
        /// sourceは先に作成済みの項目（rootからの相対パス）
        case hardLink(String, source: String)
        /// sourceは別の合成fixture内に作成済みの通常ファイル（scratch内の絶対URL）
        case externalHardLink(String, source: URL)
    }

    override func setUpWithError() throws {
        guard let base = UITestStoreIsolation.trustedScratchBase() else {
            let reason = "scratch領域が存在しないか、所有者・権限・symlinkの安全条件を満たしません"
#if MELETE_SCRATCH_ISOLATION
            // scratch検証ビルドではscratchが前提なので、全テストがスキップされて成功扱いにならないよう失敗にする
            XCTFail(reason)
            throw ScratchFixtureError.scratchUnavailable
#else
            // 通常DEBUGではscratchが無い環境もあり得るのでスキップしてよい
            throw XCTSkip(reason)
#endif
        }
        scratchBase = base
    }

    // MARK: - 正常系 / コンパイル条件

    func testValidScratchFixtureIsAcceptedOnlyInScratchBuild() throws {
        let fixture = try makeFixture()
        let experimental = fixture.arguments + ["--melete-v2-experimental"]
#if MELETE_SCRATCH_ISOLATION
        XCTAssertEqual(UITestStoreIsolation.storeURL(arguments: fixture.arguments), fixture.store.appendingPathComponent("Melete.store"))
        XCTAssertEqual(StartupRouteSelection.select(arguments: fixture.arguments, isDebug: true, isolationIsValid: true), .isolatedV1)
        XCTAssertNotNil(UITestStoreIsolation.storeURL(arguments: experimental))
        // 初回起動後に作られるストア関連ファイルがある状態も許可する（別の新規fixtureで最初から用意する）
        let storeFiles = ["Melete.store", "Melete.store-wal", "Melete.store-shm"].map { Entry.file("store/" + $0, contents: "合成store") }
        let withStoreFiles = try makeFixture(entries: Self.validMarkers() + storeFiles)
        XCTAssertNotNil(UITestStoreIsolation.storeURL(arguments: withStoreFiles.arguments))
#else
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: fixture.arguments), "通常DEBUGではscratchを許可しない")
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: experimental), "通常DEBUGではscratchのV2検証も許可しない")
#endif
    }

    // MARK: - 許可外の場所

    func testRejectsLocationsOutsideScratchDirectChildren() throws {
        let manager = FileManager.default
        let temporaryRoot = manager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL

        // scratch直下より深い階層（scratch内のネスト）に、それ以外は正常なfixtureを実在させる
        let container = try makeTopLevelDirectory()
        let nested = try makeFixture(rootParent: container)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: nested.arguments), "scratchの孫階層rootを拒否する")
        // 拒否理由が経路ガードであることを確認する：場所以外の条件は満たしている
        XCTAssertTrue(UITestStoreIsolation.isTrustedDirectory(nested.root, manager: manager))
        XCTAssertTrue(UITestStoreIsolation.isTrustedDirectory(nested.store, manager: manager))
        XCTAssertEqual(try String(contentsOf: nested.root.appendingPathComponent(UITestStoreIsolation.rootMarker), encoding: .utf8), Self.validRootMarkerContents)
        XCTAssertNotNil(UUID(uuidString: try String(contentsOf: nested.store.appendingPathComponent(UITestStoreIsolation.storeMarker), encoding: .utf8)))
        // 経路ガード単体でネストしたrootが拒否される
        XCTAssertFalse(UITestStoreIsolation.rootIsInAllowedArea(nested.root, temporaryRoot: temporaryRoot, manager: manager), "経路ガードがネストrootを拒否する")
        // 対照：同じ作り方のscratch直下fixtureは、scratch検証ビルドでのみ経路ガードを通る
        let direct = try makeFixture()
#if MELETE_SCRATCH_ISOLATION
        XCTAssertTrue(UITestStoreIsolation.rootIsInAllowedArea(direct.root, temporaryRoot: temporaryRoot, manager: manager))
        XCTAssertNotNil(UITestStoreIsolation.storeURL(arguments: direct.arguments))
#else
        XCTAssertFalse(UITestStoreIsolation.rootIsInAllowedArea(direct.root, temporaryRoot: temporaryRoot, manager: manager))
#endif

        // scratch自体をrootにすることは拒否する（scratchには何も作らない）
        let missingStore = scratchBase.appendingPathComponent(Self.fixturePrefix + UUID().uuidString, isDirectory: true)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: ["--melete-ui-test-root", scratchBase.path, "--melete-ui-test-store", missingStore.path]))

        // scratchの親（許可外）を指す存在しないrootを拒否する。ここにはファイルを作らない
        let outside = scratchBase.deletingLastPathComponent().appendingPathComponent(Self.fixturePrefix + UUID().uuidString, isDirectory: true)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: ["--melete-ui-test-root", outside.path, "--melete-ui-test-store", outside.appendingPathComponent("store").path]))

        // `..` でscratch外へ出るstore指定を拒否する
        let fixture = try makeFixture()
        let escaping = fixture.root.path + "/../" + fixture.root.lastPathComponent + "-escape/store"
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: ["--melete-ui-test-root", fixture.root.path, "--melete-ui-test-store", escaping]))

        // 別fixtureのstoreをroot外として拒否する
        let other = try makeFixture()
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: ["--melete-ui-test-root", fixture.root.path, "--melete-ui-test-store", other.store.path]))
    }

    // MARK: - symlink

    func testRejectsSymlinks() throws {
        let manager = FileManager.default
        let target = try makeFixture()

        // scratch直下のsymlink rootを拒否する（新しいUUID名なので既存項目とは衝突しない）
        let linkedRoot = scratchBase.appendingPathComponent(Self.fixturePrefix + UUID().uuidString, isDirectory: true)
        try manager.createSymbolicLink(at: linkedRoot, withDestinationURL: target.root)
        let linkedStore = linkedRoot.appendingPathComponent("store", isDirectory: true)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: ["--melete-ui-test-root", linkedRoot.path, "--melete-ui-test-store", linkedStore.path]))

        // store markerのsymlinkを拒否する（最初からsymlinkとして作る）
        let markerLinked = try makeFixture(entries: [
            Self.validRootMarker(),
            .file("store/Melete.store", contents: UUID().uuidString),
            .symlink(Self.storeMarkerPath, destination: "store/Melete.store"),
        ])
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: markerLinked.arguments))

        // scratch内のsymlinkディレクトリは信頼済みディレクトリとして扱わない
        XCTAssertFalse(UITestStoreIsolation.isTrustedDirectory(linkedRoot, manager: manager))
        XCTAssertTrue(UITestStoreIsolation.isTrustedDirectory(target.root, manager: manager))
    }

    // MARK: - hard link

    func testRejectsHardLinkedStoreFiles() throws {
        // store本体同士のhard link
        let storeLinked = try makeFixture(entries: Self.validMarkers() + [
            .file("store/Melete.store", contents: "合成store"),
            .hardLink("store/Melete.store-wal", source: "store/Melete.store"),
        ])
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: storeLinked.arguments))
    }

    func testRejectsHardLinkedRootMarker() throws {
        // 別の合成fixture内の通常ファイル（正しいroot marker内容）を作り、検証対象のroot markerをそこへのhard linkにする
        let source = try makeExternalLinkSource(contents: Self.validRootMarkerContents)
        let fixture = try makeFixture(entries: [
            .externalHardLink(Self.rootMarkerPath, source: source),
            Self.validStoreMarker(),
        ])
        // 拒否理由がhard linkであることを確認する：内容は正しく、リンク数だけが1でない
        let marker = fixture.root.appendingPathComponent(UITestStoreIsolation.rootMarker)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), Self.validRootMarkerContents)
        XCTAssertEqual(try Self.referenceCount(of: marker), 2)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: fixture.arguments))
    }

    func testRejectsHardLinkedStoreMarker() throws {
        // 別の合成fixture内の通常ファイル（正しいUUID内容）を作り、検証対象のstore markerをそこへのhard linkにする
        let source = try makeExternalLinkSource(contents: UUID().uuidString)
        let fixture = try makeFixture(entries: [
            Self.validRootMarker(),
            .externalHardLink(Self.storeMarkerPath, source: source),
        ])
        // 拒否理由がhard linkであることを確認する：内容は正しく、リンク数だけが1でない
        let marker = fixture.store.appendingPathComponent(UITestStoreIsolation.storeMarker)
        XCTAssertNotNil(UUID(uuidString: try String(contentsOf: marker, encoding: .utf8)))
        XCTAssertEqual(try Self.referenceCount(of: marker), 2)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: fixture.arguments))
    }

    // MARK: - 権限

    func testRejectsLoosePermissions() throws {
        let manager = FileManager.default

        let looseRoot = try makeFixture(rootPermissions: 0o755)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: looseRoot.arguments), "root 755を拒否する")

        let looseStore = try makeFixture(storePermissions: 0o750)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: looseStore.arguments), "store 750を拒否する")

        // group書き込み可能なディレクトリは信頼済みディレクトリとして扱わない（700の対照は別の新規ディレクトリ）
        let groupWritable = try makeTopLevelDirectory(permissions: 0o720)
        XCTAssertFalse(UITestStoreIsolation.isTrustedDirectory(groupWritable, manager: manager))
        let ownerOnly = try makeTopLevelDirectory(permissions: 0o700)
        XCTAssertTrue(UITestStoreIsolation.isTrustedDirectory(ownerOnly, manager: manager))
    }

    // MARK: - marker

    func testRejectsInvalidMarkers() throws {
        let wrongRootMarker = try makeFixture(entries: [
            .file(Self.rootMarkerPath, contents: "Melete UI test root v0"),
            Self.validStoreMarker(),
        ])
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: wrongRootMarker.arguments))

        let nonUUIDStoreMarker = try makeFixture(entries: [
            Self.validRootMarker(),
            .file(Self.storeMarkerPath, contents: "not-a-uuid"),
        ])
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: nonUUIDStoreMarker.arguments))

        // store markerを最初から作らない
        let missingStoreMarker = try makeFixture(entries: [Self.validRootMarker()])
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: missingStoreMarker.arguments))

        // markerが正規ファイルでない（ディレクトリ）場合を拒否する
        let directoryMarker = try makeFixture(entries: [
            .directory(Self.rootMarkerPath),
            Self.validStoreMarker(),
        ])
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: directoryMarker.arguments))
    }

    // MARK: - fail closed

    func testFailsClosedOnIncompleteOrUnexpectedInput() throws {
        let fixture = try makeFixture()

        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: []))
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: ["--melete-ui-test-root", fixture.root.path, "--melete-ui-test-store"]))
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: ["--melete-ui-test-store", fixture.store.path]))

        // 存在しないscratch直下rootを拒否する（何も作らない）
        let missing = scratchBase.appendingPathComponent(Self.fixturePrefix + UUID().uuidString, isDirectory: true)
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: ["--melete-ui-test-root", missing.path, "--melete-ui-test-store", missing.appendingPathComponent("store").path]))

        // root・storeに想定外のファイルがあれば拒否する
        let unexpectedInRoot = try makeFixture(entries: Self.validMarkers() + [.file("unexpected", contents: "")])
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: unexpectedInRoot.arguments))

        let unexpectedInStore = try makeFixture(entries: Self.validMarkers() + [.file("store/unexpected", contents: "")])
        XCTAssertNil(UITestStoreIsolation.storeURL(arguments: unexpectedInStore.arguments))

        // 隔離が無効なら通常ストアへfallbackせずエラーになる
        XCTAssertEqual(StartupRouteSelection.select(arguments: unexpectedInStore.arguments, isDebug: true, isolationIsValid: false), .error)
        XCTAssertEqual(StartupRouteSelection.select(arguments: fixture.arguments, isDebug: false, isolationIsValid: true), .error, "DEBUG以外では拒否する")
    }

    // MARK: - fixture

    private static func validRootMarker() -> Entry {
        .file(rootMarkerPath, contents: validRootMarkerContents)
    }

    /// 毎回新しいUUIDを内容にする
    private static func validStoreMarker() -> Entry {
        .file(storeMarkerPath, contents: UUID().uuidString)
    }

    private static func validMarkers() -> [Entry] {
        [validRootMarker(), validStoreMarker()]
    }

    /// scratch直下に新規ユニーク名のディレクトリを作る。既に存在すれば失敗する（上書きしない）
    private func makeTopLevelDirectory(permissions: Int = 0o700) throws -> URL {
        let url = scratchBase.appendingPathComponent(Self.fixturePrefix + UUID().uuidString, isDirectory: true)
        try makeNewDirectory(url, permissions: permissions)
        return url
    }

    /// 合成fixtureを新規作成する。rootParent未指定ならscratch直下。
    /// root・storeディレクトリを作った後、entriesを順に作り、最後に権限を設定する。
    private func makeFixture(
        rootParent: URL? = nil,
        entries: [Entry] = ScratchStoreIsolationSafetyTests.validMarkers(),
        rootPermissions: Int = 0o700,
        storePermissions: Int = 0o700
    ) throws -> Fixture {
        let root: URL
        if let rootParent {
            // ネストさせる場合もscratch内だけに限定する
            guard rootParent.standardizedFileURL.path.hasPrefix(scratchBase.path + "/") else {
                throw ScratchFixtureError.outsideScratch
            }
            root = rootParent.appendingPathComponent(Self.fixturePrefix + UUID().uuidString, isDirectory: true)
            try makeNewDirectory(root, permissions: 0o700)
        } else {
            root = try makeTopLevelDirectory()
        }
        let store = root.appendingPathComponent("store", isDirectory: true)
        try makeNewDirectory(store, permissions: 0o700)

        for entry in entries {
            try create(entry, in: root)
        }
        // 中身を作り終えてから最終的な権限にする（権限変更はこの新規fixtureだけ）
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: storePermissions], ofItemAtPath: store.path)
        try manager.setAttributes([.posixPermissions: rootPermissions], ofItemAtPath: root.path)
        return Fixture(root: root.standardizedFileURL, store: store.standardizedFileURL)
    }

    private func create(_ entry: Entry, in root: URL) throws {
        let manager = FileManager.default
        switch entry {
        case let .file(path, contents):
            try createRegularFile(resolve(path, in: root), contents: contents)
        case let .directory(path):
            try makeNewDirectory(resolve(path, in: root), permissions: 0o700)
        case let .symlink(path, destination):
            // createSymbolicLinkは既存項目があると失敗する
            try manager.createSymbolicLink(at: resolve(path, in: root), withDestinationURL: resolve(destination, in: root))
        case let .hardLink(path, source):
            // linkItemはリンク先に既存項目があると失敗する
            try manager.linkItem(at: resolve(source, in: root), to: resolve(path, in: root))
        case let .externalHardLink(path, source):
            // リンク元もscratch内の合成fixtureに限定する
            guard source.standardizedFileURL.path.hasPrefix(scratchBase.path + "/") else {
                throw ScratchFixtureError.outsideScratch
            }
            try manager.linkItem(at: source, to: resolve(path, in: root))
        }
    }

    /// hard linkのリンク元にする通常ファイルを、scratch直下の新規ディレクトリ（別の合成fixture）内に作る
    private func makeExternalLinkSource(contents: String) throws -> URL {
        let directory = try makeTopLevelDirectory()
        let file = directory.appendingPathComponent("link-source")
        try createRegularFile(file, contents: contents)
        return file
    }

    private static func referenceCount(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.referenceCount] as? NSNumber).uint64Value
    }

    /// rootからの相対パスをURLにする。絶対パスや `..` でfixture外を指すものは拒否する
    private func resolve(_ relativePath: String, in root: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"), !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ScratchFixtureError.invalidEntryPath
        }
        return root.appendingPathComponent(relativePath)
    }

    /// 新規ディレクトリを作る。withIntermediateDirectories: false なので既存なら失敗する
    private func makeNewDirectory(_ url: URL, permissions: Int) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // umaskの影響を受けないよう、作成後に明示的に設定する
        try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    /// 新規ファイルを作る。.withoutOverwritingにより既存ファイルがあれば失敗し、上書きしない
    private func createRegularFile(_ url: URL, contents: String) throws {
        try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private enum ScratchFixtureError: Error {
    case outsideScratch
    case invalidEntryPath
    case scratchUnavailable
}
#endif
