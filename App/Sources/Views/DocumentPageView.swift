import MinutesCore
import SwiftUI
import UIKit

/// Shows the second page of a meeting's PDF as an image. Only the automated screenshot run
/// opens this (the "document" demo screen), so a drawing fault in the PDF, such as pages after
/// the first coming out mirrored, is visible in the build's screenshots.
struct DocumentPageView: View {
    @EnvironmentObject private var model: AppModel
    let meetingID: String

    var body: some View {
        Group {
            if let image = pageImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .background(Color.white)
            } else {
                Text("The PDF has no second page.")
            }
        }
        .navigationTitle("Document, page 2")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pageImage: UIImage? {
        guard var m = model.meeting(meetingID) else { return nil }
        // Enough transcript for a second page.
        if let u = m.utterances, !u.isEmpty {
            var more = u
            var offset = (u.last?.end ?? 0) + 1
            for _ in 0..<3 {
                for x in u {
                    var copy = x
                    copy.id = more.count
                    copy.start += offset
                    copy.end += offset
                    more.append(copy)
                }
                offset += (u.last?.end ?? 0) + 1
            }
            m.utterances = more
        }
        guard let data = MeetingDocument.pdf(m), let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages >= 2, let page = document.page(at: 2)
        else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let renderer = UIGraphicsImageRenderer(size: box.size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: box.size))
            let cg = context.cgContext
            cg.translateBy(x: 0, y: box.size.height)
            cg.scaleBy(x: 1, y: -1)
            cg.drawPDFPage(page)
        }
    }
}
