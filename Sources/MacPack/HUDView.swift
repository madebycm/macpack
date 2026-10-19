import SwiftUI

enum HUDLayout {
    static let width: CGFloat = 232
    static let height: CGFloat = 40
    static let screenMargin: CGFloat = 10
    static let cornerRadius: CGFloat = 12

    static var size: CGSize {
        CGSize(width: width, height: height)
    }
}

struct HUDView: View {
    @ObservedObject var model: MacPackModel
    let openQueue: () -> Void
    let dismiss: () -> Void
    // Plain State storage (not the @State macro): the Command Line Tools
    // toolchain ships without the SwiftUIMacros plugin.
    private let hoverState = State(initialValue: false)
    private var isHovering: Bool {
        get { hoverState.wrappedValue }
        nonmutating set { hoverState.wrappedValue = newValue }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 8) {
                statusGlyph
                    .frame(width: 14, height: 14)

                Text(primaryText)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 3)

                if job?.status == .installing, let progress = job?.progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else if model.pendingCount > 1 {
                    Text("+\(model.pendingCount - 1)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else if let build = model.developmentBuild {
                    Text("D\(build)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.tertiary)
                }

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isHovering ? .primary : .tertiary)
                        .frame(width: 16, height: 16)
                        .background(
                            Circle().fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Hide until the next install")
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)

            if job?.status == .installing, let progress = job?.progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.09))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(
                                width: max(
                                    2,
                                    geometry.size.width * min(max(progress, 0), 1)
                                )
                            )
                    }
                }
                .frame(height: 2)
                .padding(.horizontal, 10)
                .padding(.bottom, 3)
            }
        }
        .frame(width: HUDLayout.width, height: HUDLayout.height)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(
                cornerRadius: HUDLayout.cornerRadius,
                style: .continuous
            )
        )
        .contentShape(
            RoundedRectangle(
                cornerRadius: HUDLayout.cornerRadius,
                style: .continuous
            )
        )
        .onTapGesture(perform: openQueue)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(primaryText), \(job?.message ?? "Ready")")
    }

    private var job: InstallJob? { model.hudJob }

    private var primaryText: String {
        if job?.status == .postProcessing {
            return job?.message ?? "Cleaning plug-in duplicates…"
        }
        return job?.fileName ?? "MacPack"
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch job?.status {
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .waiting:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .staging, .installing, .postProcessing:
            ProgressView()
                .controlSize(.mini)
        case .queued:
            Image(systemName: "clock.fill").foregroundStyle(.secondary)
        case .cancelled:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        default:
            Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
        }
    }
}
