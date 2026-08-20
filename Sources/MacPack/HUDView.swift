import SwiftUI

struct HUDView: View {
    @ObservedObject var model: MacPackModel
    let openQueue: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            statusGlyph

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(job?.fileName ?? "MacPack")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if model.pendingCount > 1 {
                        Text("+\(model.pendingCount - 1)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if let build = model.developmentBuild {
                        Text("D\(build)")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }

                if job?.status == .installing {
                    ProgressView(value: job?.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(.accentColor)
                } else {
                    Text(job?.message ?? "Ready")
                        .font(.system(size: 10))
                        .foregroundStyle(messageColor)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 13)
        .frame(width: 300, height: 58)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: openQueue)
    }

    private var job: InstallJob? { model.hudJob }

    @ViewBuilder
    private var statusGlyph: some View {
        switch job?.status {
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .waiting:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        default:
            Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
        }
    }

    private var messageColor: Color {
        job?.status == .failed ? .red : .secondary
    }
}
