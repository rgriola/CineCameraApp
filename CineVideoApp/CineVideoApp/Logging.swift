//
//  Logging.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import OSLog

// NOTE Turn on metadata in Xcode to see all this. 

/// Centralized `Logger` instances, one per subsystem area, so Console.app
/// filtering (by category) lines up with how the app is actually organized.
/// All logs share the app's bundle identifier as the subsystem.
///
/// `Logger` is a `Sendable` value type safe to use from any thread/actor, so
/// these are marked `nonisolated` to opt out of this project's default
/// MainActor isolation — they're called from sessionQueue and background
/// delegate callbacks just as often as from the main actor.
extension Logger {
    nonisolated private static let subsystem = Bundle.main.bundleIdentifier ?? "com.rodczaro.CineVideoApp"

    /// Capture session lifecycle: configuration, format/codec setup, rotation.
    nonisolated static let camera = Logger(subsystem: subsystem, category: "Camera")

    /// Recording lifecycle: start/stop, and saving to the Photo Library.
    nonisolated static let recording = Logger(subsystem: subsystem, category: "Recording")

    /// Camera, microphone, and photo library permission requests/results.
    nonisolated static let permissions = Logger(subsystem: subsystem, category: "Permissions")

    /// HDMI/USB external display connect/disconnect and audio mirroring.
    nonisolated static let externalDisplay = Logger(subsystem: subsystem, category: "ExternalDisplay")

    /// App-wide interface-orientation lock/unlock during recording.
    nonisolated static let orientation = Logger(subsystem: subsystem, category: "Orientation")
}
