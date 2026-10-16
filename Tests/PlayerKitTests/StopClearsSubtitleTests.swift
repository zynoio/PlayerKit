import XCTest
import CoreVideo
import QuartzCore
@testable import PlayerKit
@testable import PlayerKitNative

/// zyno#206:换片 stop() 后,UI 持有的 Player.state 副本不能还带着上一部影片的字幕。
private final class NullRenderer: VideoRenderer {
    let layer = CALayer()
    var displayCapability: DisplayCapability = .macSDR
    func render(pixelBuffer: CVPixelBuffer, pts: Double, colorParams: VideoColorParams,
                metadata: FrameMetadata, strategy: RendererStrategy?) {}
    func flush() {}
    func clear() {}
}

final class StopClearsSubtitleTests: XCTestCase {
    @MainActor
    func testStopPushesClearedSubtitleStateToObserver() throws {
        let backend = try NativeBackend(renderer: NullRenderer(), audioOutput: nil)
        var lastNotified: PlayerState?
        backend.onStateChange = { lastNotified = $0 }

        backend.state.currentSubtitleText = "上一部影片的字幕"
        backend.notifyStateChange()
        XCTAssertEqual(lastNotified?.currentSubtitleText, "上一部影片的字幕")

        backend.stop()

        XCTAssertNotNil(lastNotified)
        XCTAssertNil(lastNotified?.currentSubtitleText,
                     "stop() 清了后端状态却没通知,UI 副本会残留旧字幕直到下一次状态推送")
    }
}
