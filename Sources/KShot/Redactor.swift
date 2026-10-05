import AppKit
import Vision

/// 自动打码：OCR 后用正则找出敏感信息，返回它们在图片中的位置（归一化，左下原点）
enum Redactor {
    struct Rule {
        let name: String
        let regex: NSRegularExpression
        var validate: ((String) -> Bool)? = nil
    }

    static let rules: [Rule] = {
        func r(_ name: String, _ pattern: String, _ validate: ((String) -> Bool)? = nil) -> Rule {
            Rule(name: name, regex: try! NSRegularExpression(pattern: pattern), validate: validate)
        }
        return [
            r("邮箱", #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),
            r("身份证", #"(?<![0-9A-Za-z])\d{6}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx](?![0-9A-Za-z])"#),
            r("银行卡", #"(?<![0-9])(?:\d[ \-]?){15,18}\d(?![0-9])"#) { s in
                let digits = s.filter(\.isNumber)
                return digits.hasPrefix("62") || luhn(digits)
            },
            r("手机号", #"(?<![0-9])(?:\+?86[ \-]?)?1[3-9]\d[ \-]?\d{4}[ \-]?\d{4}(?![0-9])"#),
            r("密钥", #"(?:sk-[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9\-]{10,}|AIza[0-9A-Za-z_\-]{35}|eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,})"#),
            // 长随机串（同时含字母和数字，32 位以上）
            r("令牌", #"(?<![A-Za-z0-9])[A-Za-z0-9_\-]{32,}(?![A-Za-z0-9])"#) { s in
                s.contains(where: \.isLetter) && s.contains(where: \.isNumber)
            },
        ]
    }()

    static func luhn(_ digits: String) -> Bool {
        let nums = digits.compactMap(\.wholeNumberValue)
        guard nums.count >= 13 else { return false }
        var sum = 0
        for (i, d) in nums.reversed().enumerated() {
            if i % 2 == 1 {
                let x = d * 2
                sum += x > 9 ? x - 9 : x
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }

    /// 在一行文字里找出所有敏感片段的范围（去掉被更长片段覆盖的重复匹配）
    static func matches(in text: String) -> [(String, Range<String.Index>)] {
        var found: [(String, Range<String.Index>)] = []
        let ns = text as NSString
        for rule in rules {
            for m in rule.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(m.range, in: text) else { continue }
                let s = String(text[range])
                if let v = rule.validate, !v(s) { continue }
                if found.contains(where: { $0.1.overlaps(range) }) { continue }
                found.append((rule.name, range))
            }
        }
        return found
    }

    static func findSensitive(in image: CGImage) async throws -> [CGRect] {
        try await withCheckedThrowingContinuation { cont in
            let request = VNRecognizeTextRequest { request, error in
                if let error { cont.resume(throwing: error); return }
                var boxes: [CGRect] = []
                for obs in (request.results as? [VNRecognizedTextObservation]) ?? [] {
                    guard let cand = obs.topCandidates(1).first else { continue }
                    for (name, range) in matches(in: cand.string) {
                        if let box = try? cand.boundingBox(for: range)?.boundingBox {
                            boxes.append(box)
                            Log.info("redact \(name): \(box)")
                        }
                    }
                }
                cont.resume(returning: boxes)
            }
            request.recognitionLevel = .accurate
            // 不做语言纠错，避免把数字串“纠正”掉
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) } catch { cont.resume(throwing: error) }
            }
        }
    }
}
