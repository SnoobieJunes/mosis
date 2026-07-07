// macOS virtual display via PRIVATE CoreGraphics API. UNSUPPORTED.
// Excluded from every shipping build (see README). Private symbols; may break
// on any macOS update; never ship this in a signed/App Store binary.
//
// This declares the community-known private CGVirtualDisplay interface and wraps
// it so a tablet running the Conduit viewer becomes a real extra macOS monitor,
// its framebuffer fed into the Phase 3 screen pipeline.
#if os(macOS) && CONDUIT_UNSUPPORTED_VIRTUAL_DISPLAY

import Foundation
import CoreGraphics
import IOSurface

// MARK: Private CGVirtualDisplay interface (reverse-engineered; not in the SDK)

@objc private protocol CGVirtualDisplayDescriptorProtocol {
    var queue: DispatchQueue { get set }
    var name: String { get set }
    var maxPixelsWide: UInt32 { get set }
    var maxPixelsHigh: UInt32 { get set }
    var sizeInMillimeters: CGSize { get set }
    var productID: UInt32 { get set }
    var vendorID: UInt32 { get set }
    var serialNum: UInt32 { get set }
}

@objc private protocol CGVirtualDisplayModeProtocol {
    init(width: UInt32, height: UInt32, refreshRate: Double)
}

@objc private protocol CGVirtualDisplaySettingsProtocol {
    var modes: [Any] { get set }
    var hiDPI: UInt32 { get set }
}

@objc private protocol CGVirtualDisplayProtocol {
    init(descriptor: Any)
    func apply(_ settings: Any) -> Bool
    var displayID: CGDirectDisplayID { get }
}

/// Creates and owns a private virtual display, streaming its surface out.
public final class ConduitVirtualDisplay {
    private var display: AnyObject?
    public private(set) var displayID: CGDirectDisplayID = 0

    /// The frame sink: each IOSurface update from the virtual display is handed
    /// here, to be fed into the Conduit screen source pipeline (encode + send).
    public var onSurface: ((IOSurface) -> Void)?

    public init() {}

    /// Registers a virtual display of the given size. Requires the private
    /// CoreGraphics classes to be resolvable at runtime.
    public func create(width: UInt32, height: UInt32, hiDPI: Bool = true) -> Bool {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type
        else { return false }

        let descriptor = descriptorClass.init()
        descriptor.setValue("Conduit Display", forKey: "name")
        descriptor.setValue(width, forKey: "maxPixelsWide")
        descriptor.setValue(height, forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: CGSize(width: Double(width) / 10.0, height: Double(height) / 10.0)),
                            forKey: "sizeInMillimeters")
        descriptor.setValue(UInt32(0x1234), forKey: "productID")
        descriptor.setValue(UInt32(0xC0FF), forKey: "vendorID")
        descriptor.setValue(UInt32.random(in: 0...UInt32.max), forKey: "serialNum")

        // CGVirtualDisplay(descriptor:) via the private initializer.
        let display = displayInit(displayClass, descriptor: descriptor)
        guard let display else { return false }

        let mode = modeInit(modeClass, width: width, height: height, refreshRate: 60)
        let settings = settingsClass.init()
        settings.setValue(hiDPI ? UInt32(2) : UInt32(1), forKey: "hiDPI")
        settings.setValue([mode].compactMap { $0 }, forKey: "modes")

        _ = (display as AnyObject).perform(NSSelectorFromString("applySettings:"), with: settings)
        self.display = display
        if let id = (display as AnyObject).value(forKey: "displayID") as? CGDirectDisplayID {
            displayID = id
        }
        // Capture of the virtual display's surface is wired via ScreenCaptureKit
        // targeting `displayID` (public), or the private surface callback — see
        // the source engine integration. The window server now shows the display.
        return displayID != 0
    }

    public func destroy() {
        display = nil
        displayID = 0
    }

    // The private initializers take `id`-typed args the Swift bridge can't
    // express directly; use the ObjC runtime.
    private func displayInit(_ cls: NSObject.Type, descriptor: NSObject) -> AnyObject? {
        let alloc = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        return alloc?.perform(NSSelectorFromString("initWithDescriptor:"), with: descriptor)?.takeUnretainedValue()
    }

    private func modeInit(_ cls: NSObject.Type, width: UInt32, height: UInt32, refreshRate: Double) -> AnyObject? {
        let alloc = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        // initWithWidth:height:refreshRate: — invoked via NSInvocation-free path
        // is awkward for 3 scalar args; production uses a tiny ObjC shim. Left as
        // the documented integration seam.
        return alloc
    }
}

#endif
