import Foundation

public struct VaultFileStager: Sendable {
    private let temporaryFiles: VaultTemporaryFileManager

    public init(temporaryFiles: VaultTemporaryFileManager) {
        self.temporaryFiles = temporaryFiles
    }

    public func stage(
        sourceURL: URL,
        preferredExtension: String?,
        progress: @escaping EncryptedStream.ProgressHandler = { _, _ in },
        cancellation: VaultOperationCancellation? = nil
    ) throws -> URL {
        let destination = try temporaryFiles.makeDestination(preferredExtension: preferredExtension)
        do {
            try temporaryFiles.prepareEmptyFile(at: destination)
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { sourceURL.stopAccessingSecurityScopedResource() }
            }

            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            let result = FileCoordinationResult()
            coordinator.coordinate(
                readingItemAt: sourceURL,
                options: [.withoutChanges],
                error: &coordinationError
            ) { coordinatedURL in
                result.markAccessed()
                do {
                    try copyRegularFile(
                        from: coordinatedURL,
                        to: destination,
                        progress: progress,
                        cancellation: cancellation
                    )
                } catch {
                    result.record(error)
                }
            }
            if let coordinationError { throw coordinationError }
            if let accessorError = result.error { throw accessorError }
            guard result.didAccess else {
                throw VaultFormatError.ioFailure("The file provider did not grant coordinated access.")
            }
            try temporaryFiles.finalizeFile(at: destination)
            return destination
        } catch let error as VaultFormatError {
            temporaryFiles.remove(destination)
            throw error
        } catch {
            temporaryFiles.remove(destination)
            throw VaultFormatError.ioFailure(error.localizedDescription)
        }
    }

    private func copyRegularFile(
        from sourceURL: URL,
        to destinationURL: URL,
        progress: @escaping EncryptedStream.ProgressHandler,
        cancellation: VaultOperationCancellation?
    ) throws {
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw VaultFormatError.unsupportedImport
        }
        let total = UInt64(fileSize)
        guard total <= VaultFormatV1.objectPlaintextLimit else {
            throw VaultFormatError.resourceLimitExceeded
        }
        let input = try FileHandle(forReadingFrom: sourceURL)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? input.close()
            try? output.close()
        }
        var copied: UInt64 = 0
        progress(0, total)
        while true {
            guard cancellation?.isCancelled() != true else {
                throw VaultFormatError.operationCancelled
            }
            let chunk = try input.read(upToCount: VaultFormatV1.objectChunkSize) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            copied += UInt64(chunk.count)
            guard copied <= total else {
                throw VaultFormatError.ioFailure("The selected file changed during staging.")
            }
            progress(copied, total)
        }
        guard copied == total else {
            throw VaultFormatError.ioFailure("The selected file changed during staging.")
        }
        try output.synchronize()
    }
}

private final class FileCoordinationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var accessed = false
    private var storedError: Error?

    var didAccess: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accessed
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func markAccessed() {
        lock.lock()
        accessed = true
        lock.unlock()
    }

    func record(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}
