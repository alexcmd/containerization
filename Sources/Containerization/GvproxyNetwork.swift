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
import Foundation

/// An interface backed by a per-VM gvproxy (gvisor-tap-vsock) userspace NAT.
///
/// The libkrun backend starts one gvproxy per VM and attaches it as a
/// virtio-net device. Every VM gets its own private subnet, so all VMs can use
/// the same addresses: guest `192.168.127.2/24`, gateway and DNS
/// `192.168.127.1`. gvproxy needs no privileges or entitlements.
public struct GvproxyInterface: Interface {
    public var ipv4Address: CIDRv4
    public var ipv4Gateway: IPv4Address?
    public var macAddress: MACAddress?
    public var mtu: UInt32

    /// The DNS server gvproxy answers on (its gateway address).
    public var nameserver: String { ipv4Gateway?.description ?? "192.168.127.1" }

    public init(
        ipv4Address: CIDRv4,
        ipv4Gateway: IPv4Address,
        macAddress: MACAddress,
        mtu: UInt32 = 1500
    ) {
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
        self.mtu = mtu
    }

    /// gvproxy's default subnet layout.
    public static func defaultInterface() throws -> GvproxyInterface {
        GvproxyInterface(
            ipv4Address: try CIDRv4("192.168.127.2/24"),
            ipv4Gateway: try IPv4Address("192.168.127.1"),
            macAddress: try MACAddress("5a:94:ef:e4:0c:ee")
        )
    }
}

/// A `Network` for the libkrun backend: hands out `GvproxyInterface`s. The
/// gvproxy process itself is owned by the VM (see `KrunVirtualMachineInstance`),
/// so there is nothing to allocate or release here beyond the interface value.
public struct GvproxyNetwork: Network {
    public init() {}

    public mutating func createInterface(_ id: String) throws -> Interface? {
        try GvproxyInterface.defaultInterface()
    }

    public mutating func releaseInterface(_ id: String) throws {}
}
#endif
