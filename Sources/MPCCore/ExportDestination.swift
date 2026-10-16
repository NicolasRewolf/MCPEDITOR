import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ExportDestinationError: LocalizedError {
    case changed
    case notEmpty
    case unverified(String)

    public var errorDescription: String? {
        switch self {
        case .changed:
            return "La destination a changé depuis sa sélection. Actualise la bibliothèque puis choisis-la à nouveau. Aucun fichier n’a été créé."
        case .notEmpty:
            return "La PART proposée n’est plus vide. Actualise la bibliothèque puis choisis une autre destination. Aucun fichier n’a été créé."
        case .unverified(let detail):
            return "Cette destination doit être vérifiée avant l’enregistrement. \(detail) Aucun fichier n’a été créé."
        }
    }
}

/// A read-only selection receipt. It holds no descriptor, so it does not prevent ejecting a card.
/// The exporter checks this identity again on its actual write directory before creating files.
public struct ExportDestination: Equatable, Sendable {
    public let url: URL
    public let requireEmpty: Bool
    public let isMountedMPCPartition: Bool
    private let canonicalURL: URL
    private let directoryIdentity: DirectoryIdentity
    private let mountIdentity: MountIdentity

    struct DirectoryIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
    }

    struct MountIdentity: Equatable, Sendable {
        let filesystem: String
        let identifier: String
        let mountedFrom: String
        let mountPoint: URL
    }

    struct FATVolumeUsage: Equatable {
        let allocationUnitBytes: Int64
        /// Allocated bytes in the FAT data-cluster pool, excluding filesystem counter offsets.
        let occupiedBytes: Int64
        let rootAllocationIsFixed: Bool

        init(allocationUnitBytes: Int64, occupiedBytes: Int64, rootAllocationIsFixed: Bool = false) {
            self.allocationUnitBytes = allocationUnitBytes
            self.occupiedBytes = occupiedBytes
            self.rootAllocationIsFixed = rootAllocationIsFixed
        }
    }

    /// Native probes are injected only by tests; production always uses descriptor-based syscalls.
    struct Environment {
        var mount: (Int32) throws -> MountIdentity = nativeMount
        var fatUsage: (Int32) throws -> FATVolumeUsage? = nativeFATUsage
        var names: (Int32) throws -> [String] = nativeNames
    }

    public static func capture(at url: URL, requireEmpty: Bool = false) throws -> ExportDestination {
        try capture(at: url, requireEmpty: requireEmpty, environment: Environment())
    }

    static func capture(at url: URL, requireEmpty: Bool = false,
                        environment: Environment) throws -> ExportDestination {
        guard url.isFileURL else { throw KitExportError.invalidDestination }
        let selected = url.standardizedFileURL
        let canonical = try resolvedDirectoryURL(selected)
        let descriptor = try openDirectory(canonical)
        defer { _ = close(descriptor) }
        let identity = try directoryIdentity(descriptor)
        let mount = try environment.mount(descriptor)
        let mountedMPC = try validateMount(mount, selectedURL: canonical)
        let receipt = ExportDestination(url: selected, requireEmpty: requireEmpty,
                                        isMountedMPCPartition: mountedMPC,
                                        canonicalURL: canonical, directoryIdentity: identity,
                                        mountIdentity: mount)
        try receipt.validate(directoryFD: descriptor, selectedURL: selected, environment: environment)
        return receipt
    }

    /// Preserve the captured identity; recapturing at the final click would hide a stale proposal.
    public func requiringEmpty() -> ExportDestination {
        ExportDestination(url: url, requireEmpty: true, isMountedMPCPartition: isMountedMPCPartition,
                          canonicalURL: canonicalURL, directoryIdentity: directoryIdentity,
                          mountIdentity: mountIdentity)
    }

    func openWriteDirectory(selectedURL: URL) throws -> Int32 {
        guard selectedURL.standardizedFileURL.path == url.path,
              try Self.resolvedDirectoryURL(selectedURL).path == canonicalURL.path else {
            throw ExportDestinationError.changed
        }
        return try Self.openDirectory(canonicalURL)
    }

    /// Bind the live write descriptor to the selected path and captured volume. Unlike
    /// preflight, this remains usable after our own files have made an empty PART busy.
    func validateLocation(directoryFD: Int32, selectedURL: URL,
                          environment: Environment = Environment()) throws {
        guard selectedURL.standardizedFileURL.path == url.path,
              try Self.resolvedDirectoryURL(selectedURL).path == canonicalURL.path,
              try Self.directoryIdentity(directoryFD) == directoryIdentity else {
            throw ExportDestinationError.changed
        }
        let currentMount = try environment.mount(directoryFD)
        guard currentMount == mountIdentity else { throw ExportDestinationError.changed }
        _ = try Self.validateMount(currentMount, selectedURL: canonicalURL)
        // Reopening also detects a renamed directory whose held descriptor remains valid.
        let pathDescriptor = try Self.openDirectory(canonicalURL)
        defer { _ = close(pathDescriptor) }
        guard try Self.resolvedDirectoryURL(selectedURL).path == canonicalURL.path,
              try Self.directoryIdentity(directoryFD) == directoryIdentity,
              try Self.directoryIdentity(pathDescriptor) == directoryIdentity,
              try environment.mount(directoryFD) == mountIdentity,
              try environment.mount(pathDescriptor) == mountIdentity else { throw ExportDestinationError.changed }
    }

    func validate(directoryFD: Int32, selectedURL: URL,
                  environment: Environment = Environment()) throws {
        try validateLocation(directoryFD: directoryFD, selectedURL: selectedURL, environment: environment)
        let currentMount = try environment.mount(directoryFD)
        if currentMount.filesystem == "msdos" {
            let root = try Self.openDirectory(Self.resolvedDirectoryURL(currentMount.mountPoint))
            defer { _ = close(root) }
            guard try environment.mount(root) == currentMount else { throw ExportDestinationError.changed }
            try Self.verifyFATInventory(directoryFD: root, requireEmpty: false, environment: environment)
        }
        if requireEmpty {
            let names = try environment.names(directoryFD)
            guard !names.contains(where: { !$0.hasPrefix(".") }) else { throw ExportDestinationError.notEmpty }
        }
        // Inventory is not an atomic snapshot; bind the path once more after reading it.
        try validateLocation(directoryFD: directoryFD, selectedURL: selectedURL, environment: environment)
    }

    private static func validateMount(_ mount: MountIdentity, selectedURL: URL) throws -> Bool {
        let mpcAncestor = selectedURL.pathComponents.enumerated().first { _, component in
            LibraryIndex.partitionLetter(for: URL(fileURLWithPath: "/" + component)) != nil
        }.map { offset, _ in URL(fileURLWithPath: NSString.path(withComponents: Array(selectedURL.pathComponents.prefix(offset + 1)))) }
        if let mpcAncestor {
            guard mount.filesystem == "msdos", mount.mountPoint.standardizedFileURL == mpcAncestor.standardizedFileURL else {
                throw ExportDestinationError.unverified("Le dossier portant ce nom de PART n’est pas une partition FAT montée.")
            }
        }
        return mount.filesystem == "msdos" &&
            LibraryIndex.partitionLetter(for: mount.mountPoint) != nil &&
            mount.mountPoint.standardizedFileURL == selectedURL.standardizedFileURL
    }

    private static func resolvedDirectoryURL(_ url: URL) throws -> URL {
        guard let resolved = url.path.withCString({ realpath($0, nil) }) else {
            throw ExportDestinationError.changed
        }
        defer { free(resolved) }
        // Foundation deliberately maps /private/var back to /var, which is a symlink.
        // Preserve realpath's components for the no-follow walk instead.
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Resolve the selected path once, then walk each component without following a newly swapped link.
    static func openDirectory(_ canonical: URL) throws -> Int32 {
        let components = canonical.pathComponents.filter { $0 != "/" }
        #if canImport(Darwin)
        // Traversal needs search permission, not enumeration of every ancestor.
        // Reading protected parents (e.g. Desktop) can trigger unrelated access
        // requests even when the user has selected the leaf in NSOpenPanel.
        let ancestorFlags = O_SEARCH | O_NOFOLLOW | O_CLOEXEC
        #else
        let ancestorFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        #endif
        let leafFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = open("/", components.isEmpty ? leafFlags : ancestorFlags)
        guard descriptor >= 0 else { throw KitExportError.invalidDestination }
        for (index, component) in components.enumerated() {
            let flags = index == components.count - 1 ? leafFlags : ancestorFlags
            let next = component.withCString { openat(descriptor, $0, flags) }
            _ = close(descriptor)
            guard next >= 0 else { throw ExportDestinationError.changed }
            descriptor = next
        }
        return descriptor
    }

    private static func directoryIdentity(_ descriptor: Int32) throws -> DirectoryIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw ExportDestinationError.changed
        }
        #if canImport(Darwin)
        return DirectoryIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino),
                                 birthSeconds: Int64(info.st_birthtimespec.tv_sec),
                                 birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
        #else
        return DirectoryIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino),
                                 birthSeconds: 0, birthNanoseconds: 0)
        #endif
    }

    static func nativeMount(_ descriptor: Int32) throws -> MountIdentity {
        #if canImport(Darwin)
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0 else {
            throw ExportDestinationError.unverified("Le montage n’est pas accessible.")
        }
        func string<T>(_ tuple: inout T) -> String {
            withUnsafePointer(to: &tuple) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
            }
        }
        let filesystem = string(&info.f_fstypename).lowercased()
        var identifier = "\(info.f_fsid.val.0):\(info.f_fsid.val.1)"
        // A FAT fsid can be derived from the device number and reused after ejecting.
        // Read the volume UUID from this descriptor to distinguish replacement media.
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_UUID)
        var bytes = [UInt8](repeating: 0, count: 20)
        let readUUID = bytes.withUnsafeMutableBytes {
            fgetattrlist(descriptor, &attributes, $0.baseAddress, $0.count, 0)
        }
        let length = bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        if readUUID == 0, length == 20, bytes.dropFirst(4).contains(where: { $0 != 0 }) {
            identifier += ":" + bytes.dropFirst(4).map { String(format: "%02x", $0) }.joined()
        } else if filesystem == "msdos" {
            throw ExportDestinationError.unverified("L’identité du volume FAT n’est pas accessible.")
        }
        return MountIdentity(filesystem: filesystem, identifier: identifier,
                             mountedFrom: string(&info.f_mntfromname),
                             mountPoint: URL(fileURLWithPath: string(&info.f_mntonname), isDirectory: true).standardizedFileURL)
        #else
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ExportDestinationError.changed }
        return MountIdentity(filesystem: "local", identifier: "\(info.st_dev)", mountedFrom: "", mountPoint: URL(fileURLWithPath: "/"))
        #endif
    }

    static func nativeFATUsage(_ descriptor: Int32) throws -> FATVolumeUsage? {
        #if canImport(Darwin)
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0 else {
            throw ExportDestinationError.unverified("Le format de la partition n’est pas accessible.")
        }
        let name = withUnsafePointer(to: &filesystem.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
        }
        guard name == "msdos" else { return nil }
        var values = statvfs()
        guard fstatvfs(descriptor, &values) == 0, values.f_frsize > 0,
              values.f_blocks >= values.f_bfree else {
            throw ExportDestinationError.unverified("L’occupation FAT n’est pas accessible.")
        }
        // FSKit explicitly publishes 0=FAT12, 1=FAT16, 2=FAT32 from its BPB-derived type:
        // apple-oss-distributions/msdosfs c9f076c4, msdosVolume.m:153-174 / FATVolume.m:1178.
        return try normalizedFATUsage(
            allocationUnitBytes: UInt64(values.f_frsize),
            totalBlocks: UInt64(values.f_blocks), freeBlocks: UInt64(values.f_bfree),
            isFSKit: filesystem.f_flags_ext & UInt32(MNT_EXT_FSKIT) != 0,
            rootAllocationIsFixed: filesystem.f_fssubtype == 0 || filesystem.f_fssubtype == 1)
        #else
        return nil
        #endif
    }

    /// FSKit FATVolume publishes maxValidCluster=dataClusters+1; the legacy kernel
    /// driver publishes dataClusters. Their used-block values must be normalized before
    /// comparing with file allocation. FAT12/16's fixed root is outside that data pool.
    /// Apple source: msdos_appex/FATVolume.m volumeStatistics; msdosItem.m getAttributes.
    static func normalizedFATUsage(allocationUnitBytes unit: UInt64,
                                   totalBlocks: UInt64, freeBlocks: UInt64,
                                   isFSKit: Bool, rootAllocationIsFixed: Bool) throws -> FATVolumeUsage {
        guard unit > 0, totalBlocks >= freeBlocks else {
            throw ExportDestinationError.unverified("Le compteur FAT est incohérent.")
        }
        var occupiedBlocks = totalBlocks - freeBlocks
        if isFSKit {
            guard occupiedBlocks > 0 else { throw ExportDestinationError.unverified("Le compteur FAT est incohérent.") }
            occupiedBlocks -= 1
        }
        let (occupied, overflow) = occupiedBlocks.multipliedReportingOverflow(by: unit)
        guard !overflow, unit <= UInt64(Int64.max), occupied <= UInt64(Int64.max) else {
            throw ExportDestinationError.unverified("L’occupation FAT ne peut pas être calculée.")
        }
        return FATVolumeUsage(allocationUnitBytes: Int64(unit), occupiedBytes: Int64(occupied),
                              rootAllocationIsFixed: rootAllocationIsFixed)
    }

    /// An independent directory stream avoids sharing and advancing the write descriptor's offset.
    static func nativeNames(directoryFD: Int32) throws -> [String] {
        let copy = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard copy >= 0 else { throw ExportDestinationError.unverified("Le dossier ne peut pas être inventorié.") }
        guard let stream = fdopendir(copy) else {
            _ = close(copy)
            throw ExportDestinationError.unverified("Le dossier ne peut pas être inventorié.")
        }
        defer { _ = closedir(stream) }
        var names: [String] = []
        var unique: Set<String> = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ExportDestinationError.unverified("La lecture du dossier est incomplète.") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard names.count < 50_000, unique.insert(name).inserted else {
                throw ExportDestinationError.unverified("Le dossier est incomplet ou contient des noms répétés.")
            }
            names.append(name)
        }
        return names
    }

    /// All files, including hidden entries, must explain the FAT volume's allocation.
    /// This is a bounded consistency check, not a repair or a claim of filesystem atomicity.
    static func verifyFATInventory(directoryFD: Int32, requireEmpty: Bool,
                                   maximumDepth: Int = 8, maximumEntries: Int = 50_000,
                                   environment: Environment, allowNonFAT: Bool = false) throws {
        let usage = try environment.fatUsage(directoryFD)
        if usage == nil, allowNonFAT { return }
        guard let before = usage, before.allocationUnitBytes > 0,
              before.occupiedBytes >= 0, maximumDepth >= 0, maximumEntries > 0 else {
            throw ExportDestinationError.unverified("L’occupation FAT n’est pas vérifiable.")
        }
        var root = stat()
        guard fstat(directoryFD, &root) == 0 else { throw ExportDestinationError.changed }
        var accounted: Int64 = 0
        var visited = 0
        var allocatedIdentities: Set<String> = []
        func account(_ info: stat) throws {
            guard info.st_dev == root.st_dev, info.st_blocks >= 0 else {
                throw ExportDestinationError.unverified("L’inventaire traverse un emplacement indéterminé.")
            }
            let (bytes, overflow) = Int64(info.st_blocks).multipliedReportingOverflow(by: 512)
            let (sum, sumOverflow) = accounted.addingReportingOverflow(bytes)
            guard !overflow, !sumOverflow else { throw ExportDestinationError.unverified("L’allocation ne peut pas être calculée.") }
            if bytes > 0, !allocatedIdentities.insert("\(info.st_dev):\(info.st_ino)").inserted {
                throw ExportDestinationError.unverified("L’inventaire contient des allocations répétées.")
            }
            accounted = sum
        }
        func inventory(_ directory: Int32, depth: Int) throws {
            let names = try environment.names(directory)
            var insensitiveNames: Set<String> = []
            for name in names {
                guard visited < maximumEntries, insensitiveNames.insert(name.uppercased()).inserted else {
                    throw ExportDestinationError.unverified("L’inventaire est incomplet ou contient des noms ambigus.")
                }
                visited += 1
                if requireEmpty, depth == 0, !name.hasPrefix(".") { throw ExportDestinationError.notEmpty }
                var info = stat()
                guard name.withCString({ fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                    throw ExportDestinationError.unverified("Une entrée de l’inventaire est indisponible.")
                }
                let type = info.st_mode & mode_t(S_IFMT)
                guard type == mode_t(S_IFREG) || type == mode_t(S_IFDIR) else {
                    throw ExportDestinationError.unverified("L’inventaire contient un lien ou un type indéterminé.")
                }
                try account(info)
                if type == mode_t(S_IFDIR) {
                    guard depth < maximumDepth else { throw ExportDestinationError.unverified("L’inventaire dépasse la profondeur autorisée.") }
                    let child = name.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
                    guard child >= 0 else { throw ExportDestinationError.unverified("Un dossier ne peut pas être parcouru.") }
                    defer { _ = close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
                        throw ExportDestinationError.changed
                    }
                    try inventory(child, depth: depth + 1)
                }
            }
        }
        if !before.rootAllocationIsFixed { try account(root) }
        try inventory(directoryFD, depth: 0)
        guard let after = try environment.fatUsage(directoryFD), after == before else {
            throw ExportDestinationError.unverified("L’occupation FAT a changé pendant la vérification.")
        }
        guard before.occupiedBytes == accounted else {
            let detail = before.occupiedBytes > accounted
                ? "\(before.occupiedBytes - accounted) octets occupés ne sont pas expliqués par l’inventaire."
                : "L’allocation annoncée ne correspond pas à l’inventaire."
            throw ExportDestinationError.unverified(detail)
        }
    }
}
