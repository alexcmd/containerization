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
import Foundation
import Logging
import NIOCore

/// How the guest sees the host GPU under the libkrun backend.
///
/// Each mode maps to a set of virglrenderer flags passed to the `krun-vmm`
/// helper. Only Venus (Vulkan forwarding) is wired today. OpenGL paths are
/// expected to land as new cases once one is proven on macOS hosts:
/// - guest-side GL over Venus (ANGLE or a patched Zink) needs no new host
///   flags, so it reuses `.venus` and only changes the guest image;
/// - host-side GL (virgl) or DRM native contexts would add their own cases.
/// `.flags(_:)` passes raw `VIRGLRENDERER_*` bits through for experiments.
public enum KrunGPUMode: Sendable, Equatable {
    /// No virtio-gpu device.
    case none
    /// Virtio-GPU with Venus: Vulkan in the guest, forwarded to the host's
    /// Vulkan driver (MoltenVK).
    ///
    /// Guest requirements: Mesa 26.x or newer, and a kernel whose virtio-gpu
    /// driver negotiates `VIRTIO_GPU_F_BLOB_ALIGNMENT` (Linux 7.2+). macOS
    /// maps host-visible blobs at 16 KiB; without the feature a 4 KiB-page
    /// guest maps Venus's ring at the wrong alignment and `vkCreateInstance`
    /// fails with `VK_ERROR_OUT_OF_HOST_MEMORY`.
    case venus
    /// Raw virglrenderer flags, for experimenting with other GPU paths.
    case flags(UInt32)

    var helperArguments: [String] {
        switch self {
        case .none:
            return ["--gpu", "none"]
        case .venus:
            return ["--gpu", "venus"]
        case .flags(let bits):
            return ["--gpu-flags", String(bits)]
        }
    }
}

/// A `VirtualMachineManager` that runs each VM under libkrun via the
/// `krun-vmm` helper binary (libkrun takes over the calling process, so the
/// VM cannot run in-process).
///
/// Unlike Virtualization.framework, libkrun exposes the Venus virtio-gpu
/// device on macOS 26 without private entitlements.
public struct KrunVirtualMachineManager: VirtualMachineManager {
    private let kernel: Kernel
    private let initialFilesystem: Mount
    private let helperBinary: URL
    private let runtimeRoot: URL
    private let gpu: KrunGPUMode
    private let group: (any EventLoopGroup)?
    private let logger: Logger?

    /// - Parameters:
    ///   - kernel: The guest kernel. Must be an uncompressed arm64 `Image`
    ///     with virtio-mmio support (the in-repo `kernel/config-arm64`).
    ///   - initialFilesystem: The vminitd rootfs (block or virtiofs).
    ///   - helperBinary: Path to `krun-vmm`. Defaults to a lookup on `PATH`.
    ///   - runtimeRoot: Directory for per-VM sockets. Keep it short: macOS
    ///     limits UNIX socket paths to 104 bytes.
    ///   - gpu: GPU exposure mode.
    public init(
        kernel: Kernel,
        initialFilesystem: Mount,
        helperBinary: URL? = nil,
        runtimeRoot: URL? = nil,
        gpu: KrunGPUMode = .none,
        group: (any EventLoopGroup)? = nil,
        logger: Logger? = nil
    ) throws {
        self.kernel = kernel
        self.initialFilesystem = initialFilesystem
        self.helperBinary = try Self.resolveBinary(helperBinary, name: "krun-vmm")
        let runtimeRoot = try runtimeRoot ?? Self.defaultRuntimeRoot()
        try FileManager.default.createDirectory(
            at: runtimeRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // The vminitd gRPC channel has no peer authentication, so the socket
        // directory's ownership and mode are the trust boundary: refuse a
        // directory someone else created or opened up.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtimeRoot.path)
        var st = stat()
        guard lstat(runtimeRoot.path, &st) == 0, st.st_uid == getuid(), (st.st_mode & S_IFMT) == S_IFDIR, st.st_mode & 0o077 == 0 else {
            throw ContainerizationError(.invalidState, message: "runtime root \(runtimeRoot.path) must be a directory owned by uid \(getuid()) with mode 0700")
        }
        self.runtimeRoot = runtimeRoot
        self.gpu = gpu
        self.group = group
        self.logger = logger
    }

    public func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        let vmConfig = config.configuration
        if vmConfig.nestedVirtualization {
            throw ContainerizationError(.unsupported, message: "nested virtualization is not supported by the libkrun backend")
        }

        var instanceConfig = KrunVirtualMachineInstance.Configuration()
        instanceConfig.cpus = vmConfig.cpus
        instanceConfig.memoryInBytes = vmConfig.memoryInBytes
        instanceConfig.interfaces = vmConfig.interfaces
        instanceConfig.mountsByID = vmConfig.mountsByID
        instanceConfig.bootLog = vmConfig.bootLog
        instanceConfig.kernel = kernel
        instanceConfig.initialFilesystem = initialFilesystem
        instanceConfig.gpu = gpu

        return try KrunVirtualMachineInstance(
            group: group,
            config: instanceConfig,
            runtimeRoot: runtimeRoot,
            helperBinary: helperBinary,
            logger: logger
        )
    }

    /// `<per-user temp dir>/krun`, e.g. `/var/folders/xx/…/T/krun`. Per-user
    /// (not shared `/tmp`) and short enough that per-VM socket paths stay well
    /// under the 104-byte `sun_path` limit.
    static func defaultRuntimeRoot() throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard len > 0, len <= buffer.count else {
            throw ContainerizationError(.internalError, message: "could not resolve the per-user temporary directory")
        }
        let base = String(decoding: buffer.prefix(len - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: base).appendingPathComponent("krun")
    }

    static func resolveBinary(_ override: URL?, name: String) throws -> URL {
        if let override {
            guard FileManager.default.isExecutableFile(atPath: override.path) else {
                throw ContainerizationError(.notFound, message: "\(name) not executable at \(override.path)")
            }
            return override
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw ContainerizationError(
            .notFound,
            message: "could not find \(name) on PATH; pass an explicit URL to KrunVirtualMachineManager.init"
        )
    }
}
#endif
