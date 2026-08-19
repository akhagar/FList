import SwiftUI
import UIKit

struct MemberAvatar: View {
    let member: FamilyMember
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let photoData = member.photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(member.initials)
                    .font(size > 60 ? .title.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.accentColor.opacity(0.15))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
