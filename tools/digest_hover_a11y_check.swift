import AppKit
import SwiftUI

@main
struct DigestHoverA11yCheck {
    static let canvasWidth = 360
    static let canvasHeight = 160

    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        OpenMyChrome.applyAppearance()

        let hosting = NSHostingView(
            rootView: DigestHoverA11yView()
                .frame(width: CGFloat(canvasWidth), height: CGFloat(canvasHeight))
        )
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let window = OneXWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 1
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = OpenMyChrome.nsCanvas
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -4000, y: 0))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        hosting.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        var labels: Set<String> = []
        var identifiers: Set<String> = []
        collect(from: hosting, labels: &labels, identifiers: &identifiers)

        precondition(!labels.contains("解释"), "悬停态不得再有「解释」，实际 \(labels.sorted())")
        precondition(labels.contains("划线"), "悬停态辅助功能树须有「划线」，实际 \(labels.sorted())")
        precondition(!identifiers.contains("digest.explain"), "不得再有 digest.explain，实际 \(identifiers.sorted())")
        precondition(identifiers.contains("digest.highlight"), "须有 digest.highlight，实际 \(identifiers.sorted())")

        window.close()
        print("digest_hover_a11y_check labels=\(labels.sorted()) ids=\(identifiers.sorted())")
        print("digest_hover_a11y_check=passed")
    }

    private static func collect(from element: Any, labels: inout Set<String>, identifiers: inout Set<String>) {
        var seen = Set<ObjectIdentifier>()
        walk(element, labels: &labels, identifiers: &identifiers, seen: &seen)
    }

    private static func walk(
        _ element: Any,
        labels: inout Set<String>,
        identifiers: inout Set<String>,
        seen: inout Set<ObjectIdentifier>
    ) {
        let object = element as AnyObject
        let token = ObjectIdentifier(object)
        guard !seen.contains(token) else { return }
        seen.insert(token)

        if let hidden = boolValue(object, selector: "isAccessibilityHidden"), hidden {
            return
        }
        if let label = stringValue(object, selector: "accessibilityLabel"), !label.isEmpty {
            labels.insert(label)
        }
        if let identifier = stringValue(object, selector: "accessibilityIdentifier"), !identifier.isEmpty {
            identifiers.insert(identifier)
        }
        if let children = arrayValue(object, selector: "accessibilityChildren") {
            for child in children {
                walk(child, labels: &labels, identifiers: &identifiers, seen: &seen)
            }
        }
        if let view = object as? NSView {
            for subview in view.subviews {
                walk(subview, labels: &labels, identifiers: &identifiers, seen: &seen)
            }
        }
    }

    private static func stringValue(_ object: AnyObject, selector: String) -> String? {
        let sel = NSSelectorFromString(selector)
        guard object.responds(to: sel) else { return nil }
        let raw = object.perform(sel)?.takeUnretainedValue()
        return raw as? String
    }

    private static func boolValue(_ object: AnyObject, selector: String) -> Bool? {
        let sel = NSSelectorFromString(selector)
        guard object.responds(to: sel) else { return nil }
        guard let raw = object.perform(sel) else { return nil }
        return raw.takeUnretainedValue() as? Bool
    }

    private static func arrayValue(_ object: AnyObject, selector: String) -> [Any]? {
        let sel = NSSelectorFromString(selector)
        guard object.responds(to: sel) else { return nil }
        return object.perform(sel)?.takeUnretainedValue() as? [Any]
    }
}

private struct DigestHoverA11yView: View {
    var body: some View {
        DigestCueRow(
            timeLabel: "0:06",
            cueText: "Hello world.\n大家好。",
            timeColumnWidth: 52,
            showsActions: true
        )
        .accessibilityElement(children: .contain)
        .padding(12)
        .frame(width: CGFloat(DigestHoverA11yCheck.canvasWidth), height: CGFloat(DigestHoverA11yCheck.canvasHeight), alignment: .topLeading)
        .background(OpenMyChrome.canvas)
        .coordinateSpace(name: "digest-book-page")
    }
}

private final class OneXWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 1 }
}
