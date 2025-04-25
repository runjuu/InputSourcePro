import AppKit
import SwiftUI

enum NSToggleViewState {
    case on, off, mixed

    var controlState: NSControl.StateValue {
        switch self {
        case .on:
            return .on
        case .mixed:
            return .mixed
        case .off:
            return .off
        }
    }
}

struct NSToggleView: NSViewRepresentable {
    let label: String
    let state: NSToggleViewState
    let onStateUpdate: () -> NSControl.StateValue

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Self.Context) -> NSButton {
        let button = NSButton()

        button.title = label
        button.allowsMixedState = true
        button.setButtonType(.switch)
        button.target = context.coordinator
        button.action = #selector(Coordinator.onClick(_:))

        return button
    }

    func updateNSView(_ button: NSButton, context _: Self.Context) {
        button.title = label
        button.state = state.controlState
    }
}

extension NSToggleView {
    final class Coordinator: NSObject {
        private let parent: NSToggleView

        init(parent: NSToggleView) {
            self.parent = parent
        }

        @IBAction
        func onClick(_ sender: NSButton) {
            sender.state = parent.onStateUpdate()
        }
    }
}
