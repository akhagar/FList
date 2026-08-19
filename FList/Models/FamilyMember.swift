import Foundation

struct FamilyMember: Identifiable, Hashable, Codable {
    enum Role: String, Codable {
        case organizer
        case member
        case you

        var title: String {
            switch self {
            case .organizer: L10n.string("Organizer")
            case .member: L10n.string("Member")
            case .you: L10n.string("You")
            }
        }
    }

    enum InviteState: String, Codable {
        case accepted
        case pending
        case unknown

        var title: String {
            switch self {
            case .accepted: L10n.string("Joined")
            case .pending: L10n.string("Invited")
            case .unknown: ""
            }
        }
    }

    var id: String
    var name: String
    var role: Role
    var inviteState: InviteState
    var isCurrentUser: Bool
    var isCustom: Bool
    var photoData: Data?

    init(
        id: String,
        name: String,
        role: Role,
        inviteState: InviteState,
        isCurrentUser: Bool,
        isCustom: Bool = false,
        photoData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.inviteState = inviteState
        self.isCurrentUser = isCurrentUser
        self.isCustom = isCustom
        self.photoData = photoData
    }

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        if letters.isEmpty { return "•" }
        return letters.joined().uppercased()
    }
}
