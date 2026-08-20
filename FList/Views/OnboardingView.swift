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

            if store.availableHouseholds.isEmpty {
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
            } else {
                HouseholdListSection(store: store)
                    .padding(.horizontal)
            }

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

            if store.accountKind == .iCloud {
                InviteLinkField(store: store)

                Button {
                    Task { await store.joinFromInvite() }
                } label: {
                    Text("I was invited")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .disabled(store.isBusy)
                .padding(.horizontal, 24)

                Text("The family list stays in the owner's Private iCloud database. After you join with the invite link, it appears under Shared on your account — not in a second Private zone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.bottom, 24)
        .overlay {
            if store.isBusy {
                ProgressView()
                    .padding(20)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .task {
            await store.refreshAvailableHouseholds()
        }
    }
}

struct InviteLinkField: View {
    @Bindable var store: FListStore
    var onFinished: (() -> Void)? = nil
    @State private var inviteLink = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Paste invite link", text: $inviteLink)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
            Button("Join with link") {
                Task {
                    await store.joinFromInviteLink(inviteLink)
                    if store.errorMessage == nil, store.hasHousehold {
                        onFinished?()
                    }
                }
            }
            .disabled(store.isBusy || inviteLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 24)
    }
}

struct HouseholdListSection: View {
    @Bindable var store: FListStore
    var onSelect: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your lists")
                .font(.headline)
            ForEach(store.availableHouseholds) { household in
                Button {
                    Task {
                        await store.selectHousehold(household)
                        onSelect?()
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(household.title)
                                .foregroundStyle(.primary)
                            Text(household.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.isCurrentHousehold(household) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(store.isBusy)
            }
        }
    }
}

struct HouseholdPickerView: View {
    @Bindable var store: FListStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !store.availableHouseholds.isEmpty {
                    Section("Your lists") {
                        ForEach(store.availableHouseholds) { household in
                            Button {
                                Task {
                                    await store.selectHousehold(household)
                                    if store.errorMessage == nil { dismiss() }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(household.title)
                                            .foregroundStyle(.primary)
                                        Text(household.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if store.isCurrentHousehold(household) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .disabled(store.isBusy)
                        }
                    }
                }

                Section {
                    InviteLinkField(store: store) {
                        dismiss()
                    }

                    Button("Create family list") {
                        Task {
                            await store.createHousehold()
                            if store.errorMessage == nil, store.hasHousehold { dismiss() }
                        }
                    }
                    .disabled(store.isBusy)

                    Button("I was invited") {
                        Task {
                            await store.joinFromInvite()
                            if store.errorMessage == nil, store.hasHousehold { dismiss() }
                        }
                    }
                    .disabled(store.isBusy)
                } footer: {
                    Text("The family list stays in the owner's Private iCloud database. After you join with the invite link, it appears under Shared on your account — not in a second Private zone.")
                }
            }
            .navigationTitle("Choose a list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await store.refreshAvailableHouseholds()
            }
            .overlay {
                if store.isBusy {
                    ProgressView()
                        .padding(20)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
    }
}

#Preview {
    OnboardingView(store: .preview)
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}
