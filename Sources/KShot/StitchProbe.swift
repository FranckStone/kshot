import AppKit

/// --vision-probe：确认 Vision 位移的符号与精度，并测耗时
enum StitchProbe {
    static func run() {
        guard let tall = StitchTest.makeTallImage(width: 1170, height: 4000) else { return }
        let est = VisionOffsetEstimator()
        let h = 1200
        for shift in [0, 3, 37, 120, 400, -3, -37, -80, -120, -400] {
            guard let prev = tall.cropping(to: CGRect(x: 0, y: 500, width: 1170, height: h)),
                  let cur = tall.cropping(to: CGRect(x: 0, y: 500 + shift, width: 1170, height: h)) else { continue }
            let t0 = Date()
            let e = est.estimate(current: cur, previous: prev)
            let ef = est.estimateFast(current: cur, previous: prev)
            print("   fast: \(ef.map { String(format: "%.2f %@", $0.dy, $0.source) } ?? "nil")")
            let ms = Date().timeIntervalSince(t0) * 1000
            print(String(format: "probe shift=%d -> dy=%@ src=%@ conf=%@ %.1fms", shift,
                         e.map { String(format: "%.2f", $0.dy) } ?? "nil", e?.source ?? "-", e.map { String(format: "%.2f", $0.confidence) } ?? "-", ms))
        }
    }
}
