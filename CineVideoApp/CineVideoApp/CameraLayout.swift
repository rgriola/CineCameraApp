//
//  CameraLayout.swift
//  CineVideoApp
//
//  Geometry for Phase 6 of the camera-controls plan: computes where the
//  live `.resizeAspect` preview actually renders its video content inside
//  a container, so chrome can be placed in the resulting letterbox/
//  pillarbox bars rather than over the image (D7 — see
//  camera-controls-plan.md). Pure geometry, no AVFoundation/UIKit types,
//  so it's trivially unit-testable like `CapturePolicy`/`ControlPolicy`.
//

import SwiftUI

enum CameraLayout {
    struct LandscapeChrome {
        let imageControls: CGRect
        let rail: CGRect
        let quickControls: CGRect
        let zoomScale: CGRect
    }

    static func landscapeChrome(
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets,
        accessibilitySize: Bool
    ) -> LandscapeChrome {
        let safe = CGRect(
            x: safeAreaInsets.leading,
            y: safeAreaInsets.top,
            width: max(0, containerSize.width - safeAreaInsets.leading - safeAreaInsets.trailing),
            height: max(0, containerSize.height - safeAreaInsets.top - safeAreaInsets.bottom)
        )
        let railWidth: CGFloat = accessibilitySize ? 88 : 64
        let image = previewFrame(containerSize: containerSize, videoDimensions: (1920, 1080)).videoRect
        let rightMarginWidth = max(0, containerSize.width - image.maxX)
        // Pillarbox placement uses the physical margin, not the horizontal safe-area boundary.
        // Leave edge clearance; otherwise retain full-size controls over the safe image edge.
        let railX = rightMarginWidth >= railWidth + 12
            ? image.maxX + (rightMarginWidth - railWidth) / 2
            : safe.maxX - railWidth
        let rail = CGRect(x: railX, y: safe.minY,
                          width: railWidth, height: max(0, safe.height))
        let left = max(image.minX + 6, safe.minX)
        let right = min(image.maxX - 6, rail.minX - 6)
        let top = max(image.minY + 6, safe.minY)
        let bottom = min(image.maxY - 6, safe.maxY)
        let controlsWidth = max(0, right - left)
        let stripWidth = controlsWidth * 0.68
        let zoomWidth: CGFloat = accessibilitySize ? 76 : 48
        return LandscapeChrome(
            imageControls: CGRect(x: left, y: top,
                                  width: controlsWidth, height: max(0, bottom - top)),
            rail: rail,
            quickControls: CGRect(
                x: left + (controlsWidth - stripWidth) / 2,
                y: containerSize.height - safeAreaInsets.bottom - 44,
                width: stripWidth,
                height: 44
            ),
            zoomScale: CGRect(
                x: rail.minX - 6 - zoomWidth,
                y: safe.minY + 6,
                width: zoomWidth,
                height: max(92, safe.height - 130)
            )
        )
    }

    /// Which pair of edges the black bars fall on for a given container:
    /// `.vertical` means the bars stack top/bottom (the container is
    /// relatively *taller* than the displayed video — the common portrait
    /// case); `.horizontal` means the bars fall left/right (the container
    /// is relatively *wider* than the displayed video — the common
    /// landscape case).
    enum BarAxis: Equatable {
        case vertical
        case horizontal
    }

    /// The fitted video rect plus the resulting bar geometry for one
    /// container size.
    struct PreviewFrame {
        /// Where the actual (non-letterboxed) video image renders, in the
        /// container's own coordinate space.
        let videoRect: CGRect
        let barAxis: BarAxis
        /// Thickness of each bar (the two bars are symmetric since the
        /// video is centered, which is `AVCaptureVideoPreviewLayer`'s
        /// default `.resizeAspect` behavior).
        let barThickness: CGFloat
    }

    /// Computes `PreviewFrame` for a `.resizeAspect` preview of
    /// `videoDimensions` inside `containerSize`.
    ///
    /// `AVCaptureVideoPreviewLayer` auto-rotates its connection to match
    /// the current interface orientation, so the *displayed* aspect ratio
    /// swaps `width`/`height` between portrait and landscape even though
    /// `videoDimensions` (the capture format's raw dimensions, always
    /// reported landscape-native, e.g. 1920×1080) doesn't change.
    /// Orientation is inferred from `containerSize` itself — the container
    /// is always the on-screen frame for the current interface orientation
    /// — rather than taking a separate orientation parameter that could
    /// drift out of sync with it.
    static func previewFrame(
        containerSize: CGSize,
        videoDimensions: (width: Int32, height: Int32)
    ) -> PreviewFrame {
        guard containerSize.width > 0, containerSize.height > 0,
              videoDimensions.width > 0, videoDimensions.height > 0 else {
            // Nothing to fit yet (e.g. first layout pass before the session
            // has configured a device) — report a bar-less full-container
            // frame rather than dividing by zero.
            return PreviewFrame(
                videoRect: CGRect(origin: .zero, size: containerSize),
                barAxis: .vertical,
                barThickness: 0
            )
        }

        let isPortraitUI = containerSize.height >= containerSize.width
        let displayedAspect: CGFloat = isPortraitUI
            ? CGFloat(videoDimensions.height) / CGFloat(videoDimensions.width)
            : CGFloat(videoDimensions.width) / CGFloat(videoDimensions.height)
        let containerAspect = containerSize.width / containerSize.height

        if containerAspect > displayedAspect {
            // Container is relatively wider than the video -> pillarboxed
            // (bars left/right), the typical landscape case.
            let videoWidth = containerSize.height * displayedAspect
            let barThickness = max(0, (containerSize.width - videoWidth) / 2)
            let videoRect = CGRect(
                x: barThickness,
                y: 0,
                width: videoWidth,
                height: containerSize.height
            )
            return PreviewFrame(videoRect: videoRect, barAxis: .horizontal, barThickness: barThickness)
        } else {
            // Container is relatively taller than the video -> letterboxed
            // (bars top/bottom), the typical portrait case.
            let videoHeight = containerSize.width / displayedAspect
            let barThickness = max(0, (containerSize.height - videoHeight) / 2)
            let videoRect = CGRect(
                x: 0,
                y: barThickness,
                width: containerSize.width,
                height: videoHeight
            )
            return PreviewFrame(videoRect: videoRect, barAxis: .vertical, barThickness: barThickness)
        }
    }

    // MARK: - Chrome placement

    /// The two bar rects derived from a `PreviewFrame`, in the same
    /// container coordinate space as `videoRect`.
    ///
    /// `leading` is the bar closer to the container's origin (top in
    /// portrait, left in landscape); `primary` is the opposite bar (bottom
    /// in portrait, right in landscape) — named "primary" because it's
    /// where the record cluster + the controls that stay active during
    /// recording (zoom/focus/exposure, D6) are docked, mirroring where a
    /// handheld camera's grip controls naturally sit.
    struct ChromeBars {
        let leading: CGRect
        let primary: CGRect
    }

    static func chromeBars(for frame: PreviewFrame, containerSize: CGSize) -> ChromeBars {
        switch frame.barAxis {
        case .vertical:
            let leading = CGRect(x: 0, y: 0, width: containerSize.width, height: frame.videoRect.minY)
            let primary = CGRect(
                x: 0,
                y: frame.videoRect.maxY,
                width: containerSize.width,
                height: max(0, containerSize.height - frame.videoRect.maxY)
            )
            return ChromeBars(leading: leading, primary: primary)
        case .horizontal:
            let leading = CGRect(x: 0, y: 0, width: frame.videoRect.minX, height: containerSize.height)
            let primary = CGRect(
                x: frame.videoRect.maxX,
                y: 0,
                width: max(0, containerSize.width - frame.videoRect.maxX),
                height: containerSize.height
            )
            return ChromeBars(leading: leading, primary: primary)
        }
    }

    // MARK: - Chrome constants

    enum Chrome {
        /// Spacing between docked controls within a bar.
        static let dockSpacing: CGFloat = 8
        /// Padding between a bar's edge and its docked content.
        static let dockPadding: CGFloat = 6
    }
}
