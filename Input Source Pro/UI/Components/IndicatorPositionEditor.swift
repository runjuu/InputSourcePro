import SwiftUI
import VisualEffects

struct IndicatorPositionEditor: View {
    @EnvironmentObject var preferencesVM: PreferencesVM

    let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 3)

    @State var hoveredAlignment: IndicatorPosition.Alignment? = nil

    let height: CGFloat = 230
    let windowHPadding: CGFloat = 30
    let windowVPadding: CGFloat = 15

    var selectedAlignment: IndicatorPosition.Alignment {
        preferencesVM.preferences.indicatorPositionAlignment ?? .bottomRight
    }

    var position: IndicatorPosition {
        preferencesVM.preferences.indicatorPosition ?? .nearMouse
    }

    var alignmentHPadding: CGFloat {
        let offset = position == .windowCorner ? windowHPadding : 0
        let minLength = position == .windowCorner ? height - offset * 2 : height
        let spacing = preferencesVM.calcSpacing(minLength: minLength)

        return spacing + offset
    }

    var alignmentVPadding: CGFloat {
        let offset = position == .windowCorner ? windowVPadding : 0
        let minLength = position == .windowCorner ? height - offset * 2 : height
        let spacing = preferencesVM.calcSpacing(minLength: minLength)

        return spacing + offset
    }

    let items: [IndicatorPosition.Alignment] = [
        .topLeft, .topCenter, .topRight,
        .centerLeft, .center, .centerRight,
        .bottomLeft, .bottomCenter, .bottomRight,
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(items, id: \.self) { (alignment: IndicatorPosition.Alignment) in
                IndicatorAlignmentItem(
                    alignment: alignment,
                    position: position,
                    isSelected: selectedAlignment == alignment,
                    content: {
                        let offset = offset(alignment: alignment)

                        alignment.indicator()
                            .rotationEffect(alignment.rotate)
                            .offset(x: offset.x, y: offset.y)
                            .foregroundColor(Color.primary)
                    }
                )
                .frame(height: height / 3)
                .onTapGesture {
                    withAnimation {
                        preferencesVM.update {
                            $0.indicatorPositionAlignment = alignment
                        }
                    }
                }
            }
            .opacity(position == .nearMouse ? 0 : 1)
        }
        .background(
            IndicatorAlignmentView(
                alignment: position == .nearMouse ? .center : selectedAlignment
            ) {
                IndicatorView()
                    .fixedSize()
                    .padding(.horizontal, alignmentHPadding)
                    .padding(.vertical, alignmentVPadding)
            }
        )
        .background(
            windowIndicator()
        )
        .background(
            Image("FakeDesktop")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .scaledToFill()
        )
    }

    @ViewBuilder
    func windowIndicator() -> some View {
        MockWindowView()
            .padding(.horizontal, windowHPadding)
            .padding(.vertical, windowVPadding)
            .frame(height: height)
            .opacity(position == .windowCorner ? 1 : 0)
            .offset(x: 0, y: position == .windowCorner ? 0 : height)
    }

    func offset(alignment: IndicatorPosition.Alignment) -> (x: Double, y: Double) {
        switch alignment {
        case .center:
            return (0, 0)
        case .centerLeft:
            return (alignmentHPadding, 0)
        case .centerRight:
            return (-alignmentHPadding, 0)
        case .topLeft:
            return (alignmentHPadding, alignmentVPadding)
        case .topCenter:
            return (0, alignmentVPadding)
        case .topRight:
            return (-alignmentHPadding, alignmentVPadding)
        case .bottomLeft:
            return (alignmentHPadding, -alignmentVPadding)
        case .bottomCenter:
            return (0, -alignmentVPadding)
        case .bottomRight:
            return (-alignmentHPadding, -alignmentVPadding)
        }
    }
}

struct IndicatorAlignmentItem<Content: View>: View {
    let alignment: IndicatorPosition.Alignment

    let position: IndicatorPosition

    let isSelected: Bool

    let content: Content

    @State var isHovered: Bool = false

    init(alignment: IndicatorPosition.Alignment, position: IndicatorPosition, isSelected: Bool, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.position = position
        self.isSelected = isSelected
        self.content = content()
    }

    var body: some View {
        IndicatorAlignmentView(alignment: alignment) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .opacity(isSelected ? 0 : 1)
        .opacity(isHovered ? 0.9 : 0.3)
        .animation(.default, value: isSelected)
        .animation(.default, value: isHovered)
        .onHover(perform: { isHovered = $0 })
    }
}

private extension IndicatorPosition.Alignment {
    var rotate: Angle {
        switch self {
        case .topLeft:
            return .degrees(-90)
        case .topRight:
            return .zero
        case .bottomLeft:
            return .degrees(180)
        case .bottomRight:
            return .degrees(90)
        case .center:
            return .degrees(45)
        case .centerLeft:
            return .zero
        case .centerRight:
            return .zero
        case .topCenter:
            return .zero
        case .bottomCenter:
            return .zero
        }
    }

    @ViewBuilder
    func indicator() -> some View {
        switch self {
        case .center:
            Rectangle()
                .frame(width: 30, height: 30)
                .cornerRadius(3)
        case .topCenter, .bottomCenter:
            Rectangle()
                .frame(width: 44, height: 8)
                .cornerRadius(2)
        case .centerLeft, .centerRight:
            Rectangle()
                .frame(width: 8, height: 30)
                .cornerRadius(2)
        default:
            Image(nsImage: .triangle)
                .resizable()
                .scaledToFit()
                .frame(width: 30)
        }
    }
}
