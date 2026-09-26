import Foundation

public final class VaultTemporaryFileManager: @unchecked Sendable {
    private let fileManager: FileManager
    private let rootDirectory: URL
    private let lock = NSLock()
    private var ownedFiles: Set<URL> = []

    public init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory.standardizedFileURL
        } else {
            guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                throw VaultFormatError.ioFailure("The caches directory is unavailable.")
            }
            self.rootDirectory = caches
                .appendingPathComponent("CalcVaultTransient", isDirectory: true)
                .standardizedFileURL
        }
        try prepareCleanDirectory()
    }

    public func makeDestination(preferredExtension: String? = nil) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        let suffix = sanitizedExtension(preferredExtension)
        let name = UUID().vaultFileComponent + (suffix.map { ".\($0)" } ?? "")
        let candidate = rootDirectory.appendingPathComponent(name, isDirectory: false).standardizedFileURL
        guard isOwned(candidate), !fileManager.fileExists(atPath: candidate.path) else {
            throw VaultFormatError.ioFailure("A unique temporary destination could not be created.")
        }
        ownedFiles.insert(candidate)
        return candidate
    }

    public func owns(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOwned(url.standardizedFileURL) && ownedFiles.contains(url.standardizedFileURL)
    }

    public func prepareEmptyFile(at url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let normalized = url.standardizedFileURL
        guard isOwned(normalized), ownedFiles.contains(normalized),
              !fileManager.fileExists(atPath: normalized.path),
              fileManager.createFile(atPath: normalized.path, contents: nil) else {
            throw VaultFormatError.ioFailure("The protected temporary file could not be created.")
        }
        try protectAndExclude(normalized)
    }

    public func finalizeFile(at url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let normalized = url.standardizedFileURL
        guard isOwned(normalized), ownedFiles.contains(normalized),
              fileManager.fileExists(atPath: normalized.path) else {
            throw VaultFormatError.ioFailure("The temporary file is outside app ownership or missing.")
        }
        try protectAndExclude(normalized)
    }

    public func remove(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        let normalized = url.standardizedFileURL
        guard isOwned(normalized), ownedFiles.remove(normalized) != nil else { return }
        try? fileManager.removeItem(at: normalized)
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for url in ownedFiles where isOwned(url) {
            try? fileManager.removeItem(at: url)
        }
        ownedFiles.removeAll()
        guard isOwnedRootSafe else { return }
        if let children = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for child in children where isOwned(child.standardizedFileURL) {
                try? fileManager.removeItem(at: child)
            }
        }
    }

    private func prepareCleanDirectory() throws {
        guard isOwnedRootSafe else {
            throw VaultFormatError.ioFailure("The temporary directory is unsafe.")
        }
        if fileManager.fileExists(atPath: rootDirectory.path) {
            let children = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
            for child in children where isOwned(child.standardizedFileURL) {
                try fileManager.removeItem(at: child)
            }
        }
        try ensureDirectory()
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try protectAndExclude(rootDirectory)
    }

    private var isOwnedRootSafe: Bool {
        let path = rootDirectory.path
        return !path.isEmpty && path != "/" && rootDirectory.lastPathComponent == "CalcVaultTransient"
    }

    private func isOwned(_ url: URL) -> Bool {
        let rootPath = rootDirectory.path.hasSuffix("/") ? rootDirectory.path : rootDirectory.path + "/"
        return isOwnedRootSafe && url.path.hasPrefix(rootPath) && url.deletingLastPathComponent() == rootDirectory
    }

    private func sanitizedExtension(_ value: String?) -> String? {
        guard let value else { return nil }
        let lowered = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !lowered.isEmpty, lowered.count <= 16,
              lowered.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return nil
        }
        return lowered
    }

    private func protectAndExclude(_ url: URL) throws {
        try (url as NSURL).setResourceValue(FileProtectionType.complete, forKey: .fileProtectionKey)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

public enum VaultTemporaryFileRegistry {
    private static let sharedResult: Result<VaultTemporaryFileManager, Error> = Result {
        try VaultTemporaryFileManager()
    }

    public static func shared() throws -> VaultTemporaryFileManager {
        try sharedResult.get()
    }
}
