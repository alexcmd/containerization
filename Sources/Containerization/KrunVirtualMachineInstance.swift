//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if os(macOS)
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Darwin
import Foundation
import Logging
import NIOCore
import NIOPosix
import Synchronization

/// A VM run by libkrun in a `krun-vmm` child process.
///
/// libkrun's device set is fixed at boot, so this backend is VZ-shaped for
/// storage (every disk and share is attached at start, no hotplug) and
/// CH-shaped for the control plane (a VMM subprocess, with vsock ports mapped
/// to per-port host UNIX sockets).
///
/// vsock limitations, both from libkrun keying its port map by port number
/// alone and requiring it before boot:
/// - `dial(_:)` (host → guest) reaches only the vminitd port.
/// - `listen(_:)` (guest → host) works for the pre-bound pool at
///   `stdioPoolBase..<stdioPoolBase+stdioPoolSize`, which covers the ports
///   `LinuxContainer` allocates for process stdio.
public final class KrunVirtualMachineInstance: Sendable {
    public typealias Agent = Vminitd

    public struct Configuration: Sendable {
        public var cpus: Int = 4
        public var memoryInBytes: UInt64 = 1024 * 1024 * 1024
        public var interfaces: [any Interface] = []
        public var mountsByID: [String: [Mount]] = [:]
        public var bootLog: BootLog?
        public var kernel: Kernel?
        public var initialFilesystem: Mount?
        public var gpu: KrunGPUMode = .none
        public var display: KrunDisplay?
        /// gvproxy binary, required when `interfaces` is non-empty.
        public var gvproxyBinary: URL?
        /// libkrun log level, 0 (off) to 5 (trace).
        public var logLevel: Int = 1

        public init() {}
    }

    static let stdioPoolBase: UInt32 = 0x1000_0000
    static let stdioPoolSize: Int = 64
    static let agentDialDeadline: Duration = .seconds(60)

    private let _state: Mutex<VirtualMachineInstanceState>
    public var state: VirtualMachineInstanceState { _state.withLock { $0 } }

    private let _mounts: Mutex<[String: [AttachedFilesystem]]>
    public var mounts: [String: [AttachedFilesystem]] { _mounts.withLock { $0 } }

    /// libkrun gives each virtio-fs share its own device and tag.
    public var virtiofsLayout: VirtiofsLayout { .perTag }

    let config: Configuration
    let workDir: URL
    let helperBinary: URL
    /// Disks in guest attach order: index 0 is /dev/vda.
    private let bootDisks: [Mount]
    private let group: any EventLoopGroup
    private let ownsGroup: Bool
    private let lock: AsyncLock
    private let timeSyncer: TimeSyncer
    private let logger: Logger?
    private let process: Mutex<VMMProcess?>
    private let _stdioPool: Mutex<[UInt32: CHStdioPortSlot]>

    var agentSocket: URL { workDir.appendingPathComponent("agent.sock") }
    var consoleLog: URL { workDir.appendingPathComponent("console.log") }
    var vmmLog: URL { workDir.appendingPathComponent("vmm.log") }
    /// gvproxy's datagram socket; `net.sock.api` is its services API.
    var netSocket: URL { workDir.appendingPathComponent("net.sock") }

    init(
        group: (any EventLoopGroup)?,
        config: Configuration,
        runtimeRoot: URL,
        helperBinary: URL,
        logger: Logger?
    ) throws {
        guard config.kernel != nil, config.initialFilesystem != nil else {
            throw ContainerizationError(.invalidArgument, message: "libkrun VM needs a kernel and an initial filesystem")
        }
        if !config.interfaces.isEmpty {
            guard config.interfaces.count == 1, config.interfaces[0] is GvproxyInterface else {
                throw ContainerizationError(
                    .unsupported, message: "the libkrun backend supports one GvproxyInterface (use GvproxyNetwork)")
            }
            guard config.gvproxyBinary != nil else {
                throw ContainerizationError(.invalidArgument, message: "networking needs a gvproxy binary")
            }
        }

        // Short random name: the per-port socket paths must stay under the
        // 104-byte sun_path limit.
        let workDir = runtimeRoot.appendingPathComponent(String(UUID().uuidString.prefix(8)).lowercased())
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.workDir = workDir

        let allocator = Character.blockDeviceTagAllocator()
        let (attachments, disks) = try config.bootInventory(allocator: allocator)
        self._mounts = Mutex(attachments)
        self.bootDisks = disks

        if let group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            self.ownsGroup = true
        }
        self.config = config
        self.helperBinary = helperBinary
        self.logger = logger
        self.lock = .init()
        self.timeSyncer = .init(logger: logger)
        self._state = Mutex(.stopped)
        self.process = Mutex(nil)
        self._stdioPool = Mutex([:])
    }
}

// MARK: - VirtualMachineInstance

extension KrunVirtualMachineInstance: VirtualMachineInstance {
    public func start() async throws {
        try await lock.withLock { _ in
            guard self.state == .stopped else {
                throw ContainerizationError(.invalidState, message: "virtual machine is not stopped (\(self.state))")
            }
            self._state.withLock { $0 = .starting }
            do {
                // The guest dials these as soon as processes start, and libkrun
                // connects to the host path on each dial, so bind them first.
                try self.prebindStdioPool()
                let args = try self.helperArguments()
                try self.launchHelper(arguments: args)
                let agent = try await self.dialAgentWithRetries()
                await self.timeSyncer.start(context: agent)
                self._state.withLock { $0 = .running }
            } catch {
                self.logger?.warning("libkrun VM start failed: \(error); vmm log: \(self.vmmLog.path)")
                await self.teardown(keepLogs: true)
                self._state.withLock { $0 = .stopped }
                throw error
            }
        }
    }

    public func stop() async throws {
        try await lock.withLock { _ in
            // A VMM that exited on its own (guest panic, helper crash) flips
            // the state to .stopped but still owns sockets, accept loops and
            // the event-loop group, so stop() must tear those down too.
            let launched = self.process.withLock { $0 != nil }
            guard self.state == .running || launched else {
                throw ContainerizationError(.invalidState, message: "vm is not running")
            }
            self._state.withLock { $0 = .stopping }
            try? await self.timeSyncer.close()
            await self.teardown(keepLogs: false)
            self._state.withLock { $0 = .stopped }
        }
    }

    public func dialAgent() async throws -> Vminitd {
        try await lock.withLock { _ in
            try self.requireRunning()
            return try await Vminitd(connection: try self.connectAgentSocket(), group: self.group)
        }
    }

    public func dial(_ port: UInt32) async throws -> FileHandle {
        guard port == Vminitd.port else {
            throw ContainerizationError(
                .unsupported,
                message: "libkrun backend can only dial the vminitd vsock port (\(Vminitd.port)), not \(port)"
            )
        }
        try requireRunning()
        return try connectAgentSocket()
    }

    public func listen(_ port: UInt32) throws -> VsockListener {
        guard let slot = _stdioPool.withLock({ $0[port] }) else {
            let end = Self.stdioPoolBase + UInt32(Self.stdioPoolSize)
            throw ContainerizationError(
                .unsupported,
                message: "vsock port \(port) is outside the libkrun pre-bound range \(Self.stdioPoolBase)..<\(end)"
            )
        }
        let listener = VsockListener(port: slot.port) { [slot] _ in
            slot.relinquish()
        }
        try slot.claim(by: listener)
        slot.startAcceptingIfNeeded(logger: logger)
        return listener
    }
}

// MARK: - Internals

extension KrunVirtualMachineInstance {
    private func requireRunning() throws {
        let current = state
        guard current == .running else {
            throw ContainerizationError(.invalidState, message: "vm is not running (state=\(current))")
        }
    }

    func helperArguments() throws -> [String] {
        guard let kernel = config.kernel, let initfs = config.initialFilesystem else {
            throw ContainerizationError(.invalidArgument, message: "libkrun VM needs a kernel and an initial filesystem")
        }
        let mib = max(UInt64(256), config.memoryInBytes / (1024 * 1024))
        var args: [String] = [
            "--cpus", String(config.cpus),
            "--mem", String(mib),
            "--kernel", kernel.path.path,
            "--cmdline", kernel.linuxCommandline(initialFilesystem: initfs),
            "--log-level", String(config.logLevel),
            "--console", consoleLogPath(),
        ]
        for (index, disk) in bootDisks.enumerated() {
            let flag = disk.options.contains("ro") ? "--disk-ro" : "--disk"
            args += [flag, "vd\(index):\(disk.source)"]
        }
        if initfs.type == "virtiofs" {
            args += ["--virtiofs", "rootfs:\(initfs.source)"]
        }
        var seenTags: Set<String> = []
        for id in config.mountsByID.keys.sorted() {
            for mount in config.mountsByID[id] ?? [] {
                guard case .virtiofs = mount.runtimeOptions else { continue }
                let tag = try hashFilePath(path: mount.source)
                if seenTags.insert(tag).inserted {
                    args += ["--virtiofs", "\(tag):\(mount.source)"]
                }
            }
        }
        args += ["--vsock-connect", "\(Vminitd.port):\(agentSocket.path)"]
        for port in _stdioPool.withLock({ $0.keys.sorted() }) {
            args += ["--vsock-listen", "\(port):\(stdioSocketPath(port).path)"]
        }
        if let iface = config.interfaces.first as? GvproxyInterface, let gvproxy = config.gvproxyBinary,
            let mac = iface.macAddress
        {
            args += ["--gvproxy", gvproxy.path, "--net-socket", netSocket.path, "--net-mac", mac.description]
        }
        args += config.gpu.helperArguments
        if let display = config.display {
            args += display.helperArguments
        }
        return args
    }

    private func consoleLogPath() -> String {
        if let bootLog = config.bootLog, case .file(let path, _) = bootLog.base {
            return path.path
        }
        return consoleLog.path
    }

    private func stdioSocketPath(_ port: UInt32) -> URL {
        workDir.appendingPathComponent("p\(port - Self.stdioPoolBase)")
    }

    private func prebindStdioPool() throws {
        var pool: [UInt32: CHStdioPortSlot] = [:]
        do {
            for offset in 0..<UInt32(Self.stdioPoolSize) {
                let port = Self.stdioPoolBase + offset
                let path = stdioSocketPath(port)
                let unix = try UnixType(path: path.path, perms: 0o600, unlinkExisting: true)
                let socket = try Socket(type: unix, closeOnDeinit: false)
                do {
                    try socket.listen()
                } catch {
                    try? socket.close()
                    throw error
                }
                Self.setCloseOnExec(socket.fileDescriptor)
                pool[port] = CHStdioPortSlot(port: port, path: path, listenFd: socket.fileDescriptor)
            }
        } catch {
            for slot in pool.values { slot.shutdown() }
            throw error
        }
        _stdioPool.withLock { $0 = pool }
    }

    private func launchHelper(arguments: [String]) throws {
        FileManager.default.createFile(atPath: vmmLog.path, contents: nil)
        let log = try FileHandle(forWritingTo: vmmLog)
        let proc = Process()
        proc.executableURL = helperBinary
        proc.arguments = arguments
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = log
        proc.standardError = log
        proc.terminationHandler = { [weak self, logger] p in
            logger?.debug("krun-vmm exited status=\(p.terminationStatus) reason=\(p.terminationReason.rawValue)")
            self?._state.withLock { state in
                if state == .running { state = .stopped }
            }
        }
        logger?.debug("launching krun-vmm \(arguments.joined(separator: " "))")
        try proc.run()
        try? log.close()
        process.withLock { $0 = VMMProcess(proc) }
    }

    /// Connect to the host side of the vminitd port. libkrun owns this
    /// socket and forwards each connection to the guest.
    private func connectAgentSocket() throws -> FileHandle {
        let unix = try UnixType(path: agentSocket.path)
        let socket = try Socket(type: unix, closeOnDeinit: false)
        do {
            try socket.connect()
        } catch {
            try? socket.close()
            throw error
        }
        Self.setCloseOnExec(socket.fileDescriptor)
        var one: Int32 = 1
        _ = setsockopt(socket.fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // Not closeOnDealloc: the consumer owns the fd (Vminitd hands it to
        // NIO via `withConnectedSocket`, which closes it), and a second close
        // from the FileHandle would hit whatever reused the number.
        return FileHandle(fileDescriptor: socket.fileDescriptor, closeOnDealloc: false)
    }

    /// Wait for vminitd to answer. libkrun may accept the host connection
    /// before the guest listens, so readiness is an RPC round trip, not a
    /// successful connect.
    private func dialAgentWithRetries() async throws -> Vminitd {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.agentDialDeadline)
        var lastError: any Error = ContainerizationError(.timeout, message: "vminitd did not answer")
        while clock.now < deadline {
            if let proc = process.withLock({ $0 }), !proc.isRunning {
                throw ContainerizationError(
                    .internalError,
                    message: "krun-vmm exited with status \(proc.status) before vminitd answered; see \(vmmLog.path) and \(consoleLogPath())"
                )
            }
            do {
                let agent = try await Vminitd(connection: try connectAgentSocket(), group: group)
                do {
                    _ = try await withTimeout(.seconds(2)) { try await agent.getenv(key: "PATH") }
                    return agent
                } catch {
                    _ = try? await withTimeout(.seconds(2)) { try await agent.close() }
                    throw error
                }
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        throw ContainerizationError(.timeout, message: "vminitd did not answer within \(Self.agentDialDeadline): \(lastError)")
    }

    /// Keep VM sockets out of later `krun-vmm` children (another VM's helper
    /// must not hold this VM's agent or stdio sockets open).
    static func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
        }
    }

    private func withTimeout<T: Sendable>(_ timeout: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ContainerizationError(.timeout, message: "operation timed out after \(timeout)")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ContainerizationError(.internalError, message: "timeout group returned no result")
            }
            return result
        }
    }

    /// Best-effort, idempotent: stop the VMM (SIGTERM ends the VM at once,
    /// matching VZ's stop(); SIGKILL if it lingers), close the stdio sockets
    /// and remove the work directory.
    private func teardown(keepLogs: Bool) async {
        try? await timeSyncer.close()
        if let proc = process.withLock({ $0 }) {
            await proc.terminate(grace: .seconds(3))
        }
        process.withLock { $0 = nil }
        let slots = _stdioPool.withLock { pool -> [CHStdioPortSlot] in
            defer { pool.removeAll() }
            return Array(pool.values)
        }
        for slot in slots { slot.shutdown() }
        if ownsGroup {
            try? await group.shutdownGracefully()
        }
        guard keepLogs else {
            try? FileManager.default.removeItem(at: workDir)
            return
        }
        // A VM that failed to start keeps its logs for diagnosis. Compare
        // names, not URLs: the listing may resolve /tmp to /private/tmp.
        let keep: Set<String> = [vmmLog.lastPathComponent, consoleLog.lastPathComponent]
        if let entries = try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) {
            for entry in entries where !keep.contains(entry.lastPathComponent) {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}

/// `Process` is not `Sendable`; this box confines access to its
/// thread-safe members.
final class VMMProcess: @unchecked Sendable {
    private let proc: Process

    init(_ proc: Process) { self.proc = proc }

    var isRunning: Bool { proc.isRunning }
    var status: Int32 { proc.isRunning ? 0 : proc.terminationStatus }

    func terminate(grace: Duration) async {
        guard proc.isRunning else { return }
        kill(proc.processIdentifier, SIGTERM)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: grace)
        while proc.isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            while proc.isRunning {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
}

// MARK: - Boot inventory

extension KrunVirtualMachineInstance.Configuration {
    /// Allocate guest disk letters in attach order: the rootfs first (so
    /// `root=/dev/vda` holds), then each container's block mounts, sorted by
    /// container id. Returns the per-container registry and the disks in the
    /// order they must be handed to libkrun.
    func bootInventory(
        allocator: any AddressAllocator<Character>
    ) throws -> (attachments: [String: [AttachedFilesystem]], disks: [Mount]) {
        var disks: [Mount] = []
        var attachments: [String: [AttachedFilesystem]] = [:]
        if let rootfs = initialFilesystem, rootfs.isBlock {
            _ = try allocator.allocate()
            disks.append(rootfs)
        }
        for id in mountsByID.keys.sorted() {
            var perContainer: [AttachedFilesystem] = []
            for mount in mountsByID[id] ?? [] {
                perContainer.append(try AttachedFilesystem(mount: mount, allocator: allocator))
                if mount.isBlock {
                    disks.append(mount)
                }
            }
            attachments[id] = perContainer
        }
        return (attachments, disks)
    }
}
#endif
