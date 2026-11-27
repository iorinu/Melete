import Darwin
import Foundation

// ChatGPT OAuth初回登録で、ブラウザからのcallbackを受け取るloopback listener。
// POSIX socketで 127.0.0.1 のOS指定portだけを待ち受け、受け取ったrequest headを既存parserで検査してからsinkへ渡す。
// アプリ本体からはまだ呼び出さない。配送前のstate一致確認以外のOAuth試行の検証・ブラウザ起動・token交換・UI・保存は扱わない。
//
// 契約（MeleteTests/ChatGPTOAuthLoopbackListenerTests.swift で検証する）:
// - bind先は AF_INET の 127.0.0.1 固定。host・interfaceを指定する引数は持たせない（外部interfaceへbindする経路を作らない）
//   SO_REUSEADDR・SO_REUSEPORTは設定しない（同じportへ他のsocketが相乗りできないようにする）
// - portはOSに選ばせ（port 0でbind）、start() はgetsocknameで確定したport（1...65535）を返す
// - 接続相手がIPv4 loopback（127.0.0.0/8）以外なら、何も読まずに閉じる
// - 同時に処理する接続は maxConnections 個まで。超えた分は何も読まずに閉じる
// - 受け取ったrequest headは、sinkへ渡す前に必ず ChatGPTOAuthLoopbackHTTPRequestParser.parse に通す。
//   parserが合格し、さらに ChatGPTOAuthCallbackValidator.verifyState でstateの一意一致を確認できたときだけ、
//   その結果（ChatGPTOAuthLoopbackCallbackRequest）をsinkへ渡す。
//   sinkを呼ぶのはlistener 1個につき最初の1回だけ。state一致を確認できなかったrequestは、この1回の枠を消費しない
// - sinkの呼び出しは、ブラウザへresponseを書き込むより前に完了させる
// - responseは ChatGPTOAuthLoopbackResponseBuilder の固定文（Connection: close付き）だけを書き込み、書き込み後に接続を閉じる
//   - parserが合格・state一致（最初の1回）: .callbackReceived
//   - parserが合格・state一致（2回目以降）: .callbackFailed（sinkは呼ばない）
//   - parserが合格・state一致を確認できない: .callbackFailed（sinkは呼ばず、枠も消費しない）
//   - parserが unexpectedPath（/favicon.ico など）: .notFound（sinkは呼ばない）
//   - parserが unsupportedMethod: .methodNotAllowed（sinkは呼ばない）
//   - head終端が maxRequestHeadLength バイト以内に来ない: .requestHeadTooLarge（sinkは呼ばない）
//   - それ以外のparser error: .callbackFailed（sinkは呼ばない）
//   - head終端の前に相手が閉じた・制限時間を超えた・stopした: responseを書かずに閉じる
// - 接続ごとのread・writeは合計 connectionDeadlineSeconds 秒まで。相手が黙ったまま・少しずつ送り続けても打ち切る
// - stop() は受付を止めてlisten socketを閉じ、処理中の接続のI/Oを取消して、workerがすべて終わるまで待ってから戻る。
//   stop() が戻った後は、sinkを一度も呼ばない（途中まで届いていたrequestも含む）
// - 二重start・stop後のstart・start中のcancellationはすべて失敗させ、同じlistenerを再利用しない（fail closed）
// - request target・header・callbackの内容は、error・description・ログのどこにも含めない（ログは一切出さない）
//
// スレッド構成: 受付用のThreadを1本と、接続ごとのworker Threadを最大 maxConnections 本使う。
// それぞれのblocking待ちは「対象socket」と「停止通知用pipe」をpollで同時に待ち、stopのpipe書き込みですぐ起きる。
// 念のためpollの1回の待ち時間にも上限（pollSliceMilliseconds）を設け、起きるたびに停止フラグも確かめる。
final class ChatGPTOAuthLoopbackListener: Sendable {
    // parserに合格したcallbackを受け取る先。listenerのworkerから呼ばれるため、すぐ戻る処理だけにする
    typealias CallbackSink = @Sendable (ChatGPTOAuthLoopbackCallbackRequest) -> Void

    // 同時に処理する接続の上限
    static let maxConnections = 4
    // 1接続あたりのread・write全体の制限時間
    static let connectionDeadlineSeconds = 5

    private let callbackSink: CallbackSink
    private let expectedState: String
    // 開始・停止の状態。startとstopが別Taskから同時に呼ばれても壊れないよう、lockで守る箱に入れる
    private let lifecycle = LoopbackListenerLifecycle()

    init(expectedState: String, callbackSink: @escaping CallbackSink) {
        self.expectedState = expectedState
        self.callbackSink = callbackSink
    }

    deinit {
        // stopされずに解放された場合も、受付・workerを止めるよう通知だけはしておく（終了は待てない）
        lifecycle.requestStopOnDeinit()
    }

    /// 127.0.0.1のOS指定portで受付を始める。
    /// 同じlistenerで2回目のstart・stop後のstart・取消済みTaskからのstartは失敗する。
    /// - Returns: bind済みのport（1...65535）
    func start() async throws -> Int {
        // socketの準備（socket・bind・listen・getsockname）はどれも待たずに終わる呼び出しなので、
        // lockを持ったまま行う。こうするとstopが準備の途中に割り込めず、「bindしたのに誰も閉じない」状態を作らない
        try lifecycle.start(expectedState: expectedState, callbackSink: callbackSink)
    }

    /// 受付を止め、処理中の接続をすべて閉じて、workerの終了まで待つ。
    /// 開始していないときは、以後startできないようにして戻る。停止済み・停止中のときは、その停止の完了まで待つ。
    func stop() async {
        guard let runtime = lifecycle.stop() else { return }
        await runtime.waitUntilFinished()
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

// MARK: - 開始・停止の状態

// listenerの状態遷移だけを受け持つ。class本体をSendableのまま保つため、可変な状態はここへ分ける
private final class LoopbackListenerLifecycle: @unchecked Sendable {
    private enum State {
        case idle
        case running(LoopbackListenerRuntime)
        // runtimeを持っておくと、後から呼ばれたstopも同じ停止の完了を待てる
        case stopped(LoopbackListenerRuntime?)
    }

    private let lock = NSLock()
    private var state = State.idle

    func start(expectedState: String, callbackSink: @escaping ChatGPTOAuthLoopbackListener.CallbackSink) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .idle:
            break
        case .running:
            throw ChatGPTOAuthLoopbackListenerError.alreadyStarted
        case .stopped:
            throw ChatGPTOAuthLoopbackListenerError.stopped
        }
        // ここから先でどんな失敗をしても、このlistenerは再利用させない
        state = .stopped(nil)

        if Task.isCancelled { throw CancellationError() }
        let runtime = try LoopbackListenerRuntime.bindLoopback(expectedState: expectedState, callbackSink: callbackSink)
        // 準備中に取消された場合は、受付を始める前に閉じて失敗させる
        if Task.isCancelled {
            runtime.closeBeforeAccepting()
            throw CancellationError()
        }
        runtime.startAccepting()
        state = .running(runtime)
        return runtime.boundPort
    }

    // 待つべきruntimeがあれば返す（lockを持ったままawaitしないよう、待つのは呼び出し側）
    func stop() -> LoopbackListenerRuntime? {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .idle:
            state = .stopped(nil)
            return nil
        case .running(let runtime):
            state = .stopped(runtime)
            runtime.requestStop()
            return runtime
        case .stopped(let runtime):
            return runtime
        }
    }

    func requestStopOnDeinit() {
        lock.lock()
        defer { lock.unlock() }
        if case .running(let runtime) = state {
            state = .stopped(runtime)
            runtime.requestStop()
        }
    }
}

// MARK: - socketと受付・worker

// 1回のstartで作るsocket一式と、受付・workerの実行状態。
// 受付Thread・worker Thread・listenerの状態が参照を持ち、すべて手放されたときにpipeを閉じる
private final class LoopbackListenerRuntime: @unchecked Sendable {
    // pollの1回の待ち時間の上限。pipeの通知を取りこぼしても、この間隔で停止フラグを確かめる
    private static let pollSliceMilliseconds: Int32 = 250
    private static let maxRequestHeadLength = ChatGPTOAuthLoopbackHTTPRequestParser.maxRequestHeadLength
    // 127.0.0.1（ホストバイトオーダー）。Cマクロ INADDR_LOOPBACK のSwiftでの型に依存しないよう自前で持つ
    private static let ipv4LoopbackAddress: UInt32 = 0x7F00_0001

    let boundPort: Int
    private let listenFD: Int32
    // stopの通知用pipe。書き込み側に1バイト書くと、読み取り側をpollしている全員が起きる（読み出さないので通知が残る）
    private let wakeReadFD: Int32
    private let wakeWriteFD: Int32
    private let callbackSink: ChatGPTOAuthLoopbackListener.CallbackSink
    private let expectedState: String

    // 受付Threadが（workerの終了を待ってから）抜けたときにleaveする。stopはこれを待つ
    private let finished = DispatchGroup()
    // 処理中のworker。受付Threadは抜ける前にこれを待つ
    private let workers = DispatchGroup()

    private let lock = NSLock()
    private var stopping = false
    private var activeConnections = 0
    private var delivered = false

    private init(boundPort: Int, listenFD: Int32, wakeReadFD: Int32, wakeWriteFD: Int32,
                 expectedState: String,
                 callbackSink: @escaping ChatGPTOAuthLoopbackListener.CallbackSink) {
        self.boundPort = boundPort
        self.listenFD = listenFD
        self.wakeReadFD = wakeReadFD
        self.wakeWriteFD = wakeWriteFD
        self.callbackSink = callbackSink
        self.expectedState = expectedState
    }

    deinit {
        // listen socketは受付Thread（またはcloseBeforeAccepting）が閉じる。ここではpipeだけを閉じる。
        // 参照が残っている間は閉じないので、stopの通知書き込みが別のfdへ紛れ込むことはない
        Darwin.close(wakeReadFD)
        Darwin.close(wakeWriteFD)
    }

    // MARK: 準備

    // 127.0.0.1:0 へbindしてlistenし、確定したportとpipeを持つruntimeを返す。失敗時は作ったfdをすべて閉じる
    static func bindLoopback(expectedState: String, callbackSink: @escaping ChatGPTOAuthLoopbackListener.CallbackSink) throws -> LoopbackListenerRuntime {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw ChatGPTOAuthLoopbackListenerError.setupFailed }
        var keepFD = false
        defer { if !keepFD { Darwin.close(fd) } }

        // 子プロセスへ引き継がない・acceptで固まらない・相手が閉じた後の書き込みでSIGPIPEを受けない
        guard setCloseOnExec(fd), setNonBlocking(fd), setNoSigPipe(fd) else {
            throw ChatGPTOAuthLoopbackListenerError.setupFailed
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        // port 0 でOSに空きportを選ばせる
        address.sin_port = 0
        // socketのアドレスはネットワークバイトオーダー（big endian）で渡す
        address.sin_addr = in_addr(s_addr: ipv4LoopbackAddress.bigEndian)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw ChatGPTOAuthLoopbackListenerError.setupFailed }
        guard Darwin.listen(fd, Int32(ChatGPTOAuthLoopbackListener.maxConnections)) == 0 else {
            throw ChatGPTOAuthLoopbackListenerError.setupFailed
        }

        // 実際にbindされたアドレスを読み戻し、127.0.0.1かつ有効なportであることを確かめる
        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLength)
            }
        }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        guard nameResult == 0,
              boundLength == socklen_t(MemoryLayout<sockaddr_in>.size),
              bound.sin_family == sa_family_t(AF_INET),
              UInt32(bigEndian: bound.sin_addr.s_addr) == ipv4LoopbackAddress,
              (1...65535).contains(port)
        else {
            throw ChatGPTOAuthLoopbackListenerError.setupFailed
        }

        var pipeFDs: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipeFDs) == 0 else { throw ChatGPTOAuthLoopbackListenerError.setupFailed }
        // stopが書き込みで固まらないよう、両端をnon-blockingにする
        guard pipeFDs.allSatisfy({ setCloseOnExec($0) && setNonBlocking($0) }) else {
            Darwin.close(pipeFDs[0])
            Darwin.close(pipeFDs[1])
            throw ChatGPTOAuthLoopbackListenerError.setupFailed
        }

        keepFD = true
        return LoopbackListenerRuntime(boundPort: port, listenFD: fd,
                                       wakeReadFD: pipeFDs[0], wakeWriteFD: pipeFDs[1],
                                       expectedState: expectedState,
                                       callbackSink: callbackSink)
    }

    // 受付Threadを始める前に取消された場合だけ使う
    func closeBeforeAccepting() {
        Darwin.close(listenFD)
    }

    func startAccepting() {
        finished.enter()
        let thread = Thread { [self] in
            acceptLoop()
            // listen socketを閉じてから、workerがすべて終わるのを待ち、最後に完了を知らせる
            Darwin.close(listenFD)
            workers.wait()
            finished.leave()
        }
        thread.name = "ChatGPTOAuthLoopbackListener.accept"
        thread.start()
    }

    // MARK: 停止

    // listenerの状態lockの中から、最初の停止で1回だけ呼ばれる
    func requestStop() {
        lock.lock()
        let alreadyStopping = stopping
        stopping = true
        lock.unlock()
        guard !alreadyStopping else { return }

        var byte: UInt8 = 1
        // non-blockingなので固まらない。失敗しても停止フラグとpollの上限時間で止まる
        _ = Darwin.write(wakeWriteFD, &byte, 1)
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finished.notify(queue: .global()) { continuation.resume() }
        }
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    // MARK: 受付

    private func acceptLoop() {
        while !isStopping {
            switch wait(for: listenFD, events: POLLIN, deadline: nil) {
            case .ready:
                guard acceptOne() else { return }
            case .sliceElapsed:
                continue
            case .stopRequested, .timedOut, .failed:
                return
            }
        }
    }

    // 受付を続けてよければtrue。続けられないエラー（fdの枯渇など）ではfalseを返して受付を止める
    private func acceptOne() -> Bool {
        var peer = sockaddr_storage()
        var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let fd = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(listenFD, $0, &peerLength)
            }
        }
        guard fd >= 0 else {
            switch errno {
            case EINTR, EAGAIN, EWOULDBLOCK, ECONNABORTED:
                return true
            default:
                return false
            }
        }

        guard Self.isIPv4Loopback(peer, length: peerLength),
              Self.setCloseOnExec(fd), Self.setNonBlocking(fd), Self.setNoSigPipe(fd),
              reserveConnection()
        else {
            // loopback以外・上限超過・停止中は、何も読まずに閉じる
            Darwin.close(fd)
            return true
        }

        workers.enter()
        let thread = Thread { [self] in
            serve(fd)
            Darwin.close(fd)
            releaseConnection()
            workers.leave()
        }
        thread.name = "ChatGPTOAuthLoopbackListener.worker"
        thread.start()
        return true
    }

    private static func isIPv4Loopback(_ peer: sockaddr_storage, length: socklen_t) -> Bool {
        guard length >= socklen_t(MemoryLayout<sockaddr_in>.size), peer.ss_family == sa_family_t(AF_INET) else {
            return false
        }
        var copy = peer
        let address = withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        }
        // 127.0.0.0/8（先頭1バイトが127）
        return UInt32(bigEndian: address) >> 24 == 127
    }

    private func reserveConnection() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping, activeConnections < ChatGPTOAuthLoopbackListener.maxConnections else { return false }
        activeConnections += 1
        return true
    }

    private func releaseConnection() {
        lock.lock()
        defer { lock.unlock() }
        activeConnections -= 1
    }

    // MARK: 1接続の処理

    private func serve(_ fd: Int32) {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(ChatGPTOAuthLoopbackListener.connectionDeadlineSeconds) * 1_000_000_000

        guard let kind = readAndRespondKind(fd, deadline: deadline),
              let response = try? ChatGPTOAuthLoopbackResponseBuilder.response(for: kind)
        else { return }
        guard writeAll(fd, response, deadline: deadline) else { return }
        // 送信側だけ先に閉じ、相手にFINで終わりを伝える（closeは呼び出し側）
        _ = Darwin.shutdown(fd, SHUT_WR)
    }

    // request headを読んでparserに通し、返すresponseの種類を決める。
    // responseを書かずに閉じるべきとき（途中終了・制限時間・停止）はnilを返す
    private func readAndRespondKind(_ fd: Int32, deadline: UInt64) -> ChatGPTOAuthLoopbackResponseKind? {
        var head: [UInt8] = []
        head.reserveCapacity(Self.maxRequestHeadLength)
        var chunk = [UInt8](repeating: 0, count: Self.maxRequestHeadLength)

        while !Self.containsHeadTerminator(head) {
            // 上限まで読んでも終端が無ければ、これ以上読んでも合格できない
            guard head.count < Self.maxRequestHeadLength else { return .requestHeadTooLarge }
            guard !isStopping else { return nil }

            switch wait(for: fd, events: POLLIN, deadline: deadline) {
            case .ready:
                let limit = Self.maxRequestHeadLength - head.count
                let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, limit) }
                if count > 0 {
                    head.append(contentsOf: chunk[0..<count])
                } else if count == 0 {
                    // head終端の前に相手が閉じた
                    return nil
                } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                    return nil
                }
            case .sliceElapsed:
                continue
            case .stopRequested, .timedOut, .failed:
                return nil
            }
        }

        let callback: ChatGPTOAuthLoopbackCallbackRequest
        do {
            callback = try ChatGPTOAuthLoopbackHTTPRequestParser.parse(Data(head), boundPort: boundPort)
        } catch ChatGPTOAuthLoopbackHTTPError.unexpectedPath {
            return .notFound
        } catch ChatGPTOAuthLoopbackHTTPError.unsupportedMethod {
            return .methodNotAllowed
        } catch ChatGPTOAuthLoopbackHTTPError.requestTooLarge {
            return .requestHeadTooLarge
        } catch {
            return .callbackFailed
        }

        // 配送枠を確保する前に、stateの一意一致をvalidatorで明示的に確認する。
        // verifyStateが失敗した応答（state不一致・欠落・重複、state照合前の構文エラーなど）は、
        // 理由を問わず枠を消費しない。state一致後の検査（scope重複・code等）は後段のAttemptに委ねる
        guard let redirectURI = URL(string: "http://127.0.0.1:\(boundPort)/auth/callback"),
              (try? ChatGPTOAuthCallbackValidator.verifyState(
                  callback: callback.callback,
                  expecting: ChatGPTOAuthCallbackExpectation(redirectURI: redirectURI, state: expectedState)
              )) != nil
        else {
            return .callbackFailed
        }

        switch claimDelivery() {
        case .deliver:
            // 停止フラグを確かめてからここへ来る。直後にstopが始まっても、stopはこのworkerの終了を待つので、
            // sinkの呼び出しがstopの戻りより後になることはない
            callbackSink(callback)
            return .callbackReceived
        case .alreadyDelivered:
            return .callbackFailed
        case .stopping:
            return nil
        }
    }

    private enum DeliveryDecision {
        case deliver
        case alreadyDelivered
        case stopping
    }

    // sinkへ渡すのはlistener 1個につき最初の1回だけ。停止中は渡さない
    private func claimDelivery() -> DeliveryDecision {
        lock.lock()
        defer { lock.unlock() }
        if stopping { return .stopping }
        if delivered { return .alreadyDelivered }
        delivered = true
        return .deliver
    }

    private func writeAll(_ fd: Int32, _ data: Data, deadline: UInt64) -> Bool {
        let bytes = [UInt8](data)
        var sent = 0
        while sent < bytes.count {
            guard !isStopping else { return false }
            switch wait(for: fd, events: POLLOUT, deadline: deadline) {
            case .ready:
                let count = bytes.withUnsafeBufferPointer {
                    Darwin.write(fd, $0.baseAddress! + sent, $0.count - sent)
                }
                if count > 0 {
                    sent += count
                } else if count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                    return false
                }
            case .sliceElapsed:
                continue
            case .stopRequested, .timedOut, .failed:
                return false
            }
        }
        return true
    }

    private static func containsHeadTerminator(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        for index in 0...(bytes.count - 4)
        where bytes[index] == 0x0D && bytes[index + 1] == 0x0A && bytes[index + 2] == 0x0D && bytes[index + 3] == 0x0A {
            return true
        }
        return false
    }

    // MARK: poll

    private enum WaitResult {
        // 対象fdが読める・書ける（または相手が閉じた。続くread・writeで判別する）
        case ready
        // pollの1回分の上限時間が過ぎただけ。停止フラグと期限を確かめて待ち直す
        case sliceElapsed
        // stopの通知を受けた
        case stopRequested
        // 接続の期限を過ぎた
        case timedOut
        // pollが失敗した、またはfdが無効
        case failed
    }

    // 対象fdと停止通知pipeを同時に待つ。deadlineがnilなら期限なし（受付用。停止通知かslice経過で戻る）
    private func wait(for fd: Int32, events: Int32, deadline: UInt64?) -> WaitResult {
        var timeout = Self.pollSliceMilliseconds
        if let deadline {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .timedOut }
            // 切り上げてms単位にし、sliceの上限で抑える
            let remaining = (deadline - now + 999_999) / 1_000_000
            timeout = Int32(min(UInt64(timeout), remaining))
        }

        var targets = [
            pollfd(fd: fd, events: Int16(events), revents: 0),
            pollfd(fd: wakeReadFD, events: Int16(POLLIN), revents: 0),
        ]
        let result = Darwin.poll(&targets, 2, timeout)
        if result < 0 {
            return errno == EINTR ? .sliceElapsed : .failed
        }
        if targets[1].revents != 0 { return .stopRequested }
        if result == 0 { return .sliceElapsed }
        if targets[0].revents & Int16(POLLNVAL) != 0 { return .failed }
        // POLLHUP・POLLERRもreadyとして返し、read・writeの結果（0やエラー）で閉じる
        return .ready
    }

    // MARK: fd設定

    private static func setCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    private static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func setNoSigPipe(_ fd: Int32) -> Bool {
        var one: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
    }
}
