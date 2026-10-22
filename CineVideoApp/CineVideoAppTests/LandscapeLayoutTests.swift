import SwiftUI
import XCTest
@testable import CineVideoApp

@MainActor
final class LandscapeLayoutTests: XCTestCase {
    func testLandscapeChromeRendering() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        for (width, height, size) in [
            (852.0, 350.0, DynamicTypeSize.large),
            (740.0, 320.0, .large),
            (852.0, 350.0, .accessibility3),
            (852.0, 350.0, .accessibility5)
        ] {
            let chrome = LandscapeCameraChrome(cameraManager: CameraManager(), panel: .constant(nil))
                .frame(width: width, height: height)
                .background(.gray)
                .environment(\.colorScheme, .dark)
                .environment(\.dynamicTypeSize, size)
                .ignoresSafeArea()
            let controller = UIHostingController(rootView: chrome)
            controller.safeAreaRegions = []
            window.rootViewController = controller
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            window.makeKeyAndVisible()
            await Task.yield()
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in
                controller.view.drawHierarchy(in: CGRect(x: 0, y: 0, width: width, height: height), afterScreenUpdates: true)
            }
            XCTAssertEqual(image.size.width, width)
            XCTAssertEqual(image.size.height, height)
            assertNoScrollContainers(in: controller.view)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Landscape chrome \(Int(width)) \(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testFixedAdjustmentPanelsAndPortraitDock() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            previousWindow?.makeKey()
        }
        for textSize in [DynamicTypeSize.large, .accessibility5] {
            do {
                let size = CGSize(width: 667, height: 320)
                let controller = UIHostingController(rootView:
                    LandscapeCameraChrome(cameraManager: CameraManager(), panel: .constant(nil))
                        .environment(\.dynamicTypeSize, textSize)
                        .environment(\.colorScheme, .dark)
                        .ignoresSafeArea()
                )
                controller.safeAreaRegions = []
                window.rootViewController = controller
                window.frame = CGRect(origin: .zero, size: size)
                window.makeKeyAndVisible()
                await Task.yield()
                controller.view.frame = window.bounds
                controller.view.layoutIfNeeded()
                assertNoScrollContainers(in: controller.view)
                assertSlidersStayInside(controller.view, expectedMinimum: 0)
                attach(controller.view, name: "Inline zoom and exposure \(textSize)")
            }
            let size = CGSize(width: 320, height: 568)
            let controller = UIHostingController(rootView:
                CameraScreen(cameraManager: CameraManager())
                    .frame(width: size.width, height: size.height)
                    .environment(\.dynamicTypeSize, textSize)
                    .environment(\.colorScheme, .dark)
                    .ignoresSafeArea()
            )
            controller.safeAreaRegions = []
            window.rootViewController = controller
            window.frame = CGRect(origin: .zero, size: size)
            window.makeKeyAndVisible()
            await Task.yield()
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            assertNoScrollContainers(in: controller.view)
            assertSlidersStayInside(controller.view, minimumY: size.height / 2)
            attach(controller.view, name: "Fixed portrait dock \(textSize)")
        }
    }

    private func assertNoScrollContainers(in view: UIView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(view is UIScrollView, "Camera controls must not install a scroll container", file: file, line: line)
        for child in view.subviews {
            assertNoScrollContainers(in: child, file: file, line: line)
        }
    }

    private func assertSlidersStayInside(
        _ root: UIView, minimumY: CGFloat = 0, expectedMinimum: Int = 1,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var sliderCount = 0
        func inspect(_ view: UIView) {
            if view is UISlider {
                sliderCount += 1
                let frame = view.convert(view.bounds, to: root)
                // The rotated native slider has a 31-point intrinsic thickness inside its 44-point SwiftUI target.
                XCTAssertGreaterThanOrEqual(frame.width, frame.height > frame.width ? 31 : 44, file: file, line: line)
                XCTAssertGreaterThanOrEqual(frame.minY, minimumY, file: file, line: line)
                XCTAssertTrue(root.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                              "Slider outside fixed surface: \(frame)", file: file, line: line)
            }
            view.subviews.forEach(inspect)
        }
        inspect(root)
        if expectedMinimum == 0 {
            XCTAssertEqual(sliderCount, 0, "Inline sliders must start hidden", file: file, line: line)
        } else {
            XCTAssertGreaterThanOrEqual(sliderCount, expectedMinimum, "Expected a rendered adjustment slider", file: file, line: line)
        }
    }

    private func attach(_ view: UIView, name: String) {
        let image = UIGraphicsImageRenderer(size: view.bounds.size).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSupportedVerticalZoomSliderRenderingAndInput() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }
        let controls = CameraControlSnapshot.make(
            zoomFactor: 2, minZoomFactor: 1, maxZoomFactor: 30,
            switchOverFactors: [2, 4], displayMultiplier: 0.5,
            exposureBias: 0, minExposureBias: -2, maxExposureBias: 2,
            isMultiLensDevice: true, isFocusLocked: false, isFocusSupported: true,
            isExposureLocked: false, isExposureSupported: true)
        for size in [DynamicTypeSize.large, .accessibility5] {
            var requestedZoom: CGFloat?
            let scale = LandscapeZoomSlider(
                controls: controls,
                size: CGSize(width: size.isAccessibilitySize ? 76 : 48, height: 220)
            ) {
                requestedZoom = $0
            }
            .frame(width: size.isAccessibilitySize ? 76 : 48, height: 220)
            .padding(8)
            .background(.black)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            .ignoresSafeArea()
            let controller = UIHostingController(rootView: scale)
            controller.safeAreaRegions = []
            window.rootViewController = controller
            window.frame = CGRect(x: 0, y: 0, width: 110, height: 250)
            window.makeKeyAndVisible()
            await Task.yield()
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            assertNoScrollContainers(in: controller.view)
            assertSlidersStayInside(controller.view)
            func sliders(in view: UIView) -> [UISlider] {
                (view as? UISlider).map { [$0] } ?? view.subviews.flatMap { sliders(in: $0) }
            }
            let slider = try XCTUnwrap(sliders(in: controller.view).first)
            let sliderFrame = slider.convert(slider.bounds, to: controller.view)
            XCTAssertGreaterThan(sliderFrame.height, sliderFrame.width, "Zoom slider must be vertical")
            XCTAssertNil(requestedZoom, "Rendering must not issue a camera command")
            for zoom in [controls.zoomRangeDisplayed.lowerBound, 3, controls.zoomRangeDisplayed.upperBound] {
                let fraction = (zoom - controls.zoomRangeDisplayed.lowerBound)
                    / (controls.zoomRangeDisplayed.upperBound - controls.zoomRangeDisplayed.lowerBound)
                slider.value = slider.minimumValue + Float(fraction) * (slider.maximumValue - slider.minimumValue)
                slider.sendActions(for: .valueChanged)
                XCTAssertEqual(try XCTUnwrap(requestedZoom), zoom, accuracy: 0.001)
            }
            let fitted = controller.sizeThatFits(in: CGSize(width: 110, height: 250))
            XCTAssertLessThanOrEqual(fitted.width, 110)
            XCTAssertLessThanOrEqual(fitted.height, 250)
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Supported vertical zoom slider \(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testCompactLayoutKeepsVerticalSafeBoundsAndDoesNotResizeImage() {
        for size in [CGSize(width: 852, height: 393), CGSize(width: 667, height: 375), CGSize(width: 1024, height: 768)] {
            let insets = EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 0)
            let layout = CameraLayout.landscapeChrome(
                containerSize: size, safeAreaInsets: insets, accessibilitySize: false)
            XCTAssertEqual(layout.rail.width, 64)
            XCTAssertGreaterThanOrEqual(layout.imageControls.minX, insets.leading)
            XCTAssertLessThan(layout.imageControls.maxX, layout.rail.minX)
            XCTAssertLessThanOrEqual(layout.rail.maxX, size.width)
            XCTAssertLessThanOrEqual(layout.rail.maxY, size.height - insets.bottom)
            XCTAssertEqual(layout.quickControls.maxY, size.height - insets.bottom, accuracy: 0.001)
            XCTAssertEqual(layout.quickControls.height, 44)
            XCTAssertEqual(layout.quickControls.midX, layout.imageControls.midX, accuracy: 0.001)
            XCTAssertLessThan(layout.quickControls.maxX, layout.rail.minX)
            let image = CameraLayout.previewFrame(containerSize: size, videoDimensions: (1920, 1080)).videoRect
            XCTAssertEqual(image.width / image.height, 16.0 / 9.0, accuracy: 0.001)
            XCTAssertLessThanOrEqual(layout.imageControls.width, image.width)
            XCTAssertGreaterThanOrEqual(layout.imageControls.minY, image.minY)
            XCTAssertLessThanOrEqual(layout.imageControls.maxY, image.maxY)
        }

    }

    func testQuickControlsMeetSafeBottomWithOrWithoutHomeIndicator() {
        for bottom in [CGFloat(0), 21] {
            for accessibility in [false, true] {
                let layout = CameraLayout.landscapeChrome(
                    containerSize: CGSize(width: 852, height: 393),
                    safeAreaInsets: EdgeInsets(top: 0, leading: 59, bottom: bottom, trailing: 0),
                    accessibilitySize: accessibility
                )
                XCTAssertEqual(layout.quickControls.maxY, 393 - bottom, accuracy: 0.001)
                XCTAssertEqual(layout.quickControls.height, 44)
                XCTAssertLessThanOrEqual(layout.rail.maxX, 852)
                XCTAssertEqual(layout.rail.maxY, 393 - bottom, accuracy: 0.001)
                XCTAssertEqual(layout.rail.minX - layout.zoomScale.maxX, 6, accuracy: 0.001)
            }
        }
    }

    func testRailCentersInPillarboxOrFallsBackToSafeTrailingEdge() {
        for size in [
            CGSize(width: 835, height: 384),
            CGSize(width: 852, height: 393),
            CGSize(width: 740, height: 320),
            CGSize(width: 667, height: 375),
            CGSize(width: 1024, height: 768)
        ] {
            for accessibility in [false, true] {
                let insets = EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)
                let layout = CameraLayout.landscapeChrome(
                    containerSize: size, safeAreaInsets: insets, accessibilitySize: accessibility)
                let image = CameraLayout.previewFrame(
                    containerSize: size, videoDimensions: (1920, 1080)).videoRect
                let marginWidth = size.width - image.maxX
                if marginWidth >= layout.rail.width + 12 {
                    XCTAssertEqual(layout.rail.midX, (image.maxX + size.width) / 2, accuracy: 0.001)
                    XCTAssertGreaterThanOrEqual(layout.rail.minX, image.maxX + 6)
                    XCTAssertLessThanOrEqual(layout.rail.maxX, size.width - 6)
                } else {
                    XCTAssertEqual(layout.rail.maxX, size.width - insets.trailing, accuracy: 0.001)
                }
                XCTAssertEqual(layout.rail.width, accessibility ? 88 : 64)
                XCTAssertEqual(layout.rail.minY, insets.top)
                XCTAssertEqual(layout.rail.maxY, size.height - insets.bottom, accuracy: 0.001)
                XCTAssertEqual(layout.rail.minX - layout.zoomScale.maxX, 6, accuracy: 0.001)
            }
        }
    }

    func testLandscapeChromeInsideSafeAreaParent() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            previousWindow?.makeKey()
        }
        for textSize in [DynamicTypeSize.large, .accessibility5] {
            let root = Color.gray
                .overlay {
                    LandscapeCameraChrome(cameraManager: CameraManager(), panel: .constant(nil))
                }
                .safeAreaInset(edge: .leading, spacing: 0) { Color.clear.frame(width: 59) }
                .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: 59) }
                .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 21) }
                .environment(\.dynamicTypeSize, textSize)
                .environment(\.colorScheme, .dark)
            let controller = UIHostingController(rootView: root)
            controller.safeAreaRegions = []
            window.rootViewController = controller
            window.frame = CGRect(x: 0, y: 0, width: 835, height: 384)
            window.makeKeyAndVisible()
            await Task.yield()
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            assertNoScrollContainers(in: controller.view)
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let layout = CameraLayout.landscapeChrome(
                containerSize: window.bounds.size,
                safeAreaInsets: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59),
                accessibilitySize: textSize.isAccessibilitySize)
            var brightSamples = 0
            for x in stride(from: layout.rail.minX + 4, to: layout.rail.maxX - 4, by: 4) {
                for y in stride(from: layout.rail.minY + 12, to: layout.rail.maxY - 12, by: 4) {
                    let sample = try pixel(in: image, at: CGPoint(x: x, y: y))
                    if sample.red > 0.85 && sample.green > 0.85 { brightSamples += 1 }
                }
            }
            XCTAssertGreaterThan(brightSamples, 20, "Rail controls must render inside the calculated rail")
            let stripEdge = try pixel(in: image, at: CGPoint(x: 400, y: 384 - 21 - 2))
            XCTAssertLessThan(stripEdge.red, 0.35, "Strip must meet the parent's safe bottom edge")
            attach(controller.view, name: "Landscape parent safe areas \(textSize)")
        }
    }

    private func pixel(in image: UIImage, at point: CGPoint) throws -> (red: Double, green: Double) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let sample = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: point.x * image.scale, y: point.y * image.scale, width: 1, height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255)
    }
}
