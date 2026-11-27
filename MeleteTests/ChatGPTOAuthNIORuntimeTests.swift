import Darwin
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest
@testable import Melete

// SwiftNIO runtimeを実際の127.0.0.1 socketで確認する。値はすべて合成値で、OAuth接続は行わない。
final class ChatGPTOAuthNIORuntimeTests: XCTestCase {
    private typealias Listener = ChatGPTOAuthNIOLoopbackListener

    private let syntheticState = "SyntheticNIOLoopbackState-012345678901234567890123456789"
    private var listeners: [Listener] = []

    #if DEBUG
    func testInputClosedWhileCallbackResponseWriteIsPendingKeepsChannelActive() throws {
        let sinkEntered = DispatchSemaphore(value: 0)
        let writeCapture = NIOEmbeddedPendingWriteCapture()
        let port = 43127
        let harness = Listener.makeEmbeddedCallbackHandler(
            expectedState: syntheticState,
            callbackSink: { _ in
                sinkEntered.signal()
            },
            boundPort: port
        )
        let channel = EmbeddedChannel(handlers: [writeCapture, harness.handler])
        defer {
            writeCapture.markClosing()
            try? channel.embeddedEventLoop.run()
            try? channel.close().wait()
            try? channel.embeddedEventLoop.run()
            try? harness.shutdown()
        }

        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: port)).wait()
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/auth/callback?code=synthetic-code&state=\(syntheticState)",
            headers: ["Host": "127.0.0.1:\(port)"]
        )
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(head)))
        XCTAssertEqual(sinkEntered.wait(timeout: .now() + 2), .success, "callback sinkへ到達しなかった")
        // sink完了イベントを処理し、response writeが未完了promiseで止まるところまで進める。
        let writeDeadline = ContinuousClock.now + .seconds(2)
        while writeCapture.promise == nil && ContinuousClock.now < writeDeadline {
            try channel.embeddedEventLoop.run()
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let pendingPromise = writeCapture.promise else {
            XCTFail("response write promiseを捕捉できなかった")
            return
        }
        let writeCompletion = NIOTestResultBox<Bool>()
        pendingPromise.futureResult.whenComplete { _ in writeCompletion.set(.success(true)) }
        try channel.embeddedEventLoop.run()
        XCTAssertNil(writeCompletion.result, "捕捉したresponse write promiseがすでに完了していた")

        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        try channel.embeddedEventLoop.run()

        XCTAssertNil(writeCompletion.result, "inputClosedの処理中にresponse write promiseが完了した")
        XCTAssertTrue(channel.isActive, "write promise未完了中のinputClosedでchannelが閉じた")
    }
    #endif

    override func tearDown() async throws {
        for listener in listeners {
            try await withTimeout("tearDown stop") { await listener.stop() }
        }
        listeners = []
        try await super.tearDown()
    }

    func testWrongStateDoesNotPreventValidCallbackAndStopClosesListener() async throws {
        let recorder = NIORuntimeCallbackRecorder()
        let listener = Listener(expectedState: syntheticState) { recorder.record($0) }
        listeners.append(listener)

        let port = try await withTimeout("start") { try await listener.start() }
        XCTAssertTrue((1...65535).contains(port), "bind済みportが範囲外")

        let failedRequest = request(path: "/auth/callback?code=synthetic-code-0001&state=wrong-state", port: port)
        let failedResponse = try ChatGPTOAuthLoopbackResponseBuilder.response(for: .callbackFailed)
        let failedOutcome = await NIOTestSocket.exchange(port: port, request: failedRequest)
        XCTAssertTrue(failedOutcome == failedResponse, "固定のcallbackFailed responseが返らなかった")
        XCTAssertTrue(recorder.callbacks.isEmpty, "state不一致のcallbackがsinkへ渡された")

        let validRequest = request(path: "/auth/callback?code=synthetic-code-0001&state=\(syntheticState)", port: port)
        let expectedCallback = try ChatGPTOAuthLoopbackHTTPRequestParser.parse(validRequest, boundPort: port).callback
        let receivedResponse = try ChatGPTOAuthLoopbackResponseBuilder.response(for: .callbackReceived)
        let receivedOutcome = await NIOTestSocket.exchange(port: port, request: validRequest)
        XCTAssertTrue(receivedOutcome == receivedResponse, "固定のcallbackReceived responseが返らなかった")
        XCTAssertTrue(recorder.callbacks == [expectedCallback], "sinkへ期待callbackがちょうど1件届いていない")

        try await withTimeout("stop") { await listener.stop() }
        let acceptsAfterStop = await NIOTestSocket.connectAndClose(port: port)
        XCTAssertFalse(acceptsAfterStop, "stop完了後も接続を受け付けた")
        XCTAssertTrue(recorder.callbacks == [expectedCallback], "stop後にsinkへ追加配送された")
    }

    #if DEBUG
    func testServerPipelineErrorNotifiesOnceAndStopsListener() async throws {
        let failures = NIORuntimeFailureRecorder()
        let listener = Listener(expectedState: syntheticState, callbackSink: { _ in }, failureHandler: { failure in
            failures.record(failure)
        })
        listeners.append(listener)
        let port = try await withTimeout("failure handler start") { try await listener.start() }

        listener.injectSyntheticServerErrorForTesting()
        listener.injectSyntheticServerErrorForTesting()
        let received = await NIOTestSocket.waitForSignal(failures.signal)
        XCTAssertTrue(received, "server pipeline errorのfailure通知が届かなかった")
        XCTAssertEqual(failures.failures.count, 1, "failure通知がちょうど1回ではなかった")
        try await withTimeout("failure handler stop") { await listener.stop() }
        let refused = await NIOTestSocket.connectionIsRefused(port: port)
        XCTAssertTrue(refused, "failure後にserver channelが閉じなかった")
    }

    func testServerErrorDuringBindFailsStartAndClosesBoundPort() async throws {
        let observedPort = NIOTestResultBox<Int>()
        let failures = NIORuntimeFailureRecorder()
        let listener = Listener(expectedState: syntheticState, callbackSink: { _ in }, failureHandler: { failure in
            failures.record(failure)
        })
        listener.setDebugHook(.init(injectSyntheticServerError: true) { port in
                observedPort.set(.success(port))
            })
        listeners.append(listener)

        do {
            _ = try await withTimeout("bind error start") { try await listener.start() }
            XCTFail("bind中に発生したserver pipeline errorでstartが失敗しなかった")
        } catch is NIOTestTimeout {
            throw NIOTestTimeout()
        } catch {
            XCTAssertEqual(error as? ChatGPTOAuthLoopbackListenerError, .setupFailed,
                           "bind中のserver pipeline errorがsetupFailedではなかった")
        }

        guard let portResult = observedPort.result,
              let port = try? portResult.get() else {
            XCTFail("検証用observerがbind済みportを受け取らなかった")
            return
        }
        let refused = await NIOTestSocket.connectionIsRefused(port: port)
        XCTAssertTrue(refused, "start失敗後にserver channelのportが接続拒否にならなかった")
        XCTAssertTrue(failures.failures.isEmpty, "bind中の失敗でfailureHandler通知が発生した")
    }
    #endif

    func testNormalStopDoesNotNotifyFailureHandler() async throws {
        let failures = NIORuntimeFailureRecorder()
        let listener = Listener(expectedState: syntheticState, callbackSink: { _ in }, failureHandler: { failure in
            failures.record(failure)
        })
        listeners.append(listener)
        _ = try await withTimeout("normal stop start") { try await listener.start() }
        try await withTimeout("normal stop") { await listener.stop() }
        XCTAssertTrue(failures.failures.isEmpty, "通常stopでfailure通知が発生した")
    }

    func testClientWriteHalfCloseStillReceivesCompleteCallbackResponse() async throws {
        let recorder = NIORuntimeCallbackRecorder()
        let listener = Listener(expectedState: syntheticState) { recorder.record($0) }
        listeners.append(listener)

        let port = try await withTimeout("half-close start") { try await listener.start() }
        let callbackRequest = request(path: "/auth/callback?code=synthetic-half-close-code&state=\(syntheticState)", port: port)
        let expectedResponse = try ChatGPTOAuthLoopbackResponseBuilder.response(for: .callbackReceived)
        let response = await NIOTestSocket.exchangeAfterWriteHalfClose(port: port, request: callbackRequest)
        XCTAssertEqual(response, expectedResponse, "送信方向をhalf-closeした後も完全なcallbackReceived responseが返らなかった")

        try await withTimeout("half-close stop") { await listener.stop() }
        let refusedAfterStop = await NIOTestSocket.connectionIsRefused(port: port)
        XCTAssertTrue(refusedAfterStop, "stop後の接続がECONNREFUSEDにならなかった")
        XCTAssertEqual(recorder.callbacks.count, 1, "callbackがちょうど1件sinkへ渡されていない")
    }

    func testStopReturnsWhileCallbackSinkIsBlocked() async throws {
        let sinkEntered = DispatchSemaphore(value: 0)
        let releaseSink = DispatchSemaphore(value: 0)
        let secretCode = "SyntheticBlockedSinkSecret-0001"
        let listener = Listener(expectedState: syntheticState) { _ in
            sinkEntered.signal()
            releaseSink.wait()
        }
        listeners.append(listener)
        defer { releaseSink.signal() }

        let port = try await withTimeout("blocked sink start") { try await listener.start() }
        let callbackRequest = request(path: "/auth/callback?code=\(secretCode)&state=\(syntheticState)", port: port)
        let clientTask = Task.detached {
            await NIOTestSocket.exchangeAfterWriteHalfClose(port: port, request: callbackRequest)
        }

        let entered = await NIOTestSocket.waitForSignal(sinkEntered)
        XCTAssertTrue(entered, "制限時間内にcallback sinkへ入らなかった")
        if !entered {
            releaseSink.signal()
            _ = await clientTask.value
            return
        }

        let stopResult = NIOTestResultBox<Bool>()
        let stopTask = Task.detached {
            await listener.stop()
            stopResult.set(.success(true))
        }
        let stopReturnedBeforeRelease = await NIOTestSocket.waitForResult(stopResult)
        XCTAssertTrue(stopReturnedBeforeRelease, "sink解放前にstopが戻らなかった")

        if !stopReturnedBeforeRelease {
            stopTask.cancel()
        }
        releaseSink.signal()
        _ = await clientTask.value
        let stopTaskRecovered = await NIOTestSocket.waitForResult(stopResult)
        if !stopTaskRecovered {
            // cancel後もstopが回収できない場合、Taskが保持するOSリソースの解放は保証できない。
            XCTFail("明示cancel後もstop taskが期限内に終了せず、回収できなかった")
        }
    }

    private func request(path: String, port: Int) -> Data {
        Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8)
    }

    private func withTimeout<T: Sendable>(_ label: String,
                                          seconds: Int = 10,
                                          operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let box = NIOTestResultBox<T>()
        let task = Task.detached {
            do { box.set(.success(try await operation())) }
            catch { box.set(.failure(error)) }
        }
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if let result = box.result {
                await task.value
                return try result.get()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        XCTFail("\(label)が制限時間内に完了しなかった")
        // operationによっては取消を無視するため、timeout後のTask回収は保証できない。
        throw NIOTestTimeout()
    }
}

private final class NIOEmbeddedPendingWriteCapture: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer

    private enum State {
        case awaiting
        case completing
        case completed
    }

    private(set) var promise: EventLoopPromise<Void>?
    private var state: State = .awaiting
    private var eventLoop: (any EventLoop)?
    private var closing = false
    private let cleanupError = NIOEmbeddedPendingWriteCleanupError()

    func handlerAdded(context: ChannelHandlerContext) {
        eventLoop = context.eventLoop
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        precondition(context.eventLoop.inEventLoop, "captureはembedded eventLoop上でのみ使用する")
        guard let promise else { context.write(data, promise: nil); return }
        if closing {
            promise.fail(cleanupError)
            return
        }
        guard self.promise == nil else {
            context.write(data, promise: promise)
            return
        }
        self.promise = promise
        state = .awaiting
        promise.futureResult.whenComplete { [weak self] _ in
            guard let self else { return }
            precondition(self.eventLoop?.inEventLoop == true, "promise状態はembedded eventLoop上でのみ変更する")
            self.state = .completed
        }
        // 意図的にforwardもpromise完了もしない。responseの送信完了待ち状態を保つ。
    }

    func markClosing() {
        guard let eventLoop else { preconditionFailure("handler追加前にcleanupされた") }
        precondition(eventLoop.inEventLoop, "captureはembedded eventLoop上でのみ使用する")
        closing = true
        guard state == .awaiting, let promise else { return }
        state = .completing
        promise.fail(cleanupError)
    }
}

private struct NIOEmbeddedPendingWriteCleanupError: Error {}

private struct NIOTestTimeout: Error {}

private final class NIOTestResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, any Error>?

    func set(_ result: Result<Value, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        stored = result
    }

    var result: Result<Value, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class NIORuntimeCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ callback: ChatGPTOAuthLoopbackCallbackRequest) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(callback.callback)
    }

    var callbacks: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class NIORuntimeFailureRecorder: @unchecked Sendable {
    let signal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: [ChatGPTOAuthNIOLoopbackListener.ChatGPTOAuthNIORuntimeFailure] = []

    func record(_ failure: ChatGPTOAuthNIOLoopbackListener.ChatGPTOAuthNIORuntimeFailure) {
        lock.lock()
        stored.append(failure)
        lock.unlock()
        signal.signal()
    }

    var failures: [ChatGPTOAuthNIOLoopbackListener.ChatGPTOAuthNIORuntimeFailure] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

// 全socket操作は別スレッドで実行し、I/Oに期限を設ける。接続先は127.0.0.1のみ。
private enum NIOTestSocket {
    private static let ioTimeout = timeval(tv_sec: 2, tv_usec: 0)

    static func exchange(port: Int, request: Data) async -> Data? {
        await offThread {
            guard let fd = openConnection(port: port) else { return nil }
            defer { Darwin.close(fd) }

            let bytes = [UInt8](request)
            var sent = 0
            while sent < bytes.count {
                let count = bytes.withUnsafeBufferPointer {
                    Darwin.send(fd, $0.baseAddress!.advanced(by: sent), $0.count - sent, 0)
                }
                if count > 0 { sent += count }
                else if count < 0 && errno == EINTR { continue }
                else { return nil }
            }

            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            let deadline = ContinuousClock.now + .seconds(6)
            while ContinuousClock.now < deadline {
                let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
                if count > 0 {
                    response.append(contentsOf: buffer[0..<count])
                    if response.count > 4096 { return nil }
                } else if count == 0 { return response }
                else if errno == EINTR { continue }
                else { return nil }
            }
            return nil
        }
    }

    // 既存exchangeの送受信意味を変えず、送信完了後にSHUT_WRする専用経路。
    static func exchangeAfterWriteHalfClose(port: Int, request: Data) async -> Data? {
        await offThread {
            guard let fd = openConnection(port: port) else { return nil }
            defer { Darwin.close(fd) }

            let bytes = [UInt8](request)
            var sent = 0
            while sent < bytes.count {
                let count = bytes.withUnsafeBufferPointer {
                    Darwin.send(fd, $0.baseAddress!.advanced(by: sent), $0.count - sent, 0)
                }
                if count > 0 { sent += count }
                else if count < 0 && errno == EINTR { continue }
                else { return nil }
            }
            guard Darwin.shutdown(fd, SHUT_WR) == 0 else { return nil }

            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            let deadline = ContinuousClock.now + .seconds(6)
            while ContinuousClock.now < deadline {
                let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
                if count > 0 {
                    response.append(contentsOf: buffer[0..<count])
                    if response.count > 4096 { return nil }
                } else if count == 0 { return response }
                else if errno == EINTR { continue }
                else { return nil }
            }
            return nil
        }
    }

    static func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
        await offThread { semaphore.wait(timeout: .now() + 6) == .success }
    }

    static func waitForResult(_ result: NIOTestResultBox<Bool>) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
            if let outcome = result.result { return (try? outcome.get()) ?? false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    static func connectAndClose(port: Int) async -> Bool {
        await offThread {
            guard let fd = openConnection(port: port) else { return false }
            Darwin.close(fd)
            return true
        }
    }

    static func connectionIsRefused(port: Int) async -> Bool {
        await offThread {
            guard let port = UInt16(exactly: port), port != 0 else { return false }
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { return false }
            defer { Darwin.close(fd) }
            var timeout = ioTimeout
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port.bigEndian)
            _ = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            return result != 0 && errno == ECONNREFUSED
        }
    }

    private static func offThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }

    private static func openConnection(port: Int) -> Int32? {
        guard let port = UInt16(exactly: port), port != 0 else { return nil }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        var closeOnFailure = true
        defer { if closeOnFailure { Darwin.close(fd) } }

        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = ioTimeout
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port.bigEndian)
        _ = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let originalFlags = fcntl(fd, F_GETFL)
        guard originalFlags >= 0, fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { return nil }
            var target = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&target, 1, 1000) == 1 else { return nil }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else { return nil }
        }
        guard fcntl(fd, F_SETFL, originalFlags) == 0 else { return nil }
        closeOnFailure = false
        return fd
    }
}
