import Darwin
import Foundation

/// Google Desktop OAuth clients redirect to 127.0.0.1. The listener accepts that host only.
final class LoopbackServer: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false

    func bind() throws -> UInt16 {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw OAuthError.server }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(socketFD)
            throw OAuthError.server
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketFD, 4) == 0 else {
            Darwin.close(socketFD)
            throw OAuthError.server
        }
        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(socketFD)
            throw OAuthError.server
        }
        lock.lock()
        fd = socketFD
        stopped = false
        lock.unlock()
        return UInt16(bigEndian: resolved.sin_port)
    }

    func stop() {
        lock.lock()
        stopped = true
        let current = fd
        fd = -1
        lock.unlock()
        if current >= 0 {
            Darwin.close(current)
        }
    }

    func waitForCode(expectedState: String) throws -> String {
        let deadline = Date().addingTimeInterval(5 * 60)
        while Date() < deadline {
            let snap = snapshot()
            if snap.stopped { throw CancellationError() }
            guard let listenFD = snap.fd else { throw CancellationError() }
            var pollFD = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            let result = poll(&pollFD, 1, 200)
            if result == 0 { continue }
            if result < 0 {
                if errno == EINTR { continue }
                if snapshot().stopped { throw CancellationError() }
                throw OAuthError.server
            }
            var clientAddress = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &length)
                }
            }
            if client < 0 { continue }
            var loopback = in_addr()
            inet_pton(AF_INET, "127.0.0.1", &loopback)
            guard clientAddress.sin_addr.s_addr == loopback.s_addr else {
                Darwin.close(client)
                continue
            }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            do {
                let code = try readCode(client: client, expectedState: expectedState)
                Darwin.close(client)
                return code
            } catch {
                Darwin.close(client)
                throw error
            }
        }
        throw OAuthError.timeout
    }

    private func snapshot() -> (fd: Int32?, stopped: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (fd >= 0 ? fd : nil, stopped)
    }

    private func readCode(client: Int32, expectedState: String) throws -> String {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let marker = Data([13, 10, 13, 10])
        while buffer.count < 16_384, buffer.range(of: marker) == nil {
            let count = recv(client, &chunk, chunk.count, 0)
            if count <= 0 { break }
            buffer.append(chunk, count: count)
        }
        let text = String(decoding: buffer, as: UTF8.self)
        let requestLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else {
            respond(client, status: 400, body: "TubeUI didn't recognize that redirect.")
            throw OAuthError.missingCode
        }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        if items["error"] != nil {
            respond(client, status: 200, body: "TubeUI did not get permission. You can close this window.")
            throw OAuthError.denied
        }
        guard items["state"] == expectedState else {
            respond(client, status: 400, body: "TubeUI couldn't match this sign-in. You can close this window.")
            throw OAuthError.stateMismatch
        }
        guard let code = items["code"], !code.isEmpty else {
            respond(client, status: 400, body: "Google didn't include a sign-in code.")
            throw OAuthError.missingCode
        }
        respond(client, status: 200, body: "Signed in. You can close this window and return to TubeUI.")
        return code
    }

    private func respond(_ socket: Int32, status: Int, body: String) {
        let html = """
        <!doctype html><meta charset="utf-8"><title>TubeUI</title>
        <body style="margin:0;min-height:100vh;display:grid;place-items:center;font:16px -apple-system,BlinkMacSystemFont,sans-serif;background:#f5f5f7;color:#1d1d1f"><p>\(body)</p>
        """
        let payload = Data(html.utf8)
        let reason = status == 200 ? "OK" : "Bad Request"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        var bytes = Array(header.utf8)
        bytes.append(contentsOf: payload)
        bytes.withUnsafeBytes { raw in
            _ = send(socket, raw.baseAddress, raw.count, 0)
        }
    }
}
