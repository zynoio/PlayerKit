import AVFoundation
import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
import PlayerKit
@_exported import CFFmpeg
import os

private let logger = Logger(subsystem: "io.zyno.PlayerKit", category: "backend")

private extension Duration {
    var secondsDouble: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// Builds one concat-demuxer script entry: a `file` line plus per-file `option`
/// directives that carry `headers` to that specific clip's http open (see call
/// site in `NativeBackend.play(concatURLs:)` for why this is necessary).
///
/// The concat script is read line-by-line (split on raw `\n`) before each line's
/// arguments are tokenized, so a directive's value can never contain an embedded
/// `\n` — ruling out a single multi-header `option headers 'A: 1\r\nB: 2\r\n'`
/// blob. Instead this maps the two headers CDNs actually gate on (User-Agent,
/// Referer) to ffmpeg http.c's dedicated single-value AVOptions (`user_agent`,
/// `referer`), and falls back to the generic `headers` option for at most one
/// other header (currently only WebDAV's `Authorization`, which drivers never
/// combine with a second custom header).
fileprivate func concatFileEntry(url: URL, headers: [String: String]) -> String {
    var lines = ["file '\(concatEscape(url.absoluteString))'"]
    var rest: [String: String] = [:]
    for (key, value) in headers {
        switch key.lowercased() {
        case "user-agent": lines.append("option user_agent '\(concatEscape(value))'")
        case "referer":    lines.append("option referer '\(concatEscape(value))'")
        default:           rest[key] = value
        }
    }
    if let (key, value) = rest.first {
        lines.append("option headers '\(concatEscape("\(key): \(value)"))'")
    }
    return lines.joined(separator: "\n") + "\n"
}

/// Escapes a value for embedding in a single-quoted concat script token, using
/// the same close-quote/escape/reopen-quote trick the format's own `av_get_token`
/// parser expects (`it's` → `it'\''s'`).
private func concatEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "'", with: "'\\''")
}

private final class DisplayLinkProxy: NSObject {
    weak var backend: NativeBackend?
    init(backend: NativeBackend) { self.backend = backend }
    @objc func tick() {
        // P2: displayNextFrame is display-thread native (all UI writes hop via
        // applyDisplayUpdate) — call directly, no main-actor hop.
        backend?.displayNextFrame()
    }
}

/// Decides whether a frame decoded by the demux loop may enter the jitter buffer after
/// a seek. `_seek` bumps `seekSerial` immediately, but the physical demuxer seek lands
/// 100-200 ms later; until then the loop still reads packets from the OLD position.
/// The serial alone cannot tell those apart (the loop captures the already-bumped
/// value), so a frame is kept only when the latest seek has PHYSICALLY landed - judged
/// from a snapshot taken at the start of the iteration (under demuxLock, which the
/// landing also holds), never at the end, or a frame decoded across the landing would
/// slip in right after the flush. Seen on the phone as the progress thumb flashing back
/// to the old position after a drag (2026-09-30).
enum SeekFrameGate {
    /// Snapshot at the start of a demux iteration.
    static func landedAtIterationStart(landedSerial: Int64, iterationSerial: Int64) -> Bool {
        landedSerial == iterationSerial
    }

    /// Whether the frame decoded in that iteration may be appended.
    static func accepts(landedAtIterationStart: Bool, iterationSerial: Int64, latestSerial: Int64) -> Bool {
        landedAtIterationStart && iterationSerial == latestSerial
    }
}

@MainActor
public final class NativeBackend: PlayerBackend {
    public internal(set) var state = PlayerState()
    public private(set) var videoWidth: Int = 0
    public private(set) var videoHeight: Int = 0
    private var codedVideoWidth: Int = 0
    private var codedVideoHeight: Int = 0
    /// P2: snapshotted by the display thread under renderConfigLock; written on
    /// the main actor at stream open.
    public nonisolated(unsafe) private(set) var colorParams = VideoColorParams()
    /// Display capability used to resolve `RendererStrategy`. Defaults to
    /// `appleMobile` (no EDR); PlayerController should set this to `macEDR` /
    /// `macSDR` on macOS after observing NSScreen EDR support. Propagates to
    /// the renderer so EDRRenderer's tone-map uniform picks up the new target
    /// peak nits on the next frame.
    public var displayCapability: DisplayCapability = .appleMobile {
        didSet {
            // Strategy is only resolved at stream open time; while a stream is
            // playing we can still refresh the renderer's tone-map target.
            _renderer.displayCapability = displayCapability
        }
    }
    /// When false, Dolby Vision streams fall back to HDR10 base layer.
    /// Set by the app layer based on Pro subscription status.
    public var doviEnabled: Bool = true

    /// Preferred maximum video width (0 = unlimited). When >0, the demuxer
    /// picks the highest-resolution video stream not exceeding this width.
    /// Set by PlayerController based on the user's quality preference.
    public nonisolated(unsafe) var preferredMaxVideoWidth: Int = 0

    /// 帧率匹配(zyno#106):按内容帧率设显示链路的 preferredFrameRateRange
    /// (24/25/30p → 保守倍频 48/50/60Hz,2:2 pulldown 消 3:2 judder;≥50p 用
    /// 原速)。默认开;个别电视对非 60Hz 模式兼容差时可关(关 = 回退固定
    /// (60,120,120) 旧行为)。切换即时生效;demux 循环报到真实 fps 时同样
    /// 即时套用(含混帧率内容的热切换)。
    public var frameRateMatchingEnabled: Bool = true {
        didSet { applyFrameRateRange() }
    }

    /// 用户字幕语言偏好(zyno#100):开播消费。"off" = 明确不挂内嵌字幕;
    /// nil/空 = 容器默认(旧行为);语言码(如 "zh"/"en")按
    /// TrackLanguageMatcher 匹配(精确 > 前缀 > 容器默认)。设置页改值后
    /// 下一次 play() 生效。
    public var preferredSubtitleLanguage: String?
    /// 用户音轨语言偏好(zyno#100):开播消费。"default"/nil/空 = 容器默认
    /// (旧行为);语言码按 TrackLanguageMatcher 匹配,无匹配则保持容器默认。
    public var preferredAudioLanguage: String?

    /// 容器章节(mkv/mp4,zyno#101)。_finishOpen 时从已打开的 demuxer 读取,
    /// 零额外 I/O;stop() 清空。BDMV 原盘走 MplsParser/playlist 路径,不经这里。
    public private(set) var chapters: [ChapterInfo] = []

    /// Strategy resolved once at open time from stream attributes + display
    /// capability + renderer's `prefersTenBit`. Drives decoder selection and
    /// is forwarded to `VideoRenderer.render` every frame so EDRRenderer can
    /// pick its tone-map algorithm without re-reading stream attributes.
    /// P2: read by the display thread under renderConfigLock.
    public nonisolated(unsafe) private(set) var rendererStrategy: RendererStrategy?
    public var onStateChange: ((PlayerState) -> Void)?

    /// Hook for stream-aware tone-mapper injection, invoked synchronously in
    /// `_finishOpen` right after `rendererStrategy` is resolved — before the
    /// decode loop starts, so the first rendered frame already goes through
    /// the returned mapper. The host app decides from the full strategy +
    /// stream attributes whether this stream needs frame-level processing;
    /// PlayerKit installs the result on (or clears it from) the active
    /// `ASBDLRenderer.toneMapper`. This is how PlayerKitPro's ToneMapProcessor
    /// gets precise injection — e.g. DoVi Profile 5 needs IPT→BT.2020
    /// correction on every frame, while HDR10/P8 base layers are better left
    /// to the system EDR pipeline (custom processing would collapse them to
    /// 8-bit SDR output).
    ///
    /// Returning nil clears the mapper for this stream. Only consulted when
    /// the active renderer is an `ASBDLRenderer` (the built-in Metal/CI
    /// renderers run their own strategy-driven tone-map pipeline). Main thread.
    public var toneMapperProvider: ((RendererStrategy, VideoStreamAttributes) -> (any ToneMapping)?)?

    private let _renderer: any VideoRenderer
    public var renderer: any VideoRenderer { _renderer }

    /// Injected PRO audio output backend. When non-nil, replaces AudioUnitOutput.
    /// Written once in init(), only read afterwards — safe to access from any thread.
    private nonisolated(unsafe) var _injectedAudioOutput: (any AudioOutputBackend)?

    /// User audio delay in CONTENT seconds, signed, ±5 clamp (zyno#104).
    /// Session-level by design: deliberately NOT part of PlayerState (state
    /// rebuilds on stop(); the delay must survive across play() calls — same
    /// reasoning as the previousRate capture). Written/read on the main actor
    /// (UI + output construction); the display thread reads it through
    /// AudioClock (audioTime / fullDelay), which is lock-guarded.
    public private(set) var audioDelay: Double = 0

    /// Apply a user audio delay (zyno#104). d>0 physically holds decoded audio
    /// in AudioUnitOutput's delay line (sound lags the picture); d<0 is a pure
    /// clock offset — sync delays the picture (mpv semantics, no content
    /// change). Instant mid-play; survives seek/pause/track-switch/stop.
    ///
    /// Passthrough (zyno#127): the PRO renderer schedules by packet PTS, so
    /// the shift lives entirely in the master clock — read sites apply
    /// AudioClock.fullDelay (the WHOLE signed d, symmetric both ways) to the
    /// injected backend's playbackTime. The renderer side needs no change and
    /// holds no delay state, so track/output rebuilds keep the target
    /// automatically.
    public func setAudioDelay(_ secs: Double) {
        let clamped = min(5.0, max(-5.0, secs.isFinite ? secs : 0))
        audioDelay = clamped
        audioClock.setDelay(clamped)
        audioUnitOutput?.setDelayTarget(contentSecs: max(0, clamped))
    }

    private var demuxer: (any PacketDemuxing)?
    /// VT may fail on extreme-parameter streams (e.g. 4K@120fps).
    /// When that happens the demux loop hot-swaps in a software FFmpegVideoDecoder.
    /// Written once in _finishOpen(), then swapped from the demux queue on fallback.
    private nonisolated(unsafe) var videoDecoder: (any VideoDecoding)?
    /// Created once per stream in _finishOpen() on the main actor, only read
    /// afterwards (display thread reads outputSampleRate for clock calibration).
    private nonisolated(unsafe) var audioDecoder: FFmpegAudioDecoder?
    /// Serial queue audio packets are decoded on, off the demux/video loop's
    /// thread. FFmpeg's software DTS-HD MA decode can be CPU-heavy enough
    /// per packet to starve video decode when both ran serially on the same
    /// thread — measured on-device: reads served instantly from a warm
    /// prefetch buffer (network fully ruled out) yet video fps still sat at
    /// 1-10fps. Also, decode staying serial with the demux loop meant a slow
    /// audio decode directly delayed audioClock, which then throttled video
    /// via the "stay within 2s of audio" sleep below — so a slow audio
    /// decoder was doubly capping video: starving its CPU time *and* pacing
    /// it down to match. Serial (not concurrent) so packet order — and
    /// therefore audio sample order — is preserved; flush() call sites are
    /// routed through this same queue (via .sync) so they can't race a
    /// still-in-flight decode() of an earlier packet.
    private let audioDecodeQueue = DispatchQueue(label: "io.zyno.PlayerKit.audioDecode")

    // A/V sync modules
    private let audioClock = AudioClock()
    /// Swapped on the main actor (open/track-switch/seek); the display thread
    /// reads it for the end-of-stream free-run probe (hasPendingOutput) —
    /// nonisolated(unsafe) like videoDecoder/isPassthroughActive, writes stay
    /// on main by convention, reads are lock-guarded inside AudioUnitOutput.
    private nonisolated(unsafe) var audioUnitOutput: AudioUnitOutput?
    /// Playback-rate time-stretch, fed between the audio decoder and the
    /// AudioUnitOutput on the audioDecodeQueue (rate≠1 only; 1x bypasses).
    private let audioTempo = PlaybackTempoProcessor()
    /// True only when compressed audio passthrough is actually in use (macOS
    /// with HDMI/SPDIF). On iOS/tvOS passthrough is disabled and PCM decode
    /// via AudioUnitOutput drives the audioClock normally.
    /// Written at stream open (main actor), read every display tick.
    private nonisolated(unsafe) var isPassthroughActive = false
    private let jitterBuffer = VideoJitterBuffer()
    /// P2: ticked from the display thread; internally lock-guarded (see SyncController).
    nonisolated(unsafe) private let syncController = SyncController()
    // Set after play() or seek(); cleared by displayNextFrame on first frame.
    // Calibrates audioClock to actual first decoded frame PTS so audio and video
    // start from the same position — required for H.264 streams whose PTS does
    // not start at 0 (e.g. B-frame reorder delays).
    // Guarded by displayLoopLock (see there).
    private nonisolated(unsafe) var needsClockCalibration: Bool = false
    // Above this, a video/audio PTS gap at calibration time is no longer a
    // normal "nearest keyframe was slightly before the seek target" rounding
    // (typically well under a second for BD content) — see displayNextFrame().
    // 15s:覆盖 4K HEVC 大 GOP(可达 5-10s)的 seek 对齐差。seek 落点
    // (目标前最近 I 帧)与目标差小于该值就校准 audioClock 到落点,避免
    // 大 GOP 时"校准失败 → audioClock 停在目标 → 视频帧全被 drain →
    // seek 后黑屏/位置跳变"。
    private let maxCalibrationGap: Double = 15.0

    // zyno#142 discard-until-target fine-seek. A byte-domain seek (BDMV clip /
    // raw MPEG-TS) lands on a GOP boundary up to ±2s from the target; the
    // calibration above then re-anchors audioClock to the LANDING, so the whole
    // timeline (picture + audible content) starts displaced from what the user
    // asked for — observed −2.1…+1.8s on a 68GB BD ISO. When the demuxer
    // reports a backward landing beyond this gap, the backend arms the discard:
    // audioClock stays anchored at the target and the landing-to-target stretch
    // is decoded but thrown away (video: display-loop pops; audio: demux-loop
    // packet drop), so playback starts AT the target.
    private static let discardArmGap: Double = 0.5
    /// Video side, read by the display loop / written by performDemuxerSeek
    /// (which holds demuxLock, NOT displayLoopLock — a dedicated tiny lock
    /// avoids any lock-order question between the two).
    private let discardLock = NSLock()
    private nonisolated(unsafe) var discardVideoUntilPts: Double?
    /// Audio side. Both writer (performDemuxerSeek) and reader (demux loop
    /// audio branch) hold demuxLock, so a plain variable is as safe as the
    /// other demux-loop state next to it.
    private nonisolated(unsafe) var discardAudioUntilPts: Double?

    // Subtitle cue buffer — written from demux loop, read from display loop.
    private struct SubtitleCue {
        let startPts: Double
        let endPts: Double
        let text: String
    }
    private let subtitleLock = NSLock()
    private nonisolated(unsafe) var subtitleCues: [SubtitleCue] = []
    private nonisolated(unsafe) var lastSubtitleText: String? = nil

    private struct SubtitleImageCue {
        let startPts: Double
        let endPts: Double
        let image: CGImage
        let rect: CGRect
    }
    private let subtitleImageLock = NSLock()
    private nonisolated(unsafe) var subtitleImageCues: [SubtitleImageCue] = []
    private nonisolated(unsafe) var lastSubtitleImage: CGImage? = nil

    private nonisolated(unsafe) var subtitleDecoder: FFmpegSubtitleDecoder?
    // libass typeset renderer for ASS/SSA streams (zyno#158); nil → legacy text cues.
    private nonisolated(unsafe) var assRenderer: ASSRenderer?

    // Pipeline control
    private let demuxLock = NSLock()
    /// Guards ONLY the demux-loop state flags (`demuxLoopRunning`, `demuxLoopDemuxer`,
    /// `demuxCancelled`). It is never held across I/O, so main-thread lifecycle
    /// calls (pause/resume/startDemuxLoop) can take it without ever waiting on the
    /// network. `demuxLock` is held by the demux loop across `readPacket()` — a
    /// blocking network read for HTTP sources — so nothing on the main thread may
    /// wait on it just to read a flag: a stalled read froze the main thread until
    /// the iOS scene-update watchdog killed the app (2026-09-30, 0x8BADF00D).
    private let demuxStateLock = NSLock()
    private let seekLock = NSLock()
    // Guarded by seekLock — safe to access from any thread holding the lock.
    private nonisolated(unsafe) var seekSerial: Int64 = 0
    /// The newest seek serial whose physical demuxer seek has landed (or that needed
    /// none). Written under demuxLock (landing / selectAudioTrack) and read by the demux
    /// loop under the same lock - see `SeekFrameGate`.
    private nonisolated(unsafe) var seekLandedSerial: Int64 = 0
    /// 有别于 seekSerial(_seek() 同步调用瞬间就 +1):这个只在 demuxer.seek()
    /// 真正物理执行之后才 +1。异步 seek 下,seekSerial 会在网络 I/O 落地前
    /// 抢跑好几次(用户连续拖动/连续 seek 时尤其明显),demux 循环若拿
    /// seekSerial 变化去触发 ptsValidator.reset(),reset 会在"抢跑"阶段就被
    /// 用掉,轮到真正物理 seek 落地、PTS 真的跳变的那一刻反而没有 reset——
    /// PTSValidator 把这次真实跳变当异常,进入 blind clock 模式,画面从旧
    /// 位置逐帧爬向新位置而不是直接跳过去(2026-09-03 用户反馈"画面抖动"/
    /// seek 后卡顿实锤)。只在 performDemuxerSeek 真正调用 demuxer.seek()
    /// 那一刻(持有 demuxLock)才 +1,由 demuxLock 保护,不需要额外的锁。
    nonisolated(unsafe) private(set) var physicalSeekGeneration: Int64 = 0
    /// 最近一次切音轨走的路径("fast"/"slow"),供测试与诊断读取(zyno#171)。
    nonisolated(unsafe) private(set) var lastAudioSwitchPath: String?
    /// Set true after seek()/play(), cleared on first frame render + audioClock advance.
    /// While true, freeze-ahead guard is bypassed so primer callbacks have time to
    /// fire and advance audioClock past 0 — without this, seek-to-0 freezes because
    /// primer debt keeps audioClock at 0 while video PTS advances past the 60ms threshold.
    private nonisolated(unsafe) var audioClockReady: Bool = false
    // demuxCancelled is written under demuxStateLock (never demuxLock — see there) and
    // read from DispatchQueue.global().
    // Bool reads/writes are atomic on ARM64 in practice; nonisolated(unsafe) makes
    // that contract explicit for the compiler's concurrency checker.
    private nonisolated(unsafe) var demuxCancelled = false
    // 当前 demux 循环是否在运行(锁内读写,dispatch-global 线程)。防止 resume()
    // 在旧循环仍在运行(PiP 场景 willResignActive 不 pause)时再启动第二个循环
    // —— 两个循环并行读同一 demuxer 会竞争包,jitterBuffer 出现交错双序列
    // append,视频卡住。
    private nonisolated(unsafe) var demuxLoopRunning = false
    // 运行中循环对应的 demuxer 实例(仅指针比较,循环退出时清空)。stop→play
    // 换媒体后旧循环必须退出、由 startDemuxLoop 等待后启动新循环;而
    // pause→resume / PiP→resume 不换 demuxer,直接复用旧循环。
    private nonisolated(unsafe) var demuxLoopDemuxer: (any PacketDemuxing)?
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
    /// zyno#106: real content fps as reported by the demux loop (single
    /// writer on the demux thread, read on the main actor). Benign race —
    /// Double stores are atomic on arm64 and a one-frame-late refresh-rate
    /// update is harmless.
    private nonisolated(unsafe) var contentFps: Double = 0
    /// P2: iOS/tvOS display-link host thread (see startDisplayLink). Owned by
    /// main-thread lifecycle code; the thread itself runs a dedicated runloop.
    private var displayLinkThread: Thread?
    /// P2: display-loop liveness flag (guarded by displayLoopLock). startDisplayLink
    /// clears it, every teardown path sets it; the iOS/tvOS host thread polls it
    /// to leave its run loop (checked ≤0.5s latency).
    private nonisolated(unsafe) var displayLoopStopped = true
    /// P2: dedicated serial queue for the macOS fallback render timer — off-main
    /// like the CVDisplayLink thread that is the primary driver. displayNextFrame
    /// is idempotent (renderGate), so fallback and link never corrupt each other.
    private let displayFallbackQueue = DispatchQueue(label: "io.zyno.PlayerKit.displayFallback", qos: .userInteractive)
    #if os(macOS)
    private var cvDisplayLink: CVDisplayLink?
    /// macOS 兜底渲染驱动。CVDisplayLink 在 stop→start 之后可能延迟数秒才恢复
    /// 回调(实测:CVDisplayLinkStart 后 6.3s 才收到 first tick),期间视频冻结、
    /// state.position 不更新 → app 层 UpNext 检测读到 ~0 的初始值误触发 EOF。
    /// 用后台串行 queue 的 DispatchSourceTimer 兜底驱动 displayNextFrame —— 它幂等
    /// (每 tick 最多 pop 一帧),与 CVDisplayLink 竞争无害;link 恢复后自然占主导,
    /// 兜底 timer 空转。(P2:从主 queue 迁出,见 displayFallbackQueue。)
    private var fallbackRenderTimer: DispatchSourceTimer?
    #endif

    // Cancellation: incremented on every play()/stop() to discard stale async
    // opens, and snapshotted by the display thread so a main-thread state apply
    // can be discarded when the session it was computed for is already gone.
    private nonisolated(unsafe) var playGeneration: Int = 0

    // MARK: Display-loop shared state (P2: presentation runs off the main thread)

    /// Serializes displayNextFrame execution. macOS drives it from two sources
    /// (CVDisplayLink + fallback timer), both now on background queues, and
    /// iOS from the display-link run-loop thread. tryLock makes double-drive /
    /// reentry harmless: if the previous tick is still running (slow renderer),
    /// this tick is skipped — idempotent, at most one frame popped per tick.
    private let renderGate = NSLock()

    /// Guards the display-loop scalars below. They are written every display
    /// tick (now on the display-link thread) and reset from main-thread
    /// lifecycle paths (play/seek/resume/stop) — trivially serialized when
    /// everything lived on the main actor, which is exactly what P2 removed.
    private let displayLoopLock = NSLock()

    // Logging
    private nonisolated(unsafe) var displayedVideoFrames = 0
    private nonisolated(unsafe) var framesSinceLastLog = 0
    private nonisolated(unsafe) var ticksSinceLastLog = 0
    private nonisolated(unsafe) var lastLogTime: Double = 0
    // [diag] tick path attribution (晃动 localization): a tick that doesn't
    // display a frame ends as a guard drain, a freeze-ahead stall, or a
    // syncController denial — these counters say which, per log window.
    private nonisolated(unsafe) var tickDrainLag = 0
    private nonisolated(unsafe) var tickStallAhead = 0
    private nonisolated(unsafe) var tickCheckDeny = 0
    private nonisolated(unsafe) var tickNoFrame = 0
    private nonisolated(unsafe) var tickGuardSkip = 0
    private nonisolated(unsafe) var tickGuardSkipSample = 0
    private nonisolated(unsafe) var tickStallSample = 0
    /// How far behind audio the frames the skip-behind guard drained were
    /// (audioTime − pts) — shallow (~40-80ms) means normal pacing overshoot,
    /// deep (100ms+) means something let audio run away.
    private nonisolated(unsafe) var drainDepthStats = SyncDiagStats()
    /// Decoded frames appended into the jitter buffer (supply-side count; the
    /// loss is display-side iff appends ≈ source fps×elapsed ≫ displayed).
    private nonisolated(unsafe) var diagAppendsSinceLog = 0
    // Diagnostic: see the gap-detection note in displayNextFrame().
    private nonisolated(unsafe) var lastTickWallTime: Double?
    private let tickGapWarnThreshold: Double = 0.05
    // Diagnostic: wall time startDisplayLink() was called, so the first tick
    // can log how long it took to actually arrive — distinguishes "the link
    // itself didn't fire for N seconds" (real main-thread/runloop stall) from
    // "ticks were firing fine but one later tick got delayed" (the existing
    // gap check only ever compares tick-to-tick, so a slow *first* tick was
    // invisible: lastTickWallTime starts nil, so tick #1 never gets a gap
    // check — it just silently sets the baseline).
    private nonisolated(unsafe) var displayLinkStartWallTime: Double?
    private nonisolated(unsafe) var firstTickLogged = false
    /// 同步旁路(audioClockReady=false)弹帧的节拍基准:上一帧实际弹出的
    /// 墙钟时刻。旁路不再每个显示驱动 tick 都弹帧,而是按源 PTS 间隔 pacing。
    /// 初始 0 → 首个 tick 立即弹出;seek/resume/stop/flush 后复位同样立即
    /// 弹出,不会等待。
    private nonisolated(unsafe) var lastBypassPopTime: Double = 0
    private nonisolated(unsafe) var lastNotifiedPos: Duration = .zero
    /// Passthrough fallback pacing anchor (wall time ↔ read-ahead frontier PTS)
    /// used while the injected output's playbackTime is unavailable. Nil once
    /// the real passthrough clock takes over; reset per session in stop().
    private var passthroughWallClockAnchor: (wall: Double, pts: Double)?
    /// resume() 后置位:后台期间(PiP 未激活/不支持)音频会话被系统暂停,
    /// AudioQueue 停止消费,音频时钟停在暂停位置,而 demux/解码器在 app
    /// 未被挂起时继续推进 —— 恢复时音频时钟可能落后视频帧 PTS 数十秒,
    /// 远超 maxCalibrationGap,不校准则 freeze-ahead 把超前帧全部冻结,
    /// 画面长时间卡死。置位后首个校准帧强制校准(丢弃暂停期静音差距);
    /// seek 场景不置位,保持 maxCalibrationGap 对 byte-offset seek 大偏差
    /// 的掩盖保护。
    /// Guarded by displayLoopLock.
    private nonisolated(unsafe) var forceClockCalibration = false

    /// Playback rate snapshot for the nonisolated display loop (zyno#99):
    /// setRate() runs on the main actor, displayNextFrame() must not touch
    /// `state` directly. Written before it's read (setRate assigns both).
    /// Guarded by displayLoopLock.
    private nonisolated(unsafe) var displayRate: Double = 1.0

    /// [diag] Per-displayed-frame `pts - audioTime` distribution, drained into
    /// the 5s logSync line. The single 5s sample cannot show an oscillating
    /// Runtime switch for the periodic `[diag]` os_log lines: the 5s A/V
    /// offset / tick attribution / display-order windows, the freeze-site and
    /// guard-skip samples, and the first 200 appends. OFF by default — these
    /// lines are what localized the 2026-10 晃动 regressions and stay
    /// available for field debugging, but a production player should not emit
    /// them.
    ///
    /// Only the log OUTPUT is gated: the distributions behind it (and the
    /// `drainDiag*` APIs the measurement tests read) always run. Turn it on
    /// with the `PLAYERKIT_DIAG=1` environment variable, or set it from the
    /// host app before playback starts.
    ///
    /// `[diag] seek videoLand` is deliberately NOT gated: one line per seek,
    /// and seek-landing accuracy is itself something we track (zyno#117).
    public nonisolated(unsafe) static var diagLoggingEnabled =
        ProcessInfo.processInfo.environment["PLAYERKIT_DIAG"] == "1"

    /// offset (user-reported 晃动/字幕-vs-声音, 2026-10-12) — the window stats
    /// (stddev / maxJump / signFlips) make one visible. Guarded by
    /// displayLoopLock. Units: seconds.
    private nonisolated(unsafe) var avOffsetStats = SyncDiagStats()
    /// [diag] Display-order integrity: distribution of the PTS interval between
    /// consecutive DISPLAYED frames (track-switch 画面来回晃/闪 localization,
    /// 2026-10-13). With B-frames the jitter buffer's PTS-sorted insertion is
    /// what restores display order; if the PTS pipeline is disturbed (see
    /// diagPTSRewriteCount) frames display in decode order and this interval
    /// stops sitting at the source frame duration — it alternates (e.g.
    /// 20.8/62.5ms at 23.976fps) or goes negative instead of a flat ~41.7ms.
    /// Intervals outside ±1s are treated as seek discontinuities and dropped.
    /// Guarded by displayLoopLock. Units: seconds.
    private nonisolated(unsafe) var shownGapStats = SyncDiagStats()
    private nonisolated(unsafe) var lastShownDiagPTS: Double = -.infinity
    /// [diag] Frames whose PTS the demux-side PTSValidator REWROTE (synthesized
    /// blind-clock PTS, >5s anomaly). A rewritten PTS no longer reflects the
    /// frame's true display time, so PTS-ordered insertion can no longer undo
    /// decoder reorder — the count is the direct signature of that failure.
    /// Reset per log window. Guarded by displayLoopLock.
    private nonisolated(unsafe) var diagPTSRewriteCount = 0
    /// [diag] Seek-landing capture: target set in _seek, consumed by the
    /// one-shot log on the first displayed frame after it. Guarded by
    /// displayLoopLock.
    private nonisolated(unsafe) var pendingSeekLandTarget: Double?
    private nonisolated(unsafe) var seekLandLogged = true

    /// [diag] Drain the live per-frame offset window (jitter measurement tests
    /// and tooling; production reads it via the 5s logSync line instead).
    func drainDiagAvOffset() -> SyncDiagStats {
        displayLoopLock.withLock { () -> SyncDiagStats in
            let s = avOffsetStats
            avOffsetStats.reset()
            return s
        }
    }

    /// [diag] Drain the AudioQueue per-callback granularity window.
    func drainAudioQueueDiag() -> SyncDiagStats {
        audioClock.drainAdvanceDiag()
    }

    /// [diag] Drain the AudioUnitOutput queue-health snapshot (enqueue/start/
    /// pause/resume counts + instantaneous paused/buffered state).
    func drainOutputQueueDiag() -> AudioUnitOutput.QueueDiag {
        if let out = audioUnitOutput { return out.drainQueueDiag() }
        return AudioUnitOutput.QueueDiag()
    }

    /// [diag] Display-tick path attribution + append count since last drain.
    /// Tells you WHERE frames die: `drainLag` = popped by the skip-behind
    /// guard, `stallAhead` = ticks held by freeze-ahead, `checkDeny` = ticks
    /// denied by SyncController pacing, `appends` = frames supplied by decode.
    struct TickDiag {
        var drainLag = 0
        var stallAhead = 0
        var checkDeny = 0
        var noFrame = 0
        var guardSkip = 0
        var drainDepth = SyncDiagStats()
        var appends = 0
    }

    nonisolated func drainTickDiag() -> TickDiag {
        displayLoopLock.withLock { () -> TickDiag in
            let t = TickDiag(drainLag: tickDrainLag, stallAhead: tickStallAhead,
                             checkDeny: tickCheckDeny, noFrame: tickNoFrame,
                             guardSkip: tickGuardSkip, drainDepth: drainDepthStats,
                             appends: diagAppendsSinceLog)
            tickDrainLag = 0
            tickStallAhead = 0
            tickCheckDeny = 0
            tickNoFrame = 0
            tickGuardSkip = 0
            drainDepthStats.reset()
            diagAppendsSinceLog = 0
            return t
        }
    }

    /// Guards render configuration (`colorParams`, `rendererStrategy`) and the
    /// frame-sink list: written on the main actor (stream open / addFrameSink),
    /// read every display tick. Since P2 those run concurrently.
    private let renderConfigLock = NSLock()
    private nonisolated(unsafe) var _frameSinks: [WeakFrameSink] = []
    private struct WeakFrameSink {
        weak var sink: (any FrameSink)?
    }

    // Throughput tracking. Written from demux queue, read on main actor.
    private nonisolated(unsafe) var totalBytesRead: Int64 = 0
    private nonisolated(unsafe) var lastBytesLogged: Int64 = 0
    private nonisolated(unsafe) var lastThroughputTime: Double = 0
    /// 吞吐计数专用叶子锁:totalBytesRead 在 demux 线程累加、display 线程采样。
    /// 不与 displayLoopLock 混用(避免锁序问题),只护这三个计数变量(zyno#145)。
    private nonisolated(unsafe) let throughputLock = NSLock()
    /// Highest PTS (seconds) of packets read by the demux loop — used to compute bufferedDuration.
    private nonisolated(unsafe) var maxDownloadedPts: Double = 0

    /// zyno#171: 备选音轨的原始包缓存(切轨命中时免 seek)。只在 demuxLock 内读写;
    /// 元素是克隆的 AVPacket,淘汰/清空时 av_packet_free。
    nonisolated(unsafe) var altAudioCache = AltAudioPacketCache<UnsafeMutablePointer<AVPacket>>(
        bytesOf: { Int($0.pointee.size) },
        onEvict: { var p: UnsafeMutablePointer<AVPacket>? = $0; av_packet_free(&p) })
    /// 正在被缓存的备选音频流下标(音轨数超门槛/多片段时为空 = 功能关闭)。
    nonisolated(unsafe) var altAudioStreams: Set<Int32> = []

    /// 按当前选中音轨重算备选缓存流集合并通知解复用层;调用方须持 demuxLock
    /// (或在无解复用循环运行时调用,如 open)。
    private func refreshAltAudioStreams(_ demuxer: any PacketDemuxing) {
        let all = demuxer.audioStreamIndices
        if AltAudioCachePolicy.shouldEnable(audioTrackCount: all.count) {
            altAudioStreams = Set(all.filter { $0 != demuxer.audioStreamIndex })
        } else {
            altAudioStreams = []
        }
        demuxer.setCachedAudioStreams(altAudioStreams)
        logger.notice("[diag] altaudio audioTracks=\(all.count, privacy: .public) enabled=\(!self.altAudioStreams.isEmpty, privacy: .public)")
    }

    /// Default init: ASBDLRenderer + AudioUnitOutput (PCM).
    public convenience init() throws {
        try self.init(renderer: nil, audioOutput: nil)
    }

    /// Default init with custom audio output (renderer uses ASBDLRenderer).
    /// - Parameter audioOutput: Custom AudioOutputBackend. nil defaults to AudioUnitOutput.
    public convenience init(audioOutput: (any AudioOutputBackend)?) throws {
        try self.init(renderer: nil, audioOutput: audioOutput)
    }

    /// PRO injection init: accepts custom renderer and audio output.
    /// - Parameters:
    ///   - renderer: Custom VideoRenderer. nil defaults to ASBDLRenderer.
    ///   - audioOutput: Custom AudioOutputBackend. nil defaults to AudioUnitOutput.
    public init(renderer: (any VideoRenderer)?, audioOutput: (any AudioOutputBackend)?) throws {
        self._renderer = try renderer ?? ASBDLRenderer()
        self._injectedAudioOutput = audioOutput
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        logger.info("init OK")
    }

    public func play(url: URL, headers: [String: String], seekTo: Duration?, knownDuration: Duration? = nil) {
        // Capture the rate BEFORE stop(): stop() ends with `state = PlayerState()`
        // (rate back to 1.0), so a capture after it always reads 1.0 and the
        // restore below was a no-op — the 2x end-to-end test opened at 1x.
        let previousRate = state.rate
        stop()
        state = PlayerState()
        // Rate is a user preference — it survives open (play() resets all
        // playback state, but a speed the user picked before open must still
        // apply to the new item; _finishOpen wires it into the new output).
        state.rate = previousRate
        state.isBuffering = true
        notifyStateChange()

        logger.notice("play \(url.absoluteString.prefix(120))")

        // Increment generation so any previously in-flight open is discarded.
        playGeneration += 1
        let gen = playGeneration

        // Open the demuxer on a background thread — avformat_open_input +
        // avformat_find_stream_info block on network I/O and must not run on
        // the main actor.  The player screen already shows isBuffering=true
        // (spinner) while we wait.
        Task.detached(priority: .userInitiated) { [weak self, preferredMaxVideoWidth] in
            let demuxer = FFmpegDemuxer()
            demuxer.preferredMaxVideoWidth = preferredMaxVideoWidth
            do {
                try demuxer.open(url: url, headers: headers,
                                 skipDurationProbe: knownDuration != nil,
                                 knownDurationSecs: knownDuration?.secondsDouble)
            } catch {
                logger.error("demuxer.open FAILED: \(error)")
                // Prefer CustomStringConvertible.description (our DemuxerError
                // provides FFmpeg ret + av_err2str). localizedDescription would
                // just return "The operation couldn't be completed. ... error N."
                let msg = (error as? CustomStringConvertible)?.description
                    ?? String(describing: error)
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.playGeneration == gen else {
                    demuxer.close()
                    return
                }
                self._finishOpen(demuxer: demuxer, url: url, headers: headers,
                                 seekTo: seekTo, knownDuration: knownDuration)
            }
        }
    }

    public func play(reader: any MediaRandomAccessReader,
                     seekTo: Duration?,
                     knownDuration: Duration? = nil) {
        // Capture the rate BEFORE stop(): stop() ends with `state = PlayerState()`
        // (rate back to 1.0), so a capture after it always reads 1.0 and the
        // restore below was a no-op — the 2x end-to-end test opened at 1x.
        let previousRate = state.rate
        stop()
        state = PlayerState()
        // Rate is a user preference — it survives open (play() resets all
        // playback state, but a speed the user picked before open must still
        // apply to the new item; _finishOpen wires it into the new output).
        state.rate = previousRate
        state.isBuffering = true
        notifyStateChange()

        let t0 = Date()
        logger.notice("play (custom I/O reader)")

        playGeneration += 1
        let gen = playGeneration

        // Use GCD instead of Task.detached — Swift Concurrency's cooperative
        // thread pool can be starved by other async work (auto-scan, keepalive),
        // causing the demuxer open to be delayed 10-15s. GCD's dedicated thread
        // pool is not affected by cooperative scheduling.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let t1 = Date()
            logger.info("GCD block started, delay=\(String(format: "%.0f", t1.timeIntervalSince(t0) * 1000))ms")

            let demuxer = FFmpegDemuxer()
            demuxer.preferredMaxVideoWidth = self.preferredMaxVideoWidth
            do {
                try demuxer.open(reader: reader,
                                 skipDurationProbe: knownDuration != nil,
                                 knownDurationSecs: knownDuration?.secondsDouble)
            } catch {
                logger.error("demuxer.open (reader) FAILED: \(error)")
                let msg = (error as? CustomStringConvertible)?.description
                    ?? String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }
            let t2 = Date()
            logger.info("demuxer.open done in \(String(format: "%.0f", t2.timeIntervalSince(t1) * 1000))ms")

            DispatchQueue.main.async { [weak self] in
                guard let self, self.playGeneration == gen else {
                    demuxer.close()
                    return
                }
                self._finishOpen(demuxer: demuxer, url: URL(string: "custom-io://reader")!,
                                 headers: [:], seekTo: seekTo, knownDuration: knownDuration)
            }
        }
    }

    public func play(concatURLs: [URL], headers: [String: String],
                     seekTo: Duration?, knownDuration: Duration? = nil) {
        // Capture the rate BEFORE stop(): stop() ends with `state = PlayerState()`
        // (rate back to 1.0), so a capture after it always reads 1.0 and the
        // restore below was a no-op — the 2x end-to-end test opened at 1x.
        let previousRate = state.rate
        stop()
        state = PlayerState()
        // Rate is a user preference — it survives open (play() resets all
        // playback state, but a speed the user picked before open must still
        // apply to the new item; _finishOpen wires it into the new output).
        state.rate = previousRate
        state.isBuffering = true
        notifyStateChange()

        guard !concatURLs.isEmpty else {
            state.error = "concat: no URLs"
            notifyStateChange()
            return
        }

        // Single URL — skip concat overhead, play directly.
        if concatURLs.count == 1 {
            play(url: concatURLs[0], headers: headers, seekTo: seekTo,
                 knownDuration: knownDuration)
            return
        }

        logger.notice("play concat \(concatURLs.count) urls")

        playGeneration += 1
        let gen = playGeneration

        let urls = concatURLs  // capture
        let hdrs = headers
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            // Write concat list to a temp file. Per-file `option` directives carry
            // auth headers to each clip's http open — the concat demuxer's own
            // `headers` AVOption (set on the outer avformat_open_input below) only
            // applies to opening this local list file, NOT to the nested per-clip
            // URLs it opens internally (ffmpeg concatdec.c: each file gets its own
            // AVDictionary built solely from that file's `option` lines). Without
            // this, CDNs that gate on User-Agent/Referer (e.g. 115: mismatched UA
            // → 403) reject every clip and the whole concat open fails.
            let listContent = urls.map { concatFileEntry(url: $0, headers: hdrs) }.joined()
            let tmpDir = FileManager.default.temporaryDirectory
            let listFile = tmpDir.appendingPathComponent("zyno-concat-\(UUID().uuidString).txt")
            do {
                try listContent.write(to: listFile, atomically: true, encoding: .utf8)
            } catch {
                let msg = "concat: failed to write list file: \(error.localizedDescription)"
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }
            defer { try? FileManager.default.removeItem(at: listFile) }

            let demuxer = FFmpegDemuxer()
            demuxer.preferredMaxVideoWidth = self.preferredMaxVideoWidth
            do {
                try demuxer.openConcat(listFileURL: listFile, headers: hdrs,
                                       skipDurationProbe: knownDuration != nil,
                                       knownDurationSecs: knownDuration?.secondsDouble)
            } catch {
                logger.error("demuxer.openConcat FAILED: \(error)")
                let msg = (error as? CustomStringConvertible)?.description
                    ?? String(describing: error)
                await MainActor.run { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.playGeneration == gen else {
                    demuxer.close()
                    return
                }
                self._finishOpen(demuxer: demuxer,
                                 url: URL(string: "concat://list")!,
                                 headers: hdrs, seekTo: seekTo,
                                 knownDuration: knownDuration)
            }
        }
    }

    /// Start playback of an ordered sequence of independently-timed clips
    /// (BDMV disc playback) as one continuous presentation timeline, using
    /// MultiClipDemuxer's per-clip demux + PTS rebase instead of ffmpeg's
    /// concat demuxer (these readers are custom-I/O, not URL-openable by
    /// ffmpeg — see `play(concatURLs:)` for the URL-based alternative).
    /// - Parameters:
    ///   - clips: Ordered clips; `reader` feeds each clip's bytes to ffmpeg,
    ///     `durationSecs` is the clip's own real duration (caller-supplied,
    ///     e.g. from BD playlist metadata). Must be non-empty with all
    ///     durations > 0.
    ///   - seekTo: Optional start position (global timeline).
    ///   - knownDuration: Pre-known total duration, skips probe if non-nil.
    public func play(clips: [(reader: any MediaRandomAccessReader, durationSecs: Double)],
                     seekTo: Duration?,
                     knownDuration: Duration? = nil) {
        // Capture the rate BEFORE stop(): stop() ends with `state = PlayerState()`
        // (rate back to 1.0), so a capture after it always reads 1.0 and the
        // restore below was a no-op — the 2x end-to-end test opened at 1x.
        let previousRate = state.rate
        stop()
        state = PlayerState()
        // Rate is a user preference — it survives open (play() resets all
        // playback state, but a speed the user picked before open must still
        // apply to the new item; _finishOpen wires it into the new output).
        state.rate = previousRate
        state.isBuffering = true
        notifyStateChange()

        guard !clips.isEmpty else {
            state.error = "play(clips:): no clips"
            notifyStateChange()
            return
        }

        logger.notice("play \(clips.count) clips")

        playGeneration += 1
        let gen = playGeneration

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let demuxer = MultiClipDemuxer(clips: clips)
            guard let demuxer else {
                let msg = "play(clips:): MultiClipDemuxer init failed (empty clips or non-positive duration)"
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }
            do {
                // MultiClipDemuxer has no finishOpen of its own — open()
                // already drives FFmpegDemuxer.open(reader:) for clip 0, which
                // runs the full avformat_find_stream_info probe, so decoder
                // setup below can read stream metadata off it directly.
                try demuxer.open()
            } catch {
                logger.error("demuxer.open (clips) FAILED: \(error)")
                let msg = (error as? CustomStringConvertible)?.description
                    ?? String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playGeneration == gen else { return }
                    self.state.error = msg
                    self.notifyStateChange()
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.playGeneration == gen else {
                    demuxer.close()
                    return
                }
                self._finishOpen(demuxer: demuxer,
                                 url: URL(string: "clips://multi")!,
                                 headers: [:], seekTo: seekTo,
                                 knownDuration: knownDuration)
            }
        }
    }

    /// adopt 预热会话(zyno#108):跳过 new+open,直接 _finishOpen —— 切集
    /// 只剩解码器初始化(数十 ms)。prepared 不可消费(已 adopt/已 abandon)
    /// 时 throw,此时当前会话未被破坏(stop() 尚未执行),调用方可回退普通
    /// play()。放在本文件内:state 的 private setter 与 _finishOpen 仅同
    /// 文件可见。
    public func play(prepared: PreparedMedia, seekTo: Duration? = nil,
                     knownDuration: Duration? = nil) throws {
        // Consume FIRST: on failure this play() must leave the current
        // session untouched (stop() below is irreversible).
        guard let demuxer = prepared.consume() else {
            throw PreparedMediaError.notConsumable
        }

        // Capture the rate BEFORE stop(): stop() ends with `state = PlayerState()`
        // (rate back to 1.0), so a capture after it always reads 1.0.
        let previousRate = state.rate
        stop()
        state = PlayerState()
        // Rate is a user preference — it survives open (see play(url:)).
        state.rate = previousRate
        state.isBuffering = true
        notifyStateChange()

        let url: URL
        let headers: [String: String]
        switch prepared.source {
        case .url(let u, let h):
            url = u
            headers = h
        case .reader:
            url = URL(string: "custom-io://reader")!
            headers = [:]
        }

        logger.notice("play (prepared, adopted demuxer)")

        // Invalidate any in-flight open from a previous play() — the adopt
        // path is synchronous on the main actor, so unlike play(url:) there
        // is no gen to check against: the old open's completion callback sees
        // a mismatched generation and closes its demuxer.
        playGeneration += 1

        _finishOpen(demuxer: demuxer, url: url, headers: headers,
                    seekTo: seekTo, knownDuration: knownDuration)
    }

    private func _finishOpen(demuxer: any PacketDemuxing, url: URL, headers: [String: String],
                              seekTo: Duration?, knownDuration: Duration?) {
        let t0 = Date()
        self.demuxer = demuxer
        // PacketDemuxing deliberately has no `duration` member (MultiClip's
        // total timeline length lives on ClipTimeline, not on the current
        // clip's demuxer), so recover it from the concrete types.
        let demuxDur: Double
        if let fd = demuxer as? FFmpegDemuxer {
            demuxDur = fd.duration
        } else if let mc = demuxer as? MultiClipDemuxer {
            demuxDur = mc.timeline.totalDurationSecs
        } else {
            demuxDur = 0
        }
        if let kd = knownDuration, kd > .zero {
            state.duration = kd
        } else if demuxDur > 0 {
            // demuxDur is refined by seekRefine() inside FFmpegDemuxer.open() —
            // it already reflects the true end-of-stream PTS, not the container placeholder.
            state.duration = Duration.seconds(demuxDur)
        }
        logger.info("duration: knownDuration=\(knownDuration.map{"\(Double($0.components.seconds))s"} ?? "nil") demuxer=\(String(format:"%.1f",demuxDur))s → using \(String(format:"%.1f",Double(self.state.duration.components.seconds)))s self=\(String(format:"%p", UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())))")

        // Extract HDR color metadata from the video stream's codec parameters
        if let vs = demuxer.videoStream {
            let cp = vs.pointee.codecpar.pointee
            var cpParams = VideoColorParams()
            switch cp.color_trc {
            case AVCOL_TRC_SMPTE2084:   cpParams.transfer = .pq
            case AVCOL_TRC_ARIB_STD_B67: cpParams.transfer = .hlg
            default: break
            }
            switch cp.color_space {
            case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: cpParams.matrix = .bt2020
            case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M:     cpParams.matrix = .bt601
            default: break
            }
            cpParams.range = cp.color_range == AVCOL_RANGE_JPEG ? .full : .limited
            // P2: displayNextFrame snapshots these on the display thread —
            // publish under renderConfigLock.
            renderConfigLock.withLock {
                self.colorParams = cpParams
                if self.colorParams.transfer == .pq || self.colorParams.transfer == .hlg {
                    logger.info("HDR: transfer=\(String(describing: self.colorParams.transfer)) matrix=\(String(describing: self.colorParams.matrix))")
                }
            }

            // Resolve the renderer strategy from stream attributes + display
            // capability + renderer's 10-bit preference. Stream attributes
            // (matrix/transfer/range, HEVC 10-bit evidence, DoVi, HDR10+) all
            // come from the demuxer's single-source videoStreamAttributes() —
            // shared verbatim with the HDR corpus conformance tests so tests
            // decide strategies against exactly what production decides on.
            // This open path is synchronous (can't throw); nil attrs is
            // unreachable inside `if let vs = demuxer.videoStream`, so the
            // all-defaults SDR fallback only satisfies the type checker.
            let attrs = demuxer.videoStreamAttributes()
                ?? VideoStreamAttributes(width: 0, height: 0, codecID: 0,
                                         colorMatrix: .bt709, transfer: .sdr, range: .limited)
            let strat = decideRendererStrategy(
                stream: attrs,
                prefersTenBit: _renderer.prefersTenBit,
                display: displayCapability,
                doviEnabled: doviEnabled
            )
            renderConfigLock.withLock { self.rendererStrategy = strat }

            // Stream-aware tone-mapper injection (see `toneMapperProvider`).
            // Main thread, pre-decode-loop: assigning the result — including
            // nil — makes the provider the single decision point for the
            // ASBDL mapper on this stream.
            if let provider = toneMapperProvider,
               let asbdl = _renderer as? ASBDLRenderer {
                asbdl.toneMapper = provider(strat, attrs)
            }
            // Verbose decision log: original container fields → resolved params →
            // final strategy. Makes "why did this stream pick SDR?" answerable
            // from a single log line at open time. See Docs/hdr-rendering.md.
            let codecName = cp.codec_id != AV_CODEC_ID_NONE
                ? String(cString: avcodec_get_name(cp.codec_id)) : "?"
            logger.info("""
            strategy decision: codec=\(codecName, privacy: .public) \(cp.width, privacy: .public)x\(cp.height, privacy: .public) \
            bits_per_raw=\(cp.bits_per_raw_sample, privacy: .public) profile=\(cp.profile, privacy: .public) \
            trc=\(cp.color_trc.rawValue, privacy: .public) matrix=\(cp.color_space.rawValue, privacy: .public) range=\(cp.color_range.rawValue, privacy: .public) \
            → resolved(transfer=\(String(describing: cpParams.transfer), privacy: .public) matrix=\(String(describing: cpParams.matrix), privacy: .public) range=\(String(describing: cpParams.range), privacy: .public)) \
            isHEVC10Bit=\(attrs.isHEVC10Bit, privacy: .public) \
            isDoVi=\(demuxer.isDolbyVision, privacy: .public) profile=\(demuxer.doviProfile, privacy: .public) \
            hasHDR10Plus=\(demuxer.hasHDR10Plus, privacy: .public) \
            sideData=\(demuxer.sideDataTypesDescription, privacy: .public) \
            displayEDR=\(self.displayCapability.supportsEDR, privacy: .public) renderer10bit=\(self._renderer.prefersTenBit, privacy: .public) \
            → \(String(describing: strat), privacy: .public)
            """)
        }

        // Sync the display capability snapshot to the renderer. EDRRenderer
        // reads `targetPeakNits` for its tone-map uniform; MetalRenderer
        // ignores the value (SDR pipeline).
        _renderer.displayCapability = displayCapability

        // Instantiate the video decoder based on the resolved strategy's
        // decoder preference. The previous version hardcoded DoVi → SW here;
        // routing through `RendererStrategy.decoderPreference` keeps the
        // decision in one place (the strategy resolver) so the renderer and
        // decoder can't disagree about which path a stream takes.
        if let vs = demuxer.videoStream {
            let sar = demuxer.sampleAspectRatio
            let preference = rendererStrategy?.decoderPreference ?? .vtHW
            let isDoVi = demuxer.isDolbyVision
            let tVDec = Date()
            switch preference {
            case .ffmpegSW:
                if let dec = FFmpegVideoDecoder(stream: vs, forceSoftware: true, colorParams: colorParams) {
                    videoDecoder = dec
                    codedVideoWidth  = dec.width; codedVideoHeight = dec.height
                    videoWidth  = sar > 1.0 ? Int(Double(dec.width) * sar) : dec.width
                    videoHeight = sar < 1.0 ? Int(Double(dec.height) / sar) : dec.height
                    let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                    logger.info("video: FFmpeg SW \(dec.width)x\(dec.height)\(sarStr) display=\(self.videoWidth)x\(self.videoHeight) (strategy \(String(describing: self.rendererStrategy)))")
                } else if let dec = VTVideoDecoder(stream: vs, prefer10Bit: _renderer.prefersTenBit, colorParams: colorParams) {
                    videoDecoder = dec
                    codedVideoWidth  = dec.width; codedVideoHeight = dec.height
                    videoWidth  = sar > 1.0 ? Int(Double(dec.width) * sar) : dec.width
                    videoHeight = sar < 1.0 ? Int(Double(dec.height) / sar) : dec.height
                    let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                    logger.info("video: FFmpeg SW failed, VT fallback \(dec.width)x\(dec.height)\(sarStr) 10bit=\(dec.is10Bit)\(isDoVi ? " (DoVi as HDR10)" : "")")
                }
            case .ffmpegHW:
                if let dec = FFmpegVideoDecoder(stream: vs, colorParams: colorParams) {
                    videoDecoder = dec
                    codedVideoWidth  = dec.width; codedVideoHeight = dec.height
                    videoWidth  = sar > 1.0 ? Int(Double(dec.width) * sar) : dec.width
                    videoHeight = sar < 1.0 ? Int(Double(dec.height) / sar) : dec.height
                    let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                    logger.info("video: FFmpeg VT \(dec.width)x\(dec.height)\(sarStr) display=\(self.videoWidth)x\(self.videoHeight) hw=\(dec.isHardware)")
                } else if let dec = VTVideoDecoder(stream: vs, prefer10Bit: _renderer.prefersTenBit, colorParams: colorParams) {
                    videoDecoder = dec
                    codedVideoWidth  = dec.width; codedVideoHeight = dec.height
                    videoWidth  = sar > 1.0 ? Int(Double(dec.width) * sar) : dec.width
                    videoHeight = sar < 1.0 ? Int(Double(dec.height) / sar) : dec.height
                    let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                    logger.info("video: FFmpeg HW failed, VT fallback \(dec.width)x\(dec.height)\(sarStr) 10bit=\(dec.is10Bit)")
                }
            case .vtHW:
                if let dec = VTVideoDecoder(stream: vs, prefer10Bit: _renderer.prefersTenBit, colorParams: colorParams) {
                    videoDecoder = dec
                    codedVideoWidth  = dec.width; codedVideoHeight = dec.height
                    videoWidth  = sar > 1.0 ? Int(Double(dec.width) * sar) : dec.width
                    videoHeight = sar < 1.0 ? Int(Double(dec.height) / sar) : dec.height
                    let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                    logger.info("video: VT \(dec.width)x\(dec.height)\(sarStr) display=\(self.videoWidth)x\(self.videoHeight) 10bit=\(dec.is10Bit)\(isDoVi ? " (DoVi as HDR10)" : "")")
                } else if let dec = FFmpegVideoDecoder(stream: vs, colorParams: colorParams) {
                    videoDecoder = dec
                    codedVideoWidth  = dec.width; codedVideoHeight = dec.height
                    videoWidth  = sar > 1.0 ? Int(Double(dec.width) * sar) : dec.width
                    videoHeight = sar < 1.0 ? Int(Double(dec.height) / sar) : dec.height
                    let sarStr = sar != 1.0 ? " sar=\(String(format:"%.3f",sar))" : ""
                    logger.info("video: VT failed, FFmpeg fallback \(dec.width)x\(dec.height)\(sarStr) hw=\(dec.isHardware)")
                }
            }
            logger.info("video decoder init took \(String(format: "%.0f", Date().timeIntervalSince(tVDec) * 1000))ms")
        }

        // Populate state.videoInfo
        if let vs = demuxer.videoStream {
            let cp = vs.pointee.codecpar.pointee
            let codecName: String? = cp.codec_id != AV_CODEC_ID_NONE
                ? String(cString: avcodec_get_name(cp.codec_id))
                : nil
            let isHDR = colorParams.transfer == .pq || colorParams.transfer == .hlg
            state.videoInfo = VideoInfo(
                width: videoWidth,
                height: videoHeight,
                codec: codecName,
                isHDR: isHDR,
                colorMatrix: isHDR ? "\(colorParams.matrix)" : nil,
                transfer: isHDR ? "\(colorParams.transfer)" : nil,
                isDolbyVision: demuxer.isDolbyVision
            )
            if demuxer.isDolbyVision {
                logger.info("Dolby Vision detected")
            }
        }

        // Populate state.audioTracks
        if let ctx = demuxer.formatContext {
            var tracks: [TrackInfo] = []
            let nb = Int(ctx.pointee.nb_streams)
            for i in 0..<nb {
                guard let s = ctx.pointee.streams[i] else { continue }
                let cp = s.pointee.codecpar.pointee
                guard cp.codec_type == AVMEDIA_TYPE_AUDIO else { continue }

                let codecName: String? = cp.codec_id != AV_CODEC_ID_NONE
                    ? String(cString: avcodec_get_name(cp.codec_id))
                    : nil

                var title: String?
                var lang: String?
                if let meta = s.pointee.metadata {
                    if let e = av_dict_get(meta, "title", nil, 0), let v = e.pointee.value {
                        title = String(cString: v)
                    }
                    if let e = av_dict_get(meta, "language", nil, 0), let v = e.pointee.value {
                        lang = String(cString: v)
                    }
                }

                let isDefault = (s.pointee.disposition & Int32(AV_DISPOSITION_DEFAULT)) != 0
                let isAtmos = (s.pointee.index == demuxer.audioStreamIndex)
                    ? demuxer.audioIsAtmos
                    : false

                tracks.append(TrackInfo(
                    id: Int(s.pointee.index),
                    title: title,
                    lang: lang,
                    codec: codecName,
                    isDefault: isDefault,
                    isAtmos: isAtmos
                ))
            }
            state.audioTracks = tracks
            logger.info("audio tracks: \(tracks.count)")
        }

        // Populate state.subtitleTracks
        if let ctx = demuxer.formatContext {
            var subs: [TrackInfo] = []
            let nb = Int(ctx.pointee.nb_streams)
            for i in 0..<nb {
                guard let s = ctx.pointee.streams[i] else { continue }
                let cp = s.pointee.codecpar.pointee
                guard cp.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }

                let codecName: String? = cp.codec_id != AV_CODEC_ID_NONE
                    ? String(cString: avcodec_get_name(cp.codec_id))
                    : nil

                var title: String?
                var lang: String?
                if let meta = s.pointee.metadata {
                    if let e = av_dict_get(meta, "title", nil, 0), let v = e.pointee.value {
                        title = String(cString: v)
                    }
                    if let e = av_dict_get(meta, "language", nil, 0), let v = e.pointee.value {
                        lang = String(cString: v)
                    }
                }

                let isDefault = (s.pointee.disposition & Int32(AV_DISPOSITION_DEFAULT)) != 0
                subs.append(TrackInfo(
                    id: Int(s.pointee.index),
                    title: title,
                    lang: lang,
                    codec: codecName,
                    isDefault: isDefault
                ))
            }
            state.subtitleTracks = subs
            logger.info("subtitle tracks: \(subs.count)")

            // Container chapters (zyno#101): read off the already-open format
            // context — no second probe, no extra I/O. Empty for chapter-less
            // files; the app layer unions this with BDMV/Jellyfin chapters.
            chapters = FFmpegChapterParser.parse(ctx)
            if !chapters.isEmpty {
                logger.info("chapters: \(self.chapters.count)")
            }

            // Auto-select a subtitle stream if the demuxer hasn't already.
            // Without this, applyStreamDiscard() sets AVDISCARD_ALL on every
            // subtitle stream (because subtitleStream == nil), so PGS packets
            // are never read and bitmap subtitles never appear. With a user
            // language preference set (zyno#100), the preference drives the
            // pick (exact > prefix > container default); "off" deliberately
            // selects nothing, leaving every subtitle stream discarded.
            if demuxer.subtitleStreamIndex < 0, !subs.isEmpty {
                let chosen: TrackInfo?
                if let pref = preferredSubtitleLanguage, !pref.isEmpty {
                    if pref.lowercased() == "off" {
                        chosen = nil
                        logger.info("subtitles: language pref off — no embedded subtitle selected")
                    } else {
                        chosen = TrackLanguageMatcher.pickSubtitle(from: subs, preference: pref)
                        if let c = chosen {
                            logger.info("subtitles: language pref '\(pref)' → stream \(c.id) (\(c.lang ?? "?"))")
                        }
                    }
                } else {
                    chosen = subs.first(where: { $0.isDefault }) ?? subs.first
                }
                if let id = chosen?.id {
                    demuxer.selectSubtitleStream(by: id)
                    state.selectedSubtitleTrackId = id
                    logger.info("[sub] auto-selected stream \(id) (\(chosen?.lang ?? "?"))")
                }
            }
        }

        // zyno#171: 备选音轨包缓存(音轨 2…4 条才启用)。
        altAudioCache.removeAll()
        refreshAltAudioStreams(demuxer)

        // Initialize graphic subtitle decoder for PGS/VOBSUB streams, and the
        // libass typeset renderer for ASS/SSA (zyno#158).
        subtitleDecoder = nil
        assRenderer = nil
        if let defaultSubStream = demuxer.subtitleStream {
            let codecId = defaultSubStream.pointee.codecpar.pointee.codec_id
            let vSize = CGSize(width: codedVideoWidth, height: codedVideoHeight)
            if codecId == AV_CODEC_ID_HDMV_PGS_SUBTITLE || codecId == AV_CODEC_ID_DVD_SUBTITLE {
                subtitleDecoder = FFmpegSubtitleDecoder(stream: defaultSubStream, videoSize: vSize)
            } else if codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA {
                let r = Self.makeASSRenderer(stream: defaultSubStream, videoSize: vSize)
                assRenderer = r
                logger.notice("[sub] ASS renderer \(r != nil ? "created" : "unavailable (no extradata)")")
            }
        }

        // Language-preference audio selection (zyno#100): the demuxer opened
        // with the container-default audio stream; if the user prefers a
        // language and a track matches, switch NOW — before the decoder and
        // output are built below — so the whole audio chain follows without a
        // re-open. No match keeps the container default (pickAudio → nil).
        if let pref = preferredAudioLanguage,
           let picked = TrackLanguageMatcher.pickAudio(from: state.audioTracks, preference: pref),
           picked.id != demuxer.audioStreamIndex,
           demuxer.selectAudioStream(by: picked.id) {
            logger.info("audio: language pref '\(pref)' → stream \(picked.id) (\(picked.lang ?? "?"))")
        }

        if let as_ = demuxer.audioStream,
           let dec = FFmpegAudioDecoder(stream: as_, sampleRate: 44100, channels: 2) {
            audioDecoder = dec
            let out = AudioUnitOutput(clock: audioClock, delaySecs: audioDelay)
            audioUnitOutput = out
            isPassthroughActive = false
            logger.info("audio: \(dec.outputSampleRate)Hz \(dec.outputChannels)ch")
            if demuxer.audioStreamIndex >= 0 {
                state.selectedAudioTrackId = Int(demuxer.audioStreamIndex)
            }
        }

        // Forward coded dimensions and SAR to the renderer for correct DAR.
        // Hardware decoders may return alignment-padded CVPixelBuffers;
        // the codec-level pixel dimensions are the ground truth.
        _renderer.configure(
            codedSize: CGSize(width: codedVideoWidth, height: codedVideoHeight),
            sampleAspectRatio: demuxer.sampleAspectRatio)

        wireJitterBuffer()

        // 音频队列必须先于 demux/display 启动建好并暂停。否则 demux 线程把
        // jitterBuffer 翻到 .playing(onStateChange → resume())时,音频队列
        // 尚未创建(start() 未跑)或本次 pause() 晚于那次 resume() 而覆盖了
        // 它 —— 两种情况下 resume() 都丢失,状态不再翻转 → 音频永久暂停,
        // audioClock 永远为 0 → audioClockReady=false → 同步旁路以显示驱动
        // 频率弹帧(macOS 双驱动最高 ~90Hz)≈ 2.4-3.6x 加速,并因排空
        // jitterBuffer 卡死 —— 即"自动播下一集加速/卡住"与偶发默认加速。
        // 主线程在两者之间稍有延迟(如自动播下一集的开场负载)就会把这个
        // 微秒级窗口放大到秒级,竞态几乎必现。
        if let out = audioUnitOutput, let dec = audioDecoder {
            out.start(sampleRate: dec.outputSampleRate, channels: dec.outputChannels)
            // Align the tempo pipeline with the stream format (zyno#99).
            audioTempo.reset(sampleRate: dec.outputSampleRate, channels: dec.outputChannels)
            out.setPlaybackRate(state.rate)
            // Pause immediately — jitterBuffer.onStateChange will resume when
            // enough video is buffered (resumeDuration = 2.0s). Without this,
            // audio runs freely during the initial BUFFERING phase and drifts
            // 500ms–1s ahead of video before the first frame appears.
            out.pause()
        }

        // 打开即恢复播放位置(seekTo)必须在 startDemuxLoop() 之前落地:demux 循环
        // 一起跑就会从偏移 0 开始读包解帧,若 seek 落地滞后(哪怕只是派发到后台
        // 异步执行),循环会抢先把好几帧 0s 附近的画面塞进 jitterBuffer,和目标
        // 位置的帧混流,表现为播放卡死在旧帧、音视频时钟差出几十秒
        // (2026-09-02 用户反馈"播放不出来"实锤)。同步执行不影响体验——
        // demuxer.open() 本身已经是秒级的网络探测延迟,多等这一下无感知。
        if let seekTo { _seek(to: seekTo, synchronousDemuxerSeek: true) }

        startDemuxLoop()
        startDisplayLink()

        // Calibrate audioClock to first decoded frame PTS on the first display
        // tick — same as post-seek calibration. Required for H.264 B-frame streams
        // whose PTS does not start at 0 (priming delay).
        // startDisplayLink above may already be ticking — lock the write.
        displayLoopLock.withLock {
            needsClockCalibration = true
            audioClockReady = false
        }

        state.isPlaying = true
        notifyStateChange()
        let t1 = Date()
        logger.info("_finishOpen done in \(String(format: "%.0f", t1.timeIntervalSince(t0) * 1000))ms")
    }

    private func wireJitterBuffer() {
        jitterBuffer.onStateChange = { [weak self] newState in
            guard let self = self else { return }
            switch newState {
            case .buffering:
                self.audioUnitOutput?.pause()
                self._injectedAudioOutput?.pause()
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.state.isBuffering = true
                    // Drop the tick-gap baseline so the refill-triggered resume
                    // isn't misreported as a main-thread stall by the gap
                    // diagnostic in displayNextFrame().
                    self.lastTickWallTime = nil
                    self.notifyStateChange()
                }
            case .playing:
                self.audioUnitOutput?.resume()
                self._injectedAudioOutput?.resume()
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.state.isBuffering = false
                    self.notifyStateChange()
                }
            }
        }
    }

    // MARK: - Demux loop

    private func startDemuxLoop() {
        demuxStateLock.lock()
        if demuxLoopRunning {
            if let current = demuxer, current as AnyObject === demuxLoopDemuxer as AnyObject {
                // PiP→resume:willResignActive 不 pause(为了让 auto-PiP 有内容
                // 可播),旧循环仍在运行;而 resume() 无条件调用本方法 —— 若再
                // 启动一个循环,两个循环并行读同一 demuxer 竞争包、jitterBuffer
                // 出现双序列 append,视频卡住(append#87→append#1 交错日志)。
                // 复位取消标志,让旧循环继续。
                demuxCancelled = false
                demuxStateLock.unlock()
                logger.info("startDemuxLoop: loop already running (same demuxer), reviving it")
                return
            }
            // stop→play 换了 demuxer:旧循环在下一次迭代看到 demuxer 不一致
            // (或 demuxCancelled)就会退出,这里等它退出再启动新循环(毫秒级)。
            var waitedTicks = 0
            while demuxLoopRunning && waitedTicks < 200 {
                demuxStateLock.unlock()
                Thread.sleep(forTimeInterval: 0.005)
                demuxStateLock.lock()
                waitedTicks += 1
            }
            if demuxLoopRunning {
                // 理论不可达:stop() 已置 demuxCancelled 并 close 旧 demuxer,
                // readPacket 立即失败 → 循环退出。防御性兜底,避免主线程死等。
                logger.warning("startDemuxLoop: old loop did not exit in 1s, forcing")
                demuxLoopRunning = false
                demuxLoopDemuxer = nil
            }
        }
        demuxLoopRunning = true
        demuxLoopDemuxer = demuxer
        demuxCancelled = false
        demuxStateLock.unlock()

        guard let demuxer = self.demuxer else {
            logger.error("startDemuxLoop: demuxer is nil (stop was called?)")
            demuxStateLock.lock()
            demuxLoopRunning = false
            demuxLoopDemuxer = nil
            demuxStateLock.unlock()
            return
        }
        let audioDec = audioDecoder
        let audioOut = audioUnitOutput
        let clock = audioClock
        let jitter = jitterBuffer
        let dLock = demuxLock
        let sLock = seekLock

        DispatchQueue.global().async { [weak self, colorParams] in
            // 任何退出路径(break/return)都清 running 标志,保证 startDemuxLoop()
            // 的防重入判断始终准确。循环内所有 break 出口都发生在 dLock 解锁
            // 之后,这里锁内清理不会死锁。
            defer {
                if let self = self {
                    self.demuxStateLock.lock()
                    // Only clear what this loop registered: startDemuxLoop's forced
                    // path may already have registered a newer loop.
                    if let current = self.demuxLoopDemuxer, current as AnyObject === demuxer as AnyObject {
                        self.demuxLoopRunning = false
                        self.demuxLoopDemuxer = nil
                    }
                    self.demuxStateLock.unlock()
                }
            }
            var ptsValidator = PTSValidator()
            var packetCount: Int32 = 0
            var eofRecoveryDone = false
            // 跟踪 physicalSeekGeneration(而非 seekSerial)——见该属性声明处
            // 注释:reset() 必须跟"demuxer.seek() 真正物理执行"同步,不能跟着
            // seekSerial 抢跑。
            var lastSeenPhysicalGen: Int64 = -1
            // Diagnostic-only: confirms whether jitterBuffer append order is
            // truly monotonic (or regresses/repeats) — see the "mouth keeps
            // repeating" report.
            var diagAppendCount = 0
            var diagLastAppendedPts = -Double.infinity
            var lastThrottleAudioPos: Double = 0

            let frameDuration: Double
            if let vs = demuxer.videoStream {
                let fr = vs.pointee.avg_frame_rate
                frameDuration = fr.num > 0 ? Double(fr.den) / Double(fr.num) : 1.0/25.0
                // VideoJitterBuffer.maxFrameCount 按源帧率换算缓冲上限（见该文件
                // configureFrameRate 的文档注释）——但只有真的调用这个方法才会生效。
                // 这里是唯一一处知道 demuxer 实际帧率的地方，漏接这一行的后果是
                // 120fps 内容仍然卡在 24fps 假设算出的 60 帧(0.5s)上限，表现为
                // "开播→弹一帧→冻结4秒"，跟从没做过这个修复一模一样。
                if fr.num > 0 && fr.den > 0 {
                    let fps = Double(fr.num) / Double(fr.den)
                    jitter.configureFrameRate(fps)
                    // zyno#106: 真实 fps 同时喂给显示链路做刷新率匹配
                    // (24/25/30p → 保守倍频;混帧率内容 fps 变化时热切换)。
                    self?.noteContentFrameRate(fps)
                }
            } else {
                frameDuration = 1.0/25.0
            }
            ptsValidator.frameDuration = frameDuration

            while true {
                guard let self, !self.demuxCancelled else { break }

                dLock.lock()
                if self.demuxCancelled { dLock.unlock(); break }
                // stop→play 换了 demuxer:旧循环捕获的是已 close 的旧实例,
                // 立即退出,由 startDemuxLoop 等待后启动新循环。
                if demuxer as AnyObject !== self.demuxer as AnyObject {
                    dLock.unlock()
                    logger.info("demux loop: demuxer replaced, exiting")
                    break
                }

                let currentSerial = sLock.withLock { self.seekSerial }
                // Under dLock, which the physical seek's landing also holds: a consistent
                // "has the latest seek landed?" for the whole iteration (see SeekFrameGate).
                let landedAtStart = SeekFrameGate.landedAtIterationStart(
                    landedSerial: self.seekLandedSerial, iterationSerial: currentSerial)

                // Reset state when a seek has *physically landed*(demuxer.seek()
                // 真的执行过),不是 seekSerial 一变就 reset——异步 seek 下
                // seekSerial 在网络 I/O 落地前就会抢跑好几次,连续 seek 时尤其
                // 明显,拿它触发 reset 会在抢跑阶段被用掉,轮到真正物理跳变的
                // 那个包反而没有 reset,PTSValidator 把这次真实跳变当异常
                // 处理,进入 blind clock 逐帧爬向新位置(2026-09-03 用户反馈
                // "画面抖动"实锤,见 physicalSeekGeneration 声明处注释)。
                let currentPhysicalGen = self.physicalSeekGeneration
                if currentPhysicalGen != lastSeenPhysicalGen {
                    logger.info("ptsValidator.reset() for physicalSeekGeneration=\(currentPhysicalGen) (was \(lastSeenPhysicalGen))")
                    ptsValidator.reset()
                    lastSeenPhysicalGen = currentPhysicalGen
                }

                guard let result = demuxer.readPacket() else {
                    dLock.unlock()
                    // Real read failure (network blackhole, risk-control
                    // block, gone cloud file) — surface it, never read it
                    // as EOF: the markEOF() tail below would end playback
                    // as a normal "played to end" and the UI would show a
                    // frozen picture with no error. Same message convention
                    // as the open-failure paths: description, not
                    // localizedDescription.
                    if let demuxError = demuxer.lastDemuxError {
                        let msg = "demux I/O error: "
                            + ((demuxError as? CustomStringConvertible)?.description
                               ?? String(describing: demuxError))
                        logger.error("\(msg, privacy: .public)")
                        DispatchQueue.main.async { [weak self] in
                            guard let self, !self.demuxCancelled else { return }
                            self.state.error = msg
                            self.notifyStateChange()
                        }
                        break
                    }
                    if packetCount == 0, !eofRecoveryDone {
                        eofRecoveryDone = true
                        logger.error("immediate EOF, recovering to 0")
                        dLock.lock()
                        _ = demuxer.seek(to: 0)
                        // Disarm any fine-seek discard armed by the seek that just
                        // failed — frames now come from 0, everything left of the
                        // old target must display or the recovery plays as a black
                        // screen up to that target.
                        discardAudioUntilPts = nil
                        discardLock.withLock { self.discardVideoUntilPts = nil }
                        self.videoDecoder?.flush()
                        // Routed through audioDecodeQueue so this can't race a
                        // still-in-flight decode() of an earlier packet on that
                        // queue (see audioDecodeQueue's doc comment).
                        self.audioDecodeQueue.sync { audioDec?.flush() }
                        dLock.unlock()
                        jitter.flush()
                        clock.reset(to: 0, sampleRate: audioDec?.outputSampleRate ?? 44100)
                        audioOut?.stop()
                        if let dec = audioDec {
                            audioOut?.start(sampleRate: dec.outputSampleRate, channels: dec.outputChannels)
                        }
                        continue
                    }
                    logger.info("demux EOF after \(packetCount) packets")
                    // 告知 jitterBuffer 视频流已结束:若剩余帧不足 resumeDuration
                    // (seek 到接近末尾),立即开播渲染,而不是永远停在 buffering
                    // 黑屏(displayNextFrame 的 guard jitterBuffer.state == .playing
                    // 直接 return,零帧显示)。
                    jitter.markEOF()
                    break
                }

                packetCount += 1
                let pktSize = Int(result.packet.pointee.size)
                if pktSize > 0 { throughputLock.withLock { self.totalBytesRead += Int64(pktSize) } }
                let streamIndex = result.streamIndex
                let packet = result.packet
                // Set true by the audio branch when it hands packet ownership
                // to audioDecodeQueue — the tail av_packet_free below must not
                // also free it in that case (audioDecodeQueue frees it once
                // decode actually runs).
                var handedOffPacket = false

                if streamIndex == demuxer.videoStreamIndex {
                    let rawPTS = Self.ptsFromPacket(packet, demuxer: demuxer)
                    // MultiClipDemuxer rebases every packet's PTS onto the
                    // continuous global timeline before handing it out, so the
                    // packet right after a clip boundary carries a known-good
                    // jump — not the kind of >5s anomaly validate() exists to
                    // detect. Write it in as the new trusted baseline directly
                    // instead of sending it through blind-clock detection.
                    let pts: Double
                    if result.didSwitchClip, rawPTS.isFinite {
                        ptsValidator.forceRebase(to: rawPTS)
                        pts = rawPTS
                    } else {
                        pts = ptsValidator.validate(rawPTS)
                        // [diag] count rewritten PTS (blind clock / anomaly path)
                        // — see diagPTSRewriteCount. A rewritten PTS is a
                        // synthesized uniform timestamp, so the frame's true
                        // display time is gone and decoder reorder can no longer
                        // be undone by PTS-sorted insertion (track-switch
                        // 画面来回晃 localization, 2026-10-13).
                        if rawPTS.isFinite, abs(pts - rawPTS) > 0.0005 {
                            displayLoopLock.withLock { self.diagPTSRewriteCount += 1 }
                        }
                    }
                    // Track download progress (highest video PTS read so far)
                    if rawPTS.isFinite && rawPTS > maxDownloadedPts { maxDownloadedPts = rawPTS }
                    if packetCount < 5 || (packetCount % 500 == 0) {
                        logger.debug("pkt#\(packetCount) rawPTS=\(String(format:"%.3f",rawPTS)) pts=\(String(format:"%.3f",pts)) audio=\(String(format:"%.3f",clock.audioTime))")
                    }

                    // VT→SW fallback: when VideoToolbox repeatedly fails to decode
                    // (e.g. 4K@120fps exceeds HW limits), hot-swap to FFmpeg software
                    // decoder without restarting the demux loop.
                    if let vt = self.videoDecoder as? VTVideoDecoder, vt.needsSoftwareFallback,
                       let vs = demuxer.videoStream,
                       let sw = FFmpegVideoDecoder(stream: vs, forceSoftware: true, colorParams: colorParams) {
                        logger.notice("VT→SW fallback: \(sw.width)x\(sw.height) — HW decoder failed, using FFmpeg SW")
                        self.videoDecoder = sw
                    }

                    // Always decode — VTVideoDecoder needs every packet for its RPS.
                    let decoded = self.videoDecoder?.decode(packet: packet)
                    dLock.unlock()

                    if let frame = decoded,
                       SeekFrameGate.accepts(landedAtIterationStart: landedAtStart,
                                             iterationSerial: currentSerial,
                                             latestSerial: sLock.withLock({ self.seekSerial })) {
                        // With B-frames, the pixel buffer returned by THIS
                        // decode() call can correspond to an earlier-submitted
                        // packet (decoder-internal reorder) — pairing it with
                        // this packet's own `pts` mislabels it by a few frame
                        // durations. When the decoder reports its own
                        // display-order pts (currently: FFmpegVideoDecoder SW
                        // fallback path; VTVideoDecoder returns nil here and
                        // this is a no-op), correct `pts` by the measured
                        // delta rather than recomputing it from scratch, so
                        // clip-rebase/anomaly-detection state from the
                        // rawPTS→pts pipeline above still applies.
                        // Sanity-bound the correction: a genuine reorder delay is at
                        // most a handful of frame durations (well under 1s for any
                        // real GOP structure) and the returned frame is always from
                        // the SAME position or earlier than the packet just sent
                        // (never later). Outside that — e.g. the decoder's first
                        // few outputs right after a mid-stream codec swap, before
                        // its internal reorder state has a clean run to interpolate
                        // from — trust the packet-based pts unmodified rather than
                        // risk a wild correction that strands the sync gate (a
                        // frame miscomputed as far in the future never becomes
                        // "not ahead of audio" and permanently stalls playback).
                        let framePts: Double
                        let diagBounded: Bool
                        if let decoderPts = frame.pts, decoderPts.isFinite,
                           decoderPts <= rawPTS, rawPTS - decoderPts < 1.0 {
                            framePts = pts - (rawPTS - decoderPts)
                            diagBounded = true
                        } else {
                            framePts = pts
                            diagBounded = false
                        }
                        diagAppendCount += 1
                        if diagAppendCount <= 200, Self.diagLoggingEnabled {
                            let regressed = framePts < diagLastAppendedPts
                            logger.info("[diag] append#\(diagAppendCount, privacy: .public) framePts=\(String(format:"%.3f",framePts), privacy: .public) decoderPts=\(frame.pts.map { String(format:"%.3f",$0) } ?? "nil", privacy: .public) bounded=\(diagBounded, privacy: .public) rawPTS=\(String(format:"%.3f",rawPTS), privacy: .public) REGRESSED=\(regressed, privacy: .public)")
                        }
                        diagLastAppendedPts = framePts
                        jitter.append(.init(pixelBuffer: frame.pixelBuffer, pts: framePts, metadata: frame.metadata))
                        displayLoopLock.withLock { self.diagAppendsSinceLog += 1 }
                        let ptsCopy = framePts
                        DispatchQueue.main.async { [weak self] in
                            guard let self = self else { return }
                            let d = Duration.milliseconds(Int64(ptsCopy * 1000))
                            if d > self.state.duration { self.state.duration = d }
                        }
                    }
                    // Throttle: keep video demux within 2s of the audio clock.
                    // HW decode runs ~4× real-time; without throttling the demux
                    // would advance 30+ seconds ahead of audio and the jitter
                    // buffer would fill with far-future frames —
                    // needsClockCalibration resets audioClock to that far-future
                    // PTS, causing A/V desync / black screen. (The demux
                    // free-running on start — audio clock still 0, this guard
                    // inactive — is also what arms the frame-count back-pressure
                    // below.)
                    //
                    // We sleep AT MOST 50ms per video packet so the outer loop
                    // continues reading audio/subtitle packets in between, keeping
                    // the AudioUnit queue fed and subtitle cues pre-read.
                    //
                    // CRITICAL: skip the throttle when audioClock has not advanced
                    // since the last iteration (AudioQueue underrun). If we sleep
                    // while audio is stalled, the demux loop never reads audio
                    // packets (they're next in the TS interleave), the AudioQueue
                    // stays empty, and audioClock never recovers — a deadlock.
                    // Observed on 4K HEVC UHD remuxes where VT decode is slow
                    // enough that the 50ms throttle × 24fps = 1.2s/s of sleep
                    // starves the audio path entirely.
                    let audioPos: Double
                    if _injectedAudioOutput != nil && isPassthroughActive,
                       let pt = _injectedAudioOutput?.playbackTime {
                        // Passthrough: the PCM AudioClock never runs; pace the
                        // read-ahead against the passthrough renderer's clock
                        // instead, or the demux loop would enqueue the entire
                        // file's audio into the renderer at decode speed.
                        // zyno#127: apply the full signed delay as a clock
                        // offset (read-ahead tracks the picture, which runs
                        // d ahead for d>0 and |d| behind for d<0), same
                        // semantics as the PCM path's audioTime.
                        audioPos = pt + audioClock.fullDelay
                        passthroughWallClockAnchor = nil
                    } else if _injectedAudioOutput != nil && isPassthroughActive {
                        // Passthrough clock unavailable (backend without a
                        // device timeline, or not yet anchored). Pace against
                        // WALL TIME anchored to the first finite read-ahead
                        // frontier: without this the `audioPos >
                        // lastThrottleAudioPos` guard below reads 0 > 0 forever
                        // and the demux loop free-runs at decode speed — the
                        // enqueue frontier outruns playback by minutes and the
                        // jitter buffer overflow-evicts frames (2026-09-20
                        // real-hardware DP-monitor regression: frozen picture,
                        // no audio, ~20x drift).
                        if let anchor = passthroughWallClockAnchor {
                            audioPos = anchor.pts + CACurrentMediaTime() - anchor.wall
                                + audioClock.fullDelay
                        } else if pts.isFinite {
                            passthroughWallClockAnchor = (CACurrentMediaTime(), pts)
                            audioPos = pts
                        } else {
                            audioPos = 0
                        }
                    } else {
                        audioPos = clock.audioTime
                    }
                    if pts.isFinite && pts > audioPos + 2.0,
                       audioPos > lastThrottleAudioPos {
                        Thread.sleep(forTimeInterval: min(pts - audioPos - 2.0, 0.050))
                    }
                    lastThrottleAudioPos = audioPos

                    // Byte back-pressure. The time throttle above is inactive until the
                    // audio clock has advanced, so right after start (audio waits for the
                    // buffer to fill) decoding ran at full speed. With 4K 10-bit HDR
                    // frames (~18.5 MB each) that put >2 GB of decoded frames in memory
                    // within a second and iOS killed the app (2026-09-30). Hold off
                    // while the frame budget is used up; short sleep only, so the loop
                    // keeps reading the audio packets interleaved with the video.
                    if jitter.isFull {
                        Thread.sleep(forTimeInterval: 0.010)
                    }

                    // Frame-count back-pressure (2026-10-12 晃动 fix). The frame
                    // cap must hold the demux loop back exactly like the byte
                    // budget above — and the buffer must never have to drop
                    // frames to respect it. It used to: append() evicted the
                    // OLDEST frame on overflow, i.e. the display loop's next
                    // frame, so a full buffer advanced its front ahead of the
                    // audio clock at supply rate and the freeze-ahead guard
                    // held the picture until audio caught up (device: 18-24fps
                    // vs 23.976fps content). VideoJitterBuffer.append now
                    // refuses the incoming frame and counts it
                    // (droppedIncomingCount); this sleep keeps that refusal
                    // rare by pacing the supply to the drain rate once the
                    // buffer is full. Short sleep only, so audio packets
                    // interleaved after this one are still read.
                    if jitter.count >= jitter.maxFrameCount {
                        Thread.sleep(forTimeInterval: 0.010)
                    }

                } else if streamIndex == demuxer.audioStreamIndex {
                    let codecName = String(cString: avcodec_get_name(
                        demuxer.audioStream!.pointee.codecpar.pointee.codec_id))
                    let usePassthrough: Bool
                    if let injected = _injectedAudioOutput,
                       injected.supportsPassthrough,
                       demuxer.isPassthroughCodec,
                       abs(state.rate - 1.0) < 0.001 {
                        // Passthrough (AC3, E-AC3, DTS, TrueHD) requires a
                        // digital audio output (HDMI ARC / SPDIF). The
                        // AudioOutputBackend.supportsPassthrough property is
                        // responsible for reporting whether the current output
                        // device can actually decode compressed audio — if not,
                        // it returns false and we fall through to PCM decode.
                        // Playback rate ≠ 1 also forces PCM: a compressed
                        // bitstream cannot be time-stretched, so tempo needs
                        // the decoded path (zyno#99).
                        usePassthrough = true
                    } else {
                        usePassthrough = false
                    }

                    // zyno#142: drop audio packets inside the discard window
                    // without decoding — audioClock is anchored at the seek
                    // target and must stay there until the first surviving
                    // sample, or audible content would start at the GOP-boundary
                    // landing (the displaced timeline fine-seek removes).
                    // Comparison is `<`, so the first packet at/after the
                    // target passes and the flag simply goes inert.
                    if let until = discardAudioUntilPts,
                       NativeBackend.ptsFromPacket(packet, demuxer: demuxer) < until {
                        dLock.unlock()  // falls through to the tail av_packet_free
                    } else if usePassthrough {
                        isPassthroughActive = true
                        // Passthrough path: route compressed packets directly to
                        // AVSampleBufferAudioRenderer (PRO backend).
                        let pkt = packet.pointee
                        let size = Int(pkt.size)
                        let pts = NativeBackend.ptsFromPacket(packet, demuxer: demuxer)
                        var data = Data(count: size)
                        if size > 0, let buf = pkt.data {
                            data.withUnsafeMutableBytes { raw in
                                raw.baseAddress!.copyMemory(from: buf, byteCount: size)
                            }
                        }
                        dLock.unlock()
                        _injectedAudioOutput?.outputCompressed(data, pts: pts, codec: codecName)
                    } else {
                        // PCM path: decode with FFmpeg and enqueue to AudioUnit,
                        // off the demux/video thread (see audioDecodeQueue's doc
                        // comment). Capture decoder/output now — selectAudioTrack
                        // may replace self.audioDecoder/audioUnitOutput before
                        // this actually runs on the queue; currentDec/currentOut
                        // stay bound to whatever was current when this packet was
                        // read, matching the previous synchronous behavior.
                        let currentDec = self.audioDecoder
                        let currentOut = self.audioUnitOutput
                        dLock.unlock()
                        handedOffPacket = true
                        let trackContent = AudioUnitOutput.tracksPlayedContent
                        let packetPts = trackContent ? Self.ptsFromPacket(packet, demuxer: demuxer) : .nan
                        let outputRate = Double(currentDec?.outputSampleRate ?? 48000)
                        audioDecodeQueue.async {
                            self.decodeAndEnqueueAudio(packet: packet, decoder: currentDec, output: currentOut,
                                                       trackContent: trackContent, packetPts: packetPts,
                                                       outputRate: outputRate)
                        }
                    }
                } else if streamIndex == demuxer.subtitleStreamIndex,
                          demuxer.subtitleStreamIndex >= 0 {
                    let stream = demuxer.subtitleStream
                    let codecId = stream?.pointee.codecpar.pointee.codec_id
                    let codecName = codecId.map { String(cString: avcodec_get_name($0)) } ?? "nil"
                    if codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA {
                        // Typeset path (zyno#158): feed the raw Matroska event
                        // to libass.  Falls back to the legacy tag-stripped
                        // text cue when the stream has no extradata (renderer
                        // never built) or the packet carries no usable PTS.
                        let r = self.assRenderer
                        let tb = stream?.pointee.time_base ?? AVRational(num: 0, den: 0)
                        let tbSecs = tb.den > 0 ? Double(tb.num) / Double(tb.den) : 0
                        let nopts = Int64(bitPattern: 0x8000000000000000)
                        let ptsValid = r != nil && tbSecs > 0
                            && packet.pointee.pts != nopts
                            && packet.pointee.size > 0
                            && packet.pointee.data != nil
                        let pts = Double(packet.pointee.pts) * tbSecs
                        let dur = packet.pointee.duration > 0 ? Double(packet.pointee.duration) * tbSecs : 5.0
                        dLock.unlock()
                        if ptsValid {
                            let data = Data(bytes: packet.pointee.data!, count: Int(packet.pointee.size))
                            r?.processPacket(data, ptsSecs: pts, durationSecs: dur)
                            logger.debug("[sub] ASS packet → libass: pts=\(String(format:"%.2f",pts)) dur=\(String(format:"%.2f",dur))")
                        } else if let cue = Self.parseASSCue(packet: packet, stream: stream) {
                            self.subtitleLock.withLock { self.subtitleCues.append(cue) }
                            logger.debug("[sub] ASS cue appended (text fallback): pts=\(String(format:"%.2f",cue.startPts))-\(String(format:"%.2f",cue.endPts)) text=\(cue.text.prefix(30))")
                        }
                    } else if codecId == AV_CODEC_ID_SUBRIP || codecId == AV_CODEC_ID_TEXT {
                        // AV_CODEC_ID_TEXT carries raw UTF-8 with no HTML tags; routing here is safe
                        // since the HTML-strip regex is a no-op when no tags are present.
                        let cue = Self.parseSRTCue(packet: packet, stream: stream)
                        dLock.unlock()
                        if let cue {
                            self.subtitleLock.withLock { self.subtitleCues.append(cue) }
                            logger.debug("[sub] SRT cue appended: pts=\(String(format:"%.2f",cue.startPts))-\(String(format:"%.2f",cue.endPts))")
                        } else {
                            logger.warning("[sub] SRT parseSRTCue returned nil")
                        }
                    } else if codecId == AV_CODEC_ID_HDMV_PGS_SUBTITLE || codecId == AV_CODEC_ID_DVD_SUBTITLE {
                        let dec = self.subtitleDecoder
                        let audioPos = clock.audioTime
                        dLock.unlock()
                        if let cue = dec?.decode(packet: packet) {
                            // If the cue's startPts is already in the past (demux
                            // read the subtitle packet late due to video throttle),
                            // adjust startPts to current audioTime so the subtitle
                            // displays immediately instead of being skipped.
                            let adjustedStart = cue.startPts < audioPos ? audioPos : cue.startPts
                            self.subtitleImageLock.withLock {
                                // Truncate existing cues' endPts to the new cue's
                                // startPts so the old subtitle stops displaying
                                // when the new one starts. Without this, the old
                                // cue (with a long endPts from PGS UINT32_MAX
                                // fallback) would shadow the new cue —
                                // first(where:) matches the old one first since
                                // its endPts hasn't been reached yet.
                                let cutoff = adjustedStart
                                for i in self.subtitleImageCues.indices {
                                    if self.subtitleImageCues[i].endPts > cutoff {
                                        self.subtitleImageCues[i] = SubtitleImageCue(
                                            startPts: self.subtitleImageCues[i].startPts,
                                            endPts: cutoff,
                                            image: self.subtitleImageCues[i].image,
                                            rect: self.subtitleImageCues[i].rect)
                                    }
                                }
                                self.subtitleImageCues.append(
                                    SubtitleImageCue(startPts: adjustedStart, endPts: cue.endPts,
                                                     image: cue.image, rect: cue.rect)
                                )
                            }
                            logger.debug("[sub] PGS cue appended: pts=\(String(format:"%.2f",adjustedStart))-\(String(format:"%.2f",cue.endPts))")
                        } else if dec == nil {
                            logger.warning("[sub] PGS packet received but subtitleDecoder is nil")
                        }
                    } else if codecId == AV_CODEC_ID_WEBVTT {
                        let cue = Self.parseWebVTTCue(packet: packet, stream: stream)
                        dLock.unlock()
                        if let cue {
                            self.subtitleLock.withLock { self.subtitleCues.append(cue) }
                            logger.debug("[sub] WebVTT cue appended: pts=\(String(format:"%.2f",cue.startPts))-\(String(format:"%.2f",cue.endPts))")
                        } else {
                            logger.warning("[sub] WebVTT parseWebVTTCue returned nil")
                        }
                    } else if codecId == AV_CODEC_ID_MOV_TEXT {
                        let cue = Self.parseMOVTextCue(packet: packet, stream: stream)
                        dLock.unlock()
                        if let cue {
                            self.subtitleLock.withLock { self.subtitleCues.append(cue) }
                            logger.debug("[sub] MOVText cue appended: pts=\(String(format:"%.2f",cue.startPts))-\(String(format:"%.2f",cue.endPts))")
                        } else {
                            logger.warning("[sub] MOVText parseMOVTextCue returned nil")
                        }
                    } else {
                        logger.warning("[sub] unsupported subtitle codec=\(codecName) streamIdx=\(streamIndex)")
                        dLock.unlock()
                    }
                } else if altAudioStreams.contains(streamIndex) {
                    // zyno#171: 备选音轨——克隆进缓存(demuxLock 仍持有),供切轨免 seek。
                    let pts = Self.ptsFromPacket(packet, demuxer: demuxer)
                    if pts.isFinite, let clone = av_packet_clone(packet) {
                        altAudioCache.append(stream: streamIndex, pts: pts, payload: clone)
                    }
                    dLock.unlock()
                } else {
                    dLock.unlock()
                }

                if !handedOffPacket {
                    var p: UnsafeMutablePointer<AVPacket>? = packet
                    av_packet_free(&p)
                }
            }
        }
    }

    private nonisolated static func ptsFromPacket(_ packet: UnsafeMutablePointer<AVPacket>,
                                                   demuxer: any PacketDemuxing) -> Double {
        guard let vs = demuxer.videoStream else { return .nan }
        let tb = vs.pointee.time_base
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard tb.den > 0, packet.pointee.pts != nopts else { return .nan }
        let pts = Double(packet.pointee.pts) * Double(tb.num) / Double(tb.den)
        // Subtract the stream's start_time so video PTS is relative to t=0.
        // HEVC/MP4 often has a non-zero video start_time (e.g. 4096 ticks at 90000 Hz ≈ 46ms)
        // while the audio stream starts at 0, causing persistent audio-ahead if uncorrected.
        if vs.pointee.start_time != nopts {
            let startOffset = Double(vs.pointee.start_time) * Double(tb.num) / Double(tb.den)
            return pts - startOffset
        }
        return pts
    }

    /// Parse an ASS/SSA subtitle packet from MKV into a SubtitleCue.
    ///
    /// MKV stores each ASS dialogue line as a raw packet with this field layout:
    ///   ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    /// The Text field (index 8) may contain ASS override tags ({...}) and hardcoded
    /// line-break sequences (\N / \n). We strip tags and convert breaks to newlines.
    /// Timing comes from packet.pts/duration scaled by the subtitle stream timebase.
    /// Builds a libass renderer for an ASS/SSA subtitle stream.  Nil when the
    /// stream carries no extradata (bare packet streams) — callers then fall
    /// back to the legacy text-cue path.  startOffsetSecs mirrors
    /// FFmpegSubtitleDecoder's start_time normalization.
    private nonisolated static func makeASSRenderer(
        stream: UnsafeMutablePointer<AVStream>, videoSize: CGSize) -> ASSRenderer? {
        guard let par = stream.pointee.codecpar else { return nil }
        guard let ex = par.pointee.extradata, par.pointee.extradata_size > 0 else { return nil }
        let exData = Data(bytes: ex, count: Int(par.pointee.extradata_size))
        let tb = stream.pointee.time_base
        let nopts = Int64(bitPattern: 0x8000000000000000)
        let offset: Double
        if stream.pointee.start_time != nopts, tb.den > 0 {
            offset = Double(stream.pointee.start_time) * Double(tb.num) / Double(tb.den)
        } else {
            offset = 0
        }
        return ASSRenderer(extradata: exData, videoSize: videoSize, startOffsetSecs: offset)
    }

    private nonisolated static func parseASSCue(
        packet: UnsafeMutablePointer<AVPacket>,
        stream: UnsafeMutablePointer<AVStream>?
    ) -> SubtitleCue? {
        guard let stream,
              packet.pointee.size > 0,
              let rawPtr = packet.pointee.data else { return nil }

        let codecId = stream.pointee.codecpar.pointee.codec_id
        guard codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA else { return nil }

        guard let raw = String(bytes: UnsafeBufferPointer(start: rawPtr,
                                                           count: Int(packet.pointee.size)),
                               encoding: .utf8) else { return nil }

        // Split on the first 8 commas only; Text (field 8) may itself contain commas.
        let parts = raw.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        guard parts.count >= 9 else { return nil }

        var text = String(parts[8]).trimmingCharacters(in: .newlines)
        // Strip ASS override tags: {\an8}, {\b1}, {\1c&Hffffff&}, etc.
        text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        // Hardcoded line breaks
        text = text.replacingOccurrences(of: "\\N", with: "\n")
        text = text.replacingOccurrences(of: "\\n", with: "\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let tb = stream.pointee.time_base
        guard tb.den > 0 else { return nil }
        let tbSecs = Double(tb.num) / Double(tb.den)
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard packet.pointee.pts != nopts else { return nil }

        let startPts = Double(packet.pointee.pts) * tbSecs
        let dur = packet.pointee.duration > 0
            ? Double(packet.pointee.duration) * tbSecs
            : 5.0
        return SubtitleCue(startPts: startPts, endPts: startPts + dur, text: text)
    }

    /// Parse a SubRip (SRT) subtitle packet from an MKV container.
    /// MKV stores SRT as raw text in packet data with timing from PTS/duration.
    /// Strips HTML-like tags (<i>, <b>, <font ...>) commonly found in SRT files.
    private nonisolated static func parseSRTCue(
        packet: UnsafeMutablePointer<AVPacket>,
        stream: UnsafeMutablePointer<AVStream>?
    ) -> SubtitleCue? {
        guard let stream,
              packet.pointee.size > 0,
              let rawPtr = packet.pointee.data else { return nil }

        let codecId = stream.pointee.codecpar.pointee.codec_id
        guard codecId == AV_CODEC_ID_SUBRIP || codecId == AV_CODEC_ID_TEXT else { return nil }

        guard var text = String(bytes: UnsafeBufferPointer(start: rawPtr,
                                                            count: Int(packet.pointee.size)),
                                encoding: .utf8) else { return nil }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let tb = stream.pointee.time_base
        guard tb.den > 0 else { return nil }
        let tbSecs = Double(tb.num) / Double(tb.den)
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard packet.pointee.pts != nopts else { return nil }

        let startPts = Double(packet.pointee.pts) * tbSecs
        let dur = packet.pointee.duration > 0
            ? Double(packet.pointee.duration) * tbSecs
            : 5.0
        return SubtitleCue(startPts: startPts, endPts: startPts + dur, text: text)
    }

    /// Parse a WebVTT subtitle packet (AV_CODEC_ID_WEBVTT) from an MKV container.
    /// The cue body may contain WebVTT inline tags (<b>, <i>, <c.class>, etc.); we strip them.
    private nonisolated static func parseWebVTTCue(
        packet: UnsafeMutablePointer<AVPacket>,
        stream: UnsafeMutablePointer<AVStream>?
    ) -> SubtitleCue? {
        guard let stream,
              packet.pointee.size > 0,
              let rawPtr = packet.pointee.data else { return nil }

        guard var text = String(bytes: UnsafeBufferPointer(start: rawPtr,
                                                            count: Int(packet.pointee.size)),
                                encoding: .utf8) else { return nil }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let tb = stream.pointee.time_base
        guard tb.den > 0 else { return nil }
        let tbSecs = Double(tb.num) / Double(tb.den)
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard packet.pointee.pts != nopts else { return nil }

        let startPts = Double(packet.pointee.pts) * tbSecs
        let dur = packet.pointee.duration > 0
            ? Double(packet.pointee.duration) * tbSecs
            : 5.0
        return SubtitleCue(startPts: startPts, endPts: startPts + dur, text: text)
    }

    /// Parse a QuickTime/MP4 timed-text packet (AV_CODEC_ID_MOV_TEXT).
    /// Packet layout: 2-byte big-endian text length, then UTF-8 text, then optional style boxes.
    private nonisolated static func parseMOVTextCue(
        packet: UnsafeMutablePointer<AVPacket>,
        stream: UnsafeMutablePointer<AVStream>?
    ) -> SubtitleCue? {
        guard let stream,
              packet.pointee.size > 2,
              let rawPtr = packet.pointee.data else { return nil }

        let textLen = Int(rawPtr[0]) << 8 | Int(rawPtr[1])
        guard textLen > 0, textLen <= packet.pointee.size - 2 else { return nil }

        guard var text = String(bytes: UnsafeBufferPointer(start: rawPtr + 2,
                                                            count: textLen),
                                encoding: .utf8) else { return nil }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let tb = stream.pointee.time_base
        guard tb.den > 0 else { return nil }
        let tbSecs = Double(tb.num) / Double(tb.den)
        let nopts = Int64(bitPattern: 0x8000000000000000)
        guard packet.pointee.pts != nopts else { return nil }

        let startPts = Double(packet.pointee.pts) * tbSecs
        let dur = packet.pointee.duration > 0
            ? Double(packet.pointee.duration) * tbSecs
            : 5.0
        return SubtitleCue(startPts: startPts, endPts: startPts + dur, text: text)
    }

    // MARK: - Display (display-link thread, P2)

    /// P2: video presentation no longer waits for the main thread. This runs
    /// on the CVDisplayLink callback thread (macOS), the fallback timer's
    /// background queue (macOS), or the CADisplayLink run-loop thread
    /// (iOS/tvOS). A busy main thread (SwiftUI, navigation, scans) therefore
    /// cannot delay or drop ticks anymore. Everything MainActor-isolated is
    /// either behind a lock (displayLoopLock / renderConfigLock / the sync
    /// modules' own locks) or applied via `applyDisplayUpdate` on the main
    /// actor — PlayerState feeds SwiftUI through Player, so its writes must
    /// stay main-thread.
    fileprivate nonisolated func displayNextFrame() {
        guard renderGate.try() else { return }
        defer { renderGate.unlock() }

        let now = CACurrentMediaTime()
        let bufferPlaying = jitterBuffer.state == .playing

        // Diagnostic: ticks fire on the display thread. An outsized tick-to-tick
        // gap while jitterBuffer has frames ready means the *display path* was
        // stalled — renderer encode cost, an oversubscribed core, or (iOS) a
        // background run-loop competing for the display thread — no longer the
        // main thread, which since P2 cannot affect presentation at all.
        displayLoopLock.lock()
        if let last = lastTickWallTime {
            let gap = now - last
            if gap > tickGapWarnThreshold && bufferPlaying {
                logger.warning("display tick gap \(Int(gap * 1000))ms (display thread stall?)")
            }
        } else if !firstTickLogged {
            // First-ever tick: no prior baseline to diff against, so the check
            // above is structurally blind to this one. Log it explicitly —
            // this is the only way to tell whether a "gap" reported once
            // jitterBuffer flips to .playing was actually one late tick, or
            // whether the display link genuinely never fired until now.
            if let linkStart = displayLinkStartWallTime {
                firstTickLogged = true
                displayLoopLock.unlock()
                logger.info("first display tick \(Int((now - linkStart) * 1000))ms after startDisplayLink()")
                displayLoopLock.lock()
            }
        }
        lastTickWallTime = now
        ticksSinceLastLog += 1
        displayLoopLock.unlock()

        // Calibrate audioClock to the actual first decoded frame PTS after seek.
        // seek() resets audioClock to the target position, but FFmpeg seeks to the
        // nearest prior I-frame, so the first decodable frame's PTS < seek target.
        // Without this, PacketDropPolicy sees "video behind audio" and drops all
        // non-keyframes up to the next I-frame, causing a 6+ second overshoot.
        //
        // IMPORTANT: calibrate at most once.  Repeatedly calling calibrate() on
        // every tick causes a primer-debt death loop when seeking to ~0: each
        // calibrate re-subtracts _primerPendingSamples from the target, wiping out
        // the progress made by primer callbacks that fired between ticks.  The
        // audioClock never advances past 0, and displayNextFrame's skip-behind
        // guard drops all frames → playback stalls permanently.
        // AudioQueueStop/Start can fire async callbacks that advance the clock
        // *after* our reset; by calibrating exactly once (not clearing the flag
        // until first render), we tolerate that race without the death loop.
        // Only apply the small-rounding correction this was designed for.
        // A byte-domain seek (FFmpegDemuxer.seekByByteOffset, used for raw
        // indexless MPEG-TS) has no keyframe awareness and can land tens
        // of seconds from the target on VBR content. Blindly relabeling
        // audioClock to match a wildly-displaced video PTS doesn't fix
        // that — it hides it: the audio hardware keeps playing real
        // content from near the seek target while the clock claims to be
        // wherever video landed, and the gap never closes (observed: a
        // persistent, non-recovering audio-behind-video desync). For a
        // large gap, skip calibration and let the freeze-ahead guard hold
        // video until the real audioClock catches up instead — a one-time
        // stall, but it converges on what's actually audible.
        // zyno#142: drain the discard window BEFORE the calibration block
        // peeks. Frames left of the target are already decoded — pop them
        // without displaying. While the discard is active this tick does
        // nothing else: the calibration below peeking a GOP-boundary frame
        // would re-anchor audioClock at the landing (the ±2s displacement this
        // stage exists to remove), and the pre-clock bypass would display
        // those frames. Once the queue front reaches the target the flag
        // clears, calibration sees a ≈0 gap (no-op), and the normal path
        // takes over. The audio side drops packets in the demux loop
        // (discardAudioUntilPts), so audioClock — anchored at the target by
        // the seek reset — stays put until the first surviving sample lands.
        while true {
            let until = discardLock.withLock { discardVideoUntilPts }
            guard let until else { break }
            if let front = jitterBuffer.peek(at: 0), front.pts < until {
                jitterBuffer.pop()
                continue
            }
            if jitterBuffer.peek(at: 0) != nil {
                discardLock.withLock { discardVideoUntilPts = nil }
                logger.info("fine-seek: discard window drained, first frame at target")
            }
            break
        }
        if discardLock.withLock({ discardVideoUntilPts }) != nil { return }

        let (needsCalibration, forceCalibration) = displayLoopLock.withLock {
            (needsClockCalibration, forceClockCalibration)
        }
        if needsCalibration, let firstFrame = jitterBuffer.peek(at: 0) {
            if forceCalibration
                || abs(firstFrame.pts - audioClock.audioTime) < maxCalibrationGap {
                audioClock.calibrate(to: firstFrame.pts, sampleRate: audioDecoder?.outputSampleRate ?? 44100)
            }
            displayLoopLock.withLock {
                needsClockCalibration = false
                forceClockCalibration = false
            }
        }

        // In passthrough mode AudioUnitOutput never runs so audioClock stays at 0.
        // Use the passthrough backend's own playback clock as the master clock.
        // The previous fallback here — the jitter buffer's next-frame PTS — was
        // self-referential (the paced quantity used as its own reference, no
        // feedback), so with the dual display drivers video free-wheeled at
        // decode speed: MKV/DTS sources played at ~2-3x (2026-09 bug report).
        // On iOS/tvOS passthrough is disabled (PCM decode), so audioClock is
        // driven by AudioUnitOutput even when PassthroughOutput is injected.
        let audioTime: Double
        if _injectedAudioOutput != nil && isPassthroughActive,
           let pt = _injectedAudioOutput?.playbackTime, pt.isFinite, pt >= 0 {
            // zyno#127: the renderer's timebase is anchored to packet PTS (=
            // what is audible), so the WHOLE signed delay lives in the master
            // clock: sync holds the picture d ahead of the sound for d>0
            // (audible lag) and |d| behind for d<0 (sound leads) — symmetric,
            // and identical to the PCM path's negative half. No PRO-side
            // change: PassthroughOutput's playbackTime stays a pure timebase
            // read, so the offset survives output/track rebuilds for free
            // (it lives in audioClock, which outlives them).
            audioTime = pt + audioClock.fullDelay
        } else {
            audioTime = audioClock.audioTime
        }
        let serial = seekLock.withLock { seekSerial }
        let playbackRate = displayLoopLock.withLock { displayRate }

        // --- Freeze-ahead / Skip-behind (commercial player A/V sync) ---
        // After the first post-seek frame has been displayed, guard against large
        // desync without changing playback speed.  Video ahead of audio: freeze
        // current frame until audio catches up.  Video behind audio: silently pop
        // stale frames.
        //
        // For high-source-fps content (120fps) on a 60Hz display, 2+ source frames
        // age per display tick.  A single pop would fall further behind each cycle
        // until almost every frame triggers the guard → the user sees a frozen image.
        // Draining ALL stale frames in one pass keeps video locked to audio regardless
        // of the source→display ratio.
        let (stillNeedsCal, clockReady) = displayLoopLock.withLock {
            (needsClockCalibration, audioClockReady)
        }
        // Audio stream finished and the output fully drained (PCM path only —
        // the passthrough renderer's pending state is not observable here).
        // Nothing advances the clock anymore: sync's reference is dead, so the
        // tail must free-run instead of freezing (see both uses below).
        let audioEnded = !isPassthroughActive && jitterBuffer.atEOF
            && !(audioUnitOutput?.hasPendingOutput ?? false)
        if syncController.hasDisplayedFrame, !stillNeedsCal, clockReady {
            // Guard window = compensation + 2 frames, scaled by max(1, rate)
            // — see SyncController.guardWindow. The old fixed 60ms sat 10ms
            // above the steady-state transient (comp 50ms + one frame), so
            // normal pacing grazed the freeze threshold and any supply hiccup
            // froze the picture: device-measured 18-24fps against 23.976fps
            // content (2026-10-12 晃动). The guard is a safety net; pacing
            // belongs to SyncController.
            let guardWindow = syncController.guardWindow(rate: playbackRate)
            // Drain frames significantly behind audio
            while let lagging = jitterBuffer.peek(at: 0), lagging.pts < audioTime - guardWindow {
                jitterBuffer.pop()
                displayLoopLock.withLock {
                    tickDrainLag += 1
                    drainDepthStats.record(audioTime - lagging.pts)
                }
            }
            // Freeze-ahead: if the front frame is ahead of audio, stall —
            // unless the audio has ended and drained (zyno#104 d<0 tail; also
            // the pre-existing short-audio-file edge): freezing would hold the
            // last frames forever and keep position short of the real end, so
            // audioEnded falls through to the source-paced free-run below.
            if let ahead = jitterBuffer.peek(at: 0), ahead.pts > audioTime + guardWindow,
               !audioEnded {
                displayLoopLock.withLock {
                    tickStallAhead += 1
                    // [diag] freeze-site sample: what front/audio actually were
                    // each time the guard held the picture (every 450th stall).
                    tickStallSample += 1
                    if tickStallSample >= 450 {
                        tickStallSample = 0
                        if Self.diagLoggingEnabled {
                            logger.warning("[diag] stall: front=\(String(format: "%.3f", ahead.pts), privacy: .public) audio=\(String(format: "%.3f", audioTime), privacy: .public) gap=\(String(format: "%.0f", (ahead.pts - audioTime) * 1000), privacy: .public)ms q=\(self.jitterBuffer.count, privacy: .public)")
                        }
                    }
                }
                // Clamp: with d<0 (zyno#104) audioTime legitimately starts
                // negative; the seek bar must not.
                let pos = Duration.milliseconds(Int64(max(0, audioTime) * 1000))
                let due = displayLoopLock.withLock { (pos - lastNotifiedPos) >= .milliseconds(500) }
                if due {
                    displayLoopLock.withLock { lastNotifiedPos = pos }
                    applyDisplayUpdate(DisplayUIUpdate(position: pos, generation: playGeneration, notify: true))
                }
                return
            }
        } else {
            // [diag] the guard branch didn't run — record why via a periodic
            // sample (per-tick counters alone can't say which condition failed).
            displayLoopLock.withLock {
                tickGuardSkip += 1
                tickGuardSkipSample += 1
                if tickGuardSkipSample >= 450 {
                    tickGuardSkipSample = 0
                    if Self.diagLoggingEnabled {
                        let front = jitterBuffer.peek(at: 0)
                        logger.warning("[diag] guardSkip: hasDisplayed=\(self.syncController.hasDisplayedFrame, privacy: .public) stillNeedsCal=\(stillNeedsCal, privacy: .public) clockReady=\(clockReady, privacy: .public) front=\(String(format: "%.3f", front?.pts ?? -1), privacy: .public) audio=\(String(format: "%.3f", audioTime), privacy: .public) q=\(self.jitterBuffer.count, privacy: .public)")
                    }
                }
            }
        }

        // Detect when audioClock has started advancing (primer callbacks fired).
        // Until then, bypass syncController timing and display frames as fast as
        // they're decoded so video doesn't stall waiting for audio to catch up.
        // zyno#104: consume-based, not audioTime-based — with d<0 audioTime
        // starts at −|d| and would only cross 0 after |d| seconds had played,
        // leaving the display free-running (unsynced) through the entire
        // negative window instead of holding the picture there.
        if !clockReady, audioClock.hasConsumedOutput {
            displayLoopLock.withLock { audioClockReady = true }
        }

        guard let frame = jitterBuffer.peek(at: 0) else {
            displayLoopLock.withLock { tickNoFrame += 1 }
            return
        }

        let followingPTS = jitterBuffer.peek(at: 1)?.pts

        // Before audioClock starts advancing (primer pending), display frames
        // at nominal rate without waiting for audio sync.  Without this the
        // syncController sees video far ahead of audio(audio=0) and holds
        // frames indefinitely → "首帧后不播放" bug.
        let (shouldShow, delay): (Bool, Double)
        if clockReady {
            if audioEnded {
                // EOF free-run (see audioEnded above): pace the remaining
                // frames at source PTS intervals — the same pacing the
                // pre-clock bypass uses — until the tail has played out and
                // position lands on the real end (upstream completion fires).
                let srcGap = followingPTS.map { max(0.01, min(0.5, $0 - frame.pts)) }
                    ?? (1.0 / 25.0)
                let due = displayLoopLock.withLock {
                    if now - lastBypassPopTime >= srcGap {
                        lastBypassPopTime = now
                        return true
                    }
                    return false
                }
                (shouldShow, delay) = (due, 0)
            } else {
                (shouldShow, delay) = syncController.check(
                    nextPTS: frame.pts,
                    followingPTS: followingPTS,
                    audioTime: audioTime,
                    now: now,
                    serial: serial,
                    rate: playbackRate
                )
            }
        } else {
            // 旁路不再每 tick 弹帧:音频时钟卡死时 audioClockReady 永远为
            // false,原来每个显示驱动 tick 都直接弹帧 —— macOS 双驱动
            // (CVDisplayLink 60Hz + 兜底 timer 30Hz)最高 ~90Hz ≈ 2.4-3.6x
            // 加速("自动播下一集加速"的直接放大器),且弹帧快于 demux
            // 补充率会排空 jitterBuffer → .buffering → 卡死。改为按源
            // PTS 间隔 pacing:首帧立即显示,后续帧等足源帧间隔,永远不
            // 高于 1x;显示线程积压的 tick 也只会弹出一帧,不爆发
            // (renderGate 串行化,tick 之间也不会并发)。
            let srcGap = followingPTS.map { max(0.01, min(0.5, $0 - frame.pts)) }
                ?? (1.0 / 25.0)
            let due = displayLoopLock.withLock {
                if now - lastBypassPopTime >= srcGap {
                    lastBypassPopTime = now
                    return true
                }
                return false
            }
            (shouldShow, delay) = (due, 0)
        }

        guard shouldShow else {
            if clockReady { displayLoopLock.withLock { tickCheckDeny += 1 } }
            // 旁路 pacing 等待时视频帧已在正确位置,用帧 PTS 而非 audioTime
            // (音频卡死时恒为 0,会把进度条打回 0)。
            let pos = Duration.milliseconds(Int64(max(0, clockReady ? audioTime : frame.pts) * 1000))
            let due = displayLoopLock.withLock { (pos - lastNotifiedPos) >= .milliseconds(500) }
            if due {
                displayLoopLock.withLock { lastNotifiedPos = pos }
                applyDisplayUpdate(DisplayUIUpdate(position: pos, generation: playGeneration, notify: true))
            }
            return
        }

        guard let popped = jitterBuffer.pop() else { return }
        syncController.advance(delay: delay, pts: popped.pts,
                               followingPTS: followingPTS, audioTime: audioTime, now: now)
        // Render config snapshot (colorParams/rendererStrategy are written on the
        // main actor at stream open; the tick reads them concurrently since P2).
        let (cpBase, strategy) = renderConfigLock.withLock { (colorParams, rendererStrategy) }
        var cp = cpBase
        cp.dovi = popped.metadata.dovi
        // Renderers are thread-safe by contract (ASBDL enqueue / Metal command
        // buffers / ToneMapProcessor's own lock) — this runs on the display thread.
        _renderer.render(pixelBuffer: popped.pixelBuffer,
                         pts: popped.pts,
                         colorParams: cp,
                         metadata: popped.metadata,
                         strategy: strategy)
        let ptsCopy = popped.pts
        let pixelBuffer = popped.pixelBuffer
        // FrameSink is @MainActor — deliver from the main thread (hop keeps the
        // display tick free of MainActor requirements; the closure retains the
        // pixel buffer for the sinks' lifetime).
        let sinks = renderConfigLock.withLock { self._frameSinks.compactMap { $0.sink } }
        if !sinks.isEmpty {
            DispatchQueue.main.async {
                for sink in sinks {
                    sink.receive(pixelBuffer: pixelBuffer, pts: ptsCopy)
                }
            }
        }
        let firstFrameRendered: Bool = displayLoopLock.withLock {
            displayedVideoFrames += 1; framesSinceLastLog += 1
            // [diag] every displayed frame feeds the offset distribution; the
            // first frame after a seek also logs the video landing error.
            avOffsetStats.record(popped.pts - audioTime)
            // [diag] display-order integrity: interval between consecutive
            // displayed frames' PTS. Continuous playback sits at the source
            // frame duration; decode-order display (broken PTS) alternates or
            // goes negative. ±1s guard drops seek jumps — see shownGapStats.
            let shownGap = popped.pts - lastShownDiagPTS
            if shownGap.isFinite, shownGap > -1.0, shownGap < 1.0 {
                shownGapStats.record(shownGap)
            }
            lastShownDiagPTS = popped.pts
            if !seekLandLogged, let target = pendingSeekLandTarget {
                seekLandLogged = true
                logger.info("[diag] seek videoLand=\(String(format:"%+.3f", popped.pts - target), privacy: .public)s target=\(String(format:"%.3f", target), privacy: .public)s pts=\(String(format:"%.3f", popped.pts), privacy: .public)s")
            }
            return displayedVideoFrames == 1
        }

        // needsClockCalibration is already cleared in the calibrate block above.
        // First frame has been rendered; subsequent ticks let audioClock advance
        // naturally via AudioQueue callbacks.

        let posDur = Duration.milliseconds(Int64(popped.pts * 1000))
        let gen = playGeneration

        // Position → UI on the 500ms throttle (or first frame). Buffered
        // duration / cacheSpeed ride along inside applyDisplayUpdate's
        // main-thread block (they read demuxer + state.duration).
        let due = displayLoopLock.withLock { (posDur - lastNotifiedPos) >= .milliseconds(500) }
        if firstFrameRendered || due {
            if due { displayLoopLock.withLock { lastNotifiedPos = posDur } }
            applyDisplayUpdate(DisplayUIUpdate(position: posDur, durationAtLeast: posDur,
                                               generation: gen, notify: true))
        }

        // Update active subtitle text/image. Matching stays on the display
        // thread (video-PTS based — see note below); the state write + notify
        // hop to the main thread via applyDisplayUpdate. Only notify when the
        // text/image actually changes to avoid redundant view invalidations
        // on every frame.
        // Use the displayed frame's PTS (not audioTime) for subtitle matching —
        // this keeps subtitles in sync with the video, not the audio clock.
        // Audio clock can lag behind video (seek, primer, underrun) causing
        // subtitles to appear late when matched against audioTime.
        let displayPts = popped.pts
        let activeSub: String? = subtitleLock.withLock {
            subtitleCues.first { $0.startPts <= displayPts && displayPts < $0.endPts }?.text
        }
        let assR = self.assRenderer
        let (newImage, newRect): (CGImage?, CGRect)
        if let assR {
            // ASS typeset rendering against the displayed frame's video PTS.
            // libass's detect_change keeps the Frame instance stable across
            // calls without content change, so the identity check below still
            // suppresses redundant UI hops.
            if let f = assR.renderFrame(ptsSecs: displayPts) {
                newImage = f.image
                newRect = f.rect
            } else {
                newImage = nil
                newRect = .zero
            }
        } else {
            (newImage, newRect) = subtitleImageLock.withLock {
                // Prune expired cues so first(where:) doesn't scan a growing list.
                // Keep only cues whose endPts hasn't passed yet.
                if subtitleImageCues.count > 4 {
                    subtitleImageCues.removeAll { $0.endPts < displayPts - 1.0 }
                }
                if let c = subtitleImageCues.first(where: { $0.startPts <= displayPts && displayPts < $0.endPts }) {
                    return (c.image, c.rect)
                }
                return (nil, .zero)
            }
        }
        let (textChanged, imageChanged) = displayLoopLock.withLock { () -> (Bool, Bool) in
            let t = activeSub != lastSubtitleText
            let i = newImage !== lastSubtitleImage
            if t { lastSubtitleText = activeSub }
            if i { lastSubtitleImage = newImage }
            return (t, i)
        }
        if textChanged || imageChanged {
            var u = DisplayUIUpdate(position: posDur, durationAtLeast: posDur,
                                    generation: gen, notify: true)
            if textChanged { u.subtitleText = activeSub }
            if imageChanged {
                u.subtitleImage = newImage
                u.subtitleImageRect = newRect
            }
            applyDisplayUpdate(u)
        }

        logSync(now: now, pts: popped.pts, audioTime: audioTime)
    }

    private nonisolated func logSync(now: Double, pts: Double, audioTime: Double) {
        let gen = playGeneration
        let (elapsed, fpsSamples): (Double, Int) = displayLoopLock.withLock {
            let e = now - lastLogTime
            guard e > 5.0 else { return (0.0, 0) }
            return (e, framesSinceLastLog)
        }
        guard elapsed > 5.0 else { return }
        let fps = Double(fpsSamples) / elapsed
        let diff = Int((pts - audioTime) * 1000)
        let subCueCount = subtitleLock.withLock { subtitleCues.count }
        let subImgCount = subtitleImageLock.withLock { subtitleImageCues.count }
        // [diag] drain the per-frame offset + AudioQueue-granularity windows
        // (display thread — same lock discipline as the record sites).
        let av = displayLoopLock.withLock { () -> SyncDiagStats in
            let s = avOffsetStats
            avOffsetStats.reset()
            return s
        }
        let aq = audioClock.drainAdvanceDiag()
        let tick = drainTickDiag()
        // [diag] display-order integrity window + PTS rewrites since last log.
        let (shown, rewrites) = displayLoopLock.withLock { () -> (SyncDiagStats, Int) in
            let s = shownGapStats
            shownGapStats.reset()
            let r = diagPTSRewriteCount
            diagPTSRewriteCount = 0
            return (s, r)
        }
        // state/demuxer reads + the cacheSpeed write stay on the main actor;
        // the whole log line hops (5s cadence — the hop costs nothing).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.playGeneration == gen else { return }
            let subStreamIdx = self.demuxer?.subtitleStreamIndex ?? -1
            let (tickCount, qCount): (Int, Int) = displayLoopLock.withLock { (self.ticksSinceLastLog, self.jitterBuffer.count) }
            logger.info("q=\(qCount, privacy: .public) dur=\(Int(self.jitterBuffer.duration*1000), privacy: .public)ms fps=\(String(format:"%.1f",fps), privacy: .public) ticks=\(tickCount, privacy: .public) diff=\(diff, privacy: .public)ms a=\(String(format:"%.2f",audioTime), privacy: .public)s v=\(String(format:"%.2f",pts), privacy: .public)s buf=\(self.state.isBuffering, privacy: .public) subStream=\(subStreamIdx, privacy: .public) subCues=\(subCueCount, privacy: .public) subImgCues=\(subImgCount, privacy: .public)")
            // [diag] window distributions. av: per-frame pts-audioTime (ms);
            // aq: per-callback consumed output samples. maxJump/flips large =
            // pacing oscillation (晃动 signature); steady offset = healthy.
            // All periodic [diag] lines are gated by diagLoggingEnabled (off
            // in production).
            if Self.diagLoggingEnabled {
                logger.info("[diag] av[n=\(av.count, privacy: .public) mean=\(String(format:"%+.1f", av.mean*1000), privacy: .public)ms sd=\(String(format:"%.1f", av.stddev*1000), privacy: .public)ms min=\(String(format:"%+.1f", av.min*1000), privacy: .public)ms max=\(String(format:"%+.1f", av.max*1000), privacy: .public)ms jump=\(String(format:"%.1f", av.maxJump*1000), privacy: .public)ms flips=\(av.signFlips, privacy: .public)] aq[n=\(aq.count, privacy: .public) mean=\(String(format:"%.0f", aq.mean), privacy: .public) min=\(String(format:"%.0f", aq.min), privacy: .public) max=\(String(format:"%.0f", aq.max), privacy: .public) jump=\(String(format:"%.0f", aq.maxJump), privacy: .public)]")
                // [diag] where ticks went: drain=skip-behind pops, stall=freeze-ahead
                // ticks, deny=SyncController refusals, appends=decode supply.
                logger.info("[diag] tick[drain=\(tick.drainLag, privacy: .public) stall=\(tick.stallAhead, privacy: .public) deny=\(tick.checkDeny, privacy: .public) noFrame=\(tick.noFrame, privacy: .public) guardSkip=\(tick.guardSkip, privacy: .public) appends=\(tick.appends, privacy: .public) depth[n=\(tick.drainDepth.count, privacy: .public) mean=\(String(format:"%.0f", tick.drainDepth.mean*1000), privacy: .public)ms max=\(String(format:"%.0f", tick.drainDepth.max*1000), privacy: .public)ms]]")
                // [diag] display-order integrity (2026-10-13): gap = pts interval
                // between displayed frames. Healthy 23.976fps content: min≈max≈41.7ms.
                // Decode-order display (broken PTS): min≈20.8 / max≈62.5 (or negative).
                // rewrites = frames whose PTS the validator synthesized this window.
                logger.info("[diag] show[n=\(shown.count, privacy: .public) mean=\(String(format:"%.1f", shown.mean*1000), privacy: .public)ms min=\(String(format:"%.1f", shown.min*1000), privacy: .public)ms max=\(String(format:"%.1f", shown.max*1000), privacy: .public)ms jump=\(String(format:"%.1f", shown.maxJump*1000), privacy: .public)ms] rewrites=\(rewrites, privacy: .public)")
            }

            // Throughput: bytes read since last sample / elapsed.
            // zyno#145 基线守卫:stop() 会把 lastThroughputTime 清 0,而 now 是
            // CACurrentMediaTime(开机秒数)。没有守卫时,开播/切集后的首个窗口
            // 分母是"开机至今",速度恒 ≈0 并持续一个采样周期(~5s)。首样本只记
            // 基线不写值,从第二个采样起窗口才有效。
            let (bytesDelta, tpElapsed, hasBaseline): (Int64, Double, Bool) = throughputLock.withLock {
                (self.totalBytesRead - self.lastBytesLogged, now - self.lastThroughputTime, self.lastThroughputTime > 0)
            }
            if hasBaseline, tpElapsed > 1.0 {
                self.state.cacheSpeed = Int64(Double(bytesDelta) / tpElapsed)
                throughputLock.withLock {
                    self.lastBytesLogged = self.totalBytesRead
                    self.lastThroughputTime = now
                }
            } else if !hasBaseline {
                throughputLock.withLock {
                    self.lastBytesLogged = self.totalBytesRead
                    self.lastThroughputTime = now
                }
            }

            displayLoopLock.withLock {
                self.lastLogTime = now
                self.framesSinceLastLog = 0
                self.ticksSinceLastLog = 0
            }
        }
    }

    // MARK: - Display → UI bridge (P2: display thread off main)

    /// One display tick's worth of UI state, produced on the display thread and
    /// applied on the main actor. Optional fields mean "don't touch this field
    /// this update"; the double-optional subtitle fields distinguish "no
    /// change" (nil) from "subtitle cleared" (.some(nil)). `generation` drops
    /// updates computed before a stop()/play() cycle — without it a stale
    /// update would resurrect old position/subtitle values in a new session.
    private struct DisplayUIUpdate {
        var position: Duration? = nil
        var durationAtLeast: Duration? = nil
        var subtitleText: String?? = nil
        var subtitleImage: CGImage?? = nil
        var subtitleImageRect: CGRect? = nil
        var generation: Int
        var notify: Bool
    }

    /// Display-thread entry: hop to the main actor and apply.
    private nonisolated func applyDisplayUpdate(_ u: DisplayUIUpdate) {
        DispatchQueue.main.async { [weak self] in
            self?.applyDisplayUpdateOnMain(u)
        }
    }

    /// Main-actor side of the bridge. Applies position/buffered/subtitle
    /// fields to `state` and notifies observers.
    private func applyDisplayUpdateOnMain(_ u: DisplayUIUpdate) {
        guard u.generation == playGeneration else { return }

        if let pos = u.position { state.position = pos }
        if let d = u.durationAtLeast, d > state.duration { state.duration = d }

        // Update bufferedDuration. Prefer reader-level download offset (reflects
        // actual pre-fetched bytes, not just the demux-loop's throttled read
        // position which is capped at ~2s).
        let currentSecs = Double(state.position.components.seconds)
        let dlOffset = demuxer?.downloadedUpToOffset ?? -1
        let fileBytes = demuxer?.totalFileBytes ?? -1
        if dlOffset > 0, fileBytes > 0, state.duration > .zero {
            let dlFraction = min(1.0, Double(dlOffset) / Double(fileBytes))
            let dlSecs = dlFraction * Double(state.duration.components.seconds)
            state.bufferedDuration = .milliseconds(Int64(max(0, dlSecs - currentSecs) * 1000))
        } else {
            // Fallback for URL-based streams without a custom reader.
            let downloaded = maxDownloadedPts
            state.bufferedDuration = downloaded > currentSecs
                ? .milliseconds(Int64((downloaded - currentSecs) * 1000))
                : .zero
        }

        if let t = u.subtitleText { state.currentSubtitleText = t }
        if let img = u.subtitleImage {
            state.currentSubtitleImage = img
            state.currentSubtitleImageRect = u.subtitleImageRect ?? .zero
        }

        if u.notify { notifyStateChange() }
    }

    // MARK: - Controls

    /// Test seam (see `AudioUnitOutput.tracksPlayedContent`): running source-content
    /// PTS of the last decoded PCM frame, so the PTS of the audio that was actually
    /// played can be compared with the picture. Laced MKV audio has NaN pts after the
    /// first frame of each lace, so it re-anchors on every finite packet pts and
    /// otherwise accumulates decoded duration. Only touched on audioDecodeQueue.
    private nonisolated(unsafe) var playedContentTrackerEnd: Double = .nan

    /// Test seam: source-content PTS the audio device has fully played minus the audio
    /// clock, in seconds. The video is paced against the clock, so this is the
    /// audio-vs-picture offset (positive = sound ahead of the picture). NaN until the
    /// first buffer completed or when `tracksPlayedContent` is off.
    func audioContentGapForTesting() -> Double {
        (audioUnitOutput?.playedContentEnd() ?? .nan) - audioClock.audioTime
    }

    public func pause() {
        logger.info("pause")
        displayLink?.invalidate(); displayLink = nil
        displayLoopLock.withLock { displayLoopStopped = true }
        #if os(macOS)
        // Keep displayLinkProxy alive: CVDisplayLink's output callback holds an
        // unretained raw pointer to it. Releasing the proxy here would leave a
        // dangling pointer that gets dereferenced on the next CVDisplayLinkStart.
        if let cv = cvDisplayLink, CVDisplayLinkIsRunning(cv) { CVDisplayLinkStop(cv) }
        fallbackRenderTimer?.cancel()
        fallbackRenderTimer = nil
        #else
        displayLinkProxy = nil
        #endif
        audioUnitOutput?.pause()
        // Stop the demux loop so jitterBuffer doesn't fill up while audio is
        // paused. Without this, the demux loop keeps reading packets and
        // appending frames (video throttle skips sleep when audioClock is
        // stalled), accumulating tens of seconds of video ahead of the paused
        // audio position. On resume, freeze-ahead guard holds all frames
        // → stutter/卡顿.
        demuxStateLock.lock()
        demuxCancelled = true
        demuxStateLock.unlock()
        state.isPlaying = false; notifyStateChange()
    }

    public func resume() {
        guard demuxer != nil else {
            logger.warning("resume: demuxer is nil, player was stopped — ignoring")
            // Don't leave demuxCancelled=true if there's no demuxer —
            // otherwise the next play() won't start the demux loop.
            demuxStateLock.lock()
            demuxCancelled = false
            demuxStateLock.unlock()
            return
        }
        logger.info("resume")
        // Re-activate the AudioSession.  After a background/PiP transition iOS may
        // deactivate the session, which silently prevents AudioQueue callbacks
        // from firing — the audio clock freezes and A/V sync stalls.
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        // PiP 恢复时 demux 循环从未中断(demuxLoopRunning && !demuxCancelled,
        // 见 startDemuxLoop 防重入):播放管线保持连续 —— 音频时钟在 PiP 期间
        // 持续推进、jitterBuffer 持续填充。此时 flush/重建反而有害:清空
        // jitterBuffer 后恢复瞬间没有新帧可显示(主画面闪过 PiP 的最后内容)、
        // 音频时钟归零重校准产生咔哒。只有真正 pause 过(循环已取消)才需要
        // 走完整的重建路径。
        let resumingContinuous = demuxStateLock.withLock { demuxLoopRunning && !demuxCancelled }
        if !resumingContinuous {
            // 重建音频输出。后台期间(PiP 未激活/不支持/启动失败)音频会话被系统
            // 暂停,AudioQueue 停止消费,音频时钟停在暂停位置;而 demux/解码器在
            // app 未被挂起时继续推进 —— resume 时音频时钟落后视频帧 PTS 可达
            // 数十秒,freeze-ahead 把超前帧全部冻结 → 画面长时间卡死。flush()
            // 丢弃后台积压的旧帧(它们的内容与校准后的时钟会错位),时钟归零,
            // 首个校准帧强制校准到帧 PTS(见 forceClockCalibration),让音频从
            // 当前视频位置重新起步,而不是从暂停位置慢速追赶。
            audioUnitOutput?.flush()
            let resumeSR = audioDecoder?.outputSampleRate ?? 44100
            let resumeCh = audioDecoder?.outputChannels ?? 2
            audioUnitOutput?.start(sampleRate: resumeSR, channels: resumeCh)
            audioUnitOutput?.pause()
            audioClock.reset(to: 0, sampleRate: resumeSR)
            displayLoopLock.withLock { forceClockCalibration = true }
        }
        // Continuous path (pipeline never stopped, e.g. PiP): resume audio output
        // regardless of jitter buffer state.
        // If the player was paused while the jitter buffer was in .buffering state,
        // the conditional guard (state == .playing) would leave audio silently stopped.
        // audioClock would stay frozen → demux backpressure (pts > audioPos+2.0) would
        // never release → no new frames appended → no .buffering→.playing transition
        // possible → permanent deadlock.  Resuming audio unconditionally lets audioClock
        // advance, which unblocks the demux loop.  onStateChange(.buffering) will pause
        // audio again if the buffer drains below minDuration, and onStateChange(.playing)
        // will resume it; those two form the normal steady-state feedback loop.
        //
        // Rebuild path: do NOT resume here. jitterBuffer.flush() below puts the buffer
        // back to .buffering, so the refilled buffer WILL flip to .playing (or EOF /
        // slow-decode grace) and onStateChange(.playing) resumes the queue — the same
        // protocol _finishOpen uses. Resuming now made the audio play by itself for the
        // ~1 s the video needs to refill, after which the clock was calibrated to the
        // first video frame: sound stayed ahead of the picture by that second
        // (measured +0.97 s on the real movie).
        if resumingContinuous {
            audioUnitOutput?.resume()
        }
        // Invalidate any existing display link before creating a new one.
        // Without this, calling resume() on an already-playing player (e.g. when
        // pip.start() was attempted but PiP never fully activated) would leave
        // the old link running and add a second one — both pop frames, draining
        // the jitter buffer at 2× speed → stuck.
        displayLink?.invalidate()
        displayLink = nil
        displayLoopLock.withLock { displayLoopStopped = true }
        #if os(iOS)
        displayLinkProxy = nil
        #endif
        // Restart the demux loop (pause() set demuxCancelled=true).
        // Flush stale frames that accumulated during pause to prevent
        // freeze-ahead stutter on resume. PiP 连续播放场景跳过 —— jitter
        // 里全是新鲜帧,flush 只会造成恢复瞬间无帧可显示(PiP 画面一闪)。
        if !resumingContinuous {
            jitterBuffer.flush()
            syncController.reset()
            displayLoopLock.withLock { lastBypassPopTime = 0 }
            // Flush the video decoder after a pause/resume or PiP/background
            // transition. VTDecompressionSession may have been invalidated by
            // the system during the transition — VTVideoDecoder will recreate
            // its session on the next transient error, but we flush delayed
            // frames first to avoid feeding stale reordered frames.
            if let vt = videoDecoder as? VTVideoDecoder {
                vt.flush()
            }
        }
        startDemuxLoop()
        startDisplayLink()
        // Calibrate audioClock to the first post-resume frame (like post-seek).
        // PiP 连续场景时钟从未停,无需校准。
        if !resumingContinuous {
            displayLoopLock.withLock {
                needsClockCalibration = true
                audioClockReady = false
            }
        }
        state.isPlaying = true; notifyStateChange()
    }

    public func seek(to: Duration) {
        _seek(to: to, synchronousDemuxerSeek: false)
    }

    /// - Parameter synchronousDemuxerSeek: 打开即恢复播放位置(`_finishOpen` 的
    ///   `seekTo`)专用。该场景必须在 `startDemuxLoop()` 启动前让 demuxer 真正
    ///   跳到目标位置——异步版本(默认路径)把 demuxer.seek()+flush 派发到后台,
    ///   若这里也异步,demux 循环会在 seek 落地前抢先从偏移 0 读出好几帧塞进
    ///   jitterBuffer,和落地后的目标位置帧混流,导致画面卡死在旧帧
    ///   (2026-09-02 用户反馈"播放不出来"实锤,音频时钟已到 75s 而视频还停在
    ///   0.04s)。初始 open 阶段本来就有秒级的网络探测延迟,这里多等几百毫秒
    ///   完全不影响体验,不像交互式拖动 seek 那样对主线程阻塞敏感。
    private func _seek(to: Duration, synchronousDemuxerSeek: Bool) {
        let secs = to.secondsDouble
        logger.info("seek to \(String(format:"%.1f",secs))s")
        // [diag] arm the seek-landing capture: the first displayed frame of the
        // new position logs pts - target (videoLand).
        displayLoopLock.withLock {
            pendingSeekLandTarget = secs
            seekLandLogged = false
        }
        // 捕获自增后的值:连续快速 seek(拖动多次/连按快进)时,后面异步执行的
        // performDemuxerSeek 要靠这个值判断"我是不是已经被更新的 seek 取代了"
        // (2026-09-03 用户反馈连续 seek 后音视频差出几十秒实锤——旧代码里
        // 谁最后抢到 demuxLock 谁说了算,不是谁最后调用 seek() 说了算,乱序
        // 执行会让 demuxer 停在一个不是用户最终目标的位置)。
        let mySerial: Int64 = seekLock.withLock { seekSerial += 1; return seekSerial }

        subtitleLock.withLock { subtitleCues.removeAll() }
        displayLoopLock.withLock { lastSubtitleText = nil }
        state.currentSubtitleText = nil
        subtitleImageLock.withLock { subtitleImageCues.removeAll() }
        assRenderer?.flushEvents()   // drop queued ASS events left of the seek target
        displayLoopLock.withLock { lastSubtitleImage = nil }
        state.currentSubtitleImage = nil
        state.currentSubtitleImageRect = .zero

        jitterBuffer.flush()
        syncController.reset()
        displayLoopLock.withLock { lastBypassPopTime = 0 }
        // The read-ahead frontier jumps to the seek target; a pre-seek wall
        // anchor would misestimate the fallback pacing position.
        passthroughWallClockAnchor = nil
        // Clear the displayed frame so the pre-seek frame doesn't linger on
        // screen until the first post-seek frame is decoded and rendered.
        _renderer.flush()

        let sr = audioDecoder?.outputSampleRate ?? 44100
        let ch = audioDecoder?.outputChannels ?? 2
        // stop() BEFORE reset: AudioQueueStop(immediate=true) fires callbacks for
        // all buffered frames, each calling clock.advance().  Resetting before stop
        // would let those callbacks push the clock past secs.  Reset after stop so
        // it always lands exactly at secs regardless of how many frames were buffered.
        audioUnitOutput?.stop()
        // Passthrough: drop audio scheduled for the old position and re-anchor
        // its clock to the first packet at the new position (playbackTime).
        // Without this, post-seek packets schedule far in the future of the
        // synchronizer timebase — silence, and a lying A/V sync clock.
        _injectedAudioOutput?.flush()
        audioClock.reset(to: secs, sampleRate: sr)
        audioUnitOutput?.start(sampleRate: sr, channels: ch)
        // Pause until jitterBuffer has enough video — same as initial play().
        audioUnitOutput?.pause()
        // Reset download tracking for the new seek position
        maxDownloadedPts = secs
        // Signal displayNextFrame to calibrate audioClock to actual I-frame PTS.
        // FFmpeg seek lands on the GOP boundary before secs, so audioClock(=secs)
        // would be ahead of the first decoded frame; without re-calibration the
        // display loop's skip-behind guard would drop the first few frames.
        displayLoopLock.withLock {
            needsClockCalibration = true
            audioClockReady = false
        }
        // 立即把 position 置为 seek 目标并通知:seek 到首帧渲染之间
        // displayNextFrame 不更新 position(渲染恢复后才写实际落点),
        // 不置位的话进度条/快进基准会停留在 seek 前的位置(旧值漂移,
        // "15s 快进实际跳 100s"的根因之一)。首帧渲染后覆盖为落点。
        state.position = .seconds(secs)
        notifyStateChange()

        // demuxer.seek() 是同步阻塞调用(FFmpeg avformat 层的 seek;网盘/HTTP
        // 流媒体场景下会触发一次新的字节范围网络请求,可能耗时几百毫秒到数秒)。
        // 此前这一段(连同 demuxLock 的争抢)整段在调用方线程——SwiftUI 手势
        // 回调直接同步调 seek(),即主线程——执行,期间整个 UI 完全冻住:拖动
        // 跟手性差/松手卡顿/点击跳转慢,根子都是这个(2026-09-02 用户反馈+
        // 代码走查实锤,NativeBackend 是 @MainActor,这个函数体此前从没让出
        // 过主线程)。派发到跟 demux 主循环(startDemuxLoop)同一个
        // DispatchQueue.global(),用同一把 demuxLock 保证跟循环互斥,不引入
        // 新的数据竞争;调用方(MainActor)在上面已经完成所有状态更新后立即
        // 返回,不用再等这段网络 I/O。videoDecoder/audioDecoder 的 flush 顺序
        // 和 audioDecodeQueue 串行化跟原来同步版本完全一致,只是搬到了后台。
        let demuxerRef = demuxer
        let videoDec = videoDecoder
        let audioDec = audioDecoder
        let dLock = demuxLock
        let aQueue = audioDecodeQueue
        let sLock = seekLock
        let audioOut = audioUnitOutput
        let clockRef = audioClock
        let jitterRef = jitterBuffer
        // Runs once the physical seek has landed (see performDemuxerSeek): re-arm the
        // one-shot clock calibration for the first POST-landing frame.
        let onLanded: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.displayLoopLock.withLock {
                    self.needsClockCalibration = true
                    self.audioClockReady = false
                    self.lastBypassPopTime = 0
                }
                self.syncController.reset()
            }
        }
        if synchronousDemuxerSeek {
            // 打开即恢复位置(_finishOpen)只会发生一次,不存在"被更新的 seek
            // 取代"的可能,但仍然传 backend 以便正确记录 physicalSeekGeneration
            // (demux 循环启动前这里同步执行,self 还在栈上,直接传不需要弱引用)。
            NativeBackend.performDemuxerSeek(to: secs, expectedSerial: mySerial, seekLock: sLock, backend: self,
                                              demuxer: demuxerRef, videoDecoder: videoDec,
                                              audioDecoder: audioDec, lock: dLock, audioQueue: aQueue,
                                              audioOutput: audioOut, audioClock: clockRef,
                                              audioSampleRate: sr, audioChannels: ch,
                                              jitterBuffer: jitterRef, onLanded: onLanded)
        } else {
            DispatchQueue.global().async { [weak self] in
                NativeBackend.performDemuxerSeek(to: secs, expectedSerial: mySerial, seekLock: sLock, backend: self,
                                                  demuxer: demuxerRef, videoDecoder: videoDec,
                                                  audioDecoder: audioDec, lock: dLock, audioQueue: aQueue,
                                              audioOutput: audioOut, audioClock: clockRef,
                                              audioSampleRate: sr, audioChannels: ch,
                                              jitterBuffer: jitterRef, onLanded: onLanded)
            }
        }
    }

    /// demuxer.seek() + 两个解码器 flush 的实际执行体,独立成静态函数以便
    /// _finishOpen() 打开即恢复播放位置时能同步调用(见下方调用点注释)。
    ///
    /// - Parameters:
    ///   - expectedSerial: 派发这次调用时的 seekSerial 快照。执行前重新核对——
    ///     如果这期间又来了更新的 seek(seekSerial 已经变了),说明这次调用
    ///     的目标位置已经过时,直接跳过物理 seek,交给更新那次自己的调用去做。
    ///     不加这个判断的话,谁最后抢到 demuxLock 谁的目标位置生效,不一定是
    ///     用户最后一次操作的目标(2026-09-03 连续 seek 音视频差出几十秒实锤)。
    ///   - backend: 用于成功执行物理 seek 后记录 physicalSeekGeneration(demux
    ///     循环靠它判断"真的物理 seek 了"来触发 PTSValidator.reset(),不能用
    ///     seekSerial——见该属性声明处注释)。弱引用语义由调用方保证(异步路径
    ///     用 [weak self] 捕获后传入)。
    private static func performDemuxerSeek(to secs: Double, expectedSerial: Int64, seekLock: NSLock,
                                            backend: NativeBackend?, demuxer: (any PacketDemuxing)?,
                                            videoDecoder: (any VideoDecoding)?, audioDecoder: FFmpegAudioDecoder?,
                                            lock: NSLock, audioQueue: DispatchQueue,
                                            audioOutput: AudioUnitOutput? = nil, audioClock: AudioClock? = nil,
                                            audioSampleRate: Int32 = 44100, audioChannels: Int32 = 2,
                                            jitterBuffer: VideoJitterBuffer? = nil,
                                            onLanded: (@Sendable () -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard seekLock.withLock({ backend?.seekSerial }) == expectedSerial else {
            logger.info("seek to \(String(format:"%.1f",secs))s skipped — superseded by a newer seek before it reached demuxLock")
            return
        }
        _ = demuxer?.seek(to: secs)
        backend?.altAudioCache.removeAll()   // zyno#171: 旧位置的备选音轨包作废
        // zyno#142: arm discard-until-target from the demuxer's reported
        // landing. Only byte-domain seeks report one (index-guided seeks
        // report nil → flags cleared → historical behavior, MKV/MP4 untouched).
        // A landing PAST the target can't be discarded back — the content is
        // already behind us; accept it as-is (seekByByteOffset itself steers
        // away from that, see its one-sided acceptance criterion).
        if let landed = demuxer?.lastSeekLandedPTS, landed <= secs, secs - landed > Self.discardArmGap {
            backend?.discardLock.withLock { backend?.discardVideoUntilPts = secs }
            backend?.discardAudioUntilPts = secs
            logger.info("fine-seek: discard \(String(format: "%.2f", secs - landed), privacy: .public)s (landed=\(String(format: "%.2f", landed), privacy: .public) target=\(String(format: "%.2f", secs), privacy: .public))")
        } else {
            backend?.discardLock.withLock { backend?.discardVideoUntilPts = nil }
            backend?.discardAudioUntilPts = nil
        }
        videoDecoder?.flush()
        // Routed through audioDecodeQueue so this can't race a still-in-flight
        // decode() of a pre-seek packet on that queue.
        audioQueue.sync {
            audioDecoder?.flush()
            // Same serial queue as tempo.process() — safe to drop stretch
            // state for the new position (stale windows would crossfade
            // pre-seek content into post-seek audio).
            backend?.audioTempo.reset()
        }
        // The sync above is a barrier: every packet read from the OLD position has
        // now been decoded and its PCM is already in the audio queue that _seek
        // restarted BEFORE this physical seek landed (a cast at a position is
        // play() + a separate seek ~30 ms later, and demux keeps reading the old
        // position until this point). Playing that would put audio from the old
        // position ahead of the post-seek audio — measured −0.86 s (old cap) and
        // −2.60 s (5 s cap) between audio content and picture. Nothing from before
        // the landing can arrive after the barrier, so restart the queue once more:
        // same sequence as _seek (stop → clock reset → start → pause; the jitter
        // buffer's .playing transition resumes it).
        if let out = audioOutput, let clock = audioClock {
            out.stop()
            clock.reset(to: secs, sampleRate: audioSampleRate)
            out.start(sampleRate: audioSampleRate, channels: audioChannels)
            out.pause()
        }
        // Same for video. Until this landing the demux loop kept reading the OLD
        // position (a cast at a position is play() + a separate seek), so the jitter
        // buffer now holds stale frames; the first of them consumed the one-shot clock
        // calibration (`needsClockCalibration`) — with the old position far from the
        // target (> maxCalibrationGap) it SKIPPED the calibration and cleared the flag.
        // The real post-landing frames then never re-calibrated the clock: it stayed at
        // the target while audio started at the landing keyframe (audio behind picture
        // by target − keyframe: −2.005 s on the real movie). Drop the stale frames and
        // let the first post-landing frame calibrate. We still hold demuxLock, so no
        // post-landing frame can have been appended yet.
        jitterBuffer?.flush()
        onLanded?()
        let gen = (backend?.physicalSeekGeneration ?? 0) + 1
        backend?.physicalSeekGeneration = gen
        // Open the gate: from the next demux iteration on, frames are from the target.
        backend?.seekLandedSerial = expectedSerial
        logger.info("seek to \(String(format:"%.1f",secs))s landed physically, physicalSeekGeneration=\(gen)")
    }

    public func stop() {
        playGeneration += 1  // discard any in-flight async open
        logger.info("stop (displayed \(self.displayLoopLock.withLock { self.displayedVideoFrames }) frames)")
        displayLink?.invalidate(); displayLink = nil; displayLinkProxy = nil
        displayLoopLock.withLock { displayLoopStopped = true }
        #if os(macOS)
        if let cv = cvDisplayLink, CVDisplayLinkIsRunning(cv) { CVDisplayLinkStop(cv) }
        cvDisplayLink = nil
        fallbackRenderTimer?.cancel()
        fallbackRenderTimer = nil
        #endif
        demuxCancelled = true
        audioUnitOutput?.stop()
        // Passthrough: drop audio scheduled for the previous session so the
        // next play() re-anchors its clock to the new stream (playbackTime).
        _injectedAudioOutput?.flush()
        demuxLock.lock()
        altAudioCache.removeAll(); altAudioStreams = []   // zyno#171
        demuxer?.close(); demuxer = nil
        videoDecoder = nil; audioDecoder = nil
        // No seek can be pending on a stream that no longer exists; never leave the
        // frame gate (SeekFrameGate) closed or a fine-seek discard window armed
        // for the next session.
        seekLock.withLock { seekLandedSerial = seekSerial }
        discardAudioUntilPts = nil
        demuxLock.unlock()
        jitterBuffer.flush()
        syncController.reset()
        displayLoopLock.withLock {
            lastBypassPopTime = 0
            forceClockCalibration = false
            discardLock.withLock { discardVideoUntilPts = nil }
            // Un-poison the status pipeline: without this, a position reported by a
            // previous (e.g. frozen/free-wheeling) session persists here and every
            // `(pos - lastNotifiedPos) >= 500ms` gate in displayNextFrame stays
            // negative for the next session → Player/onStateChange copies freeze at
            // 0 → cast /status reports a frozen position while the pipeline moves
            // (2026-09-20 real-hardware regression: "next cast frozen until app
            // restart").
            lastNotifiedPos = .zero
            displayedVideoFrames = 0
            throughputLock.withLock {
                lastBytesLogged = 0
                lastThroughputTime = 0
            }
            lastSubtitleText = nil
            lastSubtitleImage = nil
        }
        passthroughWallClockAnchor = nil
        audioClock.reset(to: 0, sampleRate: 44100)  // critical: must reset or stale seek position
                                                     // from previous session pollutes AudioClock
        _renderer.flush()
        _renderer.clear()  // hide the previous video's last frame until the new
                           // video renders its first frame (MetalRenderer.display
                           // flips opacity back to 1 on first frame)
        totalBytesRead = 0
        maxDownloadedPts = 0
        subtitleLock.withLock { subtitleCues.removeAll() }
        state.currentSubtitleText = nil
        subtitleImageLock.withLock { subtitleImageCues.removeAll() }
        state.currentSubtitleImage = nil
        state.currentSubtitleImageRect = .zero
        subtitleDecoder = nil
        assRenderer = nil
        chapters = []  // container chapters are per-session (zyno#101)
        state = PlayerState()
        // Player.state is only a copy refreshed via onStateChange; without this push the
        // previous video's subtitle lingers in the UI until the next ≥500ms position
        // notification of the new session (zyno#206).
        notifyStateChange()
    }

    public func setVolume(_ volume: Double) { state.volume = volume; notifyStateChange() }
    public func setRate(_ rate: Double) {
        let clamped = max(0.25, min(4.0, rate.isFinite ? rate : 1.0))
        state.rate = clamped
        displayLoopLock.withLock { displayRate = clamped }
        // Wire the rate to every consumer (zyno#99 — previously state.rate had
        // none, which made the UI rate control a no-op on the FFmpeg backend):
        //   - the tempo processor (audioDecodeQueue reads it per process())
        //   - the output's content-time accounting (callback → AudioClock)
        //   - the display loop's guard window and sync normalization
        audioTempo.setRate(clamped)
        audioUnitOutput?.setPlaybackRate(clamped)
        notifyStateChange()
    }
    /// zyno#171: 切轨的重负载段(flush/seek/管线重建)调度到专用串行队列,
    /// 主线程只做参数校验,不再被 demuxLock + FFmpeg seek 阻塞数百毫秒。
    private nonisolated(unsafe) static let audioSwitchQueue = DispatchQueue(
        label: "com.zyno.playerkit.audio-switch", qos: .userInitiated)

    /// 没有解码器、也无法透传的音轨不能切:解码器建不起来 → 没有 PCM → 音频时钟不走 →
    /// 视频一直等音频,整个影片冻死(zyno#171 实测 "codec not found")。
    nonisolated static func audioTrackIsSwitchable(codecID: AVCodecID, passthroughAvailable: Bool) -> Bool {
        passthroughAvailable || avcodec_find_decoder(codecID) != nil
    }

    public func selectAudioTrack(id: String) {
        // 主线程只做轻量校验(fast fail),重负载段全部在后台队列执行
        guard let demuxer else { return }
        guard let trackId = Int(id) else { return }
        guard trackId != demuxer.audioStreamIndex else { return }
        if let ctx = demuxer.formatContext {
            for i in 0..<Int(ctx.pointee.nb_streams) {
                guard let st = ctx.pointee.streams[i], Int(st.pointee.index) == trackId else { continue }
                let cid = st.pointee.codecpar.pointee.codec_id
                if !Self.audioTrackIsSwitchable(codecID: cid,
                                                passthroughAvailable: _injectedAudioOutput?.supportsPassthrough == true) {
                    logger.warning("selectAudioTrack id=\(trackId) refused: no decoder for codec \(String(cString: avcodec_get_name(cid)), privacy: .public) — keeping current track")
                    return
                }
                break
            }
        }
        logger.info("selectAudioTrack id=\(trackId) — dispatching to background (zyno#171)")

        let demuxerRef = demuxer
        Self.audioSwitchQueue.async { [weak self] in
            guard let self else { return }
            if self.performAudioTrackSwitchFast(trackId: trackId, demuxer: demuxerRef) { return }
            self.performAudioTrackSwitch(id: id, trackId: trackId, demuxer: demuxerRef)
        }
    }

    /// 解码一个音频包并送入输出;在 audioDecodeQueue 上运行,负责释放该包。
    /// 实时解复用循环与切轨快路径(回放缓存包)共用,保证两条路径的变速/内容时间
    /// 记账完全一致(zyno#171)。
    private nonisolated func decodeAndEnqueueAudio(packet: UnsafeMutablePointer<AVPacket>,
                                                   decoder: FFmpegAudioDecoder?,
                                                   output: AudioUnitOutput?,
                                                   trackContent: Bool, packetPts: Double,
                                                   outputRate: Double) {
        let pcm = decoder?.decode(packet: packet)
        if let pcm {
            // Playback rate: time-stretch the decoded PCM
            // before it reaches the AudioQueue (zyno#99).
            // Emits 0..n frames; 1x bypasses untouched.
            let stretched = audioTempo.process(pcm)
            var contentPts = Double.nan
            if trackContent {
                contentPts = packetPts.isFinite ? packetPts : playedContentTrackerEnd
                playedContentTrackerEnd = contentPts + Double(pcm.sampleCount) / outputRate
            }
            for out in stretched {
                output?.enqueue(out, contentPts: contentPts)
            }
        }
        var p: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&p)
    }

    /// 切轨快路径(zyno#171):新轨的包已在备选缓存里覆盖当前播放位置 → 不 seek、
    /// 不 flush 视频,只换解码器与音频输出,把缓存包回放给新解码器。返回 false 表示
    /// 不满足条件(未启用/未命中/透传/暂停中),此时没有任何状态被改变,调用方走慢路径。
    private func performAudioTrackSwitchFast(trackId: Int, demuxer: any PacketDemuxing) -> Bool {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let newStream = Int32(trackId)
        // 先不持锁判断资格:解复用循环持 demuxLock 读网络,拿锁可能白等数秒(实测 3.4s),
        // 不合格就别去抢(zyno#171)。持锁后下面会再校验一次。
        guard altAudioStreams.contains(newStream), state.isPlaying else { return false }
        demuxLock.lock()
        guard altAudioStreams.contains(newStream), state.isPlaying, !isPassthroughActive else {
            demuxLock.unlock(); return false
        }
        let posSecs = Double(state.position.components.seconds)
            + Double(state.position.components.attoseconds) / 1e18
        guard altAudioCache.covers(stream: newStream, at: posSecs, tolerance: 0.3) else {
            demuxLock.unlock(); return false
        }
        let oldStream = Int(demuxer.audioStreamIndex)
        guard demuxer.selectAudioStream(by: trackId), let stream = demuxer.audioStream else {
            demuxLock.unlock(); return false
        }
        // 新轨若会走透传(压缩比特流直送),缓存回放不覆盖该路径 → 还原选择,走慢路径。
        if _injectedAudioOutput?.supportsPassthrough == true, demuxer.isPassthroughCodec,
           abs(state.rate - 1.0) < 0.001 {
            _ = demuxer.selectAudioStream(by: oldStream)
            demuxLock.unlock(); return false
        }
        logger.info("selectAudioTrack id=\(trackId) — fast path (cache hit, no seek)")

        audioUnitOutput?.stop()
        audioDecodeQueue.sync { audioDecoder?.flush() }
        let newDecoder = FFmpegAudioDecoder(stream: stream, sampleRate: 44100, channels: 2)
        audioDecoder = newDecoder
        discardAudioUntilPts = nil
        let cached = altAudioCache.take(stream: newStream, from: posSecs)
        refreshAltAudioStreams(demuxer)          // 旧轨变备选、新轨不再缓存

        let sr = newDecoder?.outputSampleRate ?? 44100
        let ch = newDecoder?.outputChannels ?? 2
        audioTempo.reset(sampleRate: sr, channels: ch)
        audioClock.reset(to: posSecs, sampleRate: sr)
        let newOutput = AudioUnitOutput(clock: audioClock, delaySecs: audioDelay)
        audioUnitOutput = newOutput
        newOutput.start(sampleRate: sr, channels: ch)
        newOutput.setPlaybackRate(state.rate)
        newOutput.pause()
        let trackContent = AudioUnitOutput.tracksPlayedContent
        let outputRate = Double(sr)
        for (pts, packet) in cached {
            audioDecodeQueue.async {
                self.decodeAndEnqueueAudio(packet: packet, decoder: newDecoder, output: newOutput,
                                           trackContent: trackContent, packetPts: trackContent ? pts : .nan,
                                           outputRate: outputRate)
            }
        }
        displayLoopLock.withLock {
            needsClockCalibration = true
            audioClockReady = false
        }
        let canResume = jitterBuffer.state == .playing
        demuxLock.unlock()

        syncController.reset()
        displayLoopLock.withLock { lastBypassPopTime = 0 }
        // 视频管线没有被 flush,jitter buffer 仍在 .playing,不会再有 .buffering→.playing
        // 的跃迁来恢复新输出,这里直接恢复(与 resumingContinuous 路径同理)。
        if canResume { newOutput.resume() }

        state.selectedAudioTrackId = trackId
        refreshAudioTracks()
        notifyStateChange()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        lastAudioSwitchPath = "fast"
        logger.notice("[diag] audioswitch path=fast total=\(String(format: "%.1f", ms), privacy: .public)ms cachedPackets=\(cached.count, privacy: .public)")
        return true
    }

    /// 切轨的重负载段(原 selectAudioTrack 函数体,zyno#171 拆出)。
    /// 在后台串行队列执行:demuxLock 阻塞 demux 循环是预期行为(切换期间
    /// 不需要 demux 出帧),主线程不等待。
    private func performAudioTrackSwitch(id: String, trackId: Int, demuxer: any PacketDemuxing) {
        logger.info("selectAudioTrack id=\(trackId)")
        // zyno#171 diag: per-phase wall time of the (background) track switch.
        let t0 = DispatchTime.now().uptimeNanoseconds
        func ms(_ since: UInt64) -> String {
            String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - since) / 1e6)
        }

        // zyno#171 diag: how far the demuxer has read ahead of the playhead —
        // sizes the alt-audio packet cache window (see AltAudioPacketCache).
        let readHead = maxDownloadedPts
        let playhead = Double(state.position.components.seconds)
            + Double(state.position.components.attoseconds) / 1e18
        logger.notice("[diag] audioswitch readahead=\(String(format: "%.1f", readHead - playhead), privacy: .public)s readHead=\(String(format: "%.1f", readHead), privacy: .public) playhead=\(String(format: "%.1f", playhead), privacy: .public)")

        // 1. Stop audio output
        audioUnitOutput?.stop()
        let tStop = ms(t0)

        // 2. Under lock: flush old decoder, switch stream, seek demuxer, create new decoder.
        // All decoder/stream mutations must happen inside demuxLock so the demux loop
        // (which holds demuxLock while processing audio packets) always sees a consistent
        // pair of (audioStreamIndex, audioDecoder). Creating the decoder outside the lock
        // caused the loop to feed new-stream packets into the stale old decoder.
        demuxLock.lock()
        let tLock = ms(t0)
        // Routed through audioDecodeQueue so this can't race a still-in-flight
        // decode() of an old-track packet on that queue.
        audioDecodeQueue.sync { audioDecoder?.flush() }
        audioDecoder = nil
        let tQueue = ms(t0)
        guard demuxer.selectAudioStream(by: trackId) else {
            demuxLock.unlock()
            logger.warning("selectAudioTrack: stream \(trackId) not found, recreating original output")
            recreateAudioOutput()
            return
        }
        // Millisecond precision: components.seconds alone truncates to whole
        // seconds, seeking up to 1s behind the position being watched (and
        // anchoring audioClock there).
        let posSecs = Double(state.position.components.seconds)
            + Double(state.position.components.attoseconds) / 1e18
        let tSeek0 = DispatchTime.now().uptimeNanoseconds
        _ = demuxer.seek(to: posSecs)
        let tSeek = ms(tSeek0)
        // zyno#171: 物理 seek 之后旧缓存作废;旧轨变备选、新轨不再缓存。
        altAudioCache.removeAll()
        refreshAltAudioStreams(demuxer)
        // zyno#142: same fine-seek arming as performDemuxerSeek — the track
        // switch re-seek lands on a GOP boundary too, and without the discard
        // the timeline re-anchors at the new landing (a second displacement
        // stacked on whatever the user already had). demuxLock is held, same
        // regime as the arming in performDemuxerSeek.
        if let landed = demuxer.lastSeekLandedPTS, landed <= posSecs,
           posSecs - landed > Self.discardArmGap {
            discardLock.withLock { discardVideoUntilPts = posSecs }
            discardAudioUntilPts = posSecs
            logger.info("fine-seek (track switch): discard \(String(format: "%.2f", posSecs - landed), privacy: .public)s (landed=\(String(format: "%.2f", landed), privacy: .public))")
        } else {
            discardLock.withLock { discardVideoUntilPts = nil }
            discardAudioUntilPts = nil
        }
        if let stream = demuxer.audioStream {
            audioDecoder = FFmpegAudioDecoder(stream: stream, sampleRate: 44100, channels: 2)
        }
        // Flush the video pipeline INSIDE demuxLock, same as performDemuxerSeek:
        // the demux loop is blocked here, so no post-landing frame can slip in
        // and be wiped by the flush, and no pre-switch frame in flight in the
        // decoder can survive past it.
        videoDecoder?.flush()
        jitterBuffer.flush()
        // The demuxer has just jumped physically. The demux loop resets the
        // PTSValidator ONLY on a physicalSeekGeneration change (see
        // performDemuxerSeek) — without this bump the validator keeps the
        // pre-switch baseline, reads the landing keyframe as a >5s anomaly and
        // enters its blind clock: every subsequent PTS is SYNTHESIZED as
        // (+1 frame duration), so the jitter buffer's PTS-ordered insertion
        // degenerates to decode order and B-frames display out of order. On
        // fast motion the picture then visibly rocks back and forth, and it
        // never recovers — predicted and real timestamps advance at the same
        // rate, so the |pts - predict| < 1s exit can never fire — until a real
        // seek resets the validator (2026-10-13 切音轨后画面来回晃: the
        // validator reset is exactly why seek "fixed" it).
        physicalSeekGeneration += 1
        seekLock.withLock { seekSerial += 1; seekLandedSerial = seekSerial }   // seeked synchronously above
        demuxLock.unlock()
        let tUnlock = ms(t0)

        // 4. Flush the rest of the pipeline (the video decoders and the jitter
        // buffer were flushed under demuxLock above).
        syncController.reset()
        displayLoopLock.withLock { lastBypassPopTime = 0 }
        _renderer.flush()

        // 5. Recreate audio output with new decoder's parameters
        let sr = audioDecoder?.outputSampleRate ?? 44100
        let ch = audioDecoder?.outputChannels ?? 2
        // New stream format → drop stale WSOLA windows (they were sized for the
        // old sr/ch; a mid-pipeline format change would corrupt the crossfade).
        // Safe off-queue here: the audioDecodeQueue.sync flush above drained any
        // in-flight process(), and the demux loop is blocked on demuxLock.
        audioTempo.reset(sampleRate: sr, channels: ch)
        audioClock.reset(to: posSecs, sampleRate: sr)
        audioUnitOutput = AudioUnitOutput(clock: audioClock, delaySecs: audioDelay)
        audioUnitOutput?.start(sampleRate: sr, channels: ch)
        // A fresh output starts at rate 1.0 — reapply the current rate or a
        // track switch silently drops playback speed.
        audioUnitOutput?.setPlaybackRate(state.rate)
        audioUnitOutput?.pause()
        displayLoopLock.withLock {
            needsClockCalibration = true
            audioClockReady = false
        }
        // Reset audioClockReady — TrueHD has significant decoder delay (first
        // several packets produce no PCM output), so audioClock stays frozen at
        // posSecs while video PTS advances.  Without this reset, the display
        // loop's freeze-ahead/skip-behind guard uses the stale audioClock and
        // produces a persistent A/V desync that never converges.  Mirrors the
        // seek()/play() paths which both set audioClockReady = false.
        displayLoopLock.withLock { audioClockReady = false }
        // Reset download tracking for the new seek position (same as seek()).
        maxDownloadedPts = posSecs

        // 6. Update state
        state.selectedAudioTrackId = trackId
        refreshAudioTracks()
        notifyStateChange()

        logger.info("selectAudioTrack done, new decoder sampleRate=\(self.audioDecoder?.outputSampleRate ?? 0)")
        lastAudioSwitchPath = "slow"
        logger.notice("[diag] audioswitch path=slow main=\(Thread.isMainThread, privacy: .public) stop=\(tStop, privacy: .public)ms lock=\(tLock, privacy: .public)ms audioQueue=\(tQueue, privacy: .public)ms seek=\(tSeek, privacy: .public)ms heldLock=\(tUnlock, privacy: .public)ms total=\(ms(t0), privacy: .public)ms")
    }

    public func selectSubtitle(id: String?) {
        guard let demuxer else { return }
        let trackId = id.flatMap(Int.init)

        // Log codec name of selected track for diagnostics
        if let resolvedId = trackId, let fmtCtx = demuxer.formatContext {
            let nb = Int(fmtCtx.pointee.nb_streams)
            for i in 0..<nb {
                guard let s = fmtCtx.pointee.streams[i],
                      Int(s.pointee.index) == resolvedId else { continue }
                let cp = s.pointee.codecpar.pointee
                let codecName = cp.codec_id != AV_CODEC_ID_NONE
                    ? String(cString: avcodec_get_name(cp.codec_id)) : "none"
                logger.notice("[sub] selectSubtitle trackId=\(resolvedId) codec=\(codecName) tb=\(s.pointee.time_base.num)/\(s.pointee.time_base.den)")
                break
            }
        } else {
            logger.notice("[sub] selectSubtitle → disabled")
        }

        // Switch subtitle stream under demuxLock so the demux loop sees the new
        // subtitleStreamIndex atomically with the next readPacket call.
        demuxLock.lock()
        demuxer.selectSubtitleStream(by: trackId)
        let resolvedIdx = demuxer.subtitleStreamIndex
        demuxLock.unlock()
        logger.notice("[sub] subtitleStreamIndex after select=\(resolvedIdx)")

        // Discard cues from the previous track.
        let hadText = state.currentSubtitleText != nil
        let hadImage = state.currentSubtitleImage != nil
        subtitleLock.withLock { subtitleCues.removeAll() }
        subtitleImageLock.withLock { subtitleImageCues.removeAll() }
        displayLoopLock.withLock { lastSubtitleImage = nil }
        state.currentSubtitleImage = nil
        state.currentSubtitleImageRect = .zero

        displayLoopLock.withLock { lastSubtitleText = nil }
        state.currentSubtitleText = nil
        state.selectedSubtitleTrackId = trackId
        if hadText || hadImage {
            notifyStateChange()
        }

        subtitleDecoder = nil
        assRenderer = nil
        if let resolvedTrackId = trackId {
            let nb = Int(demuxer.formatContext?.pointee.nb_streams ?? 0)
            for i in 0..<nb {
                guard let s = demuxer.formatContext?.pointee.streams[i],
                      Int(s.pointee.index) == resolvedTrackId else { continue }
                let codecId = s.pointee.codecpar.pointee.codec_id
                if codecId == AV_CODEC_ID_HDMV_PGS_SUBTITLE || codecId == AV_CODEC_ID_DVD_SUBTITLE {
                    subtitleDecoder = FFmpegSubtitleDecoder(
                        stream: s,
                        videoSize: CGSize(width: codedVideoWidth, height: codedVideoHeight)
                    )
                    logger.notice("[sub] PGS/DVD decoder created: \(self.subtitleDecoder != nil ? "OK" : "FAILED")")
                } else if codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA {
                    let r = Self.makeASSRenderer(
                        stream: s,
                        videoSize: CGSize(width: codedVideoWidth, height: codedVideoHeight)
                    )
                    assRenderer = r
                    logger.notice("[sub] ASS renderer \(r != nil ? "created" : "unavailable (no extradata)")")
                }
                break
            }
            // No seek here: seeking would flush the video pipeline and cause 2-5s
            // re-buffering on network streams, which users misread as "subtitle failed
            // to load." The demux loop is already 2s ahead of playback; future subtitle
            // packets for the newly selected stream are processed naturally. The
            // currently-active cue (whose packet was already read) may not appear until
            // the next subtitle event — an acceptable trade-off vs. visible re-buffering.
        }
    }

    private func recreateAudioOutput() {
        audioUnitOutput = AudioUnitOutput(clock: audioClock, delaySecs: audioDelay)
        if let dec = audioDecoder {
            audioUnitOutput?.start(sampleRate: dec.outputSampleRate, channels: dec.outputChannels)
            audioUnitOutput?.pause()
            // Fresh output defaults to rate 1.0 — carry the current rate over.
            audioUnitOutput?.setPlaybackRate(state.rate)
        }
    }

    private func refreshAudioTracks() {
        guard let fmtCtx = demuxer?.formatContext else { return }
        var tracks: [TrackInfo] = []
        let nb = Int(fmtCtx.pointee.nb_streams)
        for i in 0..<nb {
            guard let s = fmtCtx.pointee.streams[i] else { continue }
            let cp = s.pointee.codecpar.pointee
            guard cp.codec_type == AVMEDIA_TYPE_AUDIO else { continue }

            let codecName: String? = cp.codec_id != AV_CODEC_ID_NONE
                ? String(cString: avcodec_get_name(cp.codec_id))
                : nil

            var title: String?
            var lang: String?
            if let meta = s.pointee.metadata {
                if let e = av_dict_get(meta, "title", nil, 0), let v = e.pointee.value {
                    title = String(cString: v)
                }
                if let e = av_dict_get(meta, "language", nil, 0), let v = e.pointee.value {
                    lang = String(cString: v)
                }
            }

            let isDefault = (s.pointee.disposition & Int32(AV_DISPOSITION_DEFAULT)) != 0
            let isAtmos = (s.pointee.index == demuxer?.audioStreamIndex)
                ? (demuxer?.audioIsAtmos ?? false)
                : false

            tracks.append(TrackInfo(
                id: Int(s.pointee.index),
                title: title,
                lang: lang,
                codec: codecName,
                isDefault: isDefault,
                isAtmos: isAtmos
            ))
        }
        state.audioTracks = tracks
    }
    public func prepareForReuse() { stop() }

    public func addFrameSink(_ sink: any FrameSink) {
        renderConfigLock.withLock {
            _frameSinks.removeAll { $0.sink == nil }
            _frameSinks.append(WeakFrameSink(sink: sink))
        }
    }

    public func removeFrameSink(_ sink: any FrameSink) {
        renderConfigLock.withLock {
            _frameSinks.removeAll { $0.sink == nil || $0.sink === sink }
        }
    }

    // MARK: - Display link

    /// Demux thread: the demux loop just (re)read the stream's real fps.
    /// Debounces (first report, or ≥0.5fps delta for mixed-rate content) and
    /// hops the display-link update to main — CADisplayLink host objects are
    /// only poked from the main actor.
    private nonisolated func noteContentFrameRate(_ fps: Double) {
        let previous = contentFps
        contentFps = fps
        guard previous == 0 || abs(fps - previous) >= 0.5 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyFrameRateRange()
        }
    }

    /// Main actor: apply the content-derived preferredFrameRateRange to the
    /// live display link. No-op on macOS — CVDisplayLink follows the screen;
    /// display-mode switching there is a separate, larger project. No-op
    /// without a live link (applied again by startDisplayLink on next play).
    private func applyFrameRateRange() {
        #if os(iOS) || os(tvOS)
        guard let link = displayLink else { return }
        guard #available(iOS 15.0, tvOS 15.0, *) else { return }
        let range = FrameRateMatcher.displayRange(contentFps: contentFps, matchingEnabled: frameRateMatchingEnabled)
        // CAFrameRateRange is Float-typed on iOS/tvOS (the macOS variant of
        // CADisplayLink takes Double — irrelevant here, this file is #if'd).
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(range.minimum), maximum: Float(range.maximum), preferred: Float(range.preferred))
        #endif
    }

    private func startDisplayLink() {
        displayLinkStartWallTime = CACurrentMediaTime()
        displayLoopLock.withLock { firstTickLogged = false; displayLoopStopped = false }
        #if os(iOS) || os(tvOS)
        let proxy = DisplayLinkProxy(backend: self)
        displayLinkProxy = proxy
        displayLink?.invalidate()
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        // P2: run the display link on a dedicated background runloop thread
        // instead of .main — video presentation no longer competes with UI work.
        // The link is registered from inside the thread (a CADisplayLink must be
        // added to its runloop before that runloop is driven; creating it on the
        // main thread and handing it over is fine). stop()/pause()/seek() set
        // displayLoopStopped, the loop notices within 0.5s and exits.
        displayLink = link
        // zyno#106: match the refresh rate to the content fps (24p → 48Hz
        // preferred = even 2:2 gaps, no 3:2 judder) instead of pinning 120Hz.
        // Before the demux loop reports the real fps — and whenever
        // frameRateMatchingEnabled is off — this applies the legacy fixed
        // range, i.e. exactly the pre-#106 behavior.
        applyFrameRateRange()
        let thread = Thread { [weak self] in
            let rl = RunLoop.current
            link.add(to: rl, forMode: .common)
            while !(self?.displayLoopStopped ?? true) {
                rl.run(mode: .common, before: Date(timeIntervalSinceNow: 0.5))
            }
        }
        thread.name = "io.zyno.PlayerKit.displayLink"
        thread.qualityOfService = QualityOfService.userInteractive
        displayLinkThread = thread
        thread.start()
        #elseif os(macOS)
        // P2: CVDisplayLink's own high-priority thread drives displayNextFrame
        // directly — no main-queue hop. displayNextFrame only touches locked /
        // nonisolated state and hops UI writes via applyDisplayUpdate.
        if cvDisplayLink == nil {
            var link: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard let link else {
                logger.error("CVDisplayLinkCreateWithActiveCGDisplays FAILED")
                return
            }
            cvDisplayLink = link
        }
        // Always (re)bind the output callback to the current proxy.  pause()
        // keeps displayLinkProxy alive on macOS so the raw pointer stays valid
        // across pause/resume cycles; we still reset the callback each start
        // so a fresh proxy (after stop()) is correctly wired.
        let proxy = displayLinkProxy ?? DisplayLinkProxy(backend: self)
        displayLinkProxy = proxy
        let proxyPtr = Unmanaged.passUnretained(proxy).toOpaque()
        CVDisplayLinkSetOutputCallback(cvDisplayLink!, { _, _, _, _, _, ctx in
            guard let ctx else { return kCVReturnSuccess }
            let p = Unmanaged<DisplayLinkProxy>.fromOpaque(ctx).takeUnretainedValue()
            p.tick()
            return kCVReturnSuccess
        }, proxyPtr)
        if let cv = cvDisplayLink, !CVDisplayLinkIsRunning(cv) {
            CVDisplayLinkStart(cv)
        }
        // 兜底驱动(见 fallbackRenderTimer 属性注释)。displayNextFrame 幂等
        // (renderGate tryLock),双驱动无副作用;后台串行 queue 不再占主线程。
        fallbackRenderTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: displayFallbackQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.033)
        timer.setEventHandler { [weak self] in
            self?.displayNextFrame()
        }
        timer.resume()
        fallbackRenderTimer = timer
        #endif
    }
}

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
