import AppKit
import Combine
import Foundation
import MacPackShared

@MainActor
final class MacPackModel: ObservableObject {
    @Published private(set) var jobs: [InstallJob]
    @Published var installImmediately: Bool {
        didSet {
            defaults.set(installImmediately, forKey: Keys.installImmediately)
            if installImmediately {
                for index in jobs.indices where jobs[index].status == .waiting {
                    jobs[index].status = .queued
                    jobs[index].message = "Queued"
                }
                persist()
                startNextIfPossible()
            }
        }
    }
    @Published var showHUD: Bool {
        didSet {
            defaults.set(showHUD, forKey: Keys.showHUD)
            if !showHUD {
                isHUDVisible = false
            } else if jobs.contains(where: { $0.status.isPending || $0.status == .failed }) {
                isHUDVisible = true
            }
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            configureLaunchAtLogin()
        }
    }

    @Published private(set) var helperState: IntegrationState = .checking
    @Published private(set) var routingState: IntegrationState = .ready
    @Published private(set) var loginItemState: IntegrationState = .checking
    @Published private(set) var isHUDVisible = false
    @Published private(set) var notice: String?

    var onNeedsAttention: (() -> Void)?
    /// Called when a freshly routed package cannot be staged, so the caller
    /// can hand the original file back to Installer.app instead of silently
    /// swallowing the user's install.
    var onStagingHandBack: ((URL) -> Void)?

    private let store = QueueStore()
    private let stagingStore = StagingStore()
    private let stagingQueue = DispatchQueue(
        label: "com.macpack.staging",
        qos: .userInitiated
    )
    private let helperClient = HelperClient()
    private let defaults = UserDefaults.standard
    private var helperReady = false
    private var hideHUDGeneration = 0

    init() {
        defaults.register(defaults: [
            Keys.installImmediately: true,
            Keys.showHUD: true,
            Keys.launchAtLogin: true
        ])
        installImmediately = defaults.bool(forKey: Keys.installImmediately)
        showHUD = defaults.bool(forKey: Keys.showHUD)
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)

        jobs = store.load().map { job in
            var recovered = job
            if recovered.status == .installing || recovered.status == .postProcessing {
                recovered.status = .queued
                recovered.progress = nil
                recovered.message = "Recovered after restart"
            }
            return recovered
        }
    }

    var activeJob: InstallJob? {
        jobs.first(where: {
            $0.status == .installing || $0.status == .postProcessing
        })
    }

    var hudJob: InstallJob? {
        activeJob
            ?? jobs.first(where: { $0.status == .queued })
            ?? jobs.first(where: { $0.status == .waiting })
            ?? jobs.last(where: { $0.status == .failed })
            ?? jobs.last(where: { $0.status == .installed })
    }

    var pendingCount: Int {
        jobs.filter { $0.status.isPending }.count
    }

    var developmentBuild: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MacPackDevBuild") as? String,
              !value.isEmpty else { return nil }
        return value
    }

    func start(firstRun _: Bool) {
        refreshSystemState()
        if launchAtLogin {
            configureLaunchAtLogin()
        }
        if jobs.contains(where: { $0.status.isPending || $0.status == .failed }) {
            showHUDNow()
        }
        let retainedSpoolIDs = Set(
            jobs
                .filter { $0.status.isPending || $0.status == .failed }
                .map(\.id)
        )
        stagingQueue.async { [stagingStore] in
            try? stagingStore.removeOrphanedSpools(retaining: retainedSpoolIDs)
        }
        for job in jobs where job.status == .staging {
            stage(jobID: job.id, sourcePath: job.sourcePath ?? job.path)
        }
    }

    func enqueue(urls: [URL]) {
        var accepted = false
        for url in urls {
            do {
                let path = try PackagePathValidator.validatedPath(url.path)
                let job = InstallJob(path: path, status: .staging)
                jobs.append(job)
                stage(jobID: job.id, sourcePath: path, handBackOnFailure: true)
                accepted = true
            } catch {
                notice = error.localizedDescription
            }
        }

        guard accepted else { return }
        persist()
        showHUDNow()
    }

    func approve(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].status == .waiting else { return }
        jobs[index].status = .queued
        jobs[index].message = "Queued"
        persist()
        showHUDNow()
        startNextIfPossible()
    }

    func prioritize(_ id: UUID) {
        guard let currentIndex = jobs.firstIndex(where: { $0.id == id }),
              jobs[currentIndex].status == .queued else { return }

        for index in jobs.indices
        where jobs[index].status == .queued && jobs[index].message == "Up next" {
            jobs[index].message = "Queued"
        }

        var promoted = jobs.remove(at: currentIndex)
        promoted.message = "Up next"
        let insertionIndex = jobs.firstIndex(where: { $0.status == .queued })
            ?? jobs.endIndex
        jobs.insert(promoted, at: insertionIndex)
        persist()
        showHUDNow()
        startNextIfPossible()
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].status == .queued || jobs[index].status == .waiting else { return }
        let stagedPath = jobs[index].path
        jobs[index].status = .cancelled
        jobs[index].message = "Cancelled"
        persist()
        settleHUDIfIdle()
        if stagingStore.contains(stagedPath) {
            stagingQueue.async { [stagingStore] in
                try? stagingStore.removeStagedPackage(atPath: stagedPath)
            }
        }
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].status == .failed else { return }
        let path = jobs[index].path
        if stagingStore.contains(path), FileManager.default.fileExists(atPath: path) {
            jobs[index].status = .queued
        } else {
            jobs[index].status = .staging
        }
        jobs[index].progress = nil
        jobs[index].message = jobs[index].status == .staging ? "Staging…" : "Queued"
        notice = nil
        persist()
        showHUDNow()
        if jobs[index].status == .staging {
            stage(jobID: id, sourcePath: jobs[index].sourcePath ?? jobs[index].path)
        } else {
            startNextIfPossible()
        }
    }

    func clearFinished() {
        let stagedPaths = jobs
            .filter { $0.status.isFinished && stagingStore.contains($0.path) }
            .map(\.path)
        jobs.removeAll(where: { $0.status.isFinished })
        persist()
        settleHUDIfIdle()
        stagingQueue.async { [stagingStore] in
            for path in stagedPaths {
                try? stagingStore.removeStagedPackage(atPath: path)
            }
        }
    }

    func dismissNotice() {
        notice = nil
    }

    func reportRoutingError(_ error: Error) {
        notice = "Could not route package to MacPack: \(error.localizedDescription)"
        onNeedsAttention?()
    }

    func refreshSystemState() {
        routingState = .ready
        loginItemState = SystemIntegration.loginItemState()
        helperState = .checking

        helperClient.ping { [weak self] ready in
            guard let self else { return }
            helperReady = ready
            helperState = ready ? .ready : SystemIntegration.helperRegistrationState()
            if ready {
                notice = nil
                startNextIfPossible()
            }
        }
    }

    func enableInstallerService() {
        do {
            helperState = try SystemIntegration.registerModernHelper()
            if helperState == .needsApproval {
                notice = "Approve MacPack under Login Items to finish one-time setup."
                SystemIntegration.openBackgroundItemSettings()
            }
            scheduleHelperRefresh()
        } catch {
            helperState = .unavailable(error.localizedDescription)
            notice = "Could not register the installer service: \(error.localizedDescription)"
        }
    }

    func openBackgroundItemSettings() {
        SystemIntegration.openBackgroundItemSettings()
    }

    private func configureLaunchAtLogin() {
        do {
            let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
            let previousPath = defaults.string(forKey: Keys.loginItemBundlePath)
            if launchAtLogin,
               SystemIntegration.loginItemState() == .ready,
               let previousPath,
               previousPath != bundlePath {
                try SystemIntegration.setLaunchAtLogin(false)
            }
            try SystemIntegration.setLaunchAtLogin(launchAtLogin)
            if launchAtLogin {
                defaults.set(bundlePath, forKey: Keys.loginItemBundlePath)
            } else {
                defaults.removeObject(forKey: Keys.loginItemBundlePath)
            }
            loginItemState = SystemIntegration.loginItemState()
        } catch {
            loginItemState = .unavailable(error.localizedDescription)
            notice = "Could not update launch-at-login: \(error.localizedDescription)"
        }
    }

    private func scheduleHelperRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshSystemState()
        }
    }

    private func startNextIfPossible() {
        guard helperReady,
              activeJob == nil,
              let index = jobs.firstIndex(where: { $0.status == .queued }) else { return }

        let id = jobs[index].id
        jobs[index].status = .installing
        jobs[index].progress = nil
        jobs[index].message = "Preparing…"
        persist()
        showHUDNow()
        let job = jobs[index]

        helperClient.install(
            job: job,
            progress: { [weak self] stage, percent, message in
                self?.updateProgress(
                    id: id,
                    stage: stage,
                    percent: percent,
                    message: message
                )
            },
            completion: { [weak self] exitCode, summary in
                self?.finish(id: id, exitCode: exitCode, summary: summary)
            }
        )
    }

    private func stage(jobID: UUID, sourcePath: String, handBackOnFailure: Bool = false) {
        stagingQueue.async { [weak self, stagingStore] in
            do {
                let stagedURL = try stagingStore.stage(
                    sourceURL: URL(fileURLWithPath: sourcePath),
                    jobID: jobID
                )
                DispatchQueue.main.async {
                    self?.finishStaging(
                        jobID: jobID,
                        stagedPath: stagedURL.path,
                        error: nil,
                        handBackOnFailure: handBackOnFailure
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self?.finishStaging(
                        jobID: jobID,
                        stagedPath: nil,
                        error: error,
                        handBackOnFailure: handBackOnFailure
                    )
                }
            }
        }
    }

    private func finishStaging(
        jobID: UUID,
        stagedPath: String?,
        error: Error?,
        handBackOnFailure: Bool
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].status == .staging else { return }

        if let stagedPath {
            jobs[index].path = stagedPath
            jobs[index].status = installImmediately ? .queued : .waiting
            jobs[index].message = jobs[index].status.label
        } else if handBackOnFailure, let onStagingHandBack {
            jobs[index].status = .failed
            jobs[index].message = "Handed back to Installer (MacPack could not stage it)"
            notice = "\(jobs[index].fileName) can't be staged by MacPack — opened in Installer instead."
            persist()
            onStagingHandBack(URL(fileURLWithPath: jobs[index].sourcePath ?? jobs[index].path))
            settleHUDIfIdle()
            return
        } else {
            jobs[index].status = .failed
            jobs[index].message = "Could not stage package: \(error?.localizedDescription ?? "Unknown error")"
            notice = "\(jobs[index].fileName) could not be staged."
        }
        persist()

        if jobs[index].status == .queued {
            startNextIfPossible()
        } else if jobs[index].status == .waiting {
            onNeedsAttention?()
        } else {
            onNeedsAttention?()
            settleHUDIfIdle()
        }
    }

    private func updateProgress(
        id: UUID,
        stage: String,
        percent: Double?,
        message: String?
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].status == .installing
                || jobs[index].status == .postProcessing else { return }

        if stage == MacPackInstallStage.postProcessing {
            jobs[index].status = .postProcessing
            jobs[index].progress = nil
        } else if jobs[index].status != .postProcessing {
            jobs[index].status = .installing
        }
        if let percent {
            jobs[index].progress = percent
        }
        if let message, !message.isEmpty {
            jobs[index].message = message
        }
        persist()
    }

    private func finish(id: UUID, exitCode: Int, summary: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if exitCode == 0 {
            jobs[index].status = .installed
            jobs[index].progress = 1
            jobs[index].message = summary.isEmpty ? "Installed" : summary
            let stagedPath = jobs[index].path
            if stagingStore.contains(stagedPath) {
                stagingQueue.async { [stagingStore] in
                    try? stagingStore.removeStagedPackage(atPath: stagedPath)
                }
            }
        } else {
            jobs[index].status = .failed
            jobs[index].progress = nil
            jobs[index].message = summary
            notice = "\(jobs[index].fileName) failed: \(summary)"
        }
        persist()

        if exitCode != 0, exitCode == Int(EX_UNAVAILABLE) {
            helperReady = false
            helperState = SystemIntegration.helperRegistrationState()
            onNeedsAttention?()
        }

        startNextIfPossible()
        settleHUDIfIdle()
    }

    private func persist() {
        store.save(jobs)
        objectWillChange.send()
    }

    private func showHUDNow() {
        hideHUDGeneration += 1
        if showHUD {
            isHUDVisible = true
        }
    }

    private func settleHUDIfIdle() {
        guard !jobs.contains(where: { $0.status.isPending }) else { return }
        if jobs.last?.status == .failed {
            isHUDVisible = showHUD
            return
        }

        hideHUDGeneration += 1
        let generation = hideHUDGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, generation == hideHUDGeneration else { return }
            isHUDVisible = false
        }
    }

    private enum Keys {
        static let installImmediately = "installImmediately"
        static let showHUD = "showHUD"
        static let launchAtLogin = "launchAtLogin"
        static let loginItemBundlePath = "loginItemBundlePath"
    }
}
