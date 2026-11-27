import Darwin
import XCTest
@testable import Melete

// ChatGPT OAuth loopback listenerの最小契約だけを検証する。
// 通信は同一プロセス内のloopback（と、自機interfaceアドレスへのconnect試行）だけで、外部ネットワークには出ない。
// 送るcodeとstateは合成値で、state消費・OAuth試行の検証・ブラウザ・token・UI・保存には触れない。
//
// テストが漏れて残らないよう、次を守る:
// - listenerのstart・stopは別Taskで動かし、制限時間を超えたら取消して回収を待つ（回収できなければ明示的に失敗）
// - テスト側socketのconnect・send・recvはすべて制限時間付き。blocking I/Oは別スレッドで行い、必ずcloseする
// - 作ったlistenerはtearDownで必ずstopし、その完了も制限時間付きで待つ
final class ChatGPTOAuthLoopbackListenerTests: XCTestCase {
    private typealias Listener = ChatGPTOAuthLoopbackListener

    // 合成のcode・state。実際のOAuthで使われる値ではない
    private let syntheticState = "SyntheticLoopbackState-012345678901234567890123456789"
    private var syntheticQuery: String { "code=synthetic-code-0001&state=\(syntheticState)" }

    // tearDownで止めるために、このテストで作ったlistenerを覚えておく
    private var createdListeners: [Listener] = []

    override func tearDown() async throws {
        for listener in createdListeners {
            _ = await runWithin("tearDownでのstop") { await listener.stop() }
        }
        createdListeners = []
        try await super.tearDown()
    }

    // MARK: - positive

    // 合成callbackを1回送ると、sinkにparserと同じ結果が1回だけ届き、固定の200 responseが返る。
    // stop完了後はlisten socketが閉じていて、新しい接続を受け付けない
    func testCallbackIsDeliveredOnceAndAnsweredWithFixedResponse() async throws {
        let recorder = CallbackRecorder()
        let listener = makeListener(recorder)

        let port = try await start(listener)
        XCTAssertTrue((1...65535).contains(port), "start()がbind済みportを返していない")

        let request = callbackRequest(path: "/auth/callback?\(syntheticQuery)", port: port)
        // listenerはsinkへ渡す前に既存parserを通す契約なので、同じバイト列をparserに通した結果と一致するはず
        let expectedCallback = try ChatGPTOAuthLoopbackHTTPRequestParser.parse(request, boundPort: port).callback

        let outcome = await exchange(port: port, request: request)
        let expectedResponse = try ChatGPTOAuthLoopbackResponseBuilder.response(for: .callbackReceived)
        XCTAssertEqual(outcome, .closed(expectedResponse), "固定のcallbackReceived responseを返してから接続を閉じていない")

        // sinkはresponseの書き込みより前に呼ばれる契約なので、responseを受け取った時点で届いている
        XCTAssertEqual(recorder.callbacks, [expectedCallback])

        try await stop(listener)
        await assertNotAccepting(port: port)
        XCTAssertEqual(recorder.callbacks, [expectedCallback], "stop後にsinkが追加で呼ばれた")
    }

    func testInvalidStateDoesNotConsumeDeliveryBeforeValidState() async throws {
        let recorder = CallbackRecorder()
        let listener = makeListener(recorder)
        let port = try await start(listener)

        let invalid = await exchange(port: port, request: callbackRequest(path: "/auth/callback?code=synthetic-code-0001&state=wrong-state", port: port))
        let failed = try ChatGPTOAuthLoopbackResponseBuilder.response(for: .callbackFailed)
        XCTAssertEqual(invalid, .closed(failed))
        XCTAssertTrue(recorder.callbacks.isEmpty)

        let valid = await exchange(port: port, request: callbackRequest(path: "/auth/callback?\(syntheticQuery)", port: port))
        let received = try ChatGPTOAuthLoopbackResponseBuilder.response(for: .callbackReceived)
        XCTAssertEqual(valid, .closed(received))
        XCTAssertEqual(recorder.callbacks.count, 1)
    }

    // stateの一意一致を確認できないrequestは、scope重複・構文エラーと組み合わさっていても配送枠を消費しない
    func testUnconfirmedStateDoesNotConsumeDeliveryEvenWithSyntaxErrors() async throws {
        let recorder = CallbackRecorder()
        let listener = makeListener(recorder)
        let port = try await start(listener)

        let otherState = "OtherSyntheticLoopbackState-0123456789012345678901"
        let code = "code=synthetic-code-0001"
        let duplicatedScope = "&scope=openid&scope=profile"
        let queries = [
            code,                                                                    // state欠落
            "\(code)&state=\(syntheticState)&state=\(syntheticState)",               // state重複（同じ値）
            "\(code)&state=\(syntheticState)&state=\(otherState)",                   // state重複（異なる値）
            "\(code)&state=\(syntheticState)&%73tate=\(otherState)",                 // encodeされたkeyによるstate重複
            "\(code)&state=",                                                        // 空のstate
            "\(code)&state=\(otherState)\(duplicatedScope)",                         // state不一致 + scope重複
            "\(code)\(duplicatedScope)",                                             // state欠落 + scope重複
            "\(code)&state=\(syntheticState)&state=\(syntheticState)\(duplicatedScope)", // state重複 + scope重複
            "\(code)&state=\(syntheticState)&&x_synthetic=1",                        // 正しいstate + 空セグメント
            "\(code)&state=\(syntheticState)&x_synthetic=%FF",                       // 正しいstate + 不正なUTF-8
        ]
        let failed = try ChatGPTOAuthLoopbackResponseBuilder.response(for: .callbackFailed)
        for (index, query) in queries.enumerated() {
            let outcome = await exchange(port: port, request: callbackRequest(path: "/auth/callback?\(query)", port: port))
            // queryの中身はメッセージに出さず、番号だけで識別する
            XCTAssertEqual(outcome, .closed(failed), "case \(index)")
        }
        XCTAssertTrue(recorder.callbacks.isEmpty, "state未確認のrequestがsinkへ渡された")

        // 後続の正当なcallbackは配送される
        let validRequest = callbackRequest(path: "/auth/callback?\(syntheticQuery)", port: port)
        let expectedCallback = try ChatGPTOAuthLoopbackHTTPRequestParser.parse(validRequest, boundPort: port).callback
        let valid = await exchange(port: port, request: validRequest)
        let received = try ChatGPTOAuthLoopbackResponseBuilder.response(for: .callbackReceived)
        XCTAssertEqual(valid, .closed(received))
        XCTAssertEqual(recorder.callbacks, [expectedCallback])
    }

    // 正しいstateを持つrequestは、scope重複があっても配送枠を消費して試行側へ渡す（拒否はAttemptが行う）。
    // その後のrequestは正当でも配送しない
    func testMatchingStateWithDuplicatedScopeConsumesDelivery() async throws {
        let recorder = CallbackRecorder()
        let listener = makeListener(recorder)
        let port = try await start(listener)

        let maliciousRequest = callbackRequest(path: "/auth/callback?\(syntheticQuery)&scope=openid&scope=profile", port: port)
        let expectedCallback = try ChatGPTOAuthLoopbackHTTPRequestParser.parse(maliciousRequest, boundPort: port).callback
        let first = await exchange(port: port, request: maliciousRequest)
        let received = try ChatGPTOAuthLoopbackResponseBuilder.response(for: .callbackReceived)
        XCTAssertEqual(first, .closed(received))
        XCTAssertEqual(recorder.callbacks, [expectedCallback])

        let second = await exchange(port: port, request: callbackRequest(path: "/auth/callback?\(syntheticQuery)", port: port))
        let failed = try ChatGPTOAuthLoopbackResponseBuilder.response(for: .callbackFailed)
        XCTAssertEqual(second, .closed(failed))
        XCTAssertEqual(recorder.callbacks.count, 1, "配送枠が2回使われた")
    }

    func testConcurrentValidCallbacksAreDeliveredAtMostOnce() async throws {
        let recorder = CallbackRecorder()
        let listener = makeListener(recorder)
        let port = try await start(listener)
        let request = callbackRequest(path: "/auth/callback?\(syntheticQuery)", port: port)

        async let first = exchange(port: port, request: request)
        async let second = exchange(port: port, request: request)
        let outcomes = await [first, second]
        let received = try ChatGPTOAuthLoopbackResponseBuilder.response(for: .callbackReceived)
        XCTAssertEqual(outcomes.filter { $0 == .closed(received) }.count, 1)
        XCTAssertEqual(recorder.callbacks.count, 1)
    }

    // MARK: - negative

    // callback path以外（/favicon.ico）はsinkへ渡さず、固定の404を返す
    func testFaviconRequestIsAnsweredWithNotFoundWithoutCallingSink() async throws {
        let recorder = CallbackRecorder()
        let listener = makeListener(recorder)
        let port = try await start(listener)

        let outcome = await exchange(port: port, request: callbackRequest(path: "/favicon.ico", port: port))
        let expectedResponse = try ChatGPTOAuthLoopbackResponseBuilder.response(for: .notFound)
        XCTAssertEqual(outcome, .closed(expectedResponse), "固定のnotFound responseを返してから接続を閉じていない")
        XCTAssertTrue(recorder.callbacks.isEmpty, "/favicon.icoでsinkが呼ばれた")

        try await stop(listener)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(recorder.callbacks.isEmpty, "stop後にsinkが呼ばれた")
    }

    // IPv6 loopback（::1）では接続を受け付けず、IPv4 loopback（127.0.0.1）では受け付ける。
    // 接続先はloopbackの2アドレスだけで、自機の他のinterfaceアドレスは列挙も接続もしない。connect後は何も送らない
    func testListenerIsNotReachableOutsideIPv4Loopback() async throws {
        let recorder = CallbackRecorder()
        let listener = makeListener(recorder)
        let port = try await start(listener)

        // :: （IPv6の全interface）でbindしていれば、ここで接続できてしまう
        await assertNotConnectable(.ipv6Loopback, port: port, label: "::1")

        // 127.0.0.1では受け付けていること（上の失敗がlistener停止によるものではないこと）を確認する
        let loopbackOutcome = await connectAndClose(.ipv4Loopback, port: port)
        XCTAssertTrue(loopbackOutcome, "127.0.0.1で接続を受け付けていない")

        try await stop(listener)
        XCTAssertTrue(recorder.callbacks.isEmpty, "requestを送っていないのにsinkが呼ばれた")
    }

    // request headの途中でstopすると、stopは処理中のI/Oを取消して戻り、
    // その後に残りを送ってもsinkは呼ばれず、responseも返らずに接続が閉じられる
    func testCallbackCompletedAfterStopIsNotDelivered() async throws {
        let recorder = CallbackRecorder()
        let listener = makeListener(recorder)
        let port = try await start(listener)

        let request = callbackRequest(path: "/auth/callback?\(syntheticQuery)", port: port)
        // request lineの直後（最初のCRLFまで）で分け、head終端（CRLF CRLF）を送らずに止める
        let firstLineEnd = try XCTUnwrap(request.range(of: Data("\r\n".utf8))).upperBound
        let firstPart = request[request.startIndex..<firstLineEnd]
        let restPart = request[firstLineEnd..<request.endIndex]

        guard case .connected(let fd) = await connect(.ipv4Loopback, port: port) else {
            XCTFail("127.0.0.1へ接続できない")
            return
        }
        defer { Darwin.close(fd) }

        let sentFirst = await offThread { TestSocket.sendAll(fd, Data(firstPart)) }
        XCTAssertTrue(sentFirst, "request headの前半を送れない")
        // listenerのworkerがreadを始めるまでの猶予。間に合わなくても、stopで閉じられる点は同じ
        try await Task.sleep(for: .milliseconds(100))

        // stopが処理中のreadを取消してworkerを待てないと、ここで制限時間を超える
        try await stop(listener)

        // stop後に残りを送る。listenerが閉じていれば送信に失敗し得るので、結果は問わない
        _ = await offThread { TestSocket.sendAll(fd, Data(restPart)) }
        let outcome = await offThread { TestSocket.readUntilClose(fd) }
        switch outcome {
        case .closed(let data), .reset(let data):
            XCTAssertTrue(data.isEmpty, "stop後の接続にresponseが書き込まれた")
        case .timedOut:
            XCTFail("stop後も接続が閉じられていない")
        case .tooLarge, .failed:
            XCTFail("stop後の接続から想定外の結果を受け取った")
        }

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(recorder.callbacks.isEmpty, "stop後に届いたcallbackがsinkへ渡された")
        await assertNotAccepting(port: port)
    }

    // MARK: - listener操作（制限時間付き）

    private func makeListener(_ recorder: CallbackRecorder) -> Listener {
        let listener = Listener(expectedState: syntheticState, callbackSink: { recorder.record($0) })
        createdListeners.append(listener)
        return listener
    }

    private struct TimedOut: Error {}

    private func start(_ listener: Listener) async throws -> Int {
        guard let result = await runWithin("start()", { try await listener.start() }) else {
            throw TimedOut()
        }
        return try result.get()
    }

    private func stop(_ listener: Listener) async throws {
        guard await runWithin("stop()", { await listener.stop() }) != nil else {
            throw TimedOut()
        }
    }

    // operationを別Taskで動かし、制限時間付きで終了を待つ。
    // 制限を超えたらTaskを取消し、さらに制限時間付きで回収を待つ。回収できなければ明示的に失敗させる
    private func runWithin<Value>(_ label: String,
                                  seconds: TimeInterval = 5,
                                  reclaimSeconds: TimeInterval = 5,
                                  _ operation: @escaping @Sendable () async throws -> Value) async -> Result<Value, any Error>? {
        let box = ResultBox<Value>()
        let task = Task.detached {
            do {
                box.set(.success(try await operation()))
            } catch {
                box.set(.failure(error))
            }
        }
        if await waitWithin(seconds: seconds, { box.value != nil }) {
            return box.value
        }
        task.cancel()
        if await waitWithin(seconds: reclaimSeconds, { box.value != nil }) {
            XCTFail("\(label)が制限時間内に終わらなかった（取消後に回収済み）")
        } else {
            XCTFail("\(label)が制限時間内に終わらず、取消後も回収できなかった")
        }
        return nil
    }

    private func waitWithin(seconds: TimeInterval, _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - テスト側socket（制限時間付き）

    // Hostはbind済みportに合わせた、parserが受理する最小のrequest head
    private func callbackRequest(path: String, port: Int) -> Data {
        Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8)
    }

    // blocking I/Oをテストの実行スレッドから外す。各I/Oはsocketの制限時間で必ず戻る
    private func offThread<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }

    private func connect(_ address: TestAddress, port: Int) async -> TestSocket.ConnectOutcome {
        await offThread { TestSocket.connect(to: address, port: port) }
    }

    // 1回だけ接続してrequestを送り、相手が閉じるまで読む
    private func exchange(port: Int, request: Data) async -> TestSocket.ReadOutcome {
        await offThread {
            guard case .connected(let fd) = TestSocket.connect(to: .ipv4Loopback, port: port) else {
                return .failed(errno: ECONNREFUSED)
            }
            defer { Darwin.close(fd) }
            guard TestSocket.sendAll(fd, request) else {
                return .failed(errno: EPIPE)
            }
            return TestSocket.readUntilClose(fd)
        }
    }

    // 接続できたらtrue。何も送らずにすぐ閉じる
    private func connectAndClose(_ address: TestAddress, port: Int) async -> Bool {
        guard case .connected(let fd) = await connect(address, port: port) else { return false }
        Darwin.close(fd)
        return true
    }

    private func assertNotConnectable(_ address: TestAddress, port: Int, label: String,
                                      file: StaticString = #filePath, line: UInt = #line) async {
        let connected = await connectAndClose(address, port: port)
        XCTAssertFalse(connected, "\(label)で接続を受け付けた", file: file, line: line)
    }

    // stop完了後、listen socketが閉じていて127.0.0.1でも接続できないこと
    private func assertNotAccepting(port: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let connected = await connectAndClose(.ipv4Loopback, port: port)
        XCTAssertFalse(connected, "stop完了後もlisten socketが閉じていない", file: file, line: line)
    }
}

// MARK: - helper型

// sinkに届いたcallbackを記録する。listenerのworkerから呼ばれるため、lockで守る
private final class CallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ request: ChatGPTOAuthLoopbackCallbackRequest) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(request.callback)
    }

    var callbacks: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

// 別Taskの結果を受け渡す入れ物。待つ側と書く側が別スレッドになるため、lockで守る
private final class ResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, any Error>?

    func set(_ result: Result<Value, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        stored = result
    }

    var value: Result<Value, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private enum TestAddress {
    case ipv4(in_addr)
    case ipv6(in6_addr)

    static var ipv4Loopback: TestAddress {
        var address = in_addr()
        _ = inet_pton(AF_INET, "127.0.0.1", &address)
        return .ipv4(address)
    }

    static var ipv6Loopback: TestAddress {
        var address = in6_addr()
        _ = inet_pton(AF_INET6, "::1", &address)
        return .ipv6(address)
    }
}

// テスト側のPOSIX socket操作。すべての呼び出しに制限時間があり、無期限には待たない
private enum TestSocket {
    static let connectTimeoutMilliseconds: Int32 = 1000
    static let ioTimeoutSeconds = 2
    // 読み取り全体の制限時間。相手が少しずつ送り続けても、ここで打ち切る
    static let readDeadlineSeconds = 5
    static let maxResponseBytes = 4096

    enum ConnectOutcome {
        case connected(Int32)
        case notConnected(errno: Int32)
    }

    enum ReadOutcome: Equatable {
        // 相手が正常に閉じた（FIN）
        case closed(Data)
        // 相手がRSTで閉じた
        case reset(Data)
        // 制限時間内に閉じられなかった
        case timedOut(Data)
        // maxResponseBytesを超えた
        case tooLarge
        case failed(errno: Int32)
    }

    // non-blockingでconnectし、pollで制限時間付きに待つ。接続後はblockingに戻し、send・recvの制限時間を設定する
    static func connect(to address: TestAddress, port: Int) -> ConnectOutcome {
        guard let port16 = UInt16(exactly: port), port16 != 0 else {
            return .notConnected(errno: EINVAL)
        }
        let family: Int32
        switch address {
        case .ipv4: family = AF_INET
        case .ipv6: family = AF_INET6
        }
        let fd = Darwin.socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return .notConnected(errno: errno) }

        // 相手が閉じた後のsendでSIGPIPEによりテストプロセスが落ちないようにする
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: ioTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let result: Int32
        switch address {
        case .ipv4(let inAddress):
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            // portはネットワークバイトオーダー（big endian）で渡す
            socketAddress.sin_port = in_port_t(port16.bigEndian)
            socketAddress.sin_addr = inAddress
            result = withUnsafePointer(to: &socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        case .ipv6(let in6Address):
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            socketAddress.sin6_port = in_port_t(port16.bigEndian)
            socketAddress.sin6_addr = in6Address
            result = withUnsafePointer(to: &socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }

        if result != 0 {
            let connectErrno = errno
            guard connectErrno == EINPROGRESS else {
                Darwin.close(fd)
                return .notConnected(errno: connectErrno)
            }
            var pollTarget = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollTarget, 1, connectTimeoutMilliseconds) == 1 else {
                Darwin.close(fd)
                return .notConnected(errno: ETIMEDOUT)
            }
            // 書き込み可能になっても接続失敗のことがあるので、SO_ERRORで結果を確かめる
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
            guard socketError == 0 else {
                Darwin.close(fd)
                return .notConnected(errno: socketError)
            }
        }

        _ = fcntl(fd, F_SETFL, flags)
        return .connected(fd)
    }

    // 全バイトを送れたらtrue。各sendはSO_SNDTIMEOで制限される
    static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBufferPointer { buffer in
                Darwin.send(fd, buffer.baseAddress! + sent, buffer.count - sent, 0)
            }
            if count > 0 {
                sent += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    // 相手が閉じるまで読む。各recvはSO_RCVTIMEOで、全体はreadDeadlineSecondsで制限される
    static func readUntilClose(_ fd: Int32) -> ReadOutcome {
        let deadline = ContinuousClock.now + .seconds(readDeadlineSeconds)
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while ContinuousClock.now < deadline {
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
                if collected.count > maxResponseBytes { return .tooLarge }
            } else if count == 0 {
                return .closed(collected)
            } else {
                let readErrno = errno
                switch readErrno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    return .timedOut(collected)
                case ECONNRESET:
                    return .reset(collected)
                default:
                    return .failed(errno: readErrno)
                }
            }
        }
        return .timedOut(collected)
    }
}
