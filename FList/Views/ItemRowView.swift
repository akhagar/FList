import SwiftUI
import UIKit

struct ItemRowView: View {
    let item: ShortageItem
    var addedByDisplayName: String
    var restockFeedbackLine: String = ""
    var buyingLine: String = ""
    var isBuying: Bool = false
    var onToggle: () -> Void
    var onEdit: () -> Void
    var onRestockWithNote: () -> Void = {}
    var onToggleBuy: () -> Void = {}
    var onDelete: () -> Void = {}
    var onViewPhoto: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: item.status == .restocked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.status == .restocked ? Color.accentColor : .secondary)

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
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.string("View photo"))
                }

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
                    if item.status == .restocked, !restockFeedbackLine.isEmpty {
                        Text(restockFeedbackLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !buyingLine.isEmpty {
                        Text(buyingLine)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .accessibilityLabel(item.name)
        .accessibilityHint(
            item.status == .restocked
                ? L10n.string("Mark as needed")
                : L10n.string("Mark as back in stock")
        )
        .accessibilityAction(named: Text("Edit item")) { onEdit() }
        .contextMenu { itemMenu }
    }

    @ViewBuilder
    private var itemMenu: some View {
        Button(action: onEdit) {
            Label("Edit item", systemImage: "pencil")
        }
        if item.status == .needed {
            Button(action: onRestockWithNote) {
                Label("Back in stock with a note", systemImage: "text.badge.checkmark")
            }
            Button(action: onToggleBuy) {
                if isBuying {
                    Label("Remove from my list", systemImage: "cart.badge.minus")
                } else {
                    Label("I'll buy this", systemImage: "cart.badge.plus")
                }
            }
        }
        if item.photoData != nil {
            Button(action: onViewPhoto) {
                Label("View photo", systemImage: "photo")
            }
        }
        Divider()
        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
        }
    }

    private var subtitle: String {
        if item.status == .restocked, let restockedAt = item.restockedAt {
            let date = restockedAt.formatted(date: .abbreviated, time: .omitted)
            return L10n.string("Back in stock · \(date)")
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
