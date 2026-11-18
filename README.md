# FlyingSketch

Native iPad infinite-canvas sketch app with Apple Pencil ink, built in Swift (iPadOS 26+). Logic lives in the local Swift package `FlyingSketchKit` (`SketchCore`, `InkEngine`, `CanvasUI`).

## Build

```sh
xcodegen generate
open FlyingSketch.xcodeproj
```

Package tests:

```sh
cd Packages/FlyingSketchKit && xcodebuild test -scheme FlyingSketchKit-Package -destination 'platform=iOS Simulator,id=<simulator-id>' -quiet
```
