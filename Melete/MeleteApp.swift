import SwiftData
import SwiftUI

@main
struct MeleteApp: App {
    private let container: ModelContainer?
    private let startupError: String?

    init() {
        do {
            let schema = Schema(versionedSchema: MeleteSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            container = try ModelContainer(for: schema, configurations: [configuration])
            startupError = nil
        } catch {
            container = nil
            startupError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                MainView().modelContainer(container)
            } else {
                ContentUnavailableView("データを開けませんでした", systemImage: "externaldrive.badge.exclamationmark", description: Text("データは初期化されていません。アプリを終了して再度起動してください。\n\(startupError ?? "")"))
            }
        }
        .windowResizability(.contentSize)
    }
}
