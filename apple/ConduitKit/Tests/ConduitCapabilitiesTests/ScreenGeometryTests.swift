import Testing
import ConduitCapabilities

/// The un-letterboxing that makes a tap on the video land where the person
/// pointed. Every one of these is a way to be off by exactly the size of a
/// letterbox bar, which is invisible in code review and obvious the moment you
/// try to click a menu.
@Suite struct ScreenGeometryTests {
    @Test func exactAspectFillsTheContainer() {
        let rect = ScreenGeometry.videoRect(
            containerWidth: 1600, containerHeight: 900, contentWidth: 1920, contentHeight: 1080
        )
        #expect(rect.x == 0 && rect.y == 0)
        #expect(rect.width == 1600 && rect.height == 900)
    }

    @Test func wideContainerBarsTheSides() {
        // 16:9 content in a 2:1 container → pillarboxed.
        let rect = ScreenGeometry.videoRect(
            containerWidth: 1000, containerHeight: 500, contentWidth: 1920, contentHeight: 1080
        )
        #expect(abs(rect.height - 500) < 0.001)
        #expect(abs(rect.width - 500 * 16.0 / 9.0) < 0.001)
        #expect(abs(rect.x - (1000 - 500 * 16.0 / 9.0) / 2) < 0.001)
        #expect(rect.y == 0)
    }

    @Test func tallContainerBarsTopAndBottom() {
        // 16:9 content in a 1:1 container → letterboxed.
        let rect = ScreenGeometry.videoRect(
            containerWidth: 900, containerHeight: 900, contentWidth: 1920, contentHeight: 1080
        )
        #expect(abs(rect.width - 900) < 0.001)
        #expect(abs(rect.height - 900 * 9.0 / 16.0) < 0.001)
        #expect(abs(rect.y - (900 - 900 * 9.0 / 16.0) / 2) < 0.001)
        #expect(rect.x == 0)
    }

    @Test func centreOfTheContainerIsTheCentreOfThePicture() {
        let normalized = ScreenGeometry.normalize(
            x: 450, y: 450, containerWidth: 900, containerHeight: 900,
            contentWidth: 1920, contentHeight: 1080
        )
        let point = try! #require(normalized)
        #expect(abs(point.nx - 0.5) < 0.0001)
        #expect(abs(point.ny - 0.5) < 0.0001)
    }

    /// The bug this exists to prevent: treating the container as the picture.
    /// A tap 50 points below the top of a letterboxed 1:1 container is NOT 5.6%
    /// down the source's screen — it is 0%, right on the top edge, because the
    /// first 253 points are black bar.
    @Test func topOfThePictureIsNotTopOfTheContainer() {
        let rect = ScreenGeometry.videoRect(
            containerWidth: 900, containerHeight: 900, contentWidth: 1920, contentHeight: 1080
        )
        let atPictureTop = try! #require(ScreenGeometry.normalize(
            x: 450, y: rect.y, containerWidth: 900, containerHeight: 900,
            contentWidth: 1920, contentHeight: 1080
        ))
        #expect(abs(atPictureTop.ny) < 0.0001)

        let naive = ScreenGeometry.normalize(
            x: 450, y: 50, containerWidth: 900, containerHeight: 900,
            contentWidth: 1920, contentHeight: 1080
        )
        #expect(naive == nil, "a point inside the letterbox bar is not on the picture at all")
    }

    @Test func pointsOutsideThePictureAreRejectedRatherThanClamped() {
        // Clamping would put the click on the source's extreme edge — a real
        // click somewhere the user did not aim, on the Dock or the menu bar.
        let above = ScreenGeometry.normalize(
            x: 500, y: 5, containerWidth: 1000, containerHeight: 1000,
            contentWidth: 1920, contentHeight: 1080
        )
        let leftOfIt = ScreenGeometry.normalize(
            x: -10, y: 500, containerWidth: 1000, containerHeight: 1000,
            contentWidth: 1920, contentHeight: 1080
        )
        #expect(above == nil)
        #expect(leftOfIt == nil)
    }

    @Test func deltaIsExpressedInTheSourcesOwnPoints() {
        // Half a 1920-wide screen is 960 of the SOURCE's points, whatever the
        // viewer's window happens to be — that is the space the receiver adds
        // the delta in.
        let delta = ScreenGeometry.delta(
            fromNX: 0.25, fromNY: 0.5, toNX: 0.75, toNY: 0.5,
            contentWidth: 1920, contentHeight: 1080
        )
        #expect(abs(delta.dx - 960) < 0.0001)
        #expect(delta.dy == 0)
    }

    @Test func degenerateSizesDoNotCrashOrDivideByZero() {
        #expect(ScreenGeometry.normalize(
            x: 0, y: 0, containerWidth: 0, containerHeight: 0,
            contentWidth: 1920, contentHeight: 1080
        ) == nil)
        #expect(ScreenGeometry.normalize(
            x: 0, y: 0, containerWidth: 100, containerHeight: 100,
            contentWidth: 0, contentHeight: 0
        ) != nil)   // falls back to the container; must not trap
    }
}

/// Where a normalized point lands on a multi-display receiver.
@Suite struct InjectionRegionTests {
    @Test func normalizedPointMapsIntoTheWatchedDisplay() {
        // A second display to the right of a 1920-wide main one.
        let region = InjectionRegion(x: 1920, y: 0, width: 2560, height: 1440)
        let centre = region.point(nx: 0.5, ny: 0.5)
        #expect(centre.x == 1920 + 1280)
        #expect(centre.y == 720)
    }

    @Test func regionComesFromTheCaptureDescriptorsOrigin() {
        let source = CaptureSourceDescriptor(
            id: "display:2", kind: .display, name: "Studio Display",
            width: 2560, height: 1440, originX: 1920, originY: 300
        )
        let region = source.injectionRegion
        #expect(region.x == 1920 && region.y == 300)
        #expect(region.width == 2560 && region.height == 1440)
        // Top-left of the watched display, not of the desktop.
        let corner = region.point(nx: 0, ny: 0)
        #expect(corner.x == 1920 && corner.y == 300)
    }

    @Test func outOfRangeInputIsClampedNotWrapped() {
        let region = InjectionRegion(x: 0, y: 0, width: 100, height: 100)
        #expect(region.point(nx: 1.5, ny: -0.5) == (100, 0))
    }
}
