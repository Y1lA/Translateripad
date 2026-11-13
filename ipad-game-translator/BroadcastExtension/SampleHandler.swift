import ReplayKit
import Vision
import Foundation
import ImageIO

struct OCRBlock {
    let text: String
    let x: Double
    let y: Double
}

class SampleHandler: RPBroadcastSampleHandler {

    private let appGroup = "group.com.tvtranslator.ipad"
    private var lastProcessTime: CFAbsoluteTime = 0
    private var lastSignature: String = ""
    private var isTranslating: Bool = false
    private var cache: [String: String] = [:]

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        lastSignature = ""
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastProcessTime < 0.95 || isTranslating {
            return
        }
        lastProcessTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var cgOrientation: CGImagePropertyOrientation = .up
        if let orientationNum = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let rawOrientation = CGImagePropertyOrientation(rawValue: orientationNum.uint32Value) {
            cgOrientation = rawOrientation
        }

        autoreleasepool {
            recognizeScreen(in: pixelBuffer, orientation: cgOrientation)
        }
    }

    private func isNoise(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < 2 { return true }
        let lower = t.lowercased()
        if lower.contains("remote play") || lower.contains("connected") { return true }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return letters.count < 2
    }

    private func recognizeScreen(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        let defaults = UserDefaults(suiteName: appGroup)
        let mode = defaults?.string(forKey: "readerMode") ?? "subtitles"

        let w = Double(CVPixelBufferGetWidth(pixelBuffer))
        let h = Double(CVPixelBufferGetHeight(pixelBuffer))
        let is4by3 = (max(w, h) / max(1.0, min(w, h))) < 1.55

        let request = VNRecognizeTextRequest { [weak self] req, _ in
            guard let self = self else { return }
            guard let observations = req.results as? [VNRecognizedTextObservation] else { return }

            var blocks: [OCRBlock] = []
            for obs in observations {
                guard let raw = obs.topCandidates(1).first?.string else { continue }
                let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if self.isNoise(clean) { continue }

                let box = obs.boundingBox
                let x = Double(box.origin.x)
                var topY = 1.0 - Double(box.origin.y + box.size.height)

                if is4by3 {
                    topY = (topY - 0.125) / 0.75
                }
                if topY < 0.0 || topY > 1.0 { continue }

                blocks.append(OCRBlock(text: clean, x: x, y: topY))
            }

            guard !blocks.isEmpty else { return }
            let limited = Array(blocks.prefix(mode == "menus" ? 10 : 4))
            let signature = mode + ":" + limited.map { $0.text }.joined(separator: "|")
            if signature == self.lastSignature { return }
            self.lastSignature = signature

            if mode == "menus" {
                self.processMenuBlocks(limited)
            } else {
                let sentence = limited.map { $0.text }.joined(separator: " ")
                self.processSubtitle(sentence)
            }
        }

        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        if mode == "subtitles" {
            request.regionOfInterest = is4by3
                ? CGRect(x: 0.12, y: 0.13, width: 0.76, height: 0.22)
                : CGRect(x: 0.12, y: 0.03, width: 0.76, height: 0.22)
        } else {
            request.regionOfInterest = CGRect(x: 0.02, y: 0.05, width: 0.96, height: 0.90)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try? handler.perform([request])
    }

    private func processSubtitle(_ english: String) {
        if let cached = cache[english] {
            sendSingleToTV(arabic: cached)
            return
        }
        isTranslating = true
        translateLine(english) { [weak self] arabic in
            guard let self = self else { return }
            if let arabic = arabic, !arabic.isEmpty {
                self.cache[english] = arabic
                self.sendSingleToTV(arabic: arabic)
            }
            self.isTranslating = false
        }
    }

    private func processMenuBlocks(_ blocks: [OCRBlock]) {
        isTranslating = true
        let defaults = UserDefaults(suiteName: appGroup)
        let apiKey = defaults?.string(forKey: "geminiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelId = defaults?.string(forKey: "modelId")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "gemma-4-27b-it"

        if !apiKey.isEmpty {
            let lines = blocks.map { $0.text }
            translateBatchWithGemini(lines: lines, apiKey: apiKey, modelId: modelId) { [weak self] translated in
                guard let self = self else { return }
                if let translated = translated, translated.count == blocks.count {
                    self.sendBlocksToTV(blocks: blocks, translations: translated)
                    self.isTranslating = false
                } else {
                    self.fallbackMenuTranslate(blocks)
                }
            }
        } else {
            fallbackMenuTranslate(blocks)
        }
    }

    private func fallbackMenuTranslate(_ blocks: [OCRBlock]) {
        let group = DispatchGroup()
        var results = Array(repeating: "", count: blocks.count)
        for (idx, b) in blocks.enumerated() {
            if let cached = cache[b.text] {
                results[idx] = cached
                continue
            }
            group.enter()
            translateFreeFallback(text: b.text) { [weak self] ar in
                let val = ar ?? b.text
                self?.cache[b.text] = val
                results[idx] = val
                group.leave()
            }
        }
        group.notify(queue: .global()) { [weak self] in
            self?.sendBlocksToTV(blocks: blocks, translations: results)
            self?.isTranslating = false
        }
    }

    private func translateLine(_ text: String, completion: @escaping (String?) -> Void) {
        let defaults = UserDefaults(suiteName: appGroup)
        let apiKey = defaults?.string(forKey: "geminiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelId = defaults?.string(forKey: "modelId")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "gemma-4-27b-it"

        if !apiKey.isEmpty {
            translateBatchWithGemini(lines: [text], apiKey: apiKey, modelId: modelId) { res in
                if let first = res?.first, !first.isEmpty {
                    completion(first)
                } else {
                    self.translateFreeFallback(text: text, completion: completion)
                }
            }
        } else {
            translateFreeFallback(text: text, completion: completion)
        }
    }

    private func translateBatchWithGemini(lines: [String], apiKey: String, modelId: String, completion: @escaping ([String]?) -> Void) {
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlStr) else { completion(nil); return }

        let numbered = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = "You are an expert Arabic video game translator. Translate each numbered English game menu item or subtitle into concise, natural Arabic (for example: Play -> اللعب, Settings -> الإعدادات, Continue -> متابعة). Return ONLY a JSON array of Arabic strings in the exact same order, with no extra text.\nItems:\n" + numbered
        let payload: [String: Any] = ["contents": [["parts": [["text": prompt]]]]]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 6
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  var rawText = parts.first?["text"] as? String else {
                completion(nil)
                return
            }
            rawText = rawText
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let arrData = rawText.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: arrData) as? [String] {
                completion(arr)
            } else {
                completion(nil)
            }
        }.resume()
    }

    private func translateFreeFallback(text: String, completion: @escaping (String?) -> Void) {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=ar&dt=t&q=\(encoded)") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let sentences = arr.first as? [Any] else {
                completion(nil)
                return
            }
            let result = sentences.compactMap { ($0 as? [Any])?.first as? String }.joined()
            completion(result.isEmpty ? nil : result)
        }.resume()
    }

    private func sendSingleToTV(arabic: String) {
        let defaults = UserDefaults(suiteName: appGroup)
        let tvIP = defaults?.string(forKey: "tvIP")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "192.168.0.138"
        let encoded = arabic.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "http://\(tvIP):8765/?text=\(encoded)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request).resume()
    }

    private func sendBlocksToTV(blocks: [OCRBlock], translations: [String]) {
        var items: [[String: Any]] = []
        for (i, b) in blocks.enumerated() where i < translations.count {
            items.append([
                "t": translations[i],
                "x": round(b.x * 1000) / 1000,
                "y": round(b.y * 1000) / 1000
            ])
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: items),
              let jsonStr = String(data: jsonData, encoding: .utf8),
              let encoded = jsonStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }

        let defaults = UserDefaults(suiteName: appGroup)
        let tvIP = defaults?.string(forKey: "tvIP")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "192.168.0.138"
        guard let url = URL(string: "http://\(tvIP):8765/?items=\(encoded)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request).resume()
    }
}
