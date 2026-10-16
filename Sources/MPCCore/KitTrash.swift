import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Moving a program to the system Trash never removes its audio or sequences.
/// FileManager has no descriptor-based trash API: identity is rechecked immediately
/// before calling it, but this is not an atomic defense against a hostile writer.
public enum KitTrash {
    public typealias Operation = @Sendable (URL) throws -> URL?

    public struct Prepared: Sendable {
        public let url: URL
        fileprivate let resolvedParent: URL
        fileprivate let parent: FileState
        fileprivate let file: FileState
        fileprivate let contents: Data
        fileprivate let destination: ExportDestination
    }

    fileprivate struct FileState: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ value: stat) {
            device = UInt64(truncatingIfNeeded: value.st_dev)
            inode = UInt64(value.st_ino)
            size = Int64(value.st_size)
            #if canImport(Darwin)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
            #else
            modifiedSeconds = Int64(value.st_mtim.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtim.tv_nsec)
            changedSeconds = Int64(value.st_ctim.tv_sec)
            changedNanoseconds = Int64(value.st_ctim.tv_nsec)
            #endif
        }

        func sameObject(as other: FileState) -> Bool {
            device == other.device && inode == other.inode
        }
    }

    public enum Failure: LocalizedError, Sendable {
        case notAProgram, unavailable, ambiguous, changed, trashUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .notAProgram:
                return "Seul un fichier programme .PGM ordinaire peut être mis à la corbeille."
            case .unavailable:
                return "Le programme ou son dossier ne peut pas être vérifié. Aucun fichier n’a été supprimé."
            case .ambiguous:
                return "Ce nom de programme apparaît plusieurs fois dans le dossier. L’app refuse de choisir un fichier ; aucun fichier n’a été supprimé."
            case .changed:
                return "Le programme ou son emplacement a changé depuis la confirmation. Aucun fichier n’a été supprimé ; actualise la bibliothèque."
            case .trashUnavailable(let detail):
                return "La mise à la corbeille a échoué. L’app ne force jamais l’effacement d’un programme. \(detail)"
            }
        }
    }

    public static func prepare(_ url: URL) throws -> Prepared {
        try prepare(url, directoryEntries: nativeNames)
    }

    // Internal seam reproduces duplicate native FAT entries without touching an SD.
    static func prepare(_ url: URL, directoryEntries: (Int32) throws -> [String]) throws -> Prepared {
        let url = url.standardizedFileURL
        guard url.isFileURL, url.pathExtension.lowercased() == "pgm" else { throw Failure.notAProgram }
        return try withVerifiedFile(url, directoryEntries: directoryEntries) { parent, descriptor in
            let info = try fileInfo(descriptor)
            guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.notAProgram }
            let contents = try readProgram(descriptor, size: info.st_size)
            guard FileState(try fileInfo(descriptor)) == FileState(info) else { throw Failure.changed }
            let destination: ExportDestination
            do { destination = try ExportDestination.capture(at: url.deletingLastPathComponent()) }
            catch { throw Failure.unavailable }
            return Prepared(url: url,
                            resolvedParent: url.deletingLastPathComponent().resolvingSymlinksInPath(),
                            parent: FileState(try fileInfo(parent)), file: FileState(info), contents: contents,
                            destination: destination)
        }
    }

    public static func move(_ prepared: Prepared, operation: Operation = { try systemTrash($0) }) throws -> URL? {
        let parentURL = prepared.url.deletingLastPathComponent()
        guard parentURL.resolvingSymlinksInPath() == prepared.resolvedParent else { throw Failure.changed }
        return try withVerifiedFile(prepared.url, directoryEntries: nativeNames) { parent, descriptor in
            do { try prepared.destination.validate(directoryFD: parent, selectedURL: parentURL) }
            catch { throw Failure.changed }
            guard prepared.parent.sameObject(as: FileState(try fileInfo(parent))),
                  prepared.file == FileState(try fileInfo(descriptor)),
                  try readProgram(descriptor, size: prepared.file.size) == prepared.contents,
                  prepared.file == FileState(try fileInfo(descriptor)) else { throw Failure.changed }
            var currentFile = stat()
            var currentParent = stat()
            guard prepared.url.path.withCString({ lstat($0, &currentFile) }) == 0,
                  parentURL.path.withCString({ lstat($0, &currentParent) }) == 0,
                  currentFile.st_mode & S_IFMT == S_IFREG,
                  prepared.file == FileState(currentFile),
                  prepared.parent.sameObject(as: FileState(currentParent)),
                  parentURL.resolvingSymlinksInPath() == prepared.resolvedParent else { throw Failure.changed }
            do { return try operation(prepared.url) }
            catch { throw Failure.trashUnavailable(error.localizedDescription) }
        }
    }

    public static func systemTrash(_ url: URL) throws -> URL? {
        #if canImport(Darwin)
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
        #else
        throw Failure.trashUnavailable("La corbeille système n’est pas disponible.")
        #endif
    }

    private static func withVerifiedFile<T>(
        _ url: URL, directoryEntries: (Int32) throws -> [String],
        body: (Int32, Int32) throws -> T
    ) throws -> T {
        let parent = url.deletingLastPathComponent().path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard parent >= 0 else { throw Failure.unavailable }
        defer { _ = close(parent) }
        let requested = url.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        let matches = try directoryEntries(parent).filter {
            $0.precomposedStringWithCanonicalMapping.lowercased() == requested
        }
        guard matches.count == 1 else { throw matches.isEmpty ? Failure.unavailable : Failure.ambiguous }
        let descriptor = url.lastPathComponent.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { _ = close(descriptor) }
        var pathInfo = stat()
        guard url.lastPathComponent.withCString({ fstatat(parent, $0, &pathInfo, AT_SYMLINK_NOFOLLOW) }) == 0,
              pathInfo.st_mode & S_IFMT == S_IFREG,
              FileState(pathInfo) == FileState(try fileInfo(descriptor)) else { throw Failure.changed }
        return try body(parent, descriptor)
    }

    private static func fileInfo(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw Failure.unavailable }
        return value
    }

    private static func readProgram(_ descriptor: Int32, size: Int64) throws -> Data {
        guard size >= 0, size <= 16 * 1024 * 1024 else { throw Failure.unavailable }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while result.count < size {
            let count = pread(descriptor, &buffer, min(buffer.count, Int(size) - result.count), off_t(result.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.unavailable }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private static func nativeNames(_ descriptor: Int32) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw Failure.unavailable }
        guard let stream = fdopendir(copy) else { _ = close(copy); throw Failure.unavailable }
        defer { _ = closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Failure.unavailable }
                return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(validatingCString: $0) }
            }
            guard let name else { throw Failure.unavailable }
            if name != "." && name != ".." { names.append(name) }
            guard names.count <= 50_000 else { throw Failure.unavailable }
        }
    }
}
