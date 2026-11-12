import AppKit
import Virtualization

extension Notification.Name {
    /// A VM was created, deleted, started or stopped (object: the VM id, or nil).
    static let vmsDidChange = Notification.Name("LucentVMsDidChange")
}

/// A Linux VM: a Virtualization.framework machine plus its serial console. Owned by `VMManager`
/// (not by any tile), so closing the console tile leaves the VM running.
@MainActor
final class VMInstance: NSObject, VZVirtualMachineDelegate {
    enum State: Equatable {
        case stopped, starting, running, stopping
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting"
            case .running: return "Running"
            case .stopping: return "Shutting down"
            case .failed: return "Error"
            }
        }
        var isActive: Bool { self == .starting || self == .running || self == .stopping }
    }

    private(set) var config: VMConfig
    private(set) var state: State = .stopped { didSet { notify() } }
    private(set) var startedAt: Date?
    private var vm: VZVirtualMachine?
    private var toGuest: Pipe?
    private var fromGuest: Pipe?
    private var stopTimer: Timer?

    /// Console output so far (bounded), so a console opened later shows what happened.
    private(set) var consoleHistory = Data()
    private let historyLimit = 512 * 1024
    private var listeners: [UUID: (Data) -> Void] = [:]

    var id: String { config.id }
    var folder: URL { VMLibrary.folder(config.id) }
    var ipAddress: String? { state == .running ? VMLibrary.ipAddress(mac: config.macAddress, hostname: config.id) : nil }

    init(config: VMConfig) {
        self.config = config
    }

    private func notify() {
        NotificationCenter.default.post(name: .vmsDidChange, object: id)
    }

    // MARK: Console

    func addConsoleListener(_ f: @escaping (Data) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = f
        return id
    }

    func removeConsoleListener(_ id: UUID) { listeners[id] = nil }

    func sendToConsole(_ data: Data) {
        guard state == .running || state == .starting else { return }
        toGuest?.fileHandleForWriting.write(data)
    }

    private func received(_ data: Data) {
        consoleHistory.append(data)
        if consoleHistory.count > historyLimit {
            consoleHistory.removeSubrange(0..<(consoleHistory.count - historyLimit * 3 / 4))
        }
        listeners.values.forEach { $0(data) }
    }

    // MARK: Lifecycle

    func start() {
        guard !state.isActive else { return }
        do {
            let input = Pipe(), output = Pipe()
            let vzConfig = try makeConfiguration(consoleInput: input.fileHandleForReading,
                                                 consoleOutput: output.fileHandleForWriting)
            try vzConfig.validate()
            let machine = VZVirtualMachine(configuration: vzConfig) // main queue
            machine.delegate = self
            vm = machine
            toGuest = input
            fromGuest = output
            output.fileHandleForReading.readabilityHandler = { [weak self] h in
                let data = h.availableData
                guard !data.isEmpty else { h.readabilityHandler = nil; return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data) } }
            }
            consoleHistory = Data()
            state = .starting
            machine.start { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.startedAt = Date()
                        self.state = .running
                    case .failure(let error):
                        self.cleanUp()
                        self.state = .failed(error.localizedDescription)
                    }
                }
            }
        } catch {
            cleanUp()
            state = .failed(error.localizedDescription)
        }
    }

    /// Ask the guest to shut down (ACPI power button); force it off if it hasn't after `timeout`.
    func stop(timeout: TimeInterval = 30) {
        guard let vm, state == .running || state == .starting else { return }
        if vm.canRequestStop, (try? vm.requestStop()) != nil {
            state = .stopping
            stopTimer?.invalidate()
            let t = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.forceStop() }
            }
            RunLoop.main.add(t, forMode: .common) // also fires while quitting (modal-panel run loop mode)
            stopTimer = t
        } else {
            forceStop()
        }
    }

    /// Pull the plug.
    func forceStop() {
        guard let vm, state.isActive else { return }
        stopTimer?.invalidate()
        if vm.canStop {
            vm.stop { [weak self] _ in MainActor.assumeIsolated { self?.didStop(nil) } }
        } else {
            didStop(nil)
        }
    }

    private func didStop(_ error: Error?) {
        guard vm != nil else { return }
        cleanUp()
        if let error { state = .failed(error.localizedDescription) } else { state = .stopped }
    }

    private func cleanUp() {
        stopTimer?.invalidate()
        stopTimer = nil
        fromGuest?.fileHandleForReading.readabilityHandler = nil
        try? toGuest?.fileHandleForWriting.close()
        vm = nil
        toGuest = nil
        fromGuest = nil
        startedAt = nil
    }

    func update(_ change: (inout VMConfig) -> Void) throws {
        var c = config
        change(&c)
        try VMLibrary.save(c)
        config = c
        notify()
    }

    // MARK: VZVirtualMachineDelegate (called on the main queue)

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { didStop(nil) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated { didStop(error) }
    }

    // MARK: Configuration

    private func makeConfiguration(consoleInput: FileHandle, consoleOutput: FileHandle) throws -> VZVirtualMachineConfiguration {
        let fm = FileManager.default
        let c = VZVirtualMachineConfiguration()
        c.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                         min(config.cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        c.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                           min(UInt64(config.memoryMB) * 1024 * 1024, VZVirtualMachineConfiguration.maximumAllowedMemorySize))

        // Generic ARM64 platform with a stable machine identity (keeps the guest's view of
        // "this machine" the same across boots).
        let platform = VZGenericPlatformConfiguration()
        let idFile = folder.appendingPathComponent("machine-id")
        if let data = try? Data(contentsOf: idFile), let mid = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = mid
        } else {
            try platform.machineIdentifier.dataRepresentation.write(to: idFile)
        }
        c.platform = platform

        let boot = VZEFIBootLoader()
        let vars = folder.appendingPathComponent("efi-vars")
        boot.variableStore = fm.fileExists(atPath: vars.path)
            ? VZEFIVariableStore(url: vars)
            : try VZEFIVariableStore(creatingVariableStoreAt: vars)
        c.bootLoader = boot

        let disk = try VZDiskImageStorageDeviceAttachment(url: folder.appendingPathComponent("disk.img"), readOnly: false,
                                                          cachingMode: .automatic, synchronizationMode: .full)
        var storage: [VZStorageDeviceConfiguration] = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
        let seed = folder.appendingPathComponent("seed.iso")
        if fm.fileExists(atPath: seed.path) {
            storage.append(VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true)))
        }
        c.storageDevices = storage

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        if let mac = VZMACAddress(string: config.macAddress) { net.macAddress = mac }
        c.networkDevices = [net]

        // hvc0: Lucent's console tile.
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: consoleInput,
                                                              fileHandleForWriting: consoleOutput)
        c.serialPorts = [console]

        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        return c
    }
}

/// All VMs on disk and the running machines.
@MainActor
final class VMManager {
    static let shared = VMManager()
    private var instances: [String: VMInstance] = [:]

    private init() {}

    /// Every VM, oldest first (re-read from disk; running ones keep their instance).
    var all: [VMInstance] {
        let configs = VMLibrary.all()
        let ids = Set(configs.map(\.id))
        for (id, vm) in instances where !ids.contains(id) && !vm.state.isActive { instances[id] = nil }
        return configs.map { c in
            if let vm = instances[c.id] { return vm }
            let vm = VMInstance(config: c)
            instances[c.id] = vm
            return vm
        }
    }

    func instance(_ id: String) -> VMInstance? {
        if let vm = instances[id] { return vm }
        return all.first { $0.id == id }
    }

    var running: [VMInstance] { instances.values.filter { $0.state.isActive } }

    func delete(_ vm: VMInstance) throws {
        guard !vm.state.isActive else { throw VMError.message("Stop \(vm.config.name) before deleting it") }
        try VMLibrary.delete(vm.id)
        instances[vm.id] = nil
        NotificationCenter.default.post(name: .vmsDidChange, object: nil)
    }

    /// Shut every running VM down (cleanly if possible), then call `done`. Used when quitting.
    func stopAll(timeout: TimeInterval = 15, done: @escaping @MainActor () -> Void) {
        let vms = running
        guard !vms.isEmpty else { done(); return }
        vms.forEach { $0.stop(timeout: timeout) }
        var waited: TimeInterval = 0
        // While a quit waits on .terminateLater, AppKit runs the run loop in the modal-panel mode:
        // a default-mode timer would never fire and Lucent would hang with Quit greyed out.
        let poll = Timer(timeInterval: 0.25, repeats: true) { t in
            MainActor.assumeIsolated {
                waited += 0.25
                if vms.allSatisfy({ !$0.state.isActive }) || waited > timeout + 2 {
                    t.invalidate()
                    done()
                }
            }
        }
        RunLoop.main.add(poll, forMode: .common)
    }
}
