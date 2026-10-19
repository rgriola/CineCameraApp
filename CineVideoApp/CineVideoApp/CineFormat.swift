//
//  CineFormat.swift
//  CineVideoApp
//
//  Pure value model for the selectable recording format (resolution + frame
//  rate). Like `CapturePolicy.swift`, these types hold no AVFoundation state
//  and are marked `nonisolated` so capture code can read them from
//  `CameraManager`'s `sessionQueue` despite this module's
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default.
//
//  The raw values are the persisted `@AppStorage` representation — changing
//  one is a stored-data migration, not a rename.
//

import Foundation

nonisolated enum CaptureResolution: String, CaseIterable, Codable, Sendable {
    case hd1080 = "HD"
    case uhd4K  = "4K"

    var dimensions: (width: Int32, height: Int32) {
        switch self {
        case .hd1080: (1920, 1080)
        case .uhd4K:  (3840, 2160)
        }
    }

    var dimensionLabel: String {
        "\(dimensions.width)×\(dimensions.height)"
    }
}

nonisolated enum CaptureFrameRate: Int, CaseIterable, Codable, Sendable {
    case fps24 = 24
    case fps30 = 30
    // 60p is deliberately out of scope for now. Adding a case here silently
    // widens `CaptureFormatSelector.fallbackFrameRate`'s search space, so it
    // is a behavioral change, not just a new option.

    var displayLabel: String { "\(rawValue)p" }
}

nonisolated struct CineFormat: Equatable, Hashable, Codable, Sendable {
    var resolution: CaptureResolution
    var frameRate: CaptureFrameRate

    static let `default` = CineFormat(resolution: .hd1080, frameRate: .fps30)

    /// Maps a device's real active dimensions and frame rate back onto a
    /// modeled format, or `nil` when the device is running something this app
    /// doesn't model. Used to report what the hardware *actually* settled on
    /// rather than what was requested — the two diverge whenever a format
    /// isn't available and the session's preset picks one instead.
    static func matching(width: Int32, height: Int32, frameRate: Double) -> CineFormat? {
        guard frameRate.isFinite else { return nil }
        guard let resolution = CaptureResolution.allCases.first(where: {
            $0.dimensions.width == width && $0.dimensions.height == height
        }) else { return nil }
        // Real devices report rates like 29.97; match to the nearest whole
        // frame rather than requiring exact equality.
        guard let rate = CaptureFrameRate.allCases.first(where: {
            abs(Double($0.rawValue) - frameRate) < 0.5
        }) else { return nil }
        return CineFormat(resolution: resolution, frameRate: rate)
    }
}

extension CineFormat {
    /// `@AppStorage` keys. The two enums persist as independent raw values
    /// (`String` / `Int`) rather than one encoded blob, so `@AppStorage` can
    /// bind them directly. Centralized here so call sites can't typo them.
    nonisolated enum StorageKey {
        static let resolution = "cineFormat.resolution"
        static let frameRate  = "cineFormat.frameRate"
    }
}
