import SwiftUI

struct OnboardingView: View {
    @Bindable var store: FListStore

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "basket.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Family shortage list")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("One shared list of what's missing at home. Anyone in the family can add an item, then check it off when it's back in stock.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("Add milk, soap, or anything you're out of", systemImage: "plus.circle.fill")
                Label("Mark it when it's back on the shelf", systemImage: "checkmark.circle.fill")
                Label("Share with your iCloud Family via Apple's share sheet", systemImage: "person.3.fill")
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)

            if store.accountKind == .localOnly {
                Text("You're not signed in to iCloud, so this list stays on this iPhone. Sign in under Settings to share it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else if store.accountKind == .restricted {
                Text("iCloud is restricted on this device. You can still keep a local list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            Button {
                Task { await store.createHousehold() }
            } label: {
                Text(store.accountKind == .iCloud ? "Create family list" : "Start list on this iPhone")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

#Preview {
    OnboardingView(store: .preview)
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}
