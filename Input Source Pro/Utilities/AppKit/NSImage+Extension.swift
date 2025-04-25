import AppKit

extension NSImage {
    func markTemplateIfGrayScaleOrPdf(url: URL? = nil) -> NSImage {
        let image = copy() as! NSImage

        if url?.pathExtension == "pdf" || isGrayScale() {
            image.isTemplate = true
        }

        return image
    }

    func isGrayScale() -> Bool {
        guard let imageRef = cgImage(),
              let colorSpace = imageRef.colorSpace
        else { return false }

        if colorSpace.model == .monochrome {
            return true
        }

        guard let imageData = imageRef.dataProvider?.data,
              let rawData = CFDataGetBytePtr(imageData)
        else { return false }

        var byteIndex = 0

        for _ in 0 ..< imageRef.width * imageRef.height {
            let r = rawData[byteIndex]
            let g = rawData[byteIndex + 1]
            let b = rawData[byteIndex + 2]

            if r == g && g == b {
                byteIndex += 4
            } else {
                return false
            }
        }

        return true
    }

    func cgImage() -> CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
