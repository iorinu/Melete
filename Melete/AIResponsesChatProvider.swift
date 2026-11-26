import Foundation

// URLSessionなどの実装を含まない、Responses API providerの最初のRED段階。
// transportは合成テストから注入する。
@MainActor protocol AIResponsesChunkTransport {
    // return/throwは送受信が実際に停止した後にだけ行う。
    // onChunkがthrowした場合やTask.cancelを受けた場合も、I/Oを停止して終了を待ってから返す。
    // 取消された場合は、onChunkのエラーよりCancellationErrorを優先して投げる。
    // callback方式にして、未処理chunkの無制限なbufferやproducerの取り残しを避ける。
    func receive(body: Data, onChunk: @MainActor (Data) throws -> Void) async throws
}

@MainActor final class AIResponsesChatProvider: AIWorkoutChatProvider {
    private let builder: AIResponsesRequestBuilder
    private let model: String
    private let transport: any AIResponsesChunkTransport

    init(builder: AIResponsesRequestBuilder = AIResponsesRequestBuilder(), model: String,
         transport: any AIResponsesChunkTransport) {
        self.builder = builder
        self.model = model
        self.transport = transport
    }

    func send(_ request: AIWorkoutChatRequest) async throws -> AIWorkoutChatResponse {
        let body: Data
        do {
            body = try builder.build(request: request, model: model)
        } catch {
            throw AIResponsesChatProviderError.requestFailed
        }

        var parser = AIResponsesStreamParser()
        do {
            try await transport.receive(body: body) { chunk in
                let state = parser.consume(chunk)
                if case .failed(let failure) = state {
                    // callbackのthrowでtransportに停止を要求し、停止完了後にsendへ戻す。
                    throw failure
                }
            }
        } catch {
            // 取消をparserの失敗より優先する。取消済みならparserの失敗が残っていてもCancellationErrorにする。
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            // 取消がなければparserの失敗理由だけを保持し、transport由来の内容は外へ出さない。
            if case .failed(let failure) = parser.state {
                throw failure
            }
            throw AIResponsesChatProviderError.transportFailed
        }

        if Task.isCancelled {
            throw CancellationError()
        }
        switch parser.finish() {
        case .success(let text):
            if Task.isCancelled {
                throw CancellationError()
            }
            guard let json = text.data(using: .utf8) else {
                throw AIResponsesChatProviderError.invalidOutput
            }
            return AIWorkoutChatResponse(json: json)
        case .failure(let failure):
            throw failure
        }
    }
}

enum AIResponsesChatProviderError: Error, Equatable {
    case requestFailed
    case transportFailed
    case invalidOutput
}
