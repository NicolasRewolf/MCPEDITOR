import AppKit
import SwiftUI
import Testing
@testable import KitStudio

@MainActor
struct TrimSliderTests {
    @Test func audioFrameRangeDoesNotCreateNativeTickMarks() throws {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: SampleTrimSlider(
            title: "DÉBUT", value: 0, upper: 44_100, onChange: { _ in }
        ))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 60)
        view.layoutSubtreeIfNeeded()

        func sliders(in view: NSView) -> [NSSlider] {
            (view as? NSSlider).map { [$0] } ?? view.subviews.flatMap { sliders(in: $0) }
        }
        let slider = try #require(sliders(in: view).first)
        #expect(slider.numberOfTickMarks == 0)
    }
}
