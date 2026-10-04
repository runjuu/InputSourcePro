import AXSwift
import Cocoa

extension UIElement {
    func getCursorRectInfo(traceID: String = UUID().uuidString) -> (rect: CGRect, isContainer: Bool)? {
        let focusedElement: UIElement
        do {
            guard let element: UIElement = try attribute(.focusedUIElement) else {
                IndicatorDiagnostics.record("AX.focusMissing id=\(traceID) reason=nil")
                return nil
            }
            focusedElement = element
        } catch {
            IndicatorDiagnostics.record("AX.focusMissing id=\(traceID) error=\(error)")
            return nil
        }
        if IndicatorDiagnostics.isEnabled {
            var pid: pid_t = 0
            let result = AXUIElementGetPid(focusedElement.element, &pid)
            IndicatorDiagnostics.record("AX.focus id=\(traceID) actualPID=\(pid) pidStatus=\(result.rawValue)")
        }
        guard Self.isInputContainer(focusedElement) else {
            IndicatorDiagnostics.record("AX.rejected id=\(traceID) reason=non-input-focus")
            return nil
        }
        guard let inputAreaRect = Self.findInputAreaRect(focusedElement) else {
            IndicatorDiagnostics.record("AX.rejected id=\(traceID) reason=no-input-area")
            return nil
        }

        let cursorRect = Self.findCursorRect(focusedElement, traceID: traceID)
        if let cursorRect = cursorRect, inputAreaRect.contains(cursorRect) {
            IndicatorDiagnostics.record("AX.accepted id=\(traceID) cursor=\(cursorRect) area=\(inputAreaRect)")
            return (rect: cursorRect, isContainer: false)
        } else {
            IndicatorDiagnostics.record("AX.containerFallback id=\(traceID) cursor=\(String(describing: cursorRect)) area=\(inputAreaRect) reason=missing-or-outside-area")
            return (rect: inputAreaRect, isContainer: true)
        }
    }
}

extension UIElement {
    static func isInputContainer(_ elm: UIElement?) -> Bool {
        guard let elm = elm,
              let role = try? elm.role()
        else { return false }

        return role == .textArea || role == .textField || role == .comboBox
    }

    static func findInputAreaRect(_ focusedElement: UIElement) -> CGRect? {
        if let parent: UIElement = try? focusedElement.attribute(.parent),
           let role = try? parent.role(),
           role == .scrollArea,
           let origin: CGPoint = try? parent.attribute(.position),
           let size: CGSize = try? parent.attribute(.size)
        {
            return NSScreen.convertFromQuartz(CGRect(origin: origin, size: size))
        }

        if let origin: CGPoint = try? focusedElement.attribute(.position),
           let size: CGSize = try? focusedElement.attribute(.size)
        {
            return NSScreen.convertFromQuartz(CGRect(origin: origin, size: size))
        }

        return nil
    }
}

extension UIElement {
    static func findCursorRect(_ focusedElement: UIElement, traceID: String = UUID().uuidString) -> CGRect? {
        if let rect = findWebAreaCursor(focusedElement) {
            IndicatorDiagnostics.record("AX.cursor id=\(traceID) method=text-marker rect=\(rect)")
            return rect
        }
        let rect = findNativeInputAreaCursor(focusedElement, traceID: traceID)
        IndicatorDiagnostics.record("AX.cursor id=\(traceID) method=native rect=\(String(describing: rect))")
        return rect
    }

    static func findWebAreaCursor(_ focusedElement: UIElement) -> CGRect? {
        guard let range: AXTextMarkerRange = try? focusedElement.attribute("AXSelectedTextMarkerRange"),
              let bounds: CGRect = try? focusedElement.parameterizedAttribute("AXBoundsForTextMarkerRange", param: range)
        else { return nil }

        return NSScreen.convertFromQuartz(bounds)
    }

    static func findNativeInputAreaCursor(_ focusedElement: UIElement, traceID: String = UUID().uuidString) -> CGRect? {
        guard let selectedRange: CFRange = try? focusedElement.attribute(.selectedTextRange),
              let visibleRange: CFRange = try? focusedElement.attribute(.visibleCharacterRange),
              let rawValue: AnyObject = try? focusedElement.attribute(.value),
              CFGetTypeID(rawValue) == CFStringGetTypeID(),
              let value = rawValue as? String
        else { return nil }

        func getBounds(cursor location: Int) -> CGRect? {
            return try? focusedElement.parameterizedAttribute(
                kAXBoundsForRangeParameterizedAttribute,
                param: AXValue.range(CFRange(location: max(location, 0), length: 1))
            )
            .flatMap(NSScreen.convertFromQuartz)
        }

        func getCursorBounds() -> CGRect? {
            let lastCursor = visibleRange.location + visibleRange.length
            // Notes 最后存在两个换行符时会有问题
            // let isLastCursor = selectedRange.location >= (lastCursor - 1)
            let isLastCursor = selectedRange.location >= lastCursor
            let location = selectedRange.location - (isLastCursor ? 1 : 0)

            guard let bounds = getBounds(cursor: location)
            else { return nil }

            if isLastCursor, value.string(at: location) == "\n" {
                if location > 0 {
                    for offsetDiff in 1 ... location {
                        let offset = location - offsetDiff

                        if value.string(at: offset + 1) == "\n",
                           let prevNewLineBounds = getBounds(cursor: offset)
                        {
                            return CGRect(
                                origin: CGPoint(
                                    x: prevNewLineBounds.origin.x,
                                    y: prevNewLineBounds.minY - prevNewLineBounds.height
                                ),
                                size: bounds.size
                            )
                        }
                    }

                    return nil
                } else {
                    return nil
                }
            } else {
                return bounds
            }
        }

        func getLineBounds() -> CGRect? {
            guard let cursorLine: Int = try? focusedElement.attribute(.insertionPointLineNumber),
                  let lineRange: CFRange = try? focusedElement.parameterizedAttribute("AXRangeForLine", param: cursorLine),
                  let bounds: CGRect = try? focusedElement.parameterizedAttribute(
                      kAXBoundsForRangeParameterizedAttribute,
                      param: AXValue.range(lineRange)
                  )
            else { return nil }

            return NSScreen.convertFromQuartz(bounds)
        }

        if let bounds = getCursorBounds() { return bounds }
        let bounds = getLineBounds()
        IndicatorDiagnostics.record("AX.lineFallback id=\(traceID) rect=\(String(describing: bounds))")
        return bounds
    }
}

extension UIElement {
    func children() -> [UIElement]? {
        guard let children: [AXUIElement] = try? attribute(.children)
        else { return nil }

        return children.map { .init($0) }
    }
}

extension Role {
    static let validInputElms: [Role] = [.comboBox, .textArea, .textField]

    static let allCases: [Role] = [
        .unknown,
        .button,
        .radioButton,
        .checkBox,
        .slider,
        .tabGroup,
        .textField,
        .staticText,
        .textArea,
        .scrollArea,
        .popUpButton,
        .menuButton,
        .table,
        .application,
        .group,
        .radioGroup,
        .list,
        .scrollBar,
        .valueIndicator,
        .image,
        .menuBar,
        .menu,
        .menuItem,
        .column,
        .row,
        .toolbar,
        .busyIndicator,
        .progressIndicator,
        .window,
        .drawer,
        .systemWide,
        .outline,
        .incrementor,
        .browser,
        .comboBox,
        .splitGroup,
        .splitter,
        .colorWell,
        .growArea,
        .sheet,
        .helpTag,
        .matte,
        .ruler,
        .rulerMarker,
        .link,
        .disclosureTriangle,
        .grid,
        .relevanceIndicator,
        .levelIndicator,
        .cell,
        .popover,
        .layoutArea,
        .layoutItem,
        .handle,
    ]
}

extension AXNotification {
    static let allCases: [AXNotification] = [
        .mainWindowChanged,
        .focusedWindowChanged,
        .focusedUIElementChanged,
        .applicationActivated,
        .applicationDeactivated,
        .applicationHidden,
        .applicationShown,
        .windowCreated,
        .windowMoved,
        .windowResized,
        .windowMiniaturized,
        .windowDeminiaturized,
        .drawerCreated,
        .sheetCreated,
        .uiElementDestroyed,
        .valueChanged,
        .titleChanged,
        .resized,
        .moved,
        .created,
        .layoutChanged,
        .helpTagCreated,
        .selectedTextChanged,
        .rowCountChanged,
        .selectedChildrenChanged,
        .selectedRowsChanged,
        .selectedColumnsChanged,
        .rowExpanded,
        .rowCollapsed,
        .selectedCellsChanged,
        .unitsChanged,
        .selectedChildrenMoved,
        .announcementRequested,
    ]
}
