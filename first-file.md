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

> > > Logger

- use OSLog for the console, not print()
- These should be used to display what is going on in the console.

**_ Next Challenge _**
Video is coming out of phone to the monitor is portrait mode. It is going to the monitor succesfully.

I need horizontal video recorded and output also. In my original MVP I wanted landscape left and portrait determined by device orientation. Is this still possible or do we need to go with device setting?

Preview Mirroring
Camera Preview
Recording

BlackMagic makes a camera app, it has a clean HDMI output, I noticed it limits the monitoring to HD, and it always outputs the HDMI horizontally no matter the camera orientation.

**_ Evaluate App Feature _**
Our goal is to create a Video Camera App (with audio) that feeds clean video + audio through to an HDMI monitor out of an iPhone. Blackmagic Camera App does the Video part but not the audio.

We have hit a wall. We are able feed USB/HDMI output of the Camera Preview through HDMI but it shows the entire App UI, rather than only the camera preview.

I need a deeper look at how we can accomplish this, what we may be missing. The WindowUI and UIScene method seems blocked by iOS or App or Both. There is also a theory a second Window Group in the main startup file could be used to feed this external monitor.

Aug 24 2026
**_ Task _**

To-Do

- Add external audio support modeled after promptcam. Have agents review promptcam to make sure audio model is best practive. UI does not let me choose input.

- Review SWIFT_STRICT_CONCURRENCY and how to set this.

- Add icon so its not annoying.

Needs:
USB-C hub behavior with simultaneous external display + USB microphone input
