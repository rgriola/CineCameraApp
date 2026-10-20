//
//  Theme.swift
//  CineVideoApp
//
//  Design tokens for Phase 6 of the camera-controls plan. Ported from
//  PromptCam's `App/Theme.swift`, scoped to just what the camera chrome
//  needs right now (accent, panel background, glass border, radii,
//  spacing, `panelSpring`) rather than PromptCam's full font/VU-color
//  system, which belongs to Phase 7's VU meter work instead. Deliberately
//  avoids SwiftUI materials (`.ultraThinMaterial` etc.), matching
//  PromptCam's convention — see `ControlPanel.swift`.
//

import SwiftUI

enum Theme {

    // MARK: - Colors

    static let accent = Color(hex: "#FFD60A")
    static let panelBg = Color(hex: "#111111")
    static let glassBorder = Color.white.opacity(0.12)
    static let overlayScrim = Color.black.opacity(0.1)

    static let primaryText = Color(hex: "#F5F5F5")
    static let secondaryText = Color(hex: "#A1A1A6")

    static let bgGrad = LinearGradient(
        colors: [Color(hex: "#111111"), Color(hex: "#0B0B0B")],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Radii

    static let radiusSm: CGFloat = 8
    static let radiusMd: CGFloat = 12
    static let radiusLg: CGFloat = 16

    // MARK: - Spacing

    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space24: CGFloat = 24

    // MARK: - Animation

    /// Standard spring for panel show/hide transitions (format panel, any
    /// future popup panel).
    static let panelSpring: Animation = .spring(response: 0.35, dampingFraction: 0.8)
}

extension Color {
    /// Converts a hex string (6-digit RGB or 8-digit ARGB) to a `Color`.
    /// Ported from PromptCam's `App/Theme.swift`.
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let a, r, g, b: UInt64
        switch hex.count {
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
