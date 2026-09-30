import AppKit

enum IndicatorKind {
    case icon
    case title
    case iconAndTitle
    case alwaysOn
}

@MainActor
struct IndicatorViewConfig {
    /// A generic icon + title badge that isn't backed by an `InputSource`
    /// (e.g. the Function Keys / Media Keys mode indicator).
    struct Badge {
        let glyph: BadgeGlyph
        let title: String
    }

    let inputSource: InputSource
    let kind: IndicatorKind
    let size: IndicatorSize
    let bgColor: NSColor?
    let textColor: NSColor?
    let prefersTextInputSourceIcons: Bool

    /// When set, the indicator renders this glyph (SF Symbol or text) + title
    /// instead of the input source. Lets the same pill machinery show
    /// non-input-source state.
    var badge: Badge? = nil

    func render() -> NSView? {
        switch kind {
        case .iconAndTitle:
            if let badge {
                return renderBadgeWithLabel(badge)
            }
            return renderWithLabel()
        case .icon:
            if let badge {
                return renderBadgeWithoutLabel(badge)
            }
            return renderWithoutLabel()
        case .title:
            if let badge {
                return renderBadgeOnlyLabel(badge)
            }
            return renderOnlyLabel()
        case .alwaysOn:
            return renderAlwaysOn()
        }
    }

    func renderAlwaysOn() -> NSView? {
        let containerView = getContainerView()

        containerView.layer?.cornerRadius = 8

        containerView.snp.makeConstraints {
            $0.width.height.equalTo(8)
        }

        return containerView
    }

    private func renderBadgeWithLabel(_ badge: Badge) -> NSView? {
        renderLabeledPill(
            leading: getGlyphBadgeView(badge.glyph),
            label: NSTextField(labelWithString: badge.title)
        )
    }

    private func renderBadgeWithoutLabel(_ badge: Badge) -> NSView? {
        guard let badgeView = getGlyphBadgeView(badge.glyph)
        else { return renderBadgeOnlyLabel(badge) }

        return renderIconPill(leading: badgeView)
    }

    private func renderBadgeOnlyLabel(_ badge: Badge) -> NSView? {
        renderLabeledPill(
            leading: nil,
            label: NSTextField(labelWithString: badge.title)
        )
    }

    /// Shared layout for the labeled-pill indicator variants (glyph/icon + title,
    /// or title only): the container, stack, per-size metrics, and label styling are
    /// identical across them — only the leading content view differs.
    private func renderLabeledPill(leading: NSView?, label: NSTextField) -> NSView {
        let containerView = getContainerView()
        let stackView = NSStackView(views: [leading, label].compactMap { $0 })

        switch size {
        case .small:
            containerView.layer?.cornerRadius = 3
            stackView.spacing = 3
            label.font = .systemFont(ofSize: 10)
        case .medium:
            containerView.layer?.cornerRadius = 4
            stackView.spacing = 5
            label.font = .systemFont(ofSize: 12.6)
        case .large:
            containerView.layer?.cornerRadius = 6
            stackView.spacing = 8
            label.font = .systemFont(ofSize: 20)
        }

        label.textColor = textColor
        stackView.alignment = .centerY
        containerView.addSubview(stackView)

        stackView.snp.makeConstraints { make in
            switch size {
            case .small:
                make.edges.equalToSuperview().inset(NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3))
            case .medium:
                make.edges.equalToSuperview().inset(NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
            case .large:
                make.edges.equalToSuperview().inset(NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6))
            }
        }

        return containerView
    }

    private func renderIconPill(leading: NSView) -> NSView {
        let containerView = getContainerView()
        let stackView = NSStackView(views: [leading])

        containerView.layer?.cornerRadius = 4
        containerView.addSubview(stackView)

        stackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3))
        }

        return containerView
    }

    /// A filled dark mini-badge (foreground color) holding the glyph in the
    /// background color. It uses the same leading-icon size as input-source icons
    /// so icon-only badge rows stay aligned with input-source rows.
    private func getGlyphBadgeView(_ glyph: BadgeGlyph) -> NSView? {
        let badgeSize = CGSize(width: leadingIconWidth, height: leadingIconWidth)
        let pointSize: CGFloat

        switch size {
        case .small:
            pointSize = 8
        case .medium:
            pointSize = 10
        case .large:
            pointSize = 16
        }

        let glyphView: NSView

        switch glyph {
        case let .symbol(name):
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)

            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            else { return nil }

            let imageView = NSImageView(image: image)
            imageView.contentTintColor = bgColor
            glyphView = imageView
        case let .text(text):
            let labelView = NSTextField(labelWithString: text)
            let fontScale: CGFloat = text.count > 1 ? 0.55 : 0.7
            labelView.font = .systemFont(ofSize: leadingIconWidth * fontScale, weight: .regular)
            labelView.textColor = bgColor
            labelView.alignment = .center
            glyphView = labelView
        }

        let badgeView = NSView()
        badgeView.wantsLayer = true
        badgeView.setValue(textColor, forKey: "backgroundColor")
        badgeView.layer?.cornerRadius = leadingIconCornerRadius
        badgeView.layer?.masksToBounds = true
        badgeView.addSubview(glyphView)

        glyphView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        badgeView.snp.makeConstraints { make in
            make.size.equalTo(badgeSize)
        }

        return badgeView
    }

    private func renderWithLabel() -> NSView? {
        guard let imageView = getImageView(inputSource)
        else { return renderOnlyLabel() }

        return renderLabeledPill(
            leading: imageView,
            label: NSTextField(labelWithString: inputSource.name)
        )
    }

    private func renderWithoutLabel() -> NSView? {
        guard let imageView = getImageView(inputSource)
        else { return renderOnlyLabel() }

        return renderIconPill(leading: imageView)
    }

    private func renderOnlyLabel() -> NSView? {
        renderLabeledPill(
            leading: nil,
            label: NSTextField(labelWithString: inputSource.name)
        )
    }

    private func getImageView(_ inputSource: InputSource) -> NSView? {
        if prefersTextInputSourceIcons, let textImage = getTextImageView(inputSource) {
            return textImage
        }

        guard let image = inputSource.icon
        else { return nil }

        let imageView = NSImageView(image: image)

        imageView.contentTintColor = textColor

        imageView.snp.makeConstraints { make in
            let size = imageView.image?.size ?? .zero
            let ratio = size.width > 0 ? size.height / size.width : 1
            let width = leadingIconWidth
            let height = ratio * width

            make.size.equalTo(CGSize(width: width, height: height))
        }

        return imageView
    }

    private var leadingIconWidth: CGFloat {
        switch size {
        case .small:
            return 12
        case .medium:
            return 16
        case .large:
            return 24
        }
    }

    private var leadingIconCornerRadius: CGFloat {
        switch size {
        case .small:
            return 2
        case .medium:
            return 3
        case .large:
            return 4
        }
    }

    private func getTextImageView(_ inputSource: InputSource) -> NSView? {
        guard let labelName = inputSource.getSystemLabelName()
        else { return nil }

        let labelView = NSTextField(labelWithString: labelName)
        labelView.textColor = textColor
        labelView.alignment = .center

        switch size {
        case .small:
            labelView.font = .systemFont(ofSize: labelName.count > 1 ? 7 : 10, weight: .regular)
        case .medium:
            labelView.font = .systemFont(ofSize: labelName.count > 1 ? 10 : 13, weight: .regular)
        case .large:
            labelView.font = .systemFont(ofSize: labelName.count > 1 ? 15 : 20, weight: .regular)
        }

        labelView.snp.makeConstraints { make in
            make.width.equalTo(max(leadingIconWidth, labelView.intrinsicContentSize.width))
        }

        return labelView
    }

    private func getContainerView() -> NSView {
        let containerView = NSView()

        containerView.wantsLayer = true
        containerView.setValue(bgColor, forKey: "backgroundColor")

        containerView.layer?.borderWidth = 1
        containerView.layer?.borderColor = NSColor.black.withAlphaComponent(0.1 * (bgColor?.alphaComponent ?? 1)).cgColor

        return containerView
    }
}
