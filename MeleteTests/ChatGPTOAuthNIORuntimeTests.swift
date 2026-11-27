import Darwin
import XCTest
@testable import Melete

// SwiftNIO runtimeを実際の127.0.0.1 socketで確認する。値はすべて合成値で、OAuth接続は行わない。
final class ChatGPTOAuthNIORuntimeTests: XCTestCase {
    private typealias Listener = ChatGPTOAuthNIOLoopbackListener

    private let syntheticState = "SyntheticNIOLoopbackState-012345678901234567890123456789"
    private var listeners: [Listener] = []

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

        releaseSink.signal()
        _ = await clientTask.value
        await stopTask.value
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
