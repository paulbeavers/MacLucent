import Foundation
import Darwin

/// A process listening on a TCP port.
struct ListeningPort: Equatable {
    let port: Int
    /// "localhost", "*" (all interfaces) or a specific address; IPv4 and IPv6 sockets for the
    /// same port and process are merged into one entry.
    var address: String
    let pid: pid_t
    let name: String
    let path: String?
    let command: String
    let directory: String?
    let started: Date?

    /// Only reachable from this Mac.
    var isLocalOnly: Bool { address == "localhost" }
    /// Looks like development: started from a project folder (background app helpers and macOS
    /// services run from "/"), or a well-known dev server, database or tool.
    var isDev: Bool {
        if let d = directory, d != "/", !(path ?? "").hasPrefix("/System/") { return true }
        let tool = command.split(separator: " ").first.map(String.init)?.lowercased() ?? name.lowercased()
        return Self.devTools.contains(tool) || Self.devTools.contains(name.lowercased())
    }

    static let devTools: Set<String> = [
        "node", "python", "python3", "ruby", "java", "go", "deno", "bun", "php", "perl", "dotnet",
        "postgres", "mysqld", "mariadbd", "redis-server", "mongod", "memcached", "elasticsearch",
        "nginx", "httpd", "caddy", "traefik", "docker", "com.docker.backend", "vpnkit-bridge",
        "ollama", "jupyter", "jupyter-lab", "uvicorn", "gunicorn", "puma", "rails", "hugo", "jekyll",
        "esbuild", "vite", "next-server", "ng", "minikube", "kubectl", "colima", "lima",
    ]
}

/// Finds listening TCP sockets via libproc (no `lsof`). Only processes the user owns are visible,
/// which is exactly the set the user can act on.
enum PortScanner {
    static func scan() -> [ListeningPort] {
        var found: [String: ListeningPort] = [:] // "pid:port" → entry
        for pid in allPIDs() {
            for (port, address) in listeningSockets(of: pid) {
                let key = "\(pid):\(port)"
                if var existing = found[key] {
                    existing.address = merge(existing.address, address)
                    found[key] = existing
                    continue
                }
                let path = executablePath(pid)
                found[key] = ListeningPort(
                    port: port, address: address, pid: pid,
                    name: ProcStats.name(pid) ?? path.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)",
                    path: path, command: commandLine(pid) ?? "", directory: workingDirectory(pid),
                    started: ProcStats.startTime(pid))
            }
        }
        return found.values.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// "*" beats "localhost" beats a specific address when merging IPv4/IPv6 sockets.
    private static func merge(_ a: String, _ b: String) -> String {
        if a == "*" || b == "*" { return "*" }
        if a == "localhost" || b == "localhost" { return "localhost" }
        return a
    }

    private static func allPIDs() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
        let got = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        return pids.prefix(Int(got) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    private static func listeningSockets(of pid: pid_t) -> [(Int, String)] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var result: [(Int, String)] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize else { continue }
            let soi = info.psi
            guard soi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = soi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let ini = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            result.append((port, address(ini)))
        }
        return result
    }

    private static func address(_ ini: in_sockinfo) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var text = ""
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var a = ini.insi_laddr.ina_46.i46a_addr4
            inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
            text = String(cString: buf)
            if text == "0.0.0.0" { return "*" }
            if text.hasPrefix("127.") { return "localhost" }
        } else {
            var a = ini.insi_laddr.ina_6
            inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
            text = String(cString: buf)
            if text == "::" { return "*" }
            if text == "::1" { return "localhost" }
        }
        return text
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// The process's arguments (KERN_PROCARGS2), e.g. "node node_modules/.bin/vite --port 5173".
    static func commandLine(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 } // executable path
        while i < size && buf[i] == 0 { i += 1 } // padding
        var args: [String] = []
        while args.count < Int(argc) && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        guard !args.isEmpty else { return nil }
        // Shorten the executable to its name; keep the arguments as they are.
        args[0] = (args[0] as NSString).lastPathComponent
        return args.joined(separator: " ")
    }
}
