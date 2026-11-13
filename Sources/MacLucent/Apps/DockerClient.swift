import Foundation
import CryptoKit

/// A small Docker Engine API client over the daemon's Unix socket — the API the docker CLI
/// uses. URLSession can't reach a socket file, so this speaks HTTP/1.1 itself (including the
/// chunked encoding used by streams). Works with Docker Desktop, Colima, OrbStack and Podman.
final class DockerClient: @unchecked Sendable {
    let socketPath: String

    init(socketPath: String) { self.socketPath = socketPath }

    // MARK: Finding the daemon

    /// The socket the docker CLI would use: DOCKER_HOST, then the current docker context, then
    /// the usual places. Nil if none exists.
    static func discover() -> DockerClient? {
        candidates().first { isSocket($0) }.map(DockerClient.init)
    }

    static func candidates() -> [String] {
        let home = NSHomeDirectory()
        var list: [String] = []
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            list.append(String(host.dropFirst(7)))
        }
        if let ctx = contextSocket() { list.append(ctx) }
        list += [
            home + "/.docker/run/docker.sock",          // Docker Desktop (user install)
            "/var/run/docker.sock",
            home + "/.orbstack/run/docker.sock",
            home + "/.colima/default/docker.sock",
            home + "/.colima/docker.sock",
            home + "/.local/share/containers/podman/machine/podman.sock",
            home + "/.rd/docker.sock",                   // Rancher Desktop
        ]
        return list
    }

    /// ~/.docker/config.json's currentContext → contexts/meta/<sha256(name)>/meta.json.
    private static func contextSocket() -> String? {
        let dir = NSHomeDirectory() + "/.docker"
        guard let data = FileManager.default.contents(atPath: dir + "/config.json"),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = config["currentContext"] as? String, name != "default" else { return nil }
        let hash = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let meta = FileManager.default.contents(atPath: "\(dir)/contexts/meta/\(hash)/meta.json"),
              let obj = try? JSONSerialization.jsonObject(with: meta) as? [String: Any],
              let endpoints = obj["Endpoints"] as? [String: Any],
              let docker = endpoints["docker"] as? [String: Any],
              let host = docker["Host"] as? String, host.hasPrefix("unix://") else { return nil }
        return String(host.dropFirst(7))
    }

    private static func isSocket(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
    }

    /// The docker CLI, for commands run in terminal tiles (exec, logs, run).
    static var cliPath: String {
        let home = NSHomeDirectory()
        for p in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", home + "/.docker/bin/docker",
                  home + "/.orbstack/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
            where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return "docker"
    }

    // MARK: Requests

    struct Response {
        let status: Int
        let body: Data
        var ok: Bool { (200..<300).contains(status) }
        /// Docker's error message ({"message": …}) or the status.
        var errorMessage: String {
            if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let m = obj["message"] as? String { return m }
            return "Docker returned HTTP \(status)"
        }
    }

    func request(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 30) async throws -> Response {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(with: Result { try self.perform(method, path, body: body, timeout: timeout, onChunk: nil) })
            }
        }
    }

    /// Request that must succeed; returns the body.
    func call(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 30) async throws -> Data {
        let r = try await request(method, path, body: body, timeout: timeout)
        guard r.ok else { throw VMError.message(r.errorMessage) }
        return r.body
    }

    func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await call("GET", path))
    }

    /// A streaming request (events, pull progress): `onLine` gets each JSON line on a
    /// background thread. Cancel with `DockerStream.cancel()`.
    func stream(_ method: String, _ path: String, onLine: @escaping @Sendable (Data) -> Void,
                onEnd: @escaping @Sendable (Response?, Error?) -> Void) -> DockerStream {
        let s = DockerStream()
        DispatchQueue.global(qos: .utility).async {
            var pending = Data()
            do {
                let r = try self.perform(method, path, body: nil, timeout: nil, stream: s) { chunk in
                    pending.append(chunk)
                    while let nl = pending.firstIndex(of: 0x0A) {
                        let line = pending[pending.startIndex..<nl]
                        if !line.isEmpty { onLine(Data(line)) }
                        pending = Data(pending[(nl + 1)...])
                    }
                    return !s.isCancelled
                }
                if !pending.isEmpty { onLine(pending) }
                onEnd(r, nil)
            } catch {
                onEnd(nil, s.isCancelled ? nil : error)
            }
        }
        return s
    }

    /// Blocking HTTP/1.1 over the socket. With `onChunk`, body bytes are handed over as they
    /// arrive (return false to stop) instead of being collected.
    private func perform(_ method: String, _ path: String, body: Data?, timeout: TimeInterval?,
                         stream: DockerStream? = nil, onChunk: ((Data) -> Bool)?) throws -> Response {
        let fd = try connect()
        stream?.fd = fd
        defer { stream?.fd = -1; close(fd) }
        if let timeout {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        var req = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nUser-Agent: Lucent\r\nConnection: close\r\n"
        if let body {
            req += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        } else if method == "POST" {
            req += "Content-Length: 0\r\n"
        }
        var bytes = Data((req + "\r\n").utf8)
        if let body { bytes.append(body) }
        try writeAll(fd, bytes)

        // Headers.
        var buffer = Data()
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            guard let d = try readSome(fd) else { throw VMError.message("Docker closed the connection") }
            buffer.append(d)
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
        }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd!.lowerBound], as: UTF8.self)
        var rest = Data(buffer[headerEnd!.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        let status = Int(lines.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let colon = l.firstIndex(of: ":") {
                headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
        let length = headers["content-length"].flatMap(Int.init)

        var dechunker = Dechunker()
        var collected = Data()
        var received = 0
        func deliver(_ raw: Data) -> Bool {
            let d = chunked ? dechunker.feed(raw) : raw
            received += raw.count
            if !d.isEmpty {
                if let onChunk, (200..<300).contains(status) { if !onChunk(d) { return false } } else { collected.append(d) }
            }
            if chunked && dechunker.done { return false }
            if let length, !chunked, received >= length { return false }
            return true
        }
        var more = rest.isEmpty ? true : deliver(rest)
        rest = Data()
        if length == 0 { more = false }
        while more, let d = try readSome(fd) { more = deliver(d) }
        return Response(status: status, body: collected)
    }

    private func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VMError.message("socket() failed") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw VMError.message("Socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.withUnsafeBytes { dst.copyMemory(from: $0) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { close(fd); throw VMError.message("Can't connect to Docker at \(socketPath)") }
        return fd
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = write(fd, p.baseAddress! + off, p.count - off)
                guard n > 0 else { throw VMError.message("Writing to Docker failed") }
                off += n
            }
        }
    }

    /// Nil at end of stream.
    private func readSome(_ fd: Int32) throws -> Data? {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        if n > 0 { return Data(buf[0..<n]) }
        if n == 0 { return nil }
        if errno == EAGAIN || errno == EWOULDBLOCK { throw VMError.message("Docker didn't answer in time") }
        return nil // closed by cancel()
    }
}

/// A running streaming request.
final class DockerStream: @unchecked Sendable {
    private let lock = NSLock()
    private var _fd: Int32 = -1
    private var _cancelled = false
    var fd: Int32 {
        get { lock.withLock { _fd } }
        set { lock.withLock { _fd = newValue } }
    }
    var isCancelled: Bool { lock.withLock { _cancelled } }

    func cancel() {
        lock.withLock {
            _cancelled = true
            if _fd >= 0 { shutdown(_fd, SHUT_RDWR) }
        }
    }
}

/// Decodes HTTP chunked transfer encoding incrementally.
struct Dechunker {
    private var buffer = Data()
    private var remaining = 0
    private enum State { case size, data, crlf, done }
    private var state = State.size
    var done: Bool { state == .done }

    mutating func feed(_ input: Data) -> Data {
        buffer.append(input)
        var out = Data()
        while true {
            switch state {
            case .size:
                guard let r = buffer.range(of: Data("\r\n".utf8)) else { return out }
                let line = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
                buffer = Data(buffer[r.upperBound...])
                let hex = line.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                let size = Int(hex, radix: 16) ?? 0
                if size == 0 { state = .done; return out }
                remaining = size
                state = .data
            case .data:
                if buffer.isEmpty { return out }
                let n = min(remaining, buffer.count)
                out.append(buffer.prefix(n))
                buffer = Data(buffer.dropFirst(n))
                remaining -= n
                if remaining == 0 { state = .crlf }
            case .crlf:
                if buffer.count < 2 { return out }
                buffer = Data(buffer.dropFirst(2))
                state = .size
            case .done:
                return out
            }
        }
    }
}

// MARK: API types

struct DockerContainer: Decodable, Equatable {
    struct Port: Decodable, Equatable {
        let ip: String?
        let privatePort: Int
        let publicPort: Int?
        let type: String
        enum CodingKeys: String, CodingKey { case ip = "IP", privatePort = "PrivatePort", publicPort = "PublicPort", type = "Type" }
    }
    let id: String
    let names: [String]
    let image: String
    let imageID: String
    let state: String       // running, exited, paused, created, restarting, dead
    let status: String      // "Up 3 minutes", "Exited (0) 2 hours ago"
    let ports: [Port]
    let labels: [String: String]?
    let created: Int

    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", imageID = "ImageID", state = "State", status = "Status"
        case ports = "Ports", labels = "Labels", created = "Created"
    }

    /// Lenient: Docker sends `"Ports": null` for a running container without ports (and may
    /// omit or null other fields), which would otherwise fail the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        imageID = try c.decodeIfPresent(String.self, forKey: .imageID) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        ports = try c.decodeIfPresent([Port].self, forKey: .ports) ?? []
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels)
        created = try c.decodeIfPresent(Int.self, forKey: .created) ?? 0
    }

    var name: String { (names.first ?? String(id.prefix(12))).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    var isRunning: Bool { state == "running" }
    var isPaused: Bool { state == "paused" }
    var composeProject: String? { labels?["com.docker.compose.project"] }
    var composeService: String? { labels?["com.docker.compose.service"] }
    /// Host ports, deduplicated (IPv4 and IPv6 bindings of the same port).
    var publishedPorts: [Int] {
        Array(Set(ports.compactMap(\.publicPort))).sorted()
    }
    var portsText: String {
        let published = Dictionary(grouping: ports.filter { $0.publicPort != nil }, by: { $0.publicPort! })
            .keys.sorted().compactMap { pub -> String? in
                guard let p = ports.first(where: { $0.publicPort == pub }) else { return nil }
                return "\(pub)→\(p.privatePort)"
            }
        if !published.isEmpty { return published.joined(separator: "  ") }
        let exposed = Set(ports.map(\.privatePort)).sorted().map { "\($0)" }
        return exposed.isEmpty ? "–" : exposed.joined(separator: " ") + " (not published)"
    }
}

struct DockerImage: Decodable, Equatable {
    let id: String
    let repoTags: [String]?
    let repoDigests: [String]?
    let size: Int64
    let created: Int
    enum CodingKeys: String, CodingKey {
        case id = "Id", repoTags = "RepoTags", repoDigests = "RepoDigests", size = "Size", created = "Created"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repoTags = try c.decodeIfPresent([String].self, forKey: .repoTags)
        repoDigests = try c.decodeIfPresent([String].self, forKey: .repoDigests)
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        created = try c.decodeIfPresent(Int.self, forKey: .created) ?? 0
    }

    var shortID: String { String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }
    var tags: [String] { (repoTags ?? []).filter { $0 != "<none>:<none>" } }
    var isDangling: Bool { tags.isEmpty }
    var displayName: String {
        if let t = tags.first { return t }
        if let d = repoDigests?.first, let at = d.firstIndex(of: "@") { return String(d[..<at]) + " (untagged)" }
        return "<none>"
    }
}

/// CPU and memory from one /containers/{id}/stats sample.
struct DockerStats {
    let cpuPercent: Double
    let memoryBytes: Int64
    let memoryLimit: Int64

    init?(json: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let cpu = o["cpu_stats"] as? [String: Any], let pre = o["precpu_stats"] as? [String: Any] else { return nil }
        func total(_ s: [String: Any]) -> Double { ((s["cpu_usage"] as? [String: Any])?["total_usage"] as? NSNumber)?.doubleValue ?? 0 }
        func system(_ s: [String: Any]) -> Double { (s["system_cpu_usage"] as? NSNumber)?.doubleValue ?? 0 }
        let cpuDelta = total(cpu) - total(pre), sysDelta = system(cpu) - system(pre)
        let cpus = (cpu["online_cpus"] as? NSNumber)?.doubleValue ?? 1
        cpuPercent = sysDelta > 0 && cpuDelta > 0 ? cpuDelta / sysDelta * cpus * 100 : 0
        let mem = o["memory_stats"] as? [String: Any] ?? [:]
        let usage = (mem["usage"] as? NSNumber)?.int64Value ?? 0
        let detail = mem["stats"] as? [String: Any] ?? [:]
        let cache = (detail["inactive_file"] as? NSNumber)?.int64Value ?? (detail["cache"] as? NSNumber)?.int64Value ?? 0
        memoryBytes = max(0, usage - cache)
        memoryLimit = (mem["limit"] as? NSNumber)?.int64Value ?? 0
    }
}

extension String {
    /// For query strings.
    var urlQueryEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? self
    }
}
