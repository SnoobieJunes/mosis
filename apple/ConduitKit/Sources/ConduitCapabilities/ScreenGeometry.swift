import Foundation

/// Turns a touch on the viewer's video into a position on the source's screen.
///
/// The video is drawn aspect-fit, so unless the container happens to match the
/// stream's aspect ratio exactly there are bars on two sides. A tap's position
/// in the *container* is therefore not a position in the *picture*: on a
/// 16:9 stream in a 4:3 window, tapping the very top of the container is above
/// the image entirely, and every point in between is offset. Un-letterboxing is
/// the whole job — get it wrong and every click lands somewhere the person
/// wasn't pointing, consistently and confusingly.
///
/// Everything here is in points and normalized units; the source's pixel
/// dimensions only matter as a ratio, so retina scale cancels out and no
/// backing-scale factor is needed. Pure and platform-free so it can be tested
/// without a window (`ScreenGeometryTests`).
public enum ScreenGeometry {
    /// The rectangle the picture actually occupies inside `container`, given a
    /// stream of `contentWidth × contentHeight`, drawn aspect-fit.
    public static func videoRect(
        containerWidth: Double, containerHeight: Double,
        contentWidth: Int, contentHeight: Int
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        guard containerWidth > 0, containerHeight > 0, contentWidth > 0, contentHeight > 0 else {
            return (0, 0, max(containerWidth, 0), max(containerHeight, 0))
        }
        let contentAspect = Double(contentWidth) / Double(contentHeight)
        let containerAspect = containerWidth / containerHeight
        if containerAspect > contentAspect {
            // Container is wider than the picture: bars left and right.
            let width = containerHeight * contentAspect
            return ((containerWidth - width) / 2, 0, width, containerHeight)
        } else {
            // Container is taller: bars top and bottom.
            let height = containerWidth / contentAspect
            return (0, (containerHeight - height) / 2, containerWidth, height)
        }
    }

    /// Maps a point in the container's coordinate space (top-left origin, the
    /// space a tap arrives in) to a position on the source's screen normalized
    /// to 0…1. Returns nil for a point in the letterbox bars — a tap there is
    /// not a tap on anything, and forwarding it as a clamped edge click would
    /// silently hit whatever is at the source's border.
    public static func normalize(
        x: Double, y: Double,
        containerWidth: Double, containerHeight: Double,
        contentWidth: Int, contentHeight: Int
    ) -> (nx: Double, ny: Double)? {
        let rect = videoRect(
            containerWidth: containerWidth, containerHeight: containerHeight,
            contentWidth: contentWidth, contentHeight: contentHeight
        )
        guard rect.width > 0, rect.height > 0 else { return nil }
        let nx = (x - rect.x) / rect.width
        let ny = (y - rect.y) / rect.height
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return nil }
        return (nx, ny)
    }

    /// The delta, in the SOURCE's own points, between two normalized positions.
    ///
    /// Absolute moves carry this alongside `nx`/`ny` so a receiver that ignores
    /// the normalized fields still tracks the pointer (`InputEventBody.nx`).
    /// Expressed in the source's units, not the viewer's, because that is the
    /// space the receiver adds it to.
    public static func delta(
        fromNX: Double, fromNY: Double, toNX: Double, toNY: Double,
        contentWidth: Int, contentHeight: Int
    ) -> (dx: Double, dy: Double) {
        ((toNX - fromNX) * Double(contentWidth), (toNY - fromNY) * Double(contentHeight))
    }
}
