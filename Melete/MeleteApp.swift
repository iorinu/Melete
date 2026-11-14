import SwiftData
import SwiftUI
import AppKit

@main
struct MeleteApp: App {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let container: ModelContainer?
    private let startupError: String?
    private let isolatedStoreActive: Bool

    init() {
        do {
            let schema = Schema(versionedSchema: MeleteSchemaV1.self)
            let configuration: ModelConfiguration
            var usingIsolatedStore = false
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--melete-ui-test-store") {
                guard let isolatedStoreURL = Self.isolatedStoreURLFromLaunchArguments() else {
                    throw StartupError.invalidUITestStore
                }
                configuration = ModelConfiguration("MeleteUITest", schema: schema, url: isolatedStoreURL, cloudKitDatabase: .none)
                usingIsolatedStore = true
            } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
                        || NSClassFromString("XCTestCase") != nil {
                throw StartupError.invalidUITestStore
            } else {
                configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            }
#else
            configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
#endif
            container = try ModelContainer(for: schema, configurations: [configuration])
            isolatedStoreActive = usingIsolatedStore
            startupError = nil
        } catch {
            container = nil
            isolatedStoreActive = false
            startupError = error.localizedDescription
        }
    }

#if DEBUG
    private static func isolatedStoreURLFromLaunchArguments() -> URL? {
        UITestStoreIsolation.storeURL(arguments: ProcessInfo.processInfo.arguments)
    }
#endif

    private enum StartupError: LocalizedError {
        case invalidUITestStore
        var errorDescription: String? {
            "UIテスト用ストアの指定が安全な一時ディレクトリではありません。データは開いていません。"
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
#endif
                        MainView().modelContainer(container)
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
              (try? String(contentsOf: rootMarkerURL, encoding: .utf8)) == "Melete UI test root v1",
              storeMarkerIsRegular,
              let marker = try? String(contentsOf: storeMarkerURL, encoding: .utf8),
              UUID(uuidString: marker) != nil,
              let contents = try? manager.contentsOfDirectory(atPath: directory.path),
              validStoreContents(contents, in: directory, manager: manager),
              let rootContents = try? manager.contentsOfDirectory(atPath: root.path),
              Set(rootContents) == Set([rootMarker, directory.lastPathComponent]) else { return nil }
        return directory.appendingPathComponent("Melete.store")
    }

    private static func validStoreContents(_ contents: [String], in directory: URL, manager: FileManager) -> Bool {
        let allowedNames: Set<String> = [storeMarker, "Melete.store", "Melete.store-wal", "Melete.store-shm"]
        guard Set(contents).isSubset(of: allowedNames), contents.contains(storeMarker) else { return false }
        for name in contents where name != storeMarker {
            let url = directory.appendingPathComponent(name)
            guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL,
                  let attributes = try? manager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        }
        return true
    }
}
#endif
