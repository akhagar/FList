import SwiftUI
import UIKit

struct ItemRowView: View {
    let item: ShortageItem
    var addedByDisplayName: String
    var onToggle: () -> Void
    var onEdit: () -> Void
    var onViewPhoto: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.status == .restocked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.status == .restocked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.status == .restocked ? L10n.string( "Mark as needed") : L10n.string( "Mark as back in stock"))

            if let photoData = item.photoData, let image = UIImage(data: photoData) {
                Button(action: onViewPhoto) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.black.opacity(0.08), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("View photo"))
            }

            Button(action: onEdit) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.name)
                                .font(.headline)
                                .strikethrough(item.status == .restocked)
                                .foregroundStyle(.primary)
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("Edit item"))
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

struct ItemPhotoViewer: View {
    let image: UIImage
    var title: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                scale = min(max(1, lastScale * value.magnification), 5)
                            }
                            .onEnded { _ in
                                if scale < 1.05 {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        scale = 1
                                        lastScale = 1
                                    }
                                } else {
                                    lastScale = scale
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if scale > 1 {
                                scale = 1
                                lastScale = 1
                            } else {
                                scale = 2.5
                                lastScale = 2.5
                            }
                        }
                    }
                    .accessibilityHidden(true)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}
