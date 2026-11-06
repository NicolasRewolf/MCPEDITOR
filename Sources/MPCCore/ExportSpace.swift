import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public struct ExportVolumeSpace: Equatable, Sendable {
    public let allocationUnitBytes: Int64
    public let availableBytes: Int64
    public let reservesAppleDouble: Bool

    public init(allocationUnitBytes: Int64, availableBytes: Int64, reservesAppleDouble: Bool = true) {
        self.allocationUnitBytes = allocationUnitBytes
        self.availableBytes = availableBytes
        self.reservesAppleDouble = reservesAppleDouble
    }
}

public struct ExportSpaceEstimate: Equatable, Sendable {
    public let nominalBytes: Int64
    public let allocatedBytes: Int64
    public let metadataBytes: Int64
    public let reserveBytes: Int64
    public var requiredBytes: Int64 { allocatedBytes + metadataBytes + reserveBytes }
}

public enum ExportSpaceError: LocalizedError {
    case unavailable
    case invalidSize
    case insufficientSpace(required: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return
                String(localized: "Impossible de vérifier l’espace libre. Rebranche le disque puis actualise la bibliothèque.")
        case .invalidSize: return String(localized: "La taille nécessaire à l’enregistrement ne peut pas être calculée.")
        case .insufficientSpace(let required, let available):
            let needed = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return
                String(localized: "Espace insuffisant : \(needed) nécessaires, \(free) libres, avec l’allocation et les métadonnées macOS. Choisis une autre destination ou raccourcis les sons.")
        }
    }
}

/// Filesystem allocation, possible AppleDouble files and directory overhead are separate from PCM memory.
public enum ExportSpace {
    public static func volume(at url: URL) throws -> ExportVolumeSpace {
        let fd = url.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard fd >= 0 else { throw ExportSpaceError.unavailable }
        defer { _ = close(fd) }
        return try volume(directoryFD: fd)
    }

    public static func volume(directoryFD: Int32) throws -> ExportVolumeSpace {
        var values = statvfs()
        guard fstatvfs(directoryFD, &values) == 0 else { throw ExportSpaceError.unavailable }
        let unit = UInt64(values.f_frsize)  // f_bsize is preferred I/O, not the allocation unit.
        let (available, overflow) = UInt64(values.f_bavail).multipliedReportingOverflow(by: unit)
        guard unit > 0, unit <= UInt64(Int64.max), !overflow, available <= UInt64(Int64.max) else {
            throw ExportSpaceError.unavailable
        }
        var reservesMetadata = true
        #if canImport(Darwin)
            var filesystem = statfs()
            if fstatfs(directoryFD, &filesystem) == 0 {
                let name = withUnsafePointer(to: &filesystem.f_fstypename) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
                        String(cString: $0)
                    }
                }
                reservesMetadata = !["apfs", "hfs"].contains(name.lowercased())
            }
        #endif
        return ExportVolumeSpace(
            allocationUnitBytes: Int64(unit), availableBytes: Int64(available),
            reservesAppleDouble: reservesMetadata)
    }

    public static func estimate(fileSizes: [Int], volume: ExportVolumeSpace) throws
        -> ExportSpaceEstimate
    {
        let unit = volume.allocationUnitBytes
        guard unit > 0, volume.availableBytes >= 0 else { throw ExportSpaceError.invalidSize }
        func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else { throw ExportSpaceError.invalidSize }
            return sum
        }
        func roundUp(_ bytes: Int64) throws -> Int64 {
            if bytes == 0 { return 0 }
            let blocks = try add((bytes - 1) / unit, 1)
            let (rounded, overflow) = blocks.multipliedReportingOverflow(by: unit)
            guard !overflow else { throw ExportSpaceError.invalidSize }
            return rounded
        }
        var nominal: Int64 = 0
        var allocation: Int64 = 0
        var metadata: Int64 = 0
        for size in fileSizes {
            guard size >= 0 else { throw ExportSpaceError.invalidSize }
            nominal = try add(nominal, Int64(size))
            allocation = try add(allocation, try roundUp(Int64(size)))
            if volume.reservesAppleDouble { metadata = try add(metadata, try roundUp(4096)) }
        }
        let reserve = max(65_536, try add(unit, unit))
        _ = try add(try add(allocation, metadata), reserve)
        return ExportSpaceEstimate(
            nominalBytes: nominal, allocatedBytes: allocation,
            metadataBytes: metadata, reserveBytes: reserve)
    }
}
