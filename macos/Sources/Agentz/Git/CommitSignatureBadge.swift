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
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 0 : 4)
            .padding(.vertical, compact ? 0 : 1)
            .background(compact ? .clear : color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
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
            GitForkTheme.orange
        case .none:
            Look.shared.secondary
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
