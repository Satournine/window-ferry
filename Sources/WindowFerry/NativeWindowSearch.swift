import AppKit
import SwiftUI

struct NativeWindowSearch: NSViewRepresentable {
    @Binding var text: String
    var onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onCancel: onCancel) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search windows or apps"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search windows or apps")
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCancel = onCancel
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onCancel: () -> Void
        init(text: Binding<String>, onCancel: @escaping () -> Void) { self.text = text; self.onCancel = onCancel }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            if !text.wrappedValue.isEmpty { text.wrappedValue = ""; control.stringValue = "" }
            else { onCancel() }
            return true
        }
    }
}
