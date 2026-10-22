import SwiftUI

struct LandscapeCameraChrome: View {
    enum Panel: Hashable {
        case settings

        var title: String {
            switch self {
            case .settings: "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .settings: CameraSymbols.settings
            }
        }
    }

    let cameraManager: CameraManager
    @Binding var panel: Panel?
    @State private var isZoomSliderVisible = false
    @State private var isExposureControlsVisible = false
    @AccessibilityFocusState private var focusedTrigger: Panel?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var controls: CameraControlSnapshot { cameraManager.controls }
    private var format: CineFormat? { cameraManager.activeFormat }

    private var chromeColor: Color {
        .black.opacity(
            reduceTransparency || contrast == .increased ? 1 : 0.6
            )
    }

    var body: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let containerSize = CGSize(
                width: geometry.size.width + insets.leading + insets.trailing,
                height: geometry.size.height + insets.top + insets.bottom
            )
            let layout = CameraLayout.landscapeChrome(
                containerSize: containerSize,
                safeAreaInsets: insets,
                accessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
            ZStack {
                audioControls
                    .frame(
                        width: layout.imageControls.width,
                        height: layout.imageControls.height
                    )
                    .position(
                        x: layout.imageControls.midX,
                        y: layout.imageControls.midY
                    )

                recordingControls
                    .frame(
                        width: layout.imageControls.width, 
                        height: layout.imageControls.height
                        )
                    .position(
                        x: layout.imageControls.midX, 
                        y: layout.imageControls.midY 
                        )
                // Next to tool Rail - inline slider
                if isZoomSliderVisible {
                    zoomSlider(size: layout.zoomScale.size)
                        .frame(
                            width: layout.zoomScale.width, 
                            height: layout.zoomScale.height, alignment: .top
                            )
                        .position(
                            x: layout.zoomScale.midX, 
                            y: layout.zoomScale.midY
                            )
                }

                // Far Right of Screen
                toolRail(height: layout.rail.height)
                    .frame(
                        width: layout.rail.width, 
                        height: layout.rail.height
                        )
                    .position(
                        x: layout.rail.midX,
                        y: layout.rail.midY
                        )
                // At the Bottom of the screen
                quickControls
                    .frame(width: layout.quickControls.width, height: layout.quickControls.height)
                    .background(chromeColor, in: .rect(cornerRadius: 6))
                    .overlay(alignment: .bottom) {
                        if isExposureControlsVisible {
                            ExposureControlView(
                                cameraManager: cameraManager, compact: true
                                )
                                .padding(.horizontal, 24)
                                .padding(.vertical, 8)
                                .background(
                                    chromeColor, in: .rect(cornerRadius: 6)
                                    )
                                .padding(
                                    .bottom, layout.quickControls.height + 6)
                        }
                    }
                    .position(x: layout.quickControls.midX, y: layout.quickControls.midY)
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .accessibilityHidden(panel != nil)
            .allowsHitTesting(panel == nil)
            .overlay {
                if let panel {
                    ZStack {
                        Button(action: dismissPanel) {
                            Color.black.opacity(0.65).ignoresSafeArea()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss \(panel.title)")
                        ControlPanel(title: panel.title, icon: panel.symbol, onDismiss: dismissPanel) {
                            panelContent(panel)
                                .frame(maxHeight: max(100, containerSize.height - 130))
                        }
                        .frame(maxWidth: 560)
                    }
                }
            }
            // Translate full-screen coordinates into the parent's safe-area coordinate space.
            .position(
                x: containerSize.width / 2 - insets.leading,
                y: containerSize.height / 2 - insets.top
            )
        }
        .tint(.white)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    // MARK: Audio Controls
    private var audioControls: some View {
        Color.clear
            .overlay(
                alignment: .bottomLeading) {
                unavailable(
                    "Audio", symbol: CameraSymbols.microphone)
                    .accessibilityLabel("Microphone source and audio meters, unavailable")
                    .padding(.bottom, 58)
                }
    }

    // MARK: Record Button and Recording Status
    private var recordingControls: some View {
        Color.clear
            .overlay(alignment: .top) {
                recordingStatus
            }
            .overlay(alignment: .bottomTrailing) {
                recordButton.padding(.bottom, 54)
                    .padding(.trailing, 30)
                }
    }

    // MARK: Bottom Panel with Format and Camera Controls
    private var quickControls: some View {
        ViewThatFits(in: .horizontal) {
            if !dynamicTypeSize.isAccessibilitySize {
                quickControlRow(compact: false)
            }
            quickControlRow(compact: true)
        }
        .buttonStyle(QuickControlStyle())
        .frame(height: 44)
    }

    // MARK: FORMAT and FRAME RATE Controls
    private func quickControlRow(compact: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                if let format { cameraManager.setFormat(format.cyclingResolution) }
            } label: {
                if compact {
                    Image(systemName: CameraSymbols.format)
                } else {
                    Text(format?.resolution.rawValue ?? "HD/4K —")
                }
            }
            .disabled(format == nil || cameraManager.isOrientationLocked)
            .accessibilityInfo(
                label: Text("Recording resolution"),
                value: Text(format?.resolution.rawValue ?? "Unavailable"),
                hint: Text(cameraManager.isOrientationLocked
                    ? "Unavailable until recording finishes." : "Cycles HD and 4K.")
            )
            separator
            Button {
                if let format { cameraManager.setFormat(format.cyclingFrameRate) }
            } label: {
                if compact {
                    Image(systemName: CameraSymbols.frameRate)
                } else {
                    Text(format?.frameRate.displayLabel ?? "Rate —")
                }
            }
            .disabled(format == nil || cameraManager.isOrientationLocked)
            .accessibilityInfo(
                label: Text("Frame rate"),
                value: Text(format?.frameRate.displayLabel ?? "Unavailable"),
                hint: Text(cameraManager.isOrientationLocked
                    ? "Unavailable until recording finishes." : "Cycles 24p and 30p.")
            )
            separator
            //  inline horizontal exposure control on toggle
            Button { isExposureControlsVisible.toggle() } label: {
                if compact {
                    Image(systemName: CameraSymbols.exposure)
                } else {
                    Text(controls.isExposureSupported
                         ? String(format: "EV %+.1f", controls.exposureBias) : "EV —")
                }
            }
            .accessibilityInfo(
                label: Text("Exposure Control"),
                value: Text(controls.isExposureSupported
                    ? String(format: "%+.1f EV, %@", controls.exposureBias,
                             isExposureControlsVisible ? "Controls shown" : "Controls hidden")
                    : (isExposureControlsVisible ? "Unavailable, controls shown" : "Unavailable, controls hidden")),
                hint: Text("Shows or hides the horizontal exposure slider, Reset, and auto exposure controls.")
            )
            if !compact {
                separator
                Text("ISO —").foregroundStyle(.secondary).padding(.horizontal, 8)
                    .accessibilityLabel("ISO control, unavailable")
                separator
                Text("Shutter —").foregroundStyle(.secondary).padding(.horizontal, 8)
                    .accessibilityLabel("Shutter control, unavailable")
                separator
                Text("WB —").foregroundStyle(.secondary).padding(.horizontal, 8)
                    .accessibilityLabel("White Balance control, unavailable")
            }
        }
        .font(
            compact ? .system(size: 20) : .caption.weight(.semibold).monospacedDigit()
            )
        .fixedSize(horizontal: true, vertical: false)
        .frame(minHeight: 44)
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.4)).frame(width: 1, height: 16)
            .accessibilityHidden(true)
    }

    private func toolRail(height: CGFloat) -> some View {
        VStack(spacing: 8) {

            Spacer(minLength: 0)
            
            unavailable("Photos", symbol: CameraSymbols.photos)
            
            Spacer(minLength: 0)

            tool("Settings", symbol: CameraSymbols.settings) { panel = .settings }
                .accessibilityFocused($focusedTrigger, equals: .settings)

            Spacer(minLength: 0)

            tool("Zoom", symbol: CameraSymbols.zoom) { 
                isZoomSliderVisible.toggle() 
                }
                .accessibilityInfo(
                    label: Text("Zoom"),
                    value: Text(isZoomSliderVisible ? "Slider shown" : "Slider hidden"),
                    hint: Text("Shows or hides the vertical zoom slider")
                )

            Spacer(minLength: 0)

            tool("Focus", symbol: CameraSymbols.focus) {
                cameraManager.setAutoFocus(controls.isFocusLocked)
            }
            .disabled(!controls.isFocusSupported)
            .accessibilityValue(controls.isFocusSupported
                ? (controls.isFocusLocked ? "Locked" : "Autofocus") : "Unavailable")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .frame(minHeight: height)
        .background(Color.clear, in: .rect(cornerRadius: 6))
    }

    private var recordingStatus: some View {
        Group {
            if let start = cameraManager.recordingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("REC \(RecordingTime.label(for: start.duration(to: .now)))")
                        .font(.callout.bold().monospacedDigit())
                        .padding(8)
                        .background(.red, in: .rect(cornerRadius: 8))
                        .accessibilityInfo(
                            label: Text("Recording elapsed time"),
                            value: Text(RecordingTime.label(for: start.duration(to: .now)))
                        )
                }
            } else if cameraManager.recordingPhase == .starting {
                Text("Starting recording")
                    .padding(8)
                    .background(chromeColor, in: .rect(cornerRadius: 8))
            }
        }
    }

    private var recordButton: some View {
        Button { cameraManager.toggleRecording() } label: {
            Image(systemName: cameraManager.isRecording ? CameraSymbols.stop : CameraSymbols.record)
                .font(.system(size: 56))
                .foregroundStyle(.red)
                .background(.white, in: .rect(cornerRadius: 32))
                .frame(minWidth: 64, minHeight: 64)
        }
        .disabled(!cameraManager.isSessionRunning || cameraManager.recordingPhase.isTransitioning)
        .accessibilityInfo(
            label: Text(cameraManager.isRecording ? "Stop recording" : "Start recording"),
            value: Text(cameraManager.recordingPhase.isTransitioning
                ? (cameraManager.isRecording ? "Finishing recording" : "Starting recording") : "")
        )
    }

    private func zoomSlider(size: CGSize) -> some View {
        // padding controls the position of the element. 
        LandscapeZoomSlider(controls: controls, size: size) { 
            cameraManager.setZoom(displayed: $0) 
            }
            .background(chromeColor, in: .rect(cornerRadius: 4))
            .padding(.trailing, 10)
    }

    private func tool(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.title3).accessibilityHidden(true)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .fixedSize()
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func unavailable(_ title: String, symbol: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.title3).accessibilityHidden(true)
            if !dynamicTypeSize.isAccessibilitySize {
                Text(title).font(.caption2).fixedSize()
            }
        }
        .frame(minWidth: 44, minHeight: 44)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), unavailable")
    }

    private struct QuickControlStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
    }

    @ViewBuilder
    private func panelContent(_ panel: Panel) -> some View {
        switch panel {
        case .settings:
            Form {
                Section("Recording format") {
                    Picker("Resolution", selection: Binding(
                        get: { format?.resolution ?? .hd1080 },
                        set: { if let format { cameraManager.setFormat(CineFormat(resolution: $0, frameRate: format.frameRate)) } }
                    )) {
                        ForEach(CaptureResolution.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Frame rate", selection: Binding(
                        get: { format?.frameRate ?? .fps30 },
                        set: { if let format { cameraManager.setFormat(CineFormat(resolution: format.resolution, frameRate: $0)) } }
                    )) {
                        ForEach(CaptureFrameRate.allCases, id: \.self) { Text($0.displayLabel).tag($0) }
                    }
                }
                .disabled(format == nil || cameraManager.isOrientationLocked)
                Section("Exposure") {
                    ExposureControlView(cameraManager: cameraManager)
                }
                Section("Future controls") {
                    Text("ISO control, unavailable")
                    Text("Shutter control, unavailable")
                }
            }
        }
    }

    private func dismissPanel() {
        let previous = panel
        panel = nil
        focusedTrigger = previous
    }
}

struct LandscapeZoomSlider: View {
    let controls: CameraControlSnapshot
    let size: CGSize
    let setZoom: (CGFloat) -> Void

    private var isUnavailable: Bool {
        controls.zoomRangeDisplayed.lowerBound == controls.zoomRangeDisplayed.upperBound
    }

    var body: some View {
        let trackLength = max(44, size.height - 44)

        VStack(spacing: 0) {
            Text(
                isUnavailable ? "—" : String(
                    format: "%.1f×", controls.zoomDisplayed)
                )
                .font(
                    .caption2.weight(.bold).monospacedDigit()
                    )
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(
                    width: size.width, height: 44
                    )
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { controls.zoomDisplayed }, set: setZoom
                    ),
                    in: controls.zoomRangeDisplayed
            )
            .frame(
                width: trackLength, height: 44
                )
            .contentShape(.rect)
            .rotationEffect(.degrees(-90))
            .frame(
                width: size.width, 
                height: trackLength
                )
            .environment(\.layoutDirection, .leftToRight)
            .disabled(isUnavailable)
            .accessibilityInfo(
                label: Text("Zoom"),
                value: Text(isUnavailable ? "Unavailable" : String(format: "%.1f times", controls.zoomDisplayed)),
                hint: Text("Vertical Zoom Slider Control")
            )
        }
        .frame(width: size.width, height: size.height)
        // this changes the position of the slider inside the frame
    }
}

nonisolated enum RecordingTime {
    static func label(for elapsed: Duration) -> String {
        let seconds = max(0, elapsed.components.seconds)
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%02lld:%02lld:%02lld", hours, minutes, remainder)
            : String(format: "%02lld:%02lld", minutes, remainder)
    }
}
