import Foundation

/// Cheap running statistics for the renderer: frames per second, milliseconds per draw and
/// process CPU share, all exponentially smoothed. Call `begin()`/`end()` around each draw.
@MainActor
public final class PerfProbe {
    public private(set) var fps: Double = 0
    public private(set) var msPerDraw: Double = 0
    public private(set) var cpuPercent: Double = 0
    public private(set) var frames = 0

    private var lastFrame: Double?
    private var drawStart: Double = 0
    private var cpuLastWall: Double = 0
    private var cpuLastTime: Double = 0

    public init() {}

    public func begin() {
        drawStart = now()
    }

    public func end() {
        let t = now()
        let ms = (t - drawStart) * 1000
        msPerDraw = msPerDraw == 0 ? ms : msPerDraw * 0.9 + ms * 0.1
        if let last = lastFrame {
            let dt = t - last
            if dt > 0 {
                let f = 1 / dt
                fps = fps == 0 ? f : fps * 0.9 + f * 0.1
            }
        }
        lastFrame = t
        frames += 1
        if t - cpuLastWall >= 1 {
            let cpu = Self.processCPUSeconds()
            if cpuLastWall > 0 {
                cpuPercent = (cpu - cpuLastTime) / (t - cpuLastWall) * 100
            }
            cpuLastWall = t
            cpuLastTime = cpu
        }
    }

    private func now() -> Double { Date.timeIntervalSinceReferenceDate }

    /// User + system CPU seconds consumed by this process.
    public static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + sys
    }

    public var summary: String {
        String(format: "%.0f fps · %.2f ms/draw · %.1f%% cpu", fps, msPerDraw, cpuPercent)
    }
}
