import Alamofire
import SwiftUI

@MainActor
final class FeedbackVM: ObservableObject {
    enum Status {
        case hided, editing, sending, sent
    }

    var isSent: Bool { status == .sent }

    var isSending: Bool { status == .sending }

    var isPresented: Bool { status != .hided }

    @Published private(set) var status = Status.hided

    @Published var message = ""

    @Published var email = ""

    func show() {
        if status == .hided {
            status = .editing
        }
    }

    func hide() {
        if status != .sending {
            status = .hided
        }
    }

    func sendFeedback() async {
        withAnimation {
            status = .sending
        }

        let _ = await AF
            .request(
                "https://inputsource.pro/api/feedback",
                method: .post,
                parameters: [
                    "message": message,
                    "email": email,
                    "version": "\(Bundle.main.shortVersion) \(Bundle.main.buildVersion)",
                    "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                ],
                encoder: .json
            )
            .serializingDecodable(Alamofire.Empty.self, emptyResponseCodes: [200])
            .response

        message = ""
        email = ""

        withAnimation {
            status = .sent
        }
    }
}
