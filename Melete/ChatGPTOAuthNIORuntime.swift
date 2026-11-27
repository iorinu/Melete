import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

// ChatGPT OAuth初回登録のloopback listenerを、SwiftNIOで組み立てるための土台。
// 既存の ChatGPTOAuthLoopbackListener（POSIX socket版）とは独立していて、アプリ本体・既存listenerからはまだ呼び出さない。
// 配送前のstate一致確認以外のOAuth試行の検証・ブラウザ起動・token交換・UI・保存は扱わない。
//
// 構成:
// - event loopは専用の MultiThreadedEventLoopGroup（1 thread）。start 1回につき1つ作り、stopでshutdownする
// - bind先は 127.0.0.1:0 固定（OSがportを選ぶ）。host・interfaceを指定する引数は持たせない
// - 1接続のpipeline: [受信バイト上限] → [ByteToMessageHandler(HTTPRequestDecoder)] → [callback判定]
//   - 受信バイト上限: request headの終端までに受け取るバイト数を maxRequestHeadBytes に抑える。
//     超えた分はdecoderへ渡さず、head終端が来ないまま上限に達したら .requestHeadTooLarge を返す
//   - HTTPRequestDecoder: request line・headerの字句解析はNIO（llhttp）に任せる
//   - callback判定: decoderが組み立てたheadを ChatGPTOAuthNIORequestHeadCheck で厳格に検査し、
//     合格したら ChatGPTOAuthCallbackValidator.verifyState でstateの一意一致を確かめてからsinkへ渡す
// - 1接続につき処理するrequestは最初の1個だけ。後続（パイプラインされたrequest・body）は拒否せず読み捨て、
//   固定responseを書いた後に送信側を閉じ（FIN）、相手が閉じるか期限が来たら接続を閉じる
// - 同時に扱う接続は maxConnections 個まで。超えた分は何も読まずに閉じる
// - 接続ごとに、受付から connectionDeadlineSeconds 秒の絶対期限で閉じる（相手が黙っていても少しずつ送っても同じ）
// - sinkはevent loopの外（専用Thread）で呼ぶ。event loop上では利用者のclosureを一切実行しない
//   - .callbackReceived はsinkが戻った後だけ返す。sinkが戻る前にstop・期限が来たらresponseを書かずに閉じる
//   - sinkを呼ぶのはlistener 1個につき最初の1回だけ。state一致を確認できなかったrequestは枠を消費しない
// - stop() は新しいsinkの呼び出しを止め、server channel・全接続を閉じて、event loop groupのshutdown完了まで待つ。
//   既に実行中のsinkは強制終了できないため待たない（既存listenerと同じ契約）
// - 二重start・stop後のstart・start中のcancellationはすべて失敗させ、同じlistenerを再利用しない（fail closed）
// - request target・header・callbackの内容は、error・description・ログのどこにも含めない（ログは一切出さない）
final class ChatGPTOAuthNIOLoopbackListener: Sendable {
    // 既存listenerと同じ形のsinkを受け取る（後で差し替えやすくするため）
    typealias CallbackSink = ChatGPTOAuthLoopbackListener.CallbackSink

    // 同時に処理する接続の上限
    static let maxConnections = 4
    // 1接続あたりの絶対期限（受付からの秒数）
    static let connectionDeadlineSeconds: Int64 = 5
    // request head（request line・header・CRLF CRLF）に許す合計バイト数。既存parserと同じ値
    static let maxRequestHeadBytes = ChatGPTOAuthLoopbackHTTPRequestParser.maxRequestHeadLength
    // header行の個数と、header名の長さの上限。ブラウザが通常送る数・長さには十分な値にする
    static let maxHeaderCount = 32
    static let maxHeaderNameLength = 64

#if DEBUG
    // EmbeddedChannelから本物のcallback handler経路だけを検証するためのテスト専用factory。
    static func makeEmbeddedCallbackHandler(
        expectedState: String,
        callbackSink: @escaping CallbackSink,
        boundPort: Int
    ) -> ChatGPTOAuthNIOEmbeddedHarness {
        let runtime = NIOLoopbackRuntime(expectedState: expectedState, callbackSink: callbackSink)
        return ChatGPTOAuthNIOEmbeddedHarness(
            handler: NIOCallbackRequestHandler(
                runtime: runtime,
                connection: NIOConnectionState(),
                boundPort: boundPort
            ),
            shutdownRuntime: { try runtime.shutdownForEmbeddedTest() }
        )
    }
#endif

    private let lifecycle: NIOLoopbackLifecycle

    init(expectedState: String, callbackSink: @escaping CallbackSink) {
        lifecycle = NIOLoopbackLifecycle(expectedState: expectedState, callbackSink: callbackSink)
    }

    deinit {
        // stopされずに解放された場合も、受付を止めてgroupのshutdownを始める（終了は待てない）
        lifecycle.requestStopOnDeinit()
    }

    /// 127.0.0.1のOS指定portで受付を始める。
    /// 同じlistenerで2回目のstart・stop後のstart・取消済みTaskからのstartは失敗する。
    /// bind中に取消・stopされた場合は、作ったchannelとgroupの後始末が終わってから失敗を返す。
    /// - Returns: bind済みのport（1...65535）
    func start() async throws -> Int {
        let runtime = try lifecycle.beginStart()
        do {
            // bind（非同期）の途中で取消されたら、runtimeに停止を頼む。
            // bind自体はNIOのfutureなので途中で止まらないが、完了後のattachで停止を検出して後始末する
            let port = try await withTaskCancellationHandler {
                try await runtime.bind()
            } onCancel: {
                runtime.requestStop()
            }
            try lifecycle.finishStart(runtime)
            return port
        } catch {
            // 失敗・取消・stopのどれでも、このlistenerは再利用させず、後始末の完了まで待ってから投げる
            lifecycle.markStartFailed(runtime)
            runtime.requestStop()
            await runtime.waitUntilFinished()
            throw error
        }
    }

    /// 受付を止め、全接続を閉じて、event loop groupのshutdown完了まで待つ。
    /// 開始していないときは、以後startできないようにして戻る。停止済み・停止中・bind中のときは、その後始末の完了まで待つ。
    /// 既に実行中のsinkは待たない。sink配送はlock下で認可または取消されるが、認可済み配送のsink本体はstop後に開始しうる。
    /// sinkがstop後に副作用を起こさない必要がある場合は、consumer側で状態を検証すること。
    func stop() async {
        guard let runtime = lifecycle.stop() else { return }
        await runtime.waitUntilFinished()
    }
}

#if DEBUG
final class ChatGPTOAuthNIOEmbeddedHarness {
    let handler: ChannelHandler
    private let shutdownRuntime: () throws -> Void

    fileprivate init(handler: ChannelHandler, shutdownRuntime: @escaping () throws -> Void) {
        self.handler = handler
        self.shutdownRuntime = shutdownRuntime
    }

    func shutdown() throws {
        try shutdownRuntime()
    }
}
#endif

// MARK: - 開始・停止の状態

// listenerの状態遷移だけを受け持つ。lockの順序は常に lifecycle → runtime（runtimeからlifecycleのlockは取らない）
private final class NIOLoopbackLifecycle: @unchecked Sendable {
    private enum State {
        // start前だけexpectedStateとsinkを持つ。start後はruntimeへ渡し、ここでは持たない
        case idle(expectedState: String, callbackSink: ChatGPTOAuthNIOLoopbackListener.CallbackSink)
        // bindを待っている
        case starting(NIOLoopbackRuntime)
        case running(NIOLoopbackRuntime)
        // runtimeを持っておくと、後から呼ばれたstopも同じ後始末の完了を待てる（runtimeは停止時に秘密を手放す）
        case stopped(NIOLoopbackRuntime?)
    }

    private let lock = NSLock()
    private var state: State

    init(expectedState: String, callbackSink: @escaping ChatGPTOAuthNIOLoopbackListener.CallbackSink) {
        state = .idle(expectedState: expectedState, callbackSink: callbackSink)
    }

    // idle → starting。groupとruntimeを作るだけで、bindはlockの外（呼び出し側のawait）で行う
    func beginStart() throws -> NIOLoopbackRuntime {
        lock.lock()
        defer { lock.unlock() }

        let expectedState: String
        let callbackSink: ChatGPTOAuthNIOLoopbackListener.CallbackSink
        switch state {
        case .idle(let pendingState, let pendingSink):
            expectedState = pendingState
            callbackSink = pendingSink
        case .starting, .running:
            throw ChatGPTOAuthLoopbackListenerError.alreadyStarted
        case .stopped:
            throw ChatGPTOAuthLoopbackListenerError.stopped
        }
        // 取消済みのTaskからはgroupも作らずに失敗させる。以後このlistenerは使えない
        if Task.isCancelled {
            state = .stopped(nil)
            throw CancellationError()
        }
        let runtime = NIOLoopbackRuntime(expectedState: expectedState, callbackSink: callbackSink)
        state = .starting(runtime)
        return runtime
    }

    // starting → running。bind中にstop・取消されていたら失敗させる（後始末は呼び出し側）
    func finishStart(_ runtime: NIOLoopbackRuntime) throws {
        lock.lock()
        defer { lock.unlock() }
        guard case .starting(let current) = state, current === runtime else {
            throw ChatGPTOAuthLoopbackListenerError.stopped
        }
        if Task.isCancelled { throw CancellationError() }
        // attach直後にonCancel等で停止が始まった場合も、動いていないruntimeを「running」にしない
        guard !runtime.isStopping else { throw ChatGPTOAuthLoopbackListenerError.stopped }
        state = .running(runtime)
    }

    func markStartFailed(_ runtime: NIOLoopbackRuntime) {
        lock.lock()
        defer { lock.unlock() }
        if case .starting(let current) = state, current === runtime {
            state = .stopped(runtime)
        }
    }

    // 待つべきruntimeがあれば返す（lockを持ったままawaitしないよう、待つのは呼び出し側）
    func stop() -> NIOLoopbackRuntime? {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .idle:
            state = .stopped(nil)
            return nil
        case .starting(let runtime), .running(let runtime):
            state = .stopped(runtime)
            // bind中なら停止の予約だけになり、後始末はbind完了後にstart側が行う
            runtime.requestStop()
            return runtime
        case .stopped(let runtime):
            return runtime
        }
    }

    func requestStopOnDeinit() {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .starting(let runtime), .running(let runtime):
            state = .stopped(runtime)
            runtime.requestStop()
        case .idle, .stopped:
            break
        }
    }
}

// MARK: - groupとserver channel

// 1回のstartで作るgroup・server channel・接続と、配送枠の状態。
// 後始末（server channel・全接続のclose、groupのshutdown）は、どの経路から来ても1回だけ始める
private final class NIOLoopbackRuntime: @unchecked Sendable {
    // 127.0.0.1（ホストバイトオーダー）
    private static let ipv4LoopbackAddress: UInt32 = 0x7F00_0001

    private enum Phase {
        // bindの完了待ち。ここでstopされたら、bind完了後にbind()が後始末する
        case binding
        case serving(Channel)
        // 後始末を始めた（または始める番が決まった）。以後は何もしない
        case tornDown
    }

    private let group: MultiThreadedEventLoopGroup

    private let lock = NSLock()
    private var phase: Phase = .binding
    private var stopping = false
    private var delivered = false
    // stop開始時に手放す（nilにする）。以後の接続はこれらを読めず、新しい配送も始めない
    private var callbackSink: ChatGPTOAuthNIOLoopbackListener.CallbackSink?
    private var expectedState: String?
    // pending配送。stopとの競合はdeliveryのlock下でauthorizedまたはcancelledに一度だけ遷移する
    private var delivery: NIOSinkDelivery?
    // 処理中の接続。stopで全部閉じる。channelが閉じたら取り除く
    private var children: [ObjectIdentifier: Channel] = [:]
    // groupのshutdown完了を待っている呼び出し
    private var finished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(expectedState: String, callbackSink: @escaping ChatGPTOAuthNIOLoopbackListener.CallbackSink) {
        // 1 threadで足りる（接続は最大4、1接続のrequestは1個だけ）
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.expectedState = expectedState
        self.callbackSink = callbackSink
    }

#if DEBUG
    fileprivate func shutdownForEmbeddedTest() throws {
        try group.syncShutdownGracefully()
    }
#endif

    var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    // MARK: bind

    /// 127.0.0.1:0 へbindし、確定したportを返す。
    /// 失敗・bind中のstop・取消のときは、作ったものの後始末を始めてからthrowする
    func bind() async throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            // listenのbacklogも接続上限と同じにする
            .serverChannelOption(ChannelOptions.backlog, value: Int32(ChatGPTOAuthNIOLoopbackListener.maxConnections))
            // 相手が送信側だけ閉じても、こちらはresponseを書き終えるまで接続を保てるようにする
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { [self] channel in
                initializeChild(channel)
            }

        let serverChannel: Channel
        do {
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            serverChannel = try await bootstrap.bind(to: address).get()
        } catch {
            beginTeardownIfNeeded(serverChannel: nil)
            throw ChatGPTOAuthLoopbackListenerError.setupFailed
        }

        // 実際にbindされたアドレスを読み戻し、127.0.0.1かつ有効なportであることを確かめる
        guard let bound = Self.ipv4HostOrderAddress(serverChannel.localAddress),
              bound.address == Self.ipv4LoopbackAddress,
              (1...65535).contains(bound.port)
        else {
            beginTeardownIfNeeded(serverChannel: serverChannel)
            throw ChatGPTOAuthLoopbackListenerError.setupFailed
        }

        guard attach(serverChannel) else {
            // bind中にstop・取消された。attachが後始末を始めている
            if Task.isCancelled { throw CancellationError() }
            throw ChatGPTOAuthLoopbackListenerError.stopped
        }
        return bound.port
    }

    // binding → serving。既に停止が始まっていたら後始末を始めてfalseを返す
    private func attach(_ serverChannel: Channel) -> Bool {
        lock.lock()
        guard !stopping, case .binding = phase else {
            lock.unlock()
            beginTeardownIfNeeded(serverChannel: serverChannel)
            return false
        }
        phase = .serving(serverChannel)
        lock.unlock()
        return true
    }

    // MARK: 停止

    /// 停止を始める。何度呼んでもよい（2回目以降は何もしない）。
    /// bind中なら停止の予約だけを行い、後始末はbind()がbind完了後に始める
    func requestStop() {
        lock.lock()
        stopping = true
        // 起動待ちのsinkは始めさせず、完了通知も止める。実行中のsinkは止められないので待たない。
        // 停止フラグと同じlockの中で取消し、「停止扱いなのにsinkを始められる」隙間を作らない
        // （lockの順序は常に runtime → delivery。deliveryの中からruntimeのlockは取らない）
        delivery?.cancel()
        // 停止後に秘密やsinkのclosureを持ち続けないよう、ここで手放す
        callbackSink = nil
        expectedState = nil
        guard case .serving(let serverChannel) = phase else {
            lock.unlock()
            return
        }
        lock.unlock()
        beginTeardownIfNeeded(serverChannel: serverChannel)
    }

    // 後始末をちょうど1回だけ始める。lockの外から呼ぶ
    private func beginTeardownIfNeeded(serverChannel: Channel?) {
        lock.lock()
        if case .tornDown = phase {
            lock.unlock()
            return
        }
        phase = .tornDown
        stopping = true
        delivery?.cancel()
        callbackSink = nil
        expectedState = nil
        let openChildren = Array(children.values)
        children.removeAll()
        lock.unlock()

        // どれもevent loopへ依頼するだけで、ここでは待たない
        serverChannel?.close(promise: nil)
        for child in openChildren {
            child.close(promise: nil)
        }
        // shutdownは残っているchannelもすべて閉じ、event loopのthreadが終わってから完了を知らせる
        group.shutdownGracefully(queue: .global()) { [self] _ in
            markFinished()
        }
    }

    private func markFinished() {
        lock.lock()
        finished = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !enqueueFinishWaiter(continuation) {
                continuation.resume()
            }
        }
    }

    // 既に終わっていたらfalse（呼び出し側がすぐresumeする）
    private func enqueueFinishWaiter(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finishWaiters.append(continuation)
        return true
    }

    // MARK: 接続の受付

    // 受付ごとにevent loop上で呼ばれる。loopback以外・上限超過・停止中は、何も読まずに閉じる
    private func initializeChild(_ channel: Channel) -> EventLoopFuture<Void> {
        guard let local = Self.ipv4HostOrderAddress(channel.localAddress),
              local.address == Self.ipv4LoopbackAddress,
              (1...65535).contains(local.port),
              let remote = Self.ipv4HostOrderAddress(channel.remoteAddress),
              // 127.0.0.0/8（先頭1バイトが127）
              remote.address >> 24 == 127,
              reserveConnection(channel)
        else {
            channel.close(promise: nil)
            return channel.eventLoop.makeSucceededVoidFuture()
        }

        // 受付からの絶対期限。responseの途中でも、sinkの完了待ちでも、期限が来たら閉じる
        let deadline = channel.eventLoop.scheduleTask(
            in: .seconds(ChatGPTOAuthNIOLoopbackListener.connectionDeadlineSeconds)
        ) {
            channel.close(promise: nil)
        }
        channel.closeFuture.whenComplete { [self] _ in
            deadline.cancel()
            releaseConnection(channel)
        }

        // child channelの初期化はそのchannelのevent loop上で行われるので、syncOperationsで直接追加できる
        let maxHeadBytes = ChatGPTOAuthNIOLoopbackListener.maxRequestHeadBytes
        let boundPort = local.port
        return channel.eventLoop.makeCompletedFuture(withResultOf: {
            let connection = NIOConnectionState()
            let operations = channel.pipeline.syncOperations
            try operations.addHandler(NIORequestHeadLimitHandler(connection: connection, limit: maxHeadBytes))
            // leftOverBytesStrategy: upgradeは扱わないので、残りのバイトは捨てる
            try operations.addHandler(ByteToMessageHandler(
                HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes),
                maximumBufferSize: maxHeadBytes
            ))
            try operations.addHandler(NIOCallbackRequestHandler(runtime: self, connection: connection, boundPort: boundPort))
        })
    }

    private func reserveConnection(_ channel: Channel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping, children.count < ChatGPTOAuthNIOLoopbackListener.maxConnections else { return false }
        children[ObjectIdentifier(channel)] = channel
        return true
    }

    private func releaseConnection(_ channel: Channel) {
        lock.lock()
        defer { lock.unlock() }
        children.removeValue(forKey: ObjectIdentifier(channel))
    }

    // SocketAddressがIPv4なら、アドレス（ホストバイトオーダー）とportを返す
    private static func ipv4HostOrderAddress(_ address: SocketAddress?) -> (address: UInt32, port: Int)? {
        guard case .v4(let ipv4)? = address, let port = address?.port else { return nil }
        return (UInt32(bigEndian: ipv4.address.sin_addr.s_addr), port)
    }

    // MARK: 配送枠

    enum DeliveryDecision {
        case deliver(NIOSinkDelivery, ChatGPTOAuthNIOLoopbackListener.CallbackSink)
        case alreadyDelivered
        case stopping
    }

    // stop開始後はexpectedStateを手放しているのでnil
    func currentExpectedState() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stopping ? nil : expectedState
    }

    // sinkへ渡すのはlistener 1個につき最初の1回だけ。停止中は渡さない。
    // 配送の記録（delivery）は停止フラグと同じlockの中で作るので、直後に始まったstopも必ずこれを取消せる
    func claimDelivery() -> DeliveryDecision {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping, let sink = callbackSink else { return .stopping }
        if delivered { return .alreadyDelivered }
        delivered = true
        let newDelivery = NIOSinkDelivery()
        delivery = newDelivery
        return .deliver(newDelivery, sink)
    }
}

// MARK: - sinkの配送

// sinkが戻ったことを、接続のpipelineへ知らせるevent
private struct NIOSinkCompletedEvent: Sendable {}

// 1回の配送。pendingからauthorized/cancelledへの遷移をlockで線形化し、event loop外の専用Threadでsinkを呼ぶ。
// Threadはこのobjectとsink・callback・channelだけを持ち、runtime（group）は持たないので、
// sinkがblockしてもstop（groupのshutdown）は妨げない。authorized後はstop後にsink本体が始まりうるため、
// stop後の副作用を防ぐ必要があるconsumerは自身の状態を検証する。ここ自体には秘密を持たせない
private final class NIOSinkDelivery: @unchecked Sendable {
    private enum State {
        case pending
        case authorized
        case cancelled
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var completionSuppressed = false

    func start(_ sink: @escaping ChatGPTOAuthNIOLoopbackListener.CallbackSink,
               with callback: ChatGPTOAuthLoopbackCallbackRequest,
               channel: Channel) {
        let thread = Thread { [self] in
            // stopと競合する認可をlock下で決める。認可後のsink開始自体はstop後になりうる
            guard authorize() else { return }
            sink(callback)
            notifyCompleted(channel)
        }
        thread.name = "ChatGPTOAuthNIOLoopbackListener.sink"
        thread.start()
    }

    // stopから呼ぶ。未認可配送を取り消し、完了通知も止める（認可済み/実行中のsinkは止めない）
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if case .pending = state { state = .cancelled }
        completionSuppressed = true
    }

    private func authorize() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = state else { return false }
        state = .authorized
        return true
    }

    // 通知はcancelと同じlockの中で依頼する。stopはcancelしてからgroupのshutdownを始めるので、
    // shutdown済みのevent loopへ仕事を依頼することはない
    private func notifyCompleted(_ channel: Channel) {
        lock.lock()
        defer { lock.unlock() }
        guard !completionSuppressed else { return }
        channel.pipeline.fireUserInboundEventTriggered(NIOSinkCompletedEvent())
    }
}

// MARK: - 1接続のpipeline

// 1接続のhandler間で共有する状態。event loop上だけで読み書きする
private final class NIOConnectionState {
    // この接続の1個目のrequestについて、処理方針が決まった（head受信・decoderエラー・上限超過）。
    // 以後の受信バイトはdecoderへ渡さず読み捨てる
    var requestDecided = false
}

// head終端の前に上限へ達したことを知らせるevent
private struct NIORequestHeadLimitReachedEvent {}

// decoderの手前で、受け取るバイト数を上限で切る。
// 上限を超えた分は渡さないので、decoderが読むのは最大 limit バイトまでになる
private final class NIORequestHeadLimitHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let connection: NIOConnectionState
    private var remaining: Int
    private var limitReported = false

    init(connection: NIOConnectionState, limit: Int) {
        self.connection = connection
        self.remaining = limit
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // 方針が決まった後（パイプラインされた次のrequest等）と上限超過分は、拒否せず読み捨てる
        guard !connection.requestDecided, remaining > 0 else { return }
        var buffer = unwrapInboundIn(data)
        let length = min(buffer.readableBytes, remaining)
        guard length > 0, let slice = buffer.readSlice(length: length) else { return }
        remaining -= length
        // decoderは同期的に処理するので、この呼び出しから戻った時点でheadが組み立て済みかどうかが確定している
        context.fireChannelRead(wrapInboundOut(slice))
        if remaining == 0, !connection.requestDecided, !limitReported {
            limitReported = true
            context.fireUserInboundEventTriggered(NIORequestHeadLimitReachedEvent())
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // head終端の前に相手が送信側を閉じたら、responseを書かずに閉じる。
        // decoderへ渡すとdecodeLastのエラーで400を返してしまうので、ここで止める
        if case ChannelEvent.inputClosed? = event as? ChannelEvent, !connection.requestDecided {
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }
}

// decoderが組み立てたheadを検査し、配送・responseを決める
private final class NIOCallbackRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = ByteBuffer

    private enum Phase {
        // 1個目のrequestのheadを待っている
        case awaitingHead
        // sinkの完了を待っている（responseはまだ書かない）
        case awaitingSink
        // responseを書いた、または書かずに閉じると決めた
        case finished
        // response writeの完了を待っている。inputClosedを受けてもwrite完了までは閉じない
        case writingResponse
        // response writeが成功し、送信側を閉じた
        case responseWritten
    }

    private let runtime: NIOLoopbackRuntime
    private let connection: NIOConnectionState
    private let boundPort: Int
    private var phase: Phase = .awaitingHead
    private var inputClosed = false

    init(runtime: NIOLoopbackRuntime, connection: NIOConnectionState, boundPort: Int) {
        self.runtime = runtime
        self.connection = connection
        self.boundPort = boundPort
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // 2個目以降のrequest・bodyは読み捨てる
        guard case .awaitingHead = phase, case .head(let head) = unwrapInboundIn(data) else { return }
        connection.requestDecided = true

        switch ChatGPTOAuthNIORequestHeadCheck.evaluate(head, boundPort: boundPort) {
        case .respond(let kind):
            respond(kind, context: context)
        case .callback(let callback):
            deliver(callback, context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // headの前に起きたdecoderのエラー（構文不正・バッファ上限など）だけを400にする。
        // 1個目の後に続いたバイトのエラーは無視する
        guard case .awaitingHead = phase else { return }
        connection.requestDecided = true
        respond(.callbackFailed, context: context)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is NIORequestHeadLimitReachedEvent:
            guard case .awaitingHead = phase else { return }
            connection.requestDecided = true
            respond(.requestHeadTooLarge, context: context)
        case is NIOSinkCompletedEvent:
            guard case .awaitingSink = phase else { return }
            // 通知がevent loopへ届くまでの間にstopが始まっていたら、responseを書かずに閉じる
            guard !runtime.isStopping else {
                phase = .finished
                context.close(promise: nil)
                return
            }
            respond(.callbackReceived, context: context)
        case let channelEvent as ChannelEvent where channelEvent == .inputClosed:
            // inputClosedは記録し、response write中はchannelを維持する。期限は独立して接続を閉じる
            inputClosed = true
            if case .responseWritten = phase {
                context.close(promise: nil)
            }
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // 期限・stop・相手の切断で閉じた。sink完了の通知が後から来ても何も書かない
        phase = .finished
        context.fireChannelInactive()
    }

    // MARK: 配送

    private func deliver(_ callback: ChatGPTOAuthLoopbackCallbackRequest, context: ChannelHandlerContext) {
        // stop開始後はexpectedStateを手放しているので、照合も配送もしない
        guard let expectedState = runtime.currentExpectedState() else {
            phase = .finished
            context.close(promise: nil)
            return
        }

        // 配送枠を確保する前に、stateの一意一致をvalidatorで確認する。
        // verifyStateが失敗した応答は、理由を問わず枠を消費しない。state一致後の検査は後段のAttemptに委ねる
        // （validatorは入力4096バイト上限の純粋な関数で、利用者のclosureではないのでevent loop上で呼ぶ）
        guard let redirectURI = URL(string: "http://127.0.0.1:\(boundPort)/auth/callback"),
              (try? ChatGPTOAuthCallbackValidator.verifyState(
                  callback: callback.callback,
                  expecting: ChatGPTOAuthCallbackExpectation(redirectURI: redirectURI, state: expectedState)
              )) != nil
        else {
            respond(.callbackFailed, context: context)
            return
        }

        switch runtime.claimDelivery() {
        case .deliver(let delivery, let sink):
            // sinkはevent loopの外で呼ぶ。完了はNIOSinkCompletedEventで戻ってくる
            phase = .awaitingSink
            delivery.start(sink, with: callback, channel: context.channel)
        case .alreadyDelivered:
            respond(.callbackFailed, context: context)
        case .stopping:
            phase = .finished
            context.close(promise: nil)
        }
    }

    // MARK: response

    // 固定responseを書き、書けたら送信側だけ閉じる（FIN）。
    // 受信側を読み残したまま全体を閉じるとRSTになりresponseが捨てられうるため、相手が閉じる（inputClosed）か期限まで待つ
    private func respond(_ kind: ChatGPTOAuthLoopbackResponseKind, context: ChannelHandlerContext) {
        phase = .writingResponse
        guard let data = try? ChatGPTOAuthLoopbackResponseBuilder.response(for: kind) else {
            context.close(promise: nil)
            return
        }
        let buffer = context.channel.allocator.buffer(bytes: data)
        // closureにはSendableなchannelだけを渡す（contextはevent loopの外へ持ち出さない）
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { result in
            channel.eventLoop.execute {
                switch result {
                case .success:
                    self.phase = .responseWritten
                    channel.close(mode: .output).whenComplete { closeResult in
                        channel.eventLoop.execute {
                            if case .failure = closeResult {
                                channel.close(promise: nil)
                            } else if self.inputClosed {
                                channel.close(promise: nil)
                            }
                        }
                    }
                case .failure:
                    self.phase = .finished
                    channel.close(promise: nil)
                }
            }
        }
    }
}

// MARK: - request headの検査

// NIOのHTTPRequestDecoderが組み立てたheadを、既存parser（ChatGPTOAuthLoopbackHTTPRequestParser）と同じ方針で厳格に検査する。
// ソケット・状態を持たない純粋な関数。request target・headerの内容はerror・ログに含めない。
// 判定順: bound port → method → request target（origin-form） → path・query → version
//        → header個数・名前の長さ → header構文 → Host → body関連header
enum ChatGPTOAuthNIORequestHeadCheck {
    enum Outcome {
        // 固定responseを返して終える（sinkは呼ばない）
        case respond(ChatGPTOAuthLoopbackResponseKind)
        // 検査に合格した。stateの照合はまだ（呼び出し側がverifyStateで行う）
        case callback(ChatGPTOAuthLoopbackCallbackRequest)
    }

    private static let callbackPath = "/auth/callback"
    private static let htab: UInt8 = 0x09

    static func evaluate(_ head: HTTPRequestHead, boundPort: Int) -> Outcome {
        guard (1...65535).contains(boundPort) else { return .respond(.callbackFailed) }

        // 1. methodはGETだけ。llhttpが知らないmethodはdecoderのエラーになり、ここへは来ない
        guard head.method == .GET else { return .respond(.methodNotAllowed) }

        // 2. request targetはorigin-form（"/"で始まり、URIで許される文字だけ）
        let target = head.uri
        guard isValidOriginForm(target) else { return .respond(.callbackFailed) }

        // 3. pathは "/auth/callback" とバイト単位で完全一致し、空でないqueryを持つ
        guard let questionMark = target.firstIndex(of: "?"),
              target[..<questionMark] == callbackPath,
              target.index(after: questionMark) < target.endIndex
        else {
            return .respond(.notFound)
        }

        // 4. HTTP/1.1だけ
        guard head.version == .http1_1 else { return .respond(.callbackFailed) }

        // 5. headerの個数と名前の長さ。バイト数全体はNIORequestHeadLimitHandlerで抑えている
        guard head.headers.count <= ChatGPTOAuthNIOLoopbackListener.maxHeaderCount else {
            return .respond(.requestHeadTooLarge)
        }
        var hosts: [String] = []
        var contentLengths: [String] = []
        var hasTransferEncoding = false
        for (name, value) in head.headers {
            guard name.utf8.count <= ChatGPTOAuthNIOLoopbackListener.maxHeaderNameLength else {
                return .respond(.requestHeadTooLarge)
            }
            // 6. 名前はtoken、値は印字可能ASCIIとHTABだけ（decoderの寛容さに頼らず確認する）
            guard !name.isEmpty, name.utf8.allSatisfy(isTokenByte),
                  value.utf8.allSatisfy({ (0x20...0x7E).contains($0) || $0 == htab })
            else {
                return .respond(.callbackFailed)
            }
            switch asciiLowercased(name) {
            case "host": hosts.append(value)
            case "content-length": contentLengths.append(value)
            case "transfer-encoding": hasTransferEncoding = true
            default: break
            }
        }

        // 7. Hostはちょうど1個で、値は "127.0.0.1:<この接続のport>" と完全一致
        guard hosts.count == 1, hosts[0] == "127.0.0.1:\(boundPort)" else {
            return .respond(.callbackFailed)
        }

        // 8. bodyは受け取らない。Transfer-Encodingは不可、Content-Lengthは無しか "0" が1個だけ
        guard !hasTransferEncoding,
              contentLengths.isEmpty || (contentLengths.count == 1 && contentLengths[0] == "0")
        else {
            return .respond(.callbackFailed)
        }

        return .callback(ChatGPTOAuthLoopbackCallbackRequest(callback: "http://127.0.0.1:\(boundPort)\(target)"))
    }

    // origin-form = absolute-path [ "?" query ]（RFC 9112）。fragment・壊れた%エンコード・URIに生で書けない文字は拒否
    private static func isValidOriginForm(_ target: String) -> Bool {
        let bytes = Array(target.utf8)
        guard bytes.first == UInt8(ascii: "/") else { return false }
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%") {
                guard index + 2 < bytes.count, isHexDigit(bytes[index + 1]), isHexDigit(bytes[index + 2]) else {
                    return false
                }
                index += 3
                continue
            }
            guard isOriginFormByte(byte) else { return false }
            index += 1
        }
        return true
    }

    // pchar（unreserved / sub-delims / ":" / "@"）と、path・queryの区切りに使う "/" "?"
    private static func isOriginFormByte(_ byte: UInt8) -> Bool {
        isAlphaNumeric(byte) || "-._~!$&'()*+,;=:@/?".utf8.contains(byte)
    }

    // tchar（RFC 9110）
    private static func isTokenByte(_ byte: UInt8) -> Bool {
        isAlphaNumeric(byte) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    // localeやUnicodeの規則に依存しないよう、A〜Zだけを小文字にする（名前はtoken検査済みでASCIIのみ）
    private static func asciiLowercased(_ value: String) -> String {
        String(decoding: value.utf8.map { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) ? $0 + 0x20 : $0 },
               as: UTF8.self)
    }
}
