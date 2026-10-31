import SwiftUI

struct CommitSignatureBadge: View {
    let signature: GitCommitSignature
    var compact = false

    @ViewBuilder
    var body: some View {
        if signature.status.isSigned {
            Label {
                if !compact {
                    Text(signature.status.title)
                }
            } icon: {
                Image(systemName: symbolName)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(color.opacity(0.24), lineWidth: 1)
            )
            .help(signature.details)
            .accessibilityLabel(signature.details)
        }
    }

    private var color: Color {
        switch signature.status {
        case .good:
            GitForkTheme.green
        case .bad, .revokedKey:
            GitForkTheme.red
        case .unknownValidity, .expiredSignature, .expiredKey, .cannotCheck:
            .orange
        case .none:
            .secondary
        }
    }

    private var symbolName: String {
        switch signature.status {
        case .good:
            "checkmark.seal.fill"
        case .bad, .revokedKey:
            "xmark.seal.fill"
        case .unknownValidity, .expiredSignature, .expiredKey, .cannotCheck:
            "questionmark.diamond.fill"
        case .none:
            "seal"
        }
    }
}
