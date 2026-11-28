import Foundation

// 既存の型・初期化・開始停止APIを保ち、実装をSwiftNIO listenerへ委譲するfacade。
final class ChatGPTOAuthLoopbackListener: Sendable {
    // parserに合格したcallbackを受け取る先。
    // すぐ戻る処理にすること（戻るまでブラウザへのresponseが返らず、stop後も配送用Threadと参照が残る）
    typealias CallbackSink = @Sendable (ChatGPTOAuthLoopbackCallbackRequest) -> Void

    static let maxConnections = ChatGPTOAuthNIOLoopbackListener.maxConnections
    static let connectionDeadlineSeconds = Int(ChatGPTOAuthNIOLoopbackListener.connectionDeadlineSeconds)

    private let listener: ChatGPTOAuthNIOLoopbackListener

    // responseCompletionHandler: callbackReceived応答の確定の受け取り先。
    init(expectedState: String, callbackSink: @escaping CallbackSink,
         failureHandler: ChatGPTOAuthNIOLoopbackListener.FailureHandler? = nil,
         responseCompletionHandler: ChatGPTOAuthNIOLoopbackListener.ResponseCompletionHandler? = nil) {
        listener = ChatGPTOAuthNIOLoopbackListener(
            expectedState: expectedState,
            callbackSink: callbackSink,
            failureHandler: failureHandler,
            responseCompletionHandler: responseCompletionHandler
        )
    }

#if DEBUG
    // テスト専用。start前だけ設定できる
    func setResponseFlushTestHook(_ hook: ChatGPTOAuthNIOLoopbackListener.ResponseFlushTestHook?) {
        listener.setResponseFlushTestHook(hook)
    }
#endif

    func start() async throws -> Int {
        try await listener.start()
    }

    /// 受付を止め、全接続を閉じてevent loop groupの終了まで待つ。
    /// stop開始前に配送が認可済みでも、sink本体の開始前にstopが割り込むと、sinkはstop後に始まることがある。
    func stop() async {
        await listener.stop()
    }
}

// エラーには入力値を含めない（関連値を持たせない）
enum ChatGPTOAuthLoopbackListenerError: Error, Equatable {
    // RED段階のstubであることを示していた値。テストが「stubのままではない」ことの確認に使うため残す
    case notImplemented
    // 既にstart済み
    case alreadyStarted
    // stop済み、または前回のstartが失敗・取消された（同じlistenerは再利用しない）
    case stopped
    // socketの作成・bind・listenなど、受付の準備に失敗した
    case setupFailed
}
