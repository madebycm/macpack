import Foundation

struct StagingStore: Sendable {
    private var fileManager: FileManager { .default }

    private var baseURL: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPack", isDirectory: true)
            .appendingPathComponent("Spool", isDirectory: true)
    }

    func stage(sourceURL: URL, jobID: UUID) throws -> URL {
        let directory = baseURL.appendingPathComponent(jobID.uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent(
            sourceURL.lastPathComponent,
            isDirectory: sourceURL.hasDirectoryPath
        )

        do {
            // A process exit during copy can leave a partial spool for a job
            // that is still persisted as `staging`. Replace only that exact,
            // UUID-scoped directory before retrying recovery.
            if fileManager.fileExists(atPath: directory.path) {
                try removeDirectory(containing: destination)
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            try? removeDirectory(containing: destination)
            throw error
        }
    }

    func contains(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.hasPrefix(baseURL.standardizedFileURL.path + "/")
    }

    func removeStagedPackage(atPath path: String) throws {
        try removeDirectory(containing: URL(fileURLWithPath: path))
    }

    func removeOrphanedSpools(retaining jobIDs: Set<UUID>) throws {
        guard fileManager.fileExists(atPath: baseURL.path) else { return }
        let baseValues = try baseURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard baseValues.isSymbolicLink != true else {
            throw StagingError.unsafePath
        }

        let children = try fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for directory in children {
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let id = UUID(uuidString: directory.lastPathComponent),
                  !jobIDs.contains(id) else { continue }
            try removeDirectory(
                containing: directory.appendingPathComponent("orphan.pkg")
            )
        }
    }

    private func removeDirectory(containing packageURL: URL) throws {
        let directory = packageURL.standardizedFileURL.deletingLastPathComponent()
        let base = baseURL.standardizedFileURL
        guard directory.deletingLastPathComponent() == base,
              UUID(uuidString: directory.lastPathComponent) != nil else {
            throw StagingError.unsafePath
        }

        let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else {
            throw StagingError.unsafePath
        }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    enum StagingError: LocalizedError {
        case unsafePath

        var errorDescription: String? {
            "MacPack refused an unsafe staging path."
        }
    }
}
