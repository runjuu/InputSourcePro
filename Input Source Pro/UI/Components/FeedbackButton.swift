import SwiftUI

struct FeedbackButton: View {
    @EnvironmentObject var feedbackVM: FeedbackVM

    var body: some View {
        Button(
            action: feedbackVM.show,
            label: {
                HStack {
                    Text("Send Feedback".i18n() + "...")
                    Spacer()
                }
            }
        )
        .buttonStyle(SectionButtonStyle())
    }
}

struct FeedbackModal: ViewModifier {
    @EnvironmentObject var feedbackVM: FeedbackVM

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: .constant(feedbackVM.isPresented), content: {
                LoadingView(isShowing: feedbackVM.isSending) {
                    VStack(alignment: .leading) {
                        if feedbackVM.isSent {
                            HStack {
                                Spacer()

                                VStack {
                                    Text("FeedbackSuccessTips".i18n())
                                        .multilineTextAlignment(.center)
                                        .font(.system(size: 16))
                                        .padding(.horizontal)
                                        .padding(.vertical, 30)

                                    Button("Close".i18n()) {
                                        feedbackVM.hide()
                                    }
                                    .keyboardShortcut(.defaultAction)
                                    .padding(.bottom)
                                }

                                Spacer()
                            }
                        } else {
                            Text("FeedbackTips".i18n())
                                .foregroundColor(.primary.opacity(0.8))
                                .padding(.vertical, 8)

                            Text("FeedbackMessageTitle".i18n() + ":")

                            ISPTextEditor(text: $feedbackVM.message, placeholder: "FeedbackMessagePlaceholder".i18n(), minHeight: 80)

                            Text("FeedbackEmailTitle".i18n() + ":")
                                .padding(.top, 8)

                            ISPTextEditor(text: $feedbackVM.email, placeholder: "support@inputsource.pro", minHeight: 0)

                            HStack {
                                Spacer()

                                Button("Cancel".i18n()) {
                                    feedbackVM.hide()
                                }
                                .keyboardShortcut(.cancelAction)

                                Button("Send Feedback".i18n()) {
                                    Task {
                                        await feedbackVM.sendFeedback()
                                    }
                                }
                                .keyboardShortcut(.defaultAction)
                                .disabled(feedbackVM.message.isEmpty)
                            }
                            .padding(.top)
                        }
                    }
                    .lineLimit(nil)
                    .padding()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 450)
                    .disabled(feedbackVM.isSending)
                }
                .background(NSColor.background.color)
            })
    }
}
