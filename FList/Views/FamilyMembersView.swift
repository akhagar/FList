import SwiftUI

struct FamilyMembersView: View {
    @Bindable var store: FListStore
    @State private var shareError: String?
    @State private var newMember: FamilyMember?
    @State private var memberToRemove: FamilyMember?

    var body: some View {
        List {
            Section("Household") {
                if store.members.isEmpty {
                    Text("Just you for now")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.members) { member in
                        NavigationLink {
                            MemberEditorView(store: store, member: member)
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
                }
            } footer: {
                Text(footerText)
            }
        }
        .navigationTitle("Family")
        .navigationBarTitleDisplayMode(.inline)
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
        .alert("Couldn't share", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "")
        }
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
        return L10n.string("Send the invite once with Messages. Whoever opens the link on their iPhone can join this list.")
    }
}
