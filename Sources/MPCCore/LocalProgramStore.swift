import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A local .PGM collection. Each save creates a complete native revision, then
/// publishes one small manifest atomically. Imported files are never a write target.
/// Only the current revision appears in the library. Native revisions are retained
/// for recovery: no automatic unlink can safely exclude an external replacement
/// between checking its identity and deleting its name.
public struct LocalProgramStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) { self.rootURL = rootURL.standardizedFileURL }

    public struct ScanResult: Sendable {
        public let kits: [LibraryKit]
        public let issues: [String]
    }

    public enum Failure: LocalizedError {
        case unavailable, changed, invalidManifest, staleProgram

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                return "La bibliothèque locale ne peut pas être ouverte en toute sécurité."
            case .changed:
                return "La bibliothèque locale a changé pendant l’enregistrement. La version précédente reste disponible."
            case .invalidManifest:
                return "Un enregistrement de la bibliothèque locale est incomplet ou a été modifié. Aucun original n’a été remplacé."
            case .staleProgram:
                return "Ce .PGM local n’est plus la version courante. Rouvre-le depuis la bibliothèque avant de l’enregistrer."
            }
        }
    }

    private static let rootMarker = ".mpc-library.json"
    private static let manifestName = ".mpc-program.json"

    private struct Identity: Codable { let version: Int; let store: UUID }
    private struct FileRecord: Codable, Equatable {
        let bytes: Int
        let sha256: String
        init(_ data: Data) {
            bytes = data.count
            sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
    private struct Revision: Codable {
        let id: UUID
        let program: String
        let files: [String: FileRecord]
    }
    private struct Manifest: Codable {
        let version: Int
        let store: UUID
        let document: UUID
        let current: Revision
        let previous: Revision?
    }

    /// Ownership requires the store and document manifests, the current revision,
    /// a regular native file and a matching program fingerprint. A path prefix is
    /// never sufficient. This read does not create a library on disk.
    public func contains(_ programURL: URL) -> Bool {
        (try? withRoot(create: false, exclusive: false) { root, identity, _ in
            guard let document = documentID(for: programURL) else { return false }
            return try withDirectory(document.uuidString, in: root) { directory in
                let manifest = try readManifest(directory, document: document, store: identity.store)
                guard currentURL(manifest) == programURL.standardizedFileURL else { return false }
                return try currentProgramExists(manifest, directory: directory)
            }
        }) ?? false
    }

    /// A missing collection is an empty collection. Unknown files and directories
    /// are ignored; a damaged owned manifest is reported rather than called empty.
    public func scan() -> ScanResult {
        guard exists(rootURL) else { return ScanResult(kits: [], issues: []) }
        do {
            return try withRoot(create: false, exclusive: false) { root, identity, _ in
                var kits: [LibraryKit] = []
                var issues: [String] = []
                for name in try names(root) {
                    guard let document = UUID(uuidString: name), name == document.uuidString else { continue }
                    do {
                        try withDirectory(name, in: root) { directory in
                            guard try entryExists(Self.manifestName, in: directory) else { return }
                            let manifest = try readManifest(directory, document: document, store: identity.store)
                            // Trashing a .PGM must not resurrect an older revision.
                            guard try currentProgramExists(manifest, directory: directory) else { return }
                            kits.append(LibraryKit(url: currentURL(manifest), rootURL: rootURL,
                                                   partitionLetter: nil, relativeFolder: ""))
                        }
                    } catch {
                        issues.append("Bibliothèque locale · \(name) : \(error.localizedDescription)")
                    }
                }
                return ScanResult(kits: kits.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
                                  issues: issues)
            }
        } catch {
            return ScanResult(kits: [], issues: [error.localizedDescription])
        }
    }

    /// Compatibility for callers that only need the accessible programs.
    /// Present scan().issues alongside them when completeness matters.
    public func scanKits() throws -> [LibraryKit] { scan().kits }

    public func save(program: MPCProgram, sounds: [Int: MPCSound], name: String,
                     existingProgramURL: URL?) throws -> URL {
        try save(program: program, sounds: sounds, name: name,
                 existingProgramURL: existingProgramURL, beforePublication: {})
    }

    /// The narrow test seam models an interruption after every native body has
    /// been written but before the new revision becomes visible.
    func save(program: MPCProgram, sounds: [Int: MPCSound], name: String,
              existingProgramURL: URL?, beforePublication: () throws -> Void) throws -> URL {
        _ = try KitExport.prepareCopy(program: program, sounds: sounds)
        return try withRoot(create: true, exclusive: true) { root, identity, receipt in
            let document: UUID
            var old: Manifest?
            if let existingProgramURL, isInsideRoot(existingProgramURL) {
                guard let existingDocument = documentID(for: existingProgramURL) else { throw Failure.staleProgram }
                document = existingDocument
                old = try withDirectory(document.uuidString, in: root) { directory in
                    let manifest = try readManifest(directory, document: document, store: identity.store)
                    guard currentURL(manifest) == existingProgramURL.standardizedFileURL,
                          try currentProgramExists(manifest, directory: directory) else { throw Failure.staleProgram }
                    return manifest
                }
            } else {
                document = UUID()
                try makeDirectory(document.uuidString, in: root)
            }

            return try withDirectory(document.uuidString, in: root) { directory in
                let revisionID = UUID()
                try makeDirectory(revisionID.uuidString, in: directory)
                let revisionURL = rootURL.appendingPathComponent(document.uuidString, isDirectory: true)
                    .appendingPathComponent(revisionID.uuidString, isDirectory: true)
                let exported = try KitExport.export(program: program, sounds: sounds, name: name, to: revisionURL)
                return try withDirectory(revisionID.uuidString, in: directory) { revisionDirectory in
                    var inventory: [String: FileRecord] = [:]
                    for filename in try names(revisionDirectory) {
                        guard ["PGM", "SND"].contains((filename as NSString).pathExtension) else {
                            throw Failure.changed
                        }
                        inventory[filename] = FileRecord(try read(filename, in: revisionDirectory,
                                                                    limit: MPCSound.maximumFileBytes + 1))
                    }
                    let revision = Revision(id: revisionID, program: exported.lastPathComponent, files: inventory)
                    let manifest = Manifest(version: 1, store: identity.store, document: document,
                                            current: revision, previous: old?.current)
                    try beforePublication()
                    try receipt.validate(directoryFD: root, selectedURL: rootURL)
                    // The root lock serializes our writers. Revalidate the complete
                    // staged revision too: outside applications do not take this lock.
                    try verifyDirectory(directory, name: document.uuidString, in: root)
                    try verifyDirectory(revisionDirectory, name: revisionID.uuidString, in: directory)
                    guard Set(try names(revisionDirectory)) == Set(revision.files.keys) else { throw Failure.changed }
                    for (filename, record) in revision.files {
                        guard FileRecord(try read(filename, in: revisionDirectory, limit: record.bytes + 1)) == record else {
                            throw Failure.changed
                        }
                    }
                    if let old {
                        let current = try readManifest(directory, document: document, store: identity.store)
                        guard current.current.id == old.current.id else { throw Failure.changed }
                    } else if try entryExists(Self.manifestName, in: directory) { throw Failure.changed }
                    // Persist a new document's entry in its parent as well.
                    guard fsync(root) == 0 else { throw Failure.unavailable }
                    try publish(try JSONEncoder().encode(manifest), name: Self.manifestName, in: directory)
                    return currentURL(manifest)
                }
            }
        }
    }

    private func withRoot<T>(create: Bool, exclusive: Bool,
                             _ operation: (Int32, Identity, ExportDestination) throws -> T) throws -> T {
        guard rootURL.isFileURL else { throw Failure.unavailable }
        if create && !exists(rootURL) {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard rootURL.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unavailable }
        let receipt = try ExportDestination.capture(at: rootURL)
        // This is a Mac library, never an alternative SD export path.
        let root = try receipt.openWriteDirectory(selectedURL: rootURL)
        defer { _ = close(root) }
        guard try ExportDestination.nativeMount(root).filesystem != "msdos",
              flock(root, exclusive ? LOCK_EX : LOCK_SH) == 0 else { throw Failure.unavailable }
        defer { _ = flock(root, LOCK_UN) }
        try receipt.validate(directoryFD: root, selectedURL: rootURL)
        let identity: Identity
        if try entryExists(Self.rootMarker, in: root) {
            identity = try JSONDecoder().decode(Identity.self, from: read(Self.rootMarker, in: root, limit: 4096))
            guard identity.version == 1 else { throw Failure.invalidManifest }
        } else {
            guard create else { throw Failure.invalidManifest }
            identity = Identity(version: 1, store: UUID())
            try publish(try JSONEncoder().encode(identity), name: Self.rootMarker, in: root)
        }
        return try operation(root, identity, receipt)
    }

    private func readManifest(_ directory: Int32, document: UUID, store: UUID) throws -> Manifest {
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: read(Self.manifestName, in: directory, limit: 65_536)) }
        catch { throw Failure.invalidManifest }
        guard manifest.version == 1, manifest.document == document, manifest.store == store,
              valid(manifest.current), manifest.previous.map(valid) ?? true else { throw Failure.invalidManifest }
        return manifest
    }

    private func valid(_ revision: Revision) -> Bool {
        guard revision.program.hasSuffix(".PGM"), revision.files[revision.program] != nil,
              (1...129).contains(revision.files.count) else { return false }
        return revision.files.allSatisfy { filename, record in
            !filename.isEmpty && filename != "." && filename != ".." && !filename.contains("/") &&
                ["PGM", "SND"].contains((filename as NSString).pathExtension) &&
                record.bytes >= 0 && record.bytes <= MPCSound.maximumFileBytes + 1 && record.sha256.count == 64
        }
    }

    private func currentProgramExists(_ manifest: Manifest, directory: Int32) throws -> Bool {
        try withDirectory(manifest.current.id.uuidString, in: directory) { revision in
            guard try entryExists(manifest.current.program, in: revision) else { return false }
            guard FileRecord(try read(manifest.current.program, in: revision, limit: 65_536)) ==
                    manifest.current.files[manifest.current.program] else { throw Failure.changed }
            return true
        }
    }

    private func currentURL(_ manifest: Manifest) -> URL {
        rootURL.appendingPathComponent(manifest.document.uuidString, isDirectory: true)
            .appendingPathComponent(manifest.current.id.uuidString, isDirectory: true)
            .appendingPathComponent(manifest.current.program)
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let base = rootURL.pathComponents, path = url.standardizedFileURL.pathComponents
        return url.isFileURL && path.count > base.count && Array(path.prefix(base.count)) == base
    }

    private func documentID(for url: URL) -> UUID? {
        guard isInsideRoot(url) else { return nil }
        let components = Array(url.standardizedFileURL.pathComponents.dropFirst(rootURL.pathComponents.count))
        guard components.count == 3, let id = UUID(uuidString: components[0]),
              id.uuidString == components[0], UUID(uuidString: components[1]) != nil else { return nil }
        return id
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) } == 0
    }

    private func entryExists(_ name: String, in directory: Int32) throws -> Bool {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw Failure.unavailable }
        return false
    }

    private func makeDirectory(_ name: String, in parent: Int32) throws {
        guard mkdirat(parent, name, 0o700) == 0 else { throw Failure.unavailable }
    }

    private func withDirectory<T>(_ name: String, in parent: Int32, _ body: (Int32) throws -> T) throws -> T {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { _ = close(descriptor) }
        try verifyDirectory(descriptor, name: name, in: parent)
        return try body(descriptor)
    }

    private func verifyDirectory(_ descriptor: Int32, name: String, in parent: Int32) throws {
        var opened = stat(), named = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFDIR,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { throw Failure.changed }
    }

    private func read(_ name: String, in directory: Int32, limit: Int) throws -> Data {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw Failure.invalidManifest }
        var result = Data(count: Int(info.st_size))
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = pread(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.changed }
                offset += count
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == info.st_size,
              fstatat(directory, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_dev == after.st_dev, info.st_ino == after.st_ino else { throw Failure.changed }
        return result
    }

    private func publish(_ data: Data, name: String, in directory: Int32) throws {
        let temporary = ".save-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { _ = close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.unavailable }
                offset += count
            }
        }
        guard fsync(descriptor) == 0,
              renameat(directory, temporary, directory, name) == 0,
              fsync(directory) == 0 else { throw Failure.unavailable }
    }

    private func names(_ directory: Int32) throws -> [String] {
        let copy = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { throw Failure.unavailable }
        guard let stream = fdopendir(copy) else { _ = close(copy); throw Failure.unavailable }
        defer { _ = closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Failure.unavailable }
                return result
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingCString: $0)
                }
            }
            guard let name, result.count < 50_000 else { throw Failure.unavailable }
            if name != "." && name != ".." { result.append(name) }
        }
    }
}
