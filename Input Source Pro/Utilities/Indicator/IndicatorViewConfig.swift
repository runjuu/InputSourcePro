import AppKit

enum IndicatorKind {
    case icon
    case title
    case iconAndTitle
    case alwaysOn
}

@MainActor
struct IndicatorViewConfig {
    let inputSource: InputSource
    let kind: IndicatorKind
    let size: IndicatorSize
    let bgColor: NSColor?
    let textColor: NSColor?

    func render() -> NSView? {
        switch kind {
        case .iconAndTitle:
            return renderWithLabel()
        case .icon:
            return renderWithoutLabel()
        case .title:
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

    private func renderWithLabel() -> NSView? {
        guard let imageView = getImageView(inputSource)
        else { return renderOnlyLabel() }

        let containerView = getContainerView()
        let labelView = NSTextField(labelWithString: inputSource.name)
        let stackView = NSStackView(views: [imageView, labelView])

        switch size {
        case .small:
            containerView.layer?.cornerRadius = 3
            stackView.spacing = 3
            labelView.font = .systemFont(ofSize: 10)
        case .medium:
            containerView.layer?.cornerRadius = 4
            stackView.spacing = 5
            labelView.font = .systemFont(ofSize: 12.6)
        case .large:
            containerView.layer?.cornerRadius = 6
            stackView.spacing = 8
            labelView.font = .systemFont(ofSize: 20)
        }

        labelView.textColor = textColor
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

    private func renderWithoutLabel() -> NSView? {
        guard let imageView = getImageView(inputSource)
        else { return renderOnlyLabel() }

        let containerView = getContainerView()
        let stackView = NSStackView(views: [imageView])

        containerView.layer?.cornerRadius = 4
        containerView.addSubview(stackView)

        stackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3))
        }

        return containerView
    }

    private func renderOnlyLabel() -> NSView? {
        let containerView = getContainerView()
        let labelView = NSTextField(labelWithString: inputSource.name)
        let stackView = NSStackView(views: [labelView])

        switch size {
        case .small:
            containerView.layer?.cornerRadius = 3
            stackView.spacing = 3
            labelView.font = .systemFont(ofSize: 10)
        case .medium:
            containerView.layer?.cornerRadius = 4
            stackView.spacing = 5
            labelView.font = .systemFont(ofSize: 12.6)
        case .large:
            containerView.layer?.cornerRadius = 6
            stackView.spacing = 8
            labelView.font = .systemFont(ofSize: 20)
        }

        labelView.textColor = textColor
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

    private func getImageView(_ inputSource: InputSource) -> NSView? {
//    if let textImage = getTextImageView(inputSource) { return textImage }

        guard let image = inputSource.icon
        else { return nil }

        let imageView = NSImageView(image: image)

        imageView.contentTintColor = textColor

        imageView.snp.makeConstraints { make in
            let size = imageView.image?.size ?? .zero
            let ratio = size.height / size.width
            let width: CGFloat = {
                switch self.size {
                case .small:
                    return 12
                case .medium:
                    return 16
                case .large:
                    return 24
                }
            }()
            let height = ratio * width

            make.size.equalTo(CGSize(width: width, height: height))
        }

        return imageView
    }

    private func getTextImageView(_ inputSource: InputSource) -> NSView? {
        guard let labelName = inputSource.getSystemLabelName()
        else { return nil }

        let labelView = NSTextField(labelWithString: labelName)
        let view = NSView()

        view.addSubview(labelView)
        view.wantsLayer = true
        view.layer?.backgroundColor = textColor?.cgColor
        view.layer?.cornerRadius = 2

        labelView.snp.makeConstraints {
            $0.center.equalTo(view)
        }

        view.snp.makeConstraints {
//      $0.width.equalTo(22)
            $0.width.height.equalTo(16)
        }

        labelView.textColor = bgColor
        labelView.font = .systemFont(ofSize: labelName.count > 1 ? 10 : 11, weight: .regular)

        return view
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
