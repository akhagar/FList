import UIKit

enum ProfileImage {
    static func jpegData(from data: Data, maxDimension: CGFloat = 480) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return jpegData(from: image, maxDimension: maxDimension)
    }

    static func jpegData(from image: UIImage, maxDimension: CGFloat = 480) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return scaled.jpegData(compressionQuality: 0.72)
    }
}
