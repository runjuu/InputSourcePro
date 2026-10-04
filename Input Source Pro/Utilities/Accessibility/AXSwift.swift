import AXSwift
import Cocoa

struct CursorRectInfo {
    enum Kind { case caret, text, container }

    let rect: CGRect
    let kind: Kind

    var isContainer: Bool { kind == .container }
    var indicatorPoint: CGPoint {
        CGPoint(x: kind == .caret ? rect.midX : rect.minX, y: rect.maxY + 6)
    }

    static func insertionPoint(rect: CGRect, zeroWidthCaretWidth: CGFloat? = nil) -> CursorRectInfo? {
        guard [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width >= 0, rect.width <= 10, rect.height > 0, rect.height <= 200
        else { return nil }

        var caretRect = rect
        if caretRect.width == 0, let zeroWidthCaretWidth {
            caretRect.size.width = zeroWidthCaretWidth
        }
        return CursorRectInfo(rect: caretRect, kind: .caret)
    }

    static func fallbackCaretWidth(for rect: CGRect) -> CGFloat? {
        if #available(macOS 26, *) {
            let scale = NSScreen.getScreenInclude(rect: rect)?.backingScaleFactor ?? 1
            return 2 / scale
        }
        return nil
    }

    func alignedToSearchField(_ field: CGRect, characterBounds: CGRect?, isEmpty: Bool) -> CursorRectInfo {
        guard kind == .caret else { return self }

        var aligned = rect
        if let characterBounds,
           [characterBounds.origin.x, characterBounds.origin.y, characterBounds.width, characterBounds.height].allSatisfy(\.isFinite),
           characterBounds.height > 0, field.contains(characterBounds)
        {
            // Some NSSearchFields report insertion bounds one line above their text.
            // Keep the insertion x, but use an actual character for the text baseline.
            aligned.origin.y = characterBounds.minY
            aligned.size.height = characterBounds.height
        } else if isEmpty, !field.contains(rect),
                  [field.origin.x, field.origin.y, field.width, field.height].allSatisfy(\.isFinite),
                  field.height >= rect.height
        {
            aligned.origin.y = field.midY - rect.height / 2
        }
        return CursorRectInfo(rect: aligned, kind: kind)
    }

    static func textMarker(rect: CGRect, length: Int?, emptyInputCaretWidth: CGFloat? = nil) -> CursorRectInfo {
        // Empty editors can report the whole line for an empty selection. Apply the
        // same caret bounds as the helper before using the rectangle's center.
        let hasValidBounds = [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width >= 0 && rect.height > 0 && rect.height <= 200
        guard length == 0, hasValidBounds else {
            return CursorRectInfo(rect: rect, kind: .text)
        }
        if rect.width <= 10 {
            return CursorRectInfo(rect: rect, kind: .caret)
        }
        if let emptyInputCaretWidth {
            var caretRect = rect
            caretRect.size.width = emptyInputCaretWidth
            return CursorRectInfo(rect: caretRect, kind: .caret)
        }
        return CursorRectInfo(rect: rect, kind: .text)
    }
}

enum JavaCursorGeometry {
    // See JetBrainsRuntime's CAccessibleText.getBoundsForRange.
    // JetBrains Runtime unions the first and last characters of AXBoundsForRange.
    // A zero-length range therefore includes the previous character, possibly on
    // another line. Use nonempty ranges instead. Coordinates here are AppKit based.
    static func insertionPoint(at location: Int, characterCount: Int, bounds: (CFRange) -> CGRect?) -> CGRect? {
        guard location >= 0, location <= characterCount, characterCount > 0 else { return nil }

        func validBounds(_ range: CFRange) -> CGRect? {
            guard let rect = bounds(range),
                  [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
                  rect.width > 0, rect.height > 0
            else { return nil }
            return rect
        }

        if location < characterCount,
           let character = validBounds(CFRange(location: location, length: 1))
        {
            return CGRect(x: character.minX, y: character.minY, width: 0, height: character.height)
        }

        if location == characterCount {
            guard let previous = validBounds(CFRange(location: location - 1, length: 1)) else { return nil }
            return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }

        // Newline characters have zero width, which Java reports as an empty rect.
        // Union one with a nearby visible character to recover its endpoint. Only
        // accept an x coordinate that extends beyond the reference character.
        for distance in [1, 2, 4, 8, 16, 32] {
            for referenceIndex in [location - distance, location + distance] {
                guard referenceIndex >= 0, referenceIndex < characterCount,
                      let reference = validBounds(CFRange(location: referenceIndex, length: 1)),
                      let union = validBounds(CFRange(location: min(location, referenceIndex), length: distance + 1)),
                      union.contains(reference)
                else { continue }

                let x: CGFloat
                if union.minX < reference.minX {
                    x = union.minX
                } else if union.maxX > reference.maxX {
                    x = union.maxX
                } else {
                    continue
                }
                let y = union.minY < reference.minY ? union.minY : union.maxY - reference.height
                return CGRect(x: x, y: y, width: 0, height: reference.height)
            }
        }
        return nil
    }
}

extension UIElement {
    func getCursorRectInfo(traceID: String = UUID().uuidString) -> CursorRectInfo? {
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

        let usesJavaTextRanges = focusedElement.usesJavaTextRanges
        let cursorRect = Self.findCursorRect(focusedElement, usesJavaTextRanges: usesJavaTextRanges, traceID: traceID)
        if let cursorRect = cursorRect, inputAreaRect.contains(cursorRect.rect) {
            IndicatorDiagnostics.record("AX.accepted id=\(traceID) cursor=\(cursorRect.rect) kind=\(cursorRect.kind) area=\(inputAreaRect)")
            return cursorRect
        } else {
            if usesJavaTextRanges {
                IndicatorDiagnostics.record("AX.rejected id=\(traceID) reason=java-caret-missing-or-outside-area")
                return nil
            }
            IndicatorDiagnostics.record("AX.containerFallback id=\(traceID) cursor=\(String(describing: cursorRect)) area=\(inputAreaRect) reason=missing-or-outside-area")
            return CursorRectInfo(rect: inputAreaRect, kind: .container)
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
    private var usesJavaTextRanges: Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        else { return false }
        return bundleID.hasPrefix("com.jetbrains.")
    }

    static func findCursorRect(_ focusedElement: UIElement, usesJavaTextRanges: Bool = false, traceID: String = UUID().uuidString) -> CursorRectInfo? {
        if let rect = findWebAreaCursor(focusedElement) {
            IndicatorDiagnostics.record("AX.cursor id=\(traceID) method=text-marker rect=\(rect.rect) kind=\(rect.kind)")
            return rect
        }
        let rect = findNativeInputAreaCursor(focusedElement, usesJavaTextRanges: usesJavaTextRanges, traceID: traceID)
        IndicatorDiagnostics.record("AX.cursor id=\(traceID) method=native rect=\(String(describing: rect))")
        return rect
    }

    static func findWebAreaCursor(_ focusedElement: UIElement) -> CursorRectInfo? {
        guard let range: AXTextMarkerRange = try? focusedElement.attribute("AXSelectedTextMarkerRange"),
              let bounds: CGRect = try? focusedElement.parameterizedAttribute("AXBoundsForTextMarkerRange", param: range)
        else { return nil }

        let length: Int? = try? focusedElement.parameterizedAttribute("AXLengthForTextMarkerRange", param: range)
        return NSScreen.convertFromQuartz(bounds).map { rect in
            CursorRectInfo.textMarker(rect: rect, length: length, emptyInputCaretWidth: CursorRectInfo.fallbackCaretWidth(for: rect))
        }
    }

    static func findNativeInputAreaCursor(_ focusedElement: UIElement, usesJavaTextRanges: Bool = false, traceID: String = UUID().uuidString) -> CursorRectInfo? {
        guard let selectedRange: CFRange = try? focusedElement.attribute(.selectedTextRange)
        else { return nil }

        if usesJavaTextRanges {
            guard let characterCount: Int = try? focusedElement.attribute(.numberOfCharacters),
                  let rect = JavaCursorGeometry.insertionPoint(at: selectedRange.location, characterCount: characterCount, bounds: { range in
                      let bounds: CGRect? = try? focusedElement.parameterizedAttribute(
                          kAXBoundsForRangeParameterizedAttribute, param: AXValue.range(range)
                      )
                      return bounds.flatMap(NSScreen.convertFromQuartz)
                  })
            else { return nil }
            IndicatorDiagnostics.record("AX.javaInsertionPoint id=\(traceID) rect=\(rect)")
            return CursorRectInfo.insertionPoint(rect: rect, zeroWidthCaretWidth: CursorRectInfo.fallbackCaretWidth(for: rect))
        }

        // A zero-length range asks for the insertion point, including at the end of
        // text. Empty native fields can provide this even when AXValue is unavailable.
        if selectedRange.location >= 0, selectedRange.length == 0,
           let bounds: CGRect = try? focusedElement.parameterizedAttribute(
               kAXBoundsForRangeParameterizedAttribute,
               param: AXValue.range(CFRange(location: selectedRange.location, length: 0))
           ),
           let rect = NSScreen.convertFromQuartz(bounds),
           let caret = CursorRectInfo.insertionPoint(rect: rect, zeroWidthCaretWidth: CursorRectInfo.fallbackCaretWidth(for: rect))
        {
            IndicatorDiagnostics.record("AX.insertionPoint id=\(traceID) raw=\(rect) caret=\(caret.rect)")
            if (try? focusedElement.subrole()) == .searchField,
               let field = Self.findInputAreaRect(focusedElement),
               let characterCount: Int = try? focusedElement.attribute(.numberOfCharacters)
            {
                var characterBounds: CGRect?
                if characterCount > 0 {
                    let range = CFRange(location: min(selectedRange.location, characterCount - 1), length: 1)
                    let bounds: CGRect? = try? focusedElement.parameterizedAttribute(
                        kAXBoundsForRangeParameterizedAttribute, param: AXValue.range(range)
                    )
                    characterBounds = bounds.flatMap(NSScreen.convertFromQuartz)
                }
                let aligned = caret.alignedToSearchField(field, characterBounds: characterBounds, isEmpty: characterCount == 0)
                IndicatorDiagnostics.record("AX.searchFieldCaret id=\(traceID) rect=\(aligned.rect)")
                return aligned
            }
            return caret
        }

        guard let visibleRange: CFRange = try? focusedElement.attribute(.visibleCharacterRange),
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

        if let bounds = getCursorBounds() { return CursorRectInfo(rect: bounds, kind: .text) }
        let bounds = getLineBounds()
        IndicatorDiagnostics.record("AX.lineFallback id=\(traceID) rect=\(String(describing: bounds))")
        return bounds.map { CursorRectInfo(rect: $0, kind: .text) }
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
