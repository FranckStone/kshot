import AppKit
import Vision

/// 基于 Vision 的文字识别（中英文）
enum TextRecognizer {
    struct Line {
        let text: String
        let box: CGRect // 归一化坐标，左下原点
    }

    /// 启动时后台预热一次，避免首次识别等待模型加载
    static func warmUp() {
        Task.detached(priority: .background) {
            guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let img = ctx.makeImage() else { return }
            _ = try? await recognize(img)
            Log.info("ocr warmed up")
        }
    }

    static func recognize(_ image: CGImage) async throws -> [Line] {
        try await withCheckedThrowingContinuation { cont in
            let request = VNRecognizeTextRequest { request, error in
                if let error { cont.resume(throwing: error); return }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { obs -> Line? in
                    guard let best = obs.topCandidates(1).first else { return nil }
                    return Line(text: best.string, box: obs.boundingBox)
                }
                cont.resume(returning: Self.sorted(lines))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// 识别图片里的二维码 / 条形码，返回内容（去重，保持从上到下）
    static func detectCodes(_ image: CGImage) async -> [String] {
        await withCheckedContinuation { cont in
            let request = VNDetectBarcodesRequest { request, _ in
                let obs = ((request.results as? [VNBarcodeObservation]) ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                var seen = Set<String>()
                let payloads = obs.compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
                cont.resume(returning: payloads)
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) } catch { cont.resume(returning: []) }
            }
        }
    }

    /// 按阅读顺序排序：先按行（从上到下），同一行内从左到右
    private static func sorted(_ lines: [Line]) -> [Line] {
        let byTop = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[Line]] = []
        for line in byTop {
            if var last = rows.last, let ref = last.first,
               abs(ref.box.midY - line.box.midY) < max(ref.box.height, line.box.height) * 0.6 {
                last.append(line)
                rows[rows.count - 1] = last
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    static func joined(_ lines: [Line]) -> String {
        // 同一行的片段用空格连接，不同行换行
        var result: [String] = []
        var currentRow: [Line] = []
        for line in lines {
            if let ref = currentRow.first,
               abs(ref.box.midY - line.box.midY) < max(ref.box.height, line.box.height) * 0.6 {
                currentRow.append(line)
            } else {
                if !currentRow.isEmpty { result.append(currentRow.map(\.text).joined(separator: " ")) }
                currentRow = [line]
            }
        }
        if !currentRow.isEmpty { result.append(currentRow.map(\.text).joined(separator: " ")) }
        return result.joined(separator: "\n")
    }
}
