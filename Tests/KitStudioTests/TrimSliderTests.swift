import AppKit
import SwiftUI
import Testing
@testable import KitStudio

@MainActor
struct TrimSliderTests {
    /// The regression concerned AppKit tick marks: a stepped NSSlider allocated one
    /// tick per audio frame and stalled layout. Recent macOS releases render SwiftUI
    /// sliders without an NSSlider; there is then no AppKit tick to allocate.
    @Test func audioFrameRangeDoesNotCreateNativeTickMarks() throws {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: SampleTrimSlider(
            title: "DÉBUT", accessibilityName: "Début du sample", value: 0, upper: 44_100, onChange: { _ in }
        ))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 60)
        view.layoutSubtreeIfNeeded()

        func sliders(in view: NSView) -> [NSSlider] {
            (view as? NSSlider).map { [$0] } ?? view.subviews.flatMap { sliders(in: $0) }
        }
        for slider in sliders(in: view) {
            #expect(slider.numberOfTickMarks == 0)
        }
    }
}
