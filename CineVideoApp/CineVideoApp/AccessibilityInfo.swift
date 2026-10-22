import SwiftUI

extension View {
    /// Omitted values and hints preserve existing metadata; focus, traits, and actions stay at the call site.
    func accessibilityInfo(label: Text, value: Text? = nil, hint: Text? = nil) -> some View {
        modifier(AccessibilityInfoModifier(label: label, value: value, hint: hint))
    }
}

private struct AccessibilityInfoModifier: ViewModifier {
    let label: Text
    let value: Text?
    let hint: Text?

    func body(content: Content) -> some View {
        if let hint {
            labeledContent(content).accessibilityHint(hint)
        } else {
            labeledContent(content)
        }
    }

    @ViewBuilder
    private func labeledContent(_ content: Content) -> some View {
        if let value {
            content.accessibilityLabel(label).accessibilityValue(value)
        } else {
            content.accessibilityLabel(label)
        }
    }
}
