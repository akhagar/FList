import SwiftUI

struct FamilyMembersView: View {
    @Bindable var store: FListStore
    @State private var shareError: String?
    @State private var newMember: FamilyMember?
    @State private var memberToRemove: FamilyMember?
    @State private var showHouseholdPicker = false
    @State private var showInviteCode = false
    @State private var confirmAbandon = false
    @State private var listName = ""
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage(AppAccent.storageKey) private var accentRaw = AppAccent.green.rawValue

    var body: some View {
        List {
            Section {
                TextField("List name", text: $listName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit {
                        Task { await store.renameHousehold(listName) }
                    }
                Button("Save") {
                    Task { await store.renameHousehold(listName) }
                }
                .disabled(listName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("List name")
            } footer: {
                Text("This name appears at the top of the list for everyone who shares it.")
            }

            Section {
                Picker("Appearance", selection: $appearanceRaw) {
                    Text("iPhone settings").tag(AppAppearance.system.rawValue)
                    Text("Light").tag(AppAppearance.light.rawValue)
                    Text("Dark").tag(AppAppearance.dark.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Appearance")

                HStack(spacing: 10) {
                    ForEach(AppAccent.allCases) { accent in
                        Button {
                            accentRaw = accent.rawValue
                        } label: {
                            Circle()
                                .fill(accent.color)
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if accentRaw == accent.rawValue {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .overlay {
                                    Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accent.titleKey)
                        .accessibilityAddTraits(accentRaw == accent.rawValue ? .isSelected : [])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
            } header: {
                Text("Theme")
            } footer: {
                Text("Only on this iPhone.")
            }

            if !store.members.isEmpty {
                Section {
                    ForEach(store.members) { member in
                        Toggle(isOn: notifyBinding(for: member)) {
                            Text(member.isCurrentUser ? L10n.string("\(member.name) (you)") : member.name)
                        }
                    }
                } header: {
                    Text("Notify when items are added")
                } footer: {
                    Text("Choose who gets a notification when someone adds a missing item.")
                }
            }

            Section("Household") {
                if store.members.isEmpty {
                    Text("Just you for now")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.members) { member in
                        NavigationLink {
                            MemberEditorView(store: store, member: member)
                                .id(member.id)
                        } label: {
                            HStack(spacing: 12) {
                                MemberAvatar(member: member, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.isCurrentUser ? L10n.string("\(member.name) (you)") : member.name)
                                    Text(statusLine(for: member))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if store.canRemove(member) {
                                Button(role: .destructive) {
                                    memberToRemove = member
                                } label: {
                                    Label("Remove from list", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Button {
                    newMember = FamilyMember(
                        id: UUID().uuidString,
                        name: "",
                        role: .member,
                        inviteState: .accepted,
                        isCurrentUser: false,
                        isCustom: true
                    )
                } label: {
                    Label("Add person", systemImage: "plus.circle")
                }
            }

            Section {
                if store.usesiCloud {
                    Button {
                        CloudSharingPresenter.present(
                            title: store.householdName,
                            prepareShare: { try await store.prepareShare() },
                            onError: { shareError = $0 },
                            onChanged: {
                                Task { await store.refresh() }
                            }
                        )
                    } label: {
                        Label(store.isOwner ? "Invite family" : "Sharing details", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!store.isOwner)

                    if store.isOwner {
                        Button {
                            showInviteCode = true
                        } label: {
                            Label("Show invite code", systemImage: "qrcode")
                        }
                    }
                }
            } footer: {
                Text(footerText)
            }

            Section {
                if store.usesiCloud {
                    Button {
                        showHouseholdPicker = true
                    } label: {
                        Label("Switch list", systemImage: "arrow.left.arrow.right")
                    }
                }

                Button(store.isOwner || !store.usesiCloud ? "Delete this list" : "Leave this list", role: .destructive) {
                    confirmAbandon = true
                }
            } footer: {
                Text(store.isOwner || !store.usesiCloud
                     ? "Deletes this list for everyone who shares it."
                     : "You leave this shared list. The rest of the family keeps it.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            listName = store.householdName
        }
        .onDisappear {
            Task { await store.renameHousehold(listName) }
        }
        .onChange(of: store.householdName) { _, name in
            listName = name
        }
        .sheet(item: $newMember) { member in
            NavigationStack {
                MemberEditorView(store: store, member: member, isNew: true)
            }
        }
        .confirmationDialog(
            "Remove from list",
            isPresented: Binding(
                get: { memberToRemove != nil },
                set: { if !$0 { memberToRemove = nil } }
            ),
            titleVisibility: .visible,
            presenting: memberToRemove
        ) { member in
            Button("Remove from list", role: .destructive) {
                Task {
                    await store.deleteMember(member)
                    memberToRemove = nil
                }
            }
            Button("Cancel", role: .cancel) {
                memberToRemove = nil
            }
        } message: { member in
            Text("Remove \(member.name) from the family list?")
        }
        .sheet(isPresented: $showHouseholdPicker) {
            HouseholdPickerView(store: store)
        }
        .sheet(isPresented: $showInviteCode) {
            InviteCodeSheet(store: store)
        }
        .confirmationDialog(
            store.isOwner || !store.usesiCloud ? "Delete this list" : "Leave this list",
            isPresented: $confirmAbandon,
            titleVisibility: .visible
        ) {
            Button(store.isOwner || !store.usesiCloud ? "Delete this list" : "Leave this list", role: .destructive) {
                Task { await store.abandonCurrentHousehold() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.isOwner || !store.usesiCloud
                 ? "Deletes this list for everyone who shares it."
                 : "You leave this shared list. The rest of the family keeps it.")
        }
        .alert("Couldn't share", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "")
        }
    }

    private func notifyBinding(for member: FamilyMember) -> Binding<Bool> {
        Binding(
            get: { store.receivesNewItemNotifications(member) },
            set: { store.setReceivesNewItemNotifications(member, enabled: $0) }
        )
    }

    private func statusLine(for member: FamilyMember) -> String {
        let role = member.role.title
        if member.inviteState == .pending {
            return L10n.string("\(role) · Invited")
        }
        return role
    }

    private var footerText: String {
        if !store.usesiCloud {
            return L10n.string("Sign in to iCloud in Settings to invite people from your Family Sharing group. Apple doesn't let apps read that group automatically — you invite them once with Share.")
        }
        return L10n.string("Your items stay in your Private FamilyShortage zone. Invited people don't get a copy there — after they join, the same zone shows under Shared on their iCloud account. Use the invite code or QR — a Messages invitation expires and can't be pasted.")
    }
}
