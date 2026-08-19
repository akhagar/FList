import SwiftUI

struct ItemRowView: View {
    let item: ShortageItem
    var addedByDisplayName: String
    var onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.status == .restocked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.status == .restocked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.status == .restocked ? L10n.string( "Mark as needed") : L10n.string( "Mark as back in stock"))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.name)
                        .font(.headline)
                        .strikethrough(item.status == .restocked)
                    if item.quantity > 1 {
                        Text("×\(item.quantity)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        if item.status == .restocked, let restockedAt = item.restockedAt {
            let date = restockedAt.formatted(date: .abbreviated, time: .omitted)
            return L10n.string( "Back in stock · \(date)")
        }
        return L10n.string("Added by \(addedByDisplayName)")
    }
}
