import Foundation
import Darwin

/// Native local clients only. Set MACBRIDGE_TOKEN on server/client for bearer auth.
/// Default trust is local processes running as your user, matching the old client contract.
final class MacBridgeServer: @unchecked Sendable {
    let port: UInt16
    private var listeningSocket: Int32 = -1
    private let socketLock = NSLock()
    private let uiLock = NSRecursiveLock()
    private let clients = DispatchSemaphore(value: 16)
    private let token = ProcessInfo.processInfo.environment["MACBRIDGE_TOKEN"]
    private let maxHeader = 16 * 1024
    private let maxBody = 2 * 1024 * 1024

    init(port: UInt16) { self.port = port }
    func start() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { fatalError("socket() failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 32) == 0 else { close(fd); fatalError("Cannot bind 127.0.0.1:\(port); is MacBridge already running?") }
        socketLock.lock(); listeningSocket = fd; socketLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop(fd) }
    }
    func stop() {
        socketLock.lock(); let fd = listeningSocket; listeningSocket = -1; socketLock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
    }
    private func isListening(_ fd: Int32) -> Bool {
        socketLock.lock(); defer { socketLock.unlock() }
        return listeningSocket == fd
    }
    private func acceptLoop(_ listener: Int32) {
        while isListening(listener) {
            let fd = accept(listener, nil, nil)
            if fd < 0 { if errno == EINTR { continue }; break }
            guard clients.wait(timeout: .now()) == .success else { close(fd); continue }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async {
                defer { close(fd); self.clients.signal() }
                self.handle(fd)
            }
        }
    }
    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }
    private struct HTTPError: Error { let status: Int; let message: String }
    private func parse(_ fd: Int32) throws -> Request {
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(15)
        func receive() throws {
            guard Date() < deadline else { throw HTTPError(status: 408, message: "Read deadline exceeded") }
            let n = Darwin.read(fd, &bytes, bytes.count)
            guard n > 0 else { throw HTTPError(status: 400, message: "Incomplete request or read timeout") }
            data.append(contentsOf: bytes.prefix(n))
        }
        let delimiter = Data("\r\n\r\n".utf8)
        while data.range(of: delimiter) == nil {
            guard data.count < maxHeader else { throw HTTPError(status: 431, message: "Headers too large") }
            try receive()
        }
        guard let range = data.range(of: delimiter), range.upperBound <= maxHeader,
              let header = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            throw HTTPError(status: 400, message: "Invalid headers")
        }
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = (lines.first ?? "").split(separator: " ")
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1", requestLine[1].hasPrefix("/") else {
            throw HTTPError(status: 400, message: "Expected HTTP/1.1 origin-form request")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw HTTPError(status: 400, message: "Malformed header") }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw HTTPError(status: 400, message: "Duplicate header") }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard hosts.contains((headers["host"] ?? "").lowercased()) else { throw HTTPError(status: 403, message: "Invalid Host") }
        guard headers["origin"] == nil, headers["sec-fetch-site"] == nil else {
            throw HTTPError(status: 403, message: "Browser-origin requests are disabled; use the local Python backend")
        }
        guard headers["transfer-encoding"] == nil else { throw HTTPError(status: 400, message: "Chunked requests are unsupported") }
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let length = Int(lengthText), length <= maxBody else { throw HTTPError(status: 413, message: "Invalid or excessive body size") }
        let start = range.upperBound
        while data.count - start < length { try receive() }
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
                       body: data.subdata(in: start..<(start + length)))
    }
    private func isUI(_ path: String) -> Bool {
        ["/mouse/", "/screen/", "/ui/", "/whatsapp/", "/keyboard/", "/clipboard/", "/safari/", "/applescript/", "/automation/", "/spotify/", "/windows/"].contains(where: path.hasPrefix)
            || path.hasPrefix("/shell/stage")
    }
    private func dispatch(_ path: String, _ args: [String: Any]) -> [String: Any] {
        if isUI(path) {
            uiLock.lock(); defer { uiLock.unlock() }
            if path == "/automation/sequence" { return sequence(args) }
            return Router.dispatch(path: path, args: args)
        }
        return Router.dispatch(path: path, args: args)
    }
    private func sequence(_ args: [String: Any]) -> [String: Any] {
        guard let steps = args["steps"] as? [[String: Any]], (1...20).contains(steps.count) else {
            return ["ok": false, "error": "steps must contain 1 to 20 {path,args} objects"]
        }
        // Validate structure before any action. Arguments remain owned by each module.
        for step in steps {
            guard let path = step["path"] as? String, path != "/automation/sequence", isUI(path),
                  step["args"] == nil || step["args"] is [String: Any] else {
                return ["ok": false, "error": "Sequences accept UI routes only and cannot nest"]
            }
        }
        var results: [[String: Any]] = []
        for (index, step) in steps.enumerated() {
            let result = Router.dispatch(path: step["path"] as! String, args: step["args"] as? [String: Any] ?? [:])
            results.append(result)
            if result["ok"] as? Bool != true {
                return ["ok": false, "failedStep": index, "completed": index, "results": results,
                        "error": "Sequence stopped; previous actions were not rolled back"]
            }
        }
        return ["ok": true, "completed": results.count, "results": results]
    }
    private func handle(_ fd: Int32) {
        do {
            let request = try parse(fd)
            if request.method == "GET", request.path == "/health" {
                send(fd, 200, ["ok": true, "status": "ok", "version": "2.0-powerpack", "authRequired": token?.isEmpty == false]); return
            }
            if let token, !token.isEmpty, request.headers["authorization"] != "Bearer \(token)" {
                throw HTTPError(status: 401, message: "Missing or incorrect bearer token")
            }
            guard request.method == "POST" else { throw HTTPError(status: 405, message: "Use POST") }
            let contentType = request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
            guard contentType == "application/json" else { throw HTTPError(status: 415, message: "Use application/json") }
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let args = json["args"] as? [String: Any] else { throw HTTPError(status: 400, message: "Expected JSON object with an args object") }
            send(fd, 200, dispatch(request.path, args))
        } catch let e as HTTPError { send(fd, e.status, ["ok": false, "error": e.message]) }
        catch { send(fd, 500, ["ok": false, "error": error.localizedDescription]) }
    }
    private func send(_ fd: Int32, _ status: Int, _ body: [String: Any]) {
        let data: Data, code: Int
        if JSONSerialization.isValidJSONObject(body), let encoded = try? JSONSerialization.data(withJSONObject: body) {
            data = encoded; code = status
        } else { data = Data("{\"ok\":false,\"error\":\"Response was not JSON-safe\"}".utf8); code = 500 }
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 405: "Method Not Allowed",
                       408: "Request Timeout", 413: "Content Too Large", 415: "Unsupported Media Type", 431: "Request Header Fields Too Large", 500: "Internal Server Error"]
        var packet = Data("HTTP/1.1 \(code) \(reasons[code] ?? "Error")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        packet.append(data)
        packet.withUnsafeBytes { raw in
            guard let pointer = raw.baseAddress else { return }
            var offset = 0
            while offset < packet.count {
                let n = Darwin.write(fd, pointer.advanced(by: offset), packet.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { break }
                offset += n
            }
        }
    }
}
