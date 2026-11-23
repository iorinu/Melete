import SwiftData
import SwiftUI
import AppKit

@main
struct MeleteApp: App {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let container: ModelContainer?
    private let startupError: String?
    private let isolatedStoreActive: Bool
    private let storeMode: MainView.StoreMode
    private let scratchProcessMarker: String?

    init() {
        do {
            var resolvedContainer: ModelContainer?
            var resolvedIsolatedStoreActive = false
            var resolvedStoreMode: MainView.StoreMode = .v1
            var resolvedScratchProcessMarker: String?
            let arguments = ProcessInfo.processInfo.arguments
#if DEBUG
            let isolatedStoreURL = Self.isolatedStoreURLFromLaunchArguments(arguments: arguments)
            let route = StartupRouteSelection.select(arguments: arguments, isDebug: true, isolationIsValid: isolatedStoreURL != nil)
#else
            let route = StartupRouteSelection.select(arguments: arguments, isDebug: false, isolationIsValid: false)
#endif
            let configuration: ModelConfiguration
            var usingIsolatedStore = false
            var selectedMode: MainView.StoreMode = .v1
            guard route != .error else { throw StartupError.invalidUITestStore }
#if DEBUG && MELETE_SCRATCH_ISOLATION
            // 失敗し得る証拠の検証は、プロパティとModelContainerを確定する前に行う
            if route == .isolatedV2 {
                guard let evidence = Self.scratchEvidence(arguments: arguments) else {
                    throw StartupError.invalidUITestStore
                }
                resolvedScratchProcessMarker = evidence
            }
#endif
#if DEBUG
            if route == .isolatedV1 || route == .isolatedV2 {
                guard let isolatedStoreURL else { throw StartupError.invalidUITestStore }
                if route == .isolatedV2 {
                    let schema = Schema(versionedSchema: MeleteSchemaV2.self)
                    configuration = ModelConfiguration("MeleteUITestV2", schema: schema, url: isolatedStoreURL, cloudKitDatabase: .none)
                    do {
                        resolvedContainer = try ModelContainer(for: schema, migrationPlan: MeleteMigrationPlan.self, configurations: [configuration])
                    } catch {
#if MELETE_SCRATCH_ISOLATION
                        // SwiftDataの詳細エラーにはパス等が含まれ得るため、scratch専用画面には出さない
                        throw StartupError.scratchStoreOpenFailed
#else
                        throw error
#endif
                    }
                    selectedMode = .isolatedV2Experimental
                } else {
                    let schema = Schema(versionedSchema: MeleteSchemaV1.self)
                    configuration = ModelConfiguration("MeleteUITest", schema: schema, url: isolatedStoreURL, cloudKitDatabase: .none)
                    resolvedContainer = try ModelContainer(for: schema, configurations: [configuration])
                }
                usingIsolatedStore = true
            } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil || NSClassFromString("XCTestCase") != nil {
                throw StartupError.invalidUITestStore
            } else {
#if MELETE_SCRATCH_ISOLATION
                // scratch検証ビルドは隔離ストア専用。通常ストアは開かずに起動エラーにする
                throw StartupError.invalidUITestStore
#else
                let schema = Schema(versionedSchema: MeleteSchemaV1.self)
                configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
                resolvedContainer = try ModelContainer(for: schema, configurations: [configuration])
#endif
            }
#else
            let schema = Schema(versionedSchema: MeleteSchemaV1.self)
            configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            resolvedContainer = try ModelContainer(for: schema, configurations: [configuration])
#endif
            resolvedIsolatedStoreActive = usingIsolatedStore
            resolvedStoreMode = selectedMode
            container = resolvedContainer
            isolatedStoreActive = resolvedIsolatedStoreActive
            storeMode = resolvedStoreMode
            scratchProcessMarker = resolvedScratchProcessMarker
            startupError = nil
        } catch {
            container = nil
            isolatedStoreActive = false
            storeMode = .v1
            scratchProcessMarker = nil
            startupError = error.localizedDescription
        }
    }

#if DEBUG
    private static func isolatedStoreURLFromLaunchArguments(arguments: [String]) -> URL? {
#if MELETE_SCRATCH_ISOLATION
        let flags = ["--melete-ui-test-root", "--melete-ui-test-store", "--melete-v2-experimental"]
        let values = Array(arguments.dropFirst())
        guard values.filter({ $0 == "--melete-ui-test-root" }).count == 1,
              values.filter({ $0 == "--melete-ui-test-store" }).count == 1,
              values.filter({ $0 == "--melete-v2-experimental" }).count == 1,
              !values.contains(where: { $0.hasPrefix("--melete-") && !flags.contains($0) }) else { return nil }
#endif
        guard arguments.contains("--melete-ui-test-root") || arguments.contains("--melete-ui-test-store") || arguments.contains("--melete-v2-experimental") else { return nil }
        return UITestStoreIsolation.storeURL(arguments: arguments)
    }

#if MELETE_SCRATCH_ISOLATION
    private static func scratchEvidence(arguments: [String]) -> String? {
        guard let storeURL = UITestStoreIsolation.storeURL(arguments: arguments),
              let marker = try? String(contentsOf: storeURL.deletingLastPathComponent().appendingPathComponent(UITestStoreIsolation.storeMarker), encoding: .utf8),
              let uuid = UUID(uuidString: marker) else { return nil }
        return "melete-scratch-evidence-\(uuid.uuidString)-pid-\(ProcessInfo.processInfo.processIdentifier)"
    }
#endif
#endif

    private enum StartupError: LocalizedError {
        case invalidUITestStore
        case scratchStoreOpenFailed
        var errorDescription: String? {
            switch self {
            case .invalidUITestStore:
                return "UIテスト用ストアの指定が安全な一時ディレクトリではありません。データは開いていません。"
            case .scratchStoreOpenFailed:
                return "隔離されたscratchストアを開けませんでした。詳細情報は表示していません。データは初期化されていません。"
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container {
                    VStack(spacing: 0) {
#if DEBUG
                        if isolatedStoreActive {
                            Text("隔離ストア使用中")
                                .accessibilityIdentifier("melete-isolated-store-active")
                                .padding(6)
                        }
                        if storeMode == .isolatedV2Experimental {
                            Text("V2検証用")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("melete-experimental-v2-active")
                                .padding(4)
                        }
#if DEBUG && MELETE_SCRATCH_ISOLATION
                        if let scratchProcessMarker {
                            Text(scratchProcessMarker)
                                .accessibilityIdentifier("melete-scratch-process-evidence")
                                .accessibilityHidden(false)
                        }
#endif
#endif
                        MainView(storeMode: storeMode).modelContainer(container)
                    }
                } else {
                    ContentUnavailableView("データを開けませんでした", systemImage: "externaldrive.badge.exclamationmark", description: Text("データは初期化されていません。アプリを終了して再度起動してください。\n\(startupError ?? "")"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                } else {
                    WindowMaterial().ignoresSafeArea()
                }
            }
            .background(WindowTransparencyConfigurator())
        }
        .windowResizability(.contentSize)
    }
}

private struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct WindowTransparencyConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configureWindow(for: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configureWindow(for: view) }
    }

    private func configureWindow(for view: NSView) {
        guard let window = view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}

#if DEBUG
enum UITestStoreIsolation {
    static let rootMarker = ".melete-ui-test-root"
    static let storeMarker = ".melete-ui-test-store"

    static func storeURL(arguments: [String]) -> URL? {
        guard let rootIndex = arguments.firstIndex(of: "--melete-ui-test-root"),
              arguments.indices.contains(rootIndex + 1),
              let index = arguments.firstIndex(of: "--melete-ui-test-store"),
              arguments.indices.contains(index + 1) else { return nil }
        let manager = FileManager.default
        let root = URL(fileURLWithPath: arguments[rootIndex + 1], isDirectory: true).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let temporaryRoot = manager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard directory.path.hasPrefix(rootPath) else { return nil }
        let relativePath = String(directory.path.dropFirst(rootPath.count))
        let expectedResolvedDirectory = resolvedRoot.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
        let rootMarkerURL = root.appendingPathComponent(rootMarker)
        let storeMarkerURL = directory.appendingPathComponent(storeMarker)
        let rootMarkerIsNotSymlink = rootMarkerURL.resolvingSymlinksInPath().standardizedFileURL == rootMarkerURL
        let storeMarkerIsNotSymlink = storeMarkerURL.resolvingSymlinksInPath().standardizedFileURL == storeMarkerURL
        let rootAttributes = try? manager.attributesOfItem(atPath: resolvedRoot.path)
        let rootOwner = (rootAttributes?[.ownerAccountID] as? NSNumber)?.uint32Value
        let rootPermissions = (rootAttributes?[.posixPermissions] as? NSNumber)?.uint16Value
        let rootIsDirectory = (rootAttributes?[.type] as? FileAttributeType) == .typeDirectory
        let directoryAttributes = try? manager.attributesOfItem(atPath: resolvedDirectory.path)
        let directoryOwner = (directoryAttributes?[.ownerAccountID] as? NSNumber)?.uint32Value
        let directoryPermissions = (directoryAttributes?[.posixPermissions] as? NSNumber)?.uint16Value
        let directoryIsDirectory = (directoryAttributes?[.type] as? FileAttributeType) == .typeDirectory
        let rootMarkerIsRegular = (try? manager.attributesOfItem(atPath: rootMarkerURL.path)[.type] as? FileAttributeType) == .some(.typeRegular)
        let storeMarkerIsRegular = (try? manager.attributesOfItem(atPath: storeMarkerURL.path)[.type] as? FileAttributeType) == .some(.typeRegular)
        guard resolvedRoot == root,
              rootIsInAllowedArea(resolvedRoot, temporaryRoot: temporaryRoot, manager: manager),
              resolvedDirectory == expectedResolvedDirectory,
              rootOwner == getuid(),
              rootPermissions == 0o700,
              rootIsDirectory,
              rootMarkerIsNotSymlink,
              directoryOwner == getuid(),
              directoryPermissions == 0o700,
              directoryIsDirectory,
              storeMarkerIsNotSymlink,
              rootMarkerIsRegular,
              hasSingleHardLink(at: rootMarkerURL, manager: manager),
              (try? String(contentsOf: rootMarkerURL, encoding: .utf8)) == "Melete UI test root v1",
              storeMarkerIsRegular,
              hasSingleHardLink(at: storeMarkerURL, manager: manager),
              let marker = try? String(contentsOf: storeMarkerURL, encoding: .utf8),
              UUID(uuidString: marker) != nil,
              let contents = try? manager.contentsOfDirectory(atPath: directory.path),
              validStoreContents(contents, in: directory, manager: manager),
              let rootContents = try? manager.contentsOfDirectory(atPath: root.path),
              Set(rootContents) == Set([rootMarker, directory.lastPathComponent]) else { return nil }
        return directory.appendingPathComponent("Melete.store")
    }

    /// rootを置いてよい場所か。通常DEBUGはシステム一時ディレクトリ配下のみ。
    /// scratch検証ビルド（MELETE_SCRATCH_ISOLATION）だけ、安全条件を満たすscratch直下も許可する。
    /// 拒否理由が経路ガードであることを単体テストで確認できるよう、privateにしていない。
    static func rootIsInAllowedArea(_ root: URL, temporaryRoot: URL, manager: FileManager) -> Bool {
        let temporaryPrefix = temporaryRoot.path.hasSuffix("/") ? temporaryRoot.path : temporaryRoot.path + "/"
        if root != temporaryRoot, root.path.hasPrefix(temporaryPrefix) { return true }
#if MELETE_SCRATCH_ISOLATION
        // scratchは「直下の子ディレクトリ」だけを許可し、より深い階層やscratch自体は拒否する
        if let scratchBase = trustedScratchBase(manager: manager),
           root.deletingLastPathComponent().standardizedFileURL.path == scratchBase.path {
            return true
        }
#endif
        return false
    }

    /// ホームからの相対位置。ユーザー名などの個人パスは埋め込まない
    static let scratchRelativeComponents = [".hermes", "cache", "scratch"]

    /// 安全条件を満たすscratchの場所を返す。条件を満たさなければnil（fail closed）。
    /// この関数自体は場所の計算だけで、許可するかどうかはrootIsInAllowedAreaのコンパイル条件で決まる。
    static func trustedScratchBase(manager: FileManager = .default) -> URL? {
        // HOME環境変数は起動時に差し替えられるため使わず、パスワードDBのホームを使う
        guard let entry = getpwuid(getuid()), let homePointer = entry.pointee.pw_dir else { return nil }
        let home = URL(fileURLWithPath: String(cString: homePointer), isDirectory: true).standardizedFileURL
        guard home.path != "/", home.resolvingSymlinksInPath().standardizedFileURL == home else { return nil }
        var current = home
        for component in scratchRelativeComponents {
            current = current.appendingPathComponent(component, isDirectory: true)
            guard isTrustedDirectory(current, manager: manager) else { return nil }
        }
        return current.standardizedFileURL
    }

    /// symlinkでない実ディレクトリで、所有者が自分、group/otherに書き込み権限がないこと
    static func isTrustedDirectory(_ url: URL, manager: FileManager) -> Bool {
        // attributesOfItemはsymlinkをたどらないため、symlinkならtypeがtypeSymbolicLinkになり拒否される
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value else { return false }
        return permissions & 0o022 == 0
    }

    private static func validStoreContents(_ contents: [String], in directory: URL, manager: FileManager) -> Bool {
        let allowedNames: Set<String> = [storeMarker, "Melete.store", "Melete.store-wal", "Melete.store-shm"]
        guard Set(contents).isSubset(of: allowedNames), contents.contains(storeMarker) else { return false }
        for name in contents where name != storeMarker {
            let url = directory.appendingPathComponent(name)
            guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL,
                   let attributes = try? manager.attributesOfItem(atPath: url.path),
                   attributes[.type] as? FileAttributeType == .typeRegular,
                   hasSingleHardLink(attributes) else { return false }
        }
        return true
    }

    private static func hasSingleHardLink(at url: URL, manager: FileManager) -> Bool {
        guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { return false }
        return hasSingleHardLink(attributes)
    }

    private static func hasSingleHardLink(_ attributes: [FileAttributeKey: Any]) -> Bool {
        guard let count = attributes[.referenceCount] as? NSNumber else { return false }
        return count.uint64Value == 1
    }
}
#endif
