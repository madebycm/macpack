import Foundation

enum InstallJobStatus: String, Codable, CaseIterable {
    case staging
    case waiting
    case queued
    case installing
    case installed
    case failed
    case cancelled

    var label: String {
        switch self {
        case .staging: return "Staging"
        case .waiting: return "Waiting"
        case .queued: return "Queued"
        case .installing: return "Installing"
        case .installed: return "Installed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var isPending: Bool {
        self == .staging || self == .waiting || self == .queued || self == .installing
    }

    var isFinished: Bool {
        self == .installed || self == .failed || self == .cancelled
    }
}

struct InstallJob: Codable, Identifiable, Equatable {
    let id: UUID
    var path: String
    let sourcePath: String?
    let fileName: String
    let createdAt: Date
    var status: InstallJobStatus
    var progress: Double?
    var message: String

    init(path: String, status: InstallJobStatus) {
        id = UUID()
        self.path = path
        sourcePath = path
        fileName = URL(fileURLWithPath: path).lastPathComponent
        createdAt = Date()
        self.status = status
        progress = nil
        message = status.label
    }
}
