import Foundation

struct QueueStore {
    private let fileManager = FileManager.default

    private var directoryURL: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPack", isDirectory: true)
    }

    private var fileURL: URL {
        directoryURL.appendingPathComponent("queue.json")
    }

    func load() -> [InstallJob] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([InstallJob].self, from: data)) ?? []
    }

    func save(_ jobs: [InstallJob]) {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let retained = Array(jobs.suffix(250))
            let data = try encoder.encode(retained)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MacPack could not persist its queue: %@", error.localizedDescription)
        }
    }
}
