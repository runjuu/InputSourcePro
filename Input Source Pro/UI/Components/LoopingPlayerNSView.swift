import AppKit
import AVFoundation
import SwiftUI

struct PlayerView: NSViewRepresentable {
    let url: URL

    func updateNSView(_: NSViewType, context _: Context) {}

    func makeNSView(context _: Context) -> some NSView {
        return LoopingPlayerUIView(url: url)
    }
}

class LoopingPlayerUIView: NSView {
    private let playerLayer = AVPlayerLayer()

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    init(url: URL) {
        super.init(frame: .zero)

        // Setup the player
        let player = AVPlayer(url: url)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill

        wantsLayer = true
        layer?.addSublayer(playerLayer)

        // Setup looping
        player.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd(notification:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )

        // Start the movie
        player.play()
    }

    @objc
    func playerItemDidReachEnd(notification _: Notification) {
        playerLayer.player?.seek(to: CMTime.zero)
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
