import Foundation

/// Errors surfaced while resolving or reading the user-selected authoritative archive.
///
/// The source intentionally has no "create" or "empty" fallback path. A missing,
/// stale, unreadable, or invalid bookmark is an error that callers must show to the
/// user without replacing the selected archive.
public enum LocalArchiveError: Error, Equatable, LocalizedError, Sendable {
    case bookmarkMissing
    case bookmarkInvalid
    case bookmarkStale
    case notAFile(URL)
    case archiveMissing(URL)
    case securityScopeDenied(URL)
    case archiveUnreadable(URL)
    case malformedArchive(String)
    case unsafePath(String)
    case entryLimitExceeded
    case entryTooLarge(path: String, size: UInt64, limit: UInt64)
    case scannedByteLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .bookmarkMissing:
            return "No external archive has been selected."
        case .bookmarkInvalid:
            return "The saved external archive reference is invalid."
        case .bookmarkStale:
            return "The saved external archive reference is stale. Select the archive again."
        case .notAFile(let url):
            return "The selected archive is not a regular file: \(url.lastPathComponent)."
        case .archiveMissing(let url):
            return "The selected archive is missing: \(url.lastPathComponent)."
        case .securityScopeDenied(let url):
            return "Access to the selected archive was denied: \(url.lastPathComponent)."
        case .archiveUnreadable(let url):
            return "The selected archive could not be opened for reading: \(url.lastPathComponent)."
        case .malformedArchive(let reason):
            return "The TAR archive is malformed: \(reason)."
        case .unsafePath(let path):
            return "The TAR archive contains an unsafe path: \(path)."
        case .entryLimitExceeded:
            return "The TAR archive contains more entries than the configured limit."
        case .entryTooLarge(let path, let size, let limit):
            return "The TAR entry \(path) is \(size) bytes, above the \(limit)-byte limit."
        case .scannedByteLimitExceeded:
            return "The TAR archive exceeds the configured read-only scan limit."
        }
    }
}

/// A small persistence abstraction so tests can use an isolated UserDefaults suite.
public protocol ArchiveBookmarkStorage: AnyObject {
    func readBookmarkData() -> Data?
    func writeBookmarkData(_ data: Data) throws
}

/// Stores only the security-scoped bookmark, never an archive copy.
public final class UserDefaultsArchiveBookmarkStorage: ArchiveBookmarkStorage {
    public static let defaultKey = "CalcVault.localArchive.securityScopedBookmark"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsArchiveBookmarkStorage.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func readBookmarkData() -> Data? {
        defaults.data(forKey: key)
    }

    public func writeBookmarkData(_ data: Data) throws {
        defaults.set(data, forKey: key)
    }
}

/// A security-scoped reference to the external archive chosen by the owner.
///
/// This type deliberately does not expose archive-writing or replacement methods.
public final class LocalArchiveSource {
    private let bookmarkStorage: ArchiveBookmarkStorage

    public init(bookmarkStorage: ArchiveBookmarkStorage = UserDefaultsArchiveBookmarkStorage()) {
        self.bookmarkStorage = bookmarkStorage
    }

    /// Saves a bookmark for the selected file. The file itself remains at its original
    /// location and is never copied into the app container.
    public func selectArchive(at url: URL) throws {
        guard url.isFileURL else {
            throw LocalArchiveError.notAFile(url)
        }
        let startedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if startedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        try validateRegularFile(url)
        // Validate the candidate before changing the saved reference. A bad
        // selection must not displace the last known valid authoritative TAR.
        _ = try ReadOnlyTARListing().list(at: url)

        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(
                // iOS persists document-picker access in ordinary bookmark data.
                // The macOS-only security-scope bookmark flags do not compile for
                // an iOS target; access is still bracketed by start/stop below.
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw LocalArchiveError.bookmarkInvalid
        }
        try bookmarkStorage.writeBookmarkData(bookmark)
    }

    /// Runs a read-only operation while the security-scoped URL is open.
    ///
    /// The closure receives a read-only `FileHandle`; callers cannot accidentally use
    /// this API to replace the authoritative archive. The security scope is always
    /// relinquished before this method returns.
    public func withReadOnlyArchive<Result>(
        _ body: (FileHandle, URL, UInt64) throws -> Result
    ) throws -> Result {
        let url = try resolveSelectedArchive()
        // A document-picker URL normally requires a security scope. A URL that is
        // already inside the app's readable container may legitimately report false
        // because it does not need one; it is still validated and opened read-only.
        let acquiredSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if acquiredSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let byteCount = try archiveByteCount(at: url)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw LocalArchiveError.archiveUnreadable(url)
        }
        defer { try? handle.close() }
        return try body(handle, url, byteCount)
    }

    /// Lists the selected TAR without writing, extracting, or copying any archive data.
    public func listCurrentArchive(
        limits: TARListingLimits = .phase0Default
    ) throws -> [TAREntry] {
        try withReadOnlyArchive { handle, _, byteCount in
            try ReadOnlyTARListing(limits: limits).list(handle: handle, byteCount: byteCount)
        }
    }

    private func resolveSelectedArchive() throws -> URL {
        guard let bookmark = bookmarkStorage.readBookmarkData() else {
            throw LocalArchiveError.bookmarkMissing
        }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw LocalArchiveError.bookmarkInvalid
        }
        if isStale {
            throw LocalArchiveError.bookmarkStale
        }
        guard url.isFileURL else {
            throw LocalArchiveError.notAFile(url)
        }
        try validateRegularFile(url)
        return url
    }

    private func validateRegularFile(_ url: URL) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        } catch {
            throw LocalArchiveError.archiveMissing(url)
        }
        guard values.isRegularFile == true, values.isDirectory != true else {
            throw LocalArchiveError.notAFile(url)
        }
    }

    private func archiveByteCount(at url: URL) throws -> UInt64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let number = attributes[.size] as? NSNumber else {
                throw LocalArchiveError.archiveUnreadable(url)
            }
            return number.uint64Value
        } catch let error as LocalArchiveError {
            throw error
        } catch {
            throw LocalArchiveError.archiveUnreadable(url)
        }
    }
}

public struct TARListingLimits: Equatable, Sendable {
    public let maxEntries: Int
    public let maxEntryBytes: UInt64
    public let maxScannedBytes: UInt64

    public init(maxEntries: Int, maxEntryBytes: UInt64, maxScannedBytes: UInt64) {
        self.maxEntries = maxEntries
        self.maxEntryBytes = maxEntryBytes
        self.maxScannedBytes = maxScannedBytes
    }

    /// Conservative Phase 0 bounds. Listing metadata never reads file payloads.
    public static let phase0Default = TARListingLimits(
        maxEntries: 10_000,
        maxEntryBytes: 64 * 1024 * 1024,
        maxScannedBytes: 256 * 1024 * 1024
    )
}

public enum TAREntryKind: String, Equatable, Sendable {
    case file
    case directory
    case symbolicLink
    case hardLink
    case other
}

public struct TAREntry: Equatable, Sendable {
    public let path: String
    public let size: UInt64
    public let kind: TAREntryKind

    public init(path: String, size: UInt64, kind: TAREntryKind) {
        self.path = path
        self.size = size
        self.kind = kind
    }
}

/// Read-only, bounded TAR metadata reader.
///
/// It validates headers, checksums, sizes, terminators, and paths, but never extracts
/// or writes a payload. Regular files and directories are returned as metadata;
/// unsupported link/special records are rejected and link targets are never followed.
/// It also refuses to seek past the source file's known length.
public struct ReadOnlyTARListing: Sendable {
    public let limits: TARListingLimits

    public init(limits: TARListingLimits = .phase0Default) {
        self.limits = limits
    }

    public func list(at url: URL) throws -> [TAREntry] {
        guard url.isFileURL else { throw LocalArchiveError.notAFile(url) }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let number = attributes[.size] as? NSNumber else {
                throw LocalArchiveError.archiveUnreadable(url)
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try list(handle: handle, byteCount: number.uint64Value)
        } catch let error as LocalArchiveError {
            throw error
        } catch {
            throw LocalArchiveError.archiveUnreadable(url)
        }
    }

    public func list(handle: FileHandle, byteCount: UInt64) throws -> [TAREntry] {
        guard limits.maxEntries > 0, limits.maxEntryBytes > 0, limits.maxScannedBytes >= 512 else {
            throw LocalArchiveError.malformedArchive("invalid listing limits")
        }

        var entries: [TAREntry] = []
        var offset: UInt64 = 0
        var sawTerminator = false

        while offset < byteCount {
            guard byteCount - offset >= 512 else {
                throw LocalArchiveError.malformedArchive("truncated header")
            }
            guard offset <= limits.maxScannedBytes else {
                throw LocalArchiveError.scannedByteLimitExceeded
            }

            let header = try readExactly(handle, count: 512, at: offset)
            if header.allSatisfy({ $0 == 0 }) {
                let secondOffset = offset + 512
                guard byteCount - offset >= 1_024 else {
                    throw LocalArchiveError.malformedArchive("missing second end marker")
                }
                guard limits.maxScannedBytes - offset >= 1_024 else {
                    throw LocalArchiveError.scannedByteLimitExceeded
                }
                let second = try readExactly(handle, count: 512, at: secondOffset)
                guard second.allSatisfy({ $0 == 0 }) else {
                    throw LocalArchiveError.malformedArchive("invalid end marker")
                }
                sawTerminator = true
                break
            }

            try validateChecksum(header)
            let path = try parsePath(header)
            let size = try parseOctalField(header, range: 124..<136, fieldName: "size")
            guard size <= limits.maxEntryBytes else {
                throw LocalArchiveError.entryTooLarge(path: path, size: size, limit: limits.maxEntryBytes)
            }
            guard entries.count < limits.maxEntries else {
                throw LocalArchiveError.entryLimitExceeded
            }

            let kind = entryKind(header[156])
            guard kind == .file || kind == .directory else {
                throw LocalArchiveError.malformedArchive("unsupported special entry")
            }
            entries.append(TAREntry(path: path, size: size, kind: kind))

            let payloadOffset = offset + 512
            let paddedSize = try paddedBlockCount(for: size)
            guard paddedSize <= byteCount - payloadOffset else {
                throw LocalArchiveError.malformedArchive("truncated payload for \(path)")
            }
            let nextOffset = payloadOffset + paddedSize
            guard nextOffset <= limits.maxScannedBytes else {
                throw LocalArchiveError.scannedByteLimitExceeded
            }
            offset = nextOffset
        }

        guard sawTerminator else {
            throw LocalArchiveError.malformedArchive("missing end marker")
        }
        return entries
    }

    private func readExactly(_ handle: FileHandle, count: Int, at offset: UInt64) throws -> Data {
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else {
                throw LocalArchiveError.malformedArchive("truncated data")
            }
            return data
        } catch let error as LocalArchiveError {
            throw error
        } catch {
            throw LocalArchiveError.malformedArchive("unable to read header")
        }
    }

    private func validateChecksum(_ header: Data) throws {
        guard header.count == 512 else {
            throw LocalArchiveError.malformedArchive("invalid header length")
        }
        let expected = try parseOctalField(header, range: 148..<156, fieldName: "checksum")
        var actual: UInt64 = 0
        for index in 0..<512 {
            actual += UInt64((148..<156).contains(index) ? 32 : header[index])
        }
        guard actual == expected else {
            throw LocalArchiveError.malformedArchive("checksum mismatch")
        }
    }

    private func parsePath(_ header: Data) throws -> String {
        let name = try parseStringField(header, range: 0..<100, fieldName: "name")
        let prefix = try parseStringField(header, range: 345..<500, fieldName: "prefix")
        let combined = prefix.isEmpty ? name : "\(prefix)/\(name)"
        let path = combined.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !path.isEmpty,
              !combined.hasPrefix("/"),
              !combined.hasPrefix("\\"),
              !combined.contains("\\"),
              !combined.contains("\0") else {
            throw LocalArchiveError.unsafePath(combined)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw LocalArchiveError.unsafePath(combined)
        }
        return path
    }

    private func parseStringField(_ data: Data, range: Range<Int>, fieldName: String) throws -> String {
        let field = Data(data[range])
        let end = field.firstIndex(of: 0) ?? field.endIndex
        let value = Data(field[..<end])
        guard let string = String(data: value, encoding: .utf8) else {
            throw LocalArchiveError.malformedArchive("invalid UTF-8 in \(fieldName)")
        }
        return string.trimmingCharacters(in: .whitespaces)
    }

    private func parseOctalField(_ data: Data, range: Range<Int>, fieldName: String) throws -> UInt64 {
        let field = Data(data[range])
        let bytes = field.filter { $0 != 0 && $0 != 32 }
        if bytes.isEmpty { return 0 }
        var result: UInt64 = 0
        for byte in bytes {
            guard byte >= 48, byte <= 55 else {
                throw LocalArchiveError.malformedArchive("invalid octal \(fieldName)")
            }
            let digit = UInt64(byte - 48)
            guard result <= (UInt64.max - digit) / 8 else {
                throw LocalArchiveError.malformedArchive("overflow in \(fieldName)")
            }
            result = result * 8 + digit
        }
        return result
    }

    private func paddedBlockCount(for size: UInt64) throws -> UInt64 {
        let rounded = size > UInt64.max - 511 ? UInt64.max : size + 511
        guard rounded != UInt64.max else {
            throw LocalArchiveError.malformedArchive("size overflow")
        }
        return (rounded / 512) * 512
    }

    private func entryKind(_ flag: UInt8) -> TAREntryKind {
        switch flag {
        case 0, 48:
            return .file
        case 1, 49:
            return .hardLink
        case 2, 50:
            return .symbolicLink
        case 5, 53:
            return .directory
        default:
            return .other
        }
    }
}
