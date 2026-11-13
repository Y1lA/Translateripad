import ReplayKit
import Vision
import Foundation

class SampleHandler: RPBroadcastSampleHandler {

    private let appGroup = "group.com.tvtranslator.ipad"
    private var lastProcessTime: CFAbsoluteTime = 0
    private var lastEnglishText: String = ""
    private var isTranslating: Bool = false
    private var cache: [String: String] = [:]

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        lastEnglishText = ""
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastProcessTime < 0.7 || isTranslating {
            return
        }
        lastProcessTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        recognizeSubtitle(in: pixelBuffer)
    }

    private func recognizeSubtitle(in pixelBuffer: CVPixelBuffer) {
        let request = VNRecognizeTextRequest { [weak self] req, _ in
            guard let self = self else { return }
            guard let observations = req.results as? [VNRecognizedTextObservation] else { return }

            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            let combined = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

            guard combined.count >= 3 else { return }
            if combined == self.lastEnglishText { return }

            self.lastEnglishText = combined
            self.translateAndSend(english: combined)
        }

        request.recognitionLevel = .fast
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        // أسفل الشاشة (25% السفلية) حيث تظهر ترجمة الألعاب
        request.regionOfInterest = CGRect(x: 0.08, y: 0.03, width: 0.84, height: 0.24)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])
    }

    private func translateAndSend(english: String) {
        if let cached = cache[english] {
            sendToTV(arabic: cached)
            return
        }

        isTranslating = true
        let defaults = UserDefaults(suiteName: appGroup)
        let apiKey = defaults?.string(forKey: "geminiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelId = defaults?.string(forKey: "modelId")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "gemma-4-27b-it"

        if !apiKey.isEmpty {
            translateWithGemini(text: english, apiKey: apiKey, modelId: modelId) { [weak self] arabic in
                guard let self = self else { return }
                if let arabic = arabic, !arabic.isEmpty {
                    self.cache[english] = arabic
                    self.sendToTV(arabic: arabic)
                    self.isTranslating = false
                } else {
                    self.translateFreeFallback(text: english) { fallback in
                        if let fallback = fallback {
                            self.cache[english] = fallback
                            self.sendToTV(arabic: fallback)
                        }
                        self.isTranslating = false
                    }
                }
            }
        } else {
            translateFreeFallback(text: english) { [weak self] arabic in
                guard let self = self else { return }
                if let arabic = arabic {
                    self.cache[english] = arabic
                    self.sendToTV(arabic: arabic)
                }
                self.isTranslating = false
            }
        }
    }

    private func translateWithGemini(text: String, apiKey: String, modelId: String, completion: @escaping (String?) -> Void) {
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlStr) else { completion(nil); return }

        let prompt = "Translate this video game subtitle to natural, concise Arabic (return ONLY the Arabic text): \(text)"
        let payload: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let translated = parts.first?["text"] as? String else {
                completion(nil)
                return
            }
            completion(translated.trimmingCharacters(in: .whitespacesAndNewlines))
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

    private func sendToTV(arabic: String) {
        let defaults = UserDefaults(suiteName: appGroup)
        let tvIP = defaults?.string(forKey: "tvIP")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "192.168.0.138"
        guard let url = URL(string: "http://\(tvIP):8765/") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.httpBody = arabic.data(using: .utf8)
        URLSession.shared.dataTask(with: request).resume()
    }
}
