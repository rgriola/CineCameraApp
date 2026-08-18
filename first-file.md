**_ Task _**
Create a plan for the CameraManager Class for this app.

**_ Core Features _** Video + Audio Recording (.video Cine-HD 1920x1080 30p, H.265), Video+Audio Preview, Record to Photo Library, Video + Audio Preview Output via USB > HDMI (Same Format as Preview+Recording)

**_ guide _**

- First Launch shows user permissions for camera, microphone + saving to photo library, add fall back button to direct user to app system settings to if user does not choose any of these required permissions.

- After permissions granted UI only needs Record Button. Place record button in a standard location similar to native iOS Camera App.

- Default video orientation is Landscape Left with Portrait Available - no other orientations; User chooses orientation by turning the device.
- Recording locks the app orientation for Camera Preview, Microphone Source, Video Recording + HDMI output, this is a safety net to prevent live change of orientation.

- AVFoundation and Swift 6+ and SwiftUI (NO UIKit), other modules as needed.
- iOS Target is 18.0+
- Follow Swift, SwiftUI + iOS best practices - Note do not use ObservableObject. /Promptcam-fixer has examples of camera implimentation without ObservableObject ./promptcam-fixer/PromptCam/Services/CameraService

Mental Model: Where the code runs: How to write it
UI / SwiftUI state updates : normal @Observable properties, always on main

Background AVFoundation work : nonisolated method, called via sessionQueue.async

Delegate callbacks → UI : DispatchQueue.main.async hop inside the nonisolated method

- ask questions, do not over think this, keep the code as simple as AVFoundation can be.
