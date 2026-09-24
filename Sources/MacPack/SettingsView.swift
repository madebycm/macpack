import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: MacPackModel

    var body: some View {
        VStack(spacing: 0) {
            header

            if let notice = model.notice {
                NoticeBar(message: notice, dismiss: model.dismissNotice)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Divider()

            HStack(spacing: 0) {
                preferences
                    .frame(width: 310)

                Divider()

                queue
            }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 500, idealHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.accentColor.gradient)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("MacPack")
                    .font(.system(size: 20, weight: .semibold))
                Text("Double-click. Done.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let build = model.developmentBuild {
                Text("DEV \(build)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    private var preferences: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsSection(title: "BEHAVIOR") {
                    VStack(spacing: 0) {
                        ToggleRow(
                            title: "Install immediately",
                            detail: "No confirmation after opening a package.",
                            isOn: $model.installImmediately
                        )
                        rowDivider
                        ToggleRow(
                            title: "Corner progress",
                            detail: "A small, calm indicator while work is active.",
                            isOn: $model.showHUD
                        )
                        rowDivider
                        ToggleRow(
                            title: "Start at login",
                            detail: "Stay hidden and ready for package files.",
                            isOn: $model.launchAtLogin
                        )
                    }
                    .cardStyle()
                }

                SettingsSection(title: "SYSTEM") {
                    VStack(spacing: 0) {
                        IntegrationRow(
                            title: "Finder routing",
                            state: model.routingState,
                            buttonTitle: nil,
                            action: {}
                        )
                        rowDivider
                        IntegrationRow(
                            title: "Installer service",
                            state: model.helperState,
                            buttonTitle: helperButtonTitle,
                            action: helperAction
                        )
                        rowDivider
                        IntegrationRow(
                            title: "Login item",
                            state: model.loginItemState,
                            buttonTitle: model.loginItemState == .needsApproval ? "Open Settings" : nil,
                            action: model.openBackgroundItemSettings
                        )
                    }
                    .cardStyle()
                }

                HStack {
                    Text("MacPack \(appVersion)")
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }

    private var queue: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Queue")
                        .font(.system(size: 16, weight: .semibold))
                    Text(queueSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.jobs.contains(where: { $0.status.isFinished }) {
                    Button("Clear Finished", action: model.clearFinished)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            if model.jobs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Nothing waiting")
                        .font(.system(size: 14, weight: .medium))
                    Text("Open any .pkg and it will appear here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.jobs.reversed()) { job in
                            JobRow(job: job, model: model)
                            Divider().padding(.leading, 50)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 14)
    }

    private var helperButtonTitle: String? {
        switch model.helperState {
        case .ready, .checking: return nil
        case .needsApproval: return "Open Settings"
        case .notConfigured, .unavailable: return "Enable"
        }
    }

    private func helperAction() {
        if model.helperState == .needsApproval {
            model.openBackgroundItemSettings()
        } else {
            model.enableInstallerService()
        }
    }

    private var queueSubtitle: String {
        switch model.pendingCount {
        case 0: return "Ready for packages"
        case 1: return "1 package pending"
        default: return "\(model.pendingCount) packages pending"
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.55)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            content
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(13)
    }
}

private struct IntegrationRow: View {
    let title: String
    let state: IntegrationState
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if let buttonTitle {
                Button(buttonTitle, action: action)
                    .controlSize(.mini)
            }
        }
        .padding(12)
    }

    private var detail: String {
        if case let .unavailable(message) = state { return message }
        return state.label
    }

    private var stateColor: Color {
        switch state {
        case .ready: return .green
        case .checking: return .secondary
        case .needsApproval: return .orange
        case .notConfigured, .unavailable: return .red
        }
    }
}

private struct JobRow: View {
    let job: InstallJob
    @ObservedObject var model: MacPackModel
    // Plain State storage (not the @State macro): the Command Line Tools
    // toolchain ships without the SwiftUIMacros plugin.
    private let hoverState = State(initialValue: false)
    private var isHovering: Bool {
        get { hoverState.wrappedValue }
        nonmutating set { hoverState.wrappedValue = newValue }
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(job.fileName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(statusLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if job.status == .installing || job.status == .postProcessing {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }

                Text(job.message)
                    .font(.system(size: 10))
                    .foregroundStyle(job.status == .failed ? .red : .secondary)
                    .lineLimit(2)
            }

            if job.status == .waiting {
                Button("Install") { model.approve(job.id) }
                    .controlSize(.small)
            } else if job.status == .queued {
                Button {
                    model.cancel(job.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Remove from queue")
            } else if job.status == .failed {
                Button("Retry") { model.retry(job.id) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            if job.status == .queued && isHovering {
                Color.accentColor.opacity(0.06)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if job.status == .queued {
                model.prioritize(job.id)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(job.status == .queued ? "Click to make this package next" : job.message)
    }

    private var statusLabel: String {
        if job.status == .queued {
            if job.message == "Up next" { return "Up next" }
            if isHovering { return "Make next" }
        }
        return job.status.label
    }

    private var iconName: String {
        switch job.status {
        case .staging: return "arrow.triangle.2.circlepath.circle.fill"
        case .waiting: return "pause.circle.fill"
        case .queued: return "clock.fill"
        case .installing: return "arrow.down.circle.fill"
        case .postProcessing: return "sparkles"
        case .installed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch job.status {
        case .installed: return .green
        case .failed: return .red
        case .staging, .installing, .postProcessing: return .accentColor
        default: return .secondary
        }
    }
}

private struct NoticeBar: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }
}

private extension View {
    func cardStyle() -> some View {
        background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                }
        )
    }
}
