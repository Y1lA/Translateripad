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
    private var lastConfigCheckTime: CFAbsoluteTime = 0
    private var lastKeepAliveTime: CFAbsoluteTime = 0
    private var emptyFramesCount: Int = 0

    private var activeMode: String = "menus"
    private var activeKey: String = ""
    private var activeModel: String = "gemma-4-26b-a4b-it"
    private var activeGame: String = "GTA 6"

    private var lastTokenSet: Set<String> = []
    private var lastPixelSignature: Int = 0
    private var dialogueHistory: [String] = []
    private var isTranslating: Bool = false

    private var cache: [String: String] = [
        "PLAY": "اللعب",
        "SETTINGS": "الإعدادات",
        "OPTIONS": "الخيارات",
        "GARAGE": "المرآب",
        "PROFILE": "الملف الشخصي",
        "CLUB": "النادي",
        "ITEM SHOP": "متجر العناصر",
        "CONTINUE": "متابعة",
        "RESUME": "استئناف",
        "BACK": "رجوع",
        "EXIT": "خروج",
        "QUIT": "خروج",
        "MAP": "الخريطة",
        "SAVE": "حفظ",
        "LOAD": "تحميل",
        "NEW GAME": "لعبة جديدة",
        "TRAINING": "التدريب",
        "CASUAL": "لعب عادي",
        "COMPETITIVE": "تنافسي",
        "TOURNAMENTS": "البطولات",
        "PRIVATE MATCH": "مباراة خاصة",
        "PLAY OFFLINE": "لعب أوفلاين",
        "QUICK PLAY": "لعب سريع",
        "CREATE PARTY": "إنشاء مجموعة",
        "STORE": "المتجر",
        "CAREER": "المسيرة",
        "STORY MODE": "طور القصة",
        "ONLINE": "أونلاين",
        "MISSIONS": "المهام",
        "CONTROLS": "التحكم",
        "AUDIO": "الصوت",
        "DISPLAY": "الشاشة"
    ]

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        lastTokenSet = []
        lastPixelSignature = 0
        emptyFramesCount = 0
        fetchConfigFromTV()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastConfigCheckTime > 4.0 {
            lastConfigCheckTime = now
            fetchConfigFromTV()
        }

        if now - lastProcessTime < 0.75 || isTranslating {
            return
        }
        lastProcessTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // فحص سريع لتغير البيكسلات لتخفيف الضغط ومنع القراءة المكررة
        let sig = quickPixelFingerprint(pixelBuffer)
        if sig == lastPixelSignature && !lastTokenSet.isEmpty {
            if now - lastKeepAliveTime > 3.5 {
                lastKeepAliveTime = now
                sendKeepAlive()
            }
            return
        }
        lastPixelSignature = sig

        var cgOrientation: CGImagePropertyOrientation = .up
        if let orientationNum = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let rawOrientation = CGImagePropertyOrientation(rawValue: orientationNum.uint32Value) {
            cgOrientation = rawOrientation
        }

        autoreleasepool {
            recognizeScreen(in: pixelBuffer, orientation: cgOrientation)
        }
    }

    private func quickPixelFingerprint(_ pixelBuffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var acc = 0
        let stepY = max(1, h / 10)
        for y in stride(from: stepY, to: h, by: stepY) {
            let row = y * bpr
            for col in stride(from: 40, to: min(bpr, 1200), by: 160) {
                acc = acc &+ (Int(ptr[row + col]) / 8)
            }
        }
        return acc
    }

    private func fetchConfigFromTV() {
        let defaults = UserDefaults(suiteName: appGroup)
        let tvIP = defaults?.string(forKey: "tvIP")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "192.168.0.138"
        guard let url = URL(string: "http://\(tvIP):8765/?getconfig=1") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let m = json["mode"] as? String, (m == "subtitles" || m == "menus") { self.activeMode = m }
            if let k = json["key"] as? String { self.activeKey = k.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let mod = json["model"] as? String, !mod.isEmpty { self.activeModel = mod }
            if let g = json["game"] as? String, !g.isEmpty { self.activeGame = g }
        }.resume()
    }

    private func isNoise(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < 3 { return true }
        let lower = t.lowercased()
        let ignoreList = ["remote play", "connected", "car speed", "ball speed", "fps", "ping"]
        if ignoreList.contains(where: { lower.contains($0) }) { return true }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return letters.count < 3
    }

    private func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        let inter = Double(a.intersection(b).count)
        let uni = Double(a.union(b).count)
        return inter / uni
    }

    private func recognizeScreen(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        let mode = activeMode
        let w = Double(CVPixelBufferGetWidth(pixelBuffer))
        let h = Double(CVPixelBufferGetHeight(pixelBuffer))
        let ratio = max(w, h) / max(1.0, min(w, h))
        let is4by3 = ratio < 1.55

        let request = VNRecognizeTextRequest { [weak self] req, _ in
            guard let self = self else { return }
            guard let observations = req.results as? [VNRecognizedTextObservation] else { return }

            var rawBlocks: [OCRBlock] = []
            for obs in observations {
                let box = obs.boundingBox
                if box.size.height < 0.017 { continue }
                guard let raw = obs.topCandidates(1).first?.string else { continue }
                let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if self.isNoise(clean) { continue }

                // تصحيح الدوران 180 درجة
                let x = 1.0 - Double(box.origin.x + box.size.width)
                var topY = Double(box.origin.y)
                if is4by3 {
                    topY = (topY - 0.095) / 0.81
                }
                if topY < 0.02 || topY > 0.95 { continue }

                rawBlocks.append(OCRBlock(text: clean, x: max(0.02, x), y: topY))
            }

            if rawBlocks.isEmpty {
                self.emptyFramesCount += 1
                if self.emptyFramesCount >= 2 && !self.lastTokenSet.isEmpty {
                    self.lastTokenSet = []
                    self.sendClearToTV()
                }
                return
            }

            self.emptyFramesCount = 0
            let limited = Array(rawBlocks.prefix(mode == "menus" ? 12 : 4))
            let newTokens = Set(limited.flatMap { $0.text.uppercased().split(separator: " ").map(String.init) })

            let now = CFAbsoluteTimeGetCurrent()
            if self.similarity(newTokens, self.lastTokenSet) >= 0.80 {
                if now - self.lastKeepAliveTime > 3.5 {
                    self.lastKeepAliveTime = now
                    self.sendKeepAlive()
                }
                return
            }

            self.lastTokenSet = newTokens
            self.lastKeepAliveTime = now

            if mode == "menus" {
                self.processMenuBlocks(limited)
            } else {
                // ترتيب سطور الحوار من الأعلى للأسفل
                let ordered = limited.sorted { $0.y < $1.y }
                let sentence = ordered.map { $0.text }.joined(separator: " ")
                self.processSubtitle(sentence)
            }
        }

        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        if mode == "subtitles" {
            // حصر القراءة في الشريط السفلي الأوسط للحوارات
            request.regionOfInterest = is4by3
                ? CGRect(x: 0.14, y: 0.11, width: 0.72, height: 0.19)
                : CGRect(x: 0.14, y: 0.03, width: 0.72, height: 0.19)
        } else {
            request.regionOfInterest = CGRect(x: 0.03, y: 0.07, width: 0.94, height: 0.86)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try? handler.perform([request])
    }

    private func processSubtitle(_ english: String) {
        if let cached = cache[english.uppercased()] ?? cache[english] {
            sendSingleToTV(arabic: cached)
            return
        }
        isTranslating = true
        translateDialogue(english) { [weak self] arabic in
            guard let self = self else { return }
            if let arabic = arabic, !arabic.isEmpty {
                self.cache[english] = arabic
                self.dialogueHistory.append(english)
                if self.dialogueHistory.count > 2 { self.dialogueHistory.removeFirst() }
                self.sendSingleToTV(arabic: arabic)
            }
            self.isTranslating = false
        }
    }

    private func processMenuBlocks(_ blocks: [OCRBlock]) {
        var needsTranslation: [OCRBlock] = []
        var finalMap: [String: String] = [:]

        for b in blocks {
            if let hit = cache[b.text.uppercased()] ?? cache[b.text] {
                finalMap[b.text] = hit
            } else {
                needsTranslation.append(b)
            }
        }

        if needsTranslation.isEmpty {
            let translations = blocks.map { finalMap[$0.text] ?? $0.text }
            sendBlocksToTV(blocks: blocks, translations: translations)
            return
        }

        isTranslating = true
        if !activeKey.isEmpty {
            let lines = needsTranslation.map { $0.text }
            translateBatchWithGemini(lines: lines) { [weak self] translated in
                guard let self = self else { return }
                if let translated = translated, translated.count == needsTranslation.count {
                    for (idx, item) in needsTranslation.enumerated() {
                        self.cache[item.text] = translated[idx]
                        finalMap[item.text] = translated[idx]
                    }
                    let allTranslations = blocks.map { finalMap[$0.text] ?? $0.text }
                    self.sendBlocksToTV(blocks: blocks, translations: allTranslations)
                    self.isTranslating = false
                } else {
                    self.batchFallbackTranslate(blocks: blocks, needs: needsTranslation, finalMap: finalMap)
                }
            }
        } else {
            batchFallbackTranslate(blocks: blocks, needs: needsTranslation, finalMap: finalMap)
        }
    }

    private func batchFallbackTranslate(blocks: [OCRBlock], needs: [OCRBlock], finalMap: [String: String]) {
        var updatedMap = finalMap
        let joined = needs.map { $0.text }.joined(separator: "\n")
        translateFreeFallback(text: joined) { [weak self] ar in
            guard let self = self else { return }
            if let ar = ar {
                let parts = ar.components(separatedBy: "\n")
                for (idx, item) in needs.enumerated() where idx < parts.count {
                    let tr = parts[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tr.isEmpty {
                        self.cache[item.text] = tr
                        updatedMap[item.text] = tr
                    }
                }
            }
            let allTranslations = blocks.map { updatedMap[$0.text] ?? $0.text }
            self.sendBlocksToTV(blocks: blocks, translations: allTranslations)
            self.isTranslating = false
        }
    }

    private func translateDialogue(_ text: String, completion: @escaping (String?) -> Void) {
        if !activeKey.isEmpty {
            let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(activeModel):generateContent?key=\(activeKey)"
            if let url = URL(string: urlStr) {
                let ctx = dialogueHistory.isEmpty ? "" : "Previous lines for context only: " + dialogueHistory.joined(separator: " | ") + "\n"
                let prompt = "You are translating live dialogue subtitles for the video game \(activeGame). \(ctx)Translate the following line into natural, punchy Arabic suitable for gaming (return ONLY the Arabic translation, no quotes or notes):\n\(text)"
                let payload: [String: Any] = ["contents": [["parts": [["text": prompt]]]]]

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 5
                request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

                URLSession.shared.dataTask(with: request) { data, response, _ in
                    if let http = response as? HTTPURLResponse, http.statusCode == 200,
                       let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let candidates = json["candidates"] as? [[String: Any]],
                       let content = candidates.first?["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]],
                       let translated = parts.first?["text"] as? String {
                        completion(translated.trimmingCharacters(in: .whitespacesAndNewlines))
                        return
                    }
                    self.translateFreeFallback(text: text, completion: completion)
                }.resume()
                return
            }
        }
        translateFreeFallback(text: text, completion: completion)
    }

    private func translateBatchWithGemini(lines: [String], completion: @escaping ([String]?) -> Void) {
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(activeModel):generateContent?key=\(activeKey)"
        guard let url = URL(string: urlStr) else { completion(nil); return }

        let numbered = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = "You are an expert Arabic translator for the video game \(activeGame). Translate each numbered menu item into very concise Arabic (1-3 words max, e.g. Play -> اللعب, Settings -> الإعدادات, Casual -> لعب عادي). Return ONLY a JSON array of Arabic strings in the exact same order.\nItems:\n" + numbered
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

    private func sendKeepAlive() {
        sendRawGet("keepalive=1")
    }

    private func sendClearToTV() {
        sendRawGet("clear=1")
    }

    private func sendSingleToTV(arabic: String) {
        let encoded = arabic.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        sendRawGet("text=\(encoded)")
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
        sendRawGet("items=\(encoded)")
    }

    private func sendRawGet(_ query: String) {
        let defaults = UserDefaults(suiteName: appGroup)
        let tvIP = defaults?.string(forKey: "tvIP")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "192.168.0.138"
        guard let url = URL(string: "http://\(tvIP):8765/?\(query)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request).resume()
    }
}
