import Foundation
import Virtualization

/// A VM's settings, saved as config.json in its folder.
struct VMConfig: Codable, Equatable {
    var id: String
    var name: String
    var cpus: Int
    var memoryMB: Int
    var diskGB: Int
    var macAddress: String
    var image: String          // e.g. "debian-13"
    var user: String
    var created: Date
}

/// Linux cloud images Lucent can create VMs from. Raw ARM64 disk images (what
/// Virtualization.framework boots), set up on first boot by cloud-init.
struct CloudImage {
    let id: String
    let name: String
    let url: URL
    /// The raw disk's path inside the downloaded archive.
    let diskInArchive: String

    static let all = [
        CloudImage(id: "debian-13", name: "Debian 13 (trixie)",
                   url: URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.tar.xz")!,
                   diskInArchive: "disk.raw"),
    ]
    static func image(_ id: String) -> CloudImage? { all.first { $0.id == id } }
}

enum VMError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// VMs on disk: ~/.config/lucent/vms/<id>/ with config.json, disk.img (raw, sparse), seed.iso
/// (cloud-init), efi-vars and machine-id. Base images are cached in vms/images/.
enum VMLibrary {
    static var directory: URL {
        // Test runs point this elsewhere so they never touch the user's VMs.
        if let dir = ProcessInfo.processInfo.environment["ML_VMS_DIR"] { return URL(fileURLWithPath: dir) }
        return Config.directory.appendingPathComponent("vms")
    }
    static var imagesDirectory: URL { directory.appendingPathComponent("images") }

    static func folder(_ id: String) -> URL { directory.appendingPathComponent(id) }

    static func all() -> [VMConfig] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")) else { return nil }
            return try? JSONDecoder.vm.decode(VMConfig.self, from: data)
        }.sorted { $0.created < $1.created }
    }

    static func save(_ c: VMConfig) throws {
        try FileManager.default.createDirectory(at: folder(c.id), withIntermediateDirectories: true)
        try JSONEncoder.vm.encode(c).write(to: folder(c.id).appendingPathComponent("config.json"), options: .atomic)
    }

    /// Delete a VM (to the Trash, so its disk can be recovered).
    static func delete(_ id: String) throws {
        try FileManager.default.trashItem(at: folder(id), resultingItemURL: nil)
    }

    // MARK: Creating

    /// Create a VM: fetch the base image if needed, copy it (APFS clone — instant), grow it,
    /// and write the cloud-init seed. `progress` gets (message, fraction 0…1 or nil).
    static func create(name: String, cpus: Int, memoryMB: Int, diskGB: Int, imageID: String,
                       progress: @escaping @Sendable (String, Double?) -> Void) async throws -> VMConfig {
        guard let image = CloudImage.image(imageID) else { throw VMError.message("Unknown image \(imageID)") }
        let base = try await baseImage(image, progress: progress)

        let id = slug(name)
        let dir = folder(id)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path) else { throw VMError.message("A VM called “\(id)” already exists") }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        progress("Copying disk…", nil)
        let disk = dir.appendingPathComponent("disk.img")
        try fm.copyItem(at: base, to: disk) // APFS clonefile: no extra space until the VM writes
        let size = UInt64(diskGB) * 1_073_741_824
        let current = (try? fm.attributesOfItem(atPath: disk.path)[.size] as? UInt64) ?? 0
        if size > current {
            let h = try FileHandle(forWritingTo: disk)
            try h.truncate(atOffset: size) // sparse; cloud-init grows the root partition into it
            try h.close()
        }

        let config = VMConfig(id: id, name: name, cpus: cpus, memoryMB: memoryMB, diskGB: diskGB,
                              macAddress: VZMACAddress.randomLocallyAdministered().string,
                              image: imageID, user: NSUserName().lowercased(), created: Date())
        progress("Writing cloud-init seed…", nil)
        try writeSeed(for: config)
        try save(config)
        return config
    }

    static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(s).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "vm" : joined
    }

    /// The cached raw base image, downloading and unpacking it the first time.
    static func baseImage(_ image: CloudImage, progress: @escaping @Sendable (String, Double?) -> Void) async throws -> URL {
        let fm = FileManager.default
        let raw = imagesDirectory.appendingPathComponent("\(image.id).raw")
        if fm.fileExists(atPath: raw.path) { return raw }
        try fm.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        progress("Downloading \(image.name)…", 0)
        let archive = try await Downloader.download(image.url) { p in progress("Downloading \(image.name)…", p) }
        defer { try? fm.removeItem(at: archive) }

        progress("Unpacking \(image.name)…", nil)
        let work = imagesDirectory.appendingPathComponent(".unpack-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try run("/usr/bin/tar", ["-xJf", archive.path, "-C", work.path, image.diskInArchive])
        try fm.moveItem(at: work.appendingPathComponent(image.diskInArchive), to: raw)
        return raw
    }

    // MARK: cloud-init

    /// A NoCloud seed (ISO9660 volume "cidata"): user, SSH keys, sudo, hostname, and console
    /// autologin on hvc0 (Lucent's console tile).
    static func writeSeed(for c: VMConfig) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("lucent-seed-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let keys = sshPublicKeys().map { "      - \($0)" }.joined(separator: "\n")
        let userData = """
        #cloud-config
        hostname: \(c.id)
        users:
          - name: \(c.user)
            shell: /bin/bash
            groups: [sudo]
            sudo: ALL=(ALL) NOPASSWD:ALL
            lock_passwd: true
        \(keys.isEmpty ? "" : "    ssh_authorized_keys:\n" + keys)
        ssh_pwauth: false
        write_files:
          - path: /etc/systemd/system/serial-getty@hvc0.service.d/lucent-autologin.conf
            content: |
              [Service]
              ExecStart=
              ExecStart=-/sbin/agetty --autologin \(c.user) --keep-baud 115200,57600,38400,9600 %I $TERM
          - path: /etc/profile.d/lucent-console.sh
            content: |
        \(consoleScript.split(separator: "\n").map { "      " + $0 }.joined(separator: "\n"))
        runcmd:
          - [systemctl, daemon-reload]
          - [systemctl, restart, serial-getty@hvc0.service]
        """
        let metaData = "instance-id: \(c.id)-\(Int(c.created.timeIntervalSince1970))\nlocal-hostname: \(c.id)\n"
        try userData.write(to: work.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        try metaData.write(to: work.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
        // DHCP with the MAC as client id (systemd-networkd sends a DUID by default), so Lucent can
        // find the VM's address in macOS's lease file.
        let network = """
        version: 2
        ethernets:
          primary:
            match:
              macaddress: "\(c.macAddress)"
            dhcp4: true
            dhcp-identifier: mac
        """
        try network.write(to: work.appendingPathComponent("network-config"), atomically: true, encoding: .utf8)

        let seed = folder(c.id).appendingPathComponent("seed.iso")
        try? fm.removeItem(at: seed)
        try run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata",
                                     "-o", seed.path, work.path])
    }

    /// The serial console has no window-size signalling, so on hvc0 the shell asks Lucent for
    /// the size before each prompt (`CSI 18 t`, answered by the console tile) and runs stty.
    static let consoleScript = #"""
    # Lucent: keep the serial console's size in step with its tile.
    if [ "$(tty 2>/dev/null)" = /dev/hvc0 ]; then
      __lucent_resize() {
        local saved rows cols
        saved=$(stty -g)
        stty raw -echo min 0 time 5
        printf '\033[18t' > /dev/tty
        IFS=';' read -r -d t _ rows cols < /dev/tty
        stty "$saved"
        [ -n "$cols" ] && stty rows "$rows" cols "$cols"
      }
      PROMPT_COMMAND="__lucent_resize${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    fi
    """#

    static func sshPublicKeys() -> [String] {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "pub" }.compactMap {
            (try? String(contentsOf: $0, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw VMError.message("\((path as NSString).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    // MARK: Networking

    /// The VM's IPv4 address from macOS's DHCP leases (the NAT network's DHCP server): by MAC,
    /// else by host name (a guest that sent a DUID instead of its MAC), newest lease first.
    static func ipAddress(mac: String, hostname: String) -> String? {
        guard let text = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return nil }
        let want = normalize(mac)
        var byMAC: (ip: String, lease: UInt64)?, byName: (ip: String, lease: UInt64)?
        for block in text.components(separatedBy: "}") {
            var ip: String?, hw: String?, name: String?, lease: UInt64 = 0
            for line in block.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("ip_address=") { ip = String(t.dropFirst(11)) }
                if t.hasPrefix("name=") { name = String(t.dropFirst(5)) }
                if t.hasPrefix("hw_address=1,") { hw = String(t.dropFirst(13)) }
                if t.hasPrefix("lease=") { lease = UInt64(t.dropFirst(6).replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0 }
            }
            guard let ip else { continue }
            if let hw, normalize(hw) == want, lease >= (byMAC?.lease ?? 0) { byMAC = (ip, lease) }
            if name == hostname, lease >= (byName?.lease ?? 0) { byName = (ip, lease) }
        }
        return byMAC?.ip ?? byName?.ip
    }

    /// "02:0a:…" and "2:a:…" (how bootpd writes it) compare equal.
    private static func normalize(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { String(Int($0, radix: 16) ?? 0, radix: 16) }.joined(separator: ":")
    }
}

/// URLSession download with progress.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: @Sendable (Double) -> Void

    private init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let d = Downloader(onProgress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            d.continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns; keep it.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("lucent-dl-\(UUID().uuidString)")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw VMError.message("Download failed: HTTP \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: location, to: keep)
            continuation?.resume(returning: keep)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
    }
}

extension JSONEncoder {
    static var vm: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var vm: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
