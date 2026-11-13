import SwiftUI
import ReplayKit

struct ContentView: View {
    @AppStorage("tvIP", store: UserDefaults(suiteName: "group.com.tvtranslator.ipad"))
    private var tvIP: String = "192.168.0.138"

    @AppStorage("geminiKey", store: UserDefaults(suiteName: "group.com.tvtranslator.ipad"))
    private var geminiKey: String = ""

    @AppStorage("modelId", store: UserDefaults(suiteName: "group.com.tvtranslator.ipad"))
    private var modelId: String = "gemma-4-26b-a4b-it"

    @AppStorage("gameName", store: UserDefaults(suiteName: "group.com.tvtranslator.ipad"))
    private var gameName: String = "GTA 6"

    @AppStorage("readerMode", store: UserDefaults(suiteName: "group.com.tvtranslator.ipad"))
    private var readerMode: String = "menus"

    @State private var statusMessage: String = "جاهز للتشغيل"

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("وضع القارئ الذكي")) {
                    Picker("ماذا يترجم؟", selection: $readerMode) {
                        Text("القوائم والنصوص (ملصقات فوق كل كلمة)").tag("menus")
                        Text("الحوارات والقصص فقط (شريط سينمائي بالأسفل)").tag("subtitles")
                    }
                    .pickerStyle(.inline)
                    .onChange(of: readerMode) { _ in syncConfigToTV() }
                }

                Section(header: Text("سياق اللعبة")) {
                    TextField("اسم اللعبة (مثل: GTA 6)", text: $gameName)
                        .onChange(of: gameName) { _ in syncConfigToTV() }
                }

                Section(header: Text("إعدادات التلفزيون")) {
                    TextField("عنوان IP التلفزيون", text: $tvIP)
                        .keyboardType(.URL)
                        .autocapitalization(.none)

                    Button("حفظ الإعدادات وإرسال اختبار للتلفزيون") {
                        sendTestSubtitle()
                    }
                }

                Section(header: Text("الذكاء الاصطناعي (Google AI Studio)")) {
                    SecureField("مفتاح Gemini API", text: $geminiKey)
                        .onChange(of: geminiKey) { _ in syncConfigToTV() }
                    TextField("اسم الموديل", text: $modelId)
                        .autocapitalization(.none)
                        .onChange(of: modelId) { _ in syncConfigToTV() }
                }

                Section(header: Text("تشغيل قارئ الشاشة")) {
                    HStack {
                        Text("اضغط الدائرة لبدء قراءة الترجمة:")
                        Spacer()
                        BroadcastPickerRepresentable(bundleId: "com.tvtranslator.GameTranslator.GameTranslatorBroadcast")
                            .frame(width: 56, height: 56)
                    }
                }

                Section(header: Text("الحالة")) {
                    Text(statusMessage)
                        .foregroundColor(.blue)
                }
            }
            .navigationTitle("مترجم الألعاب الذكي")
            .onAppear { syncConfigToTV() }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func syncConfigToTV(completion: ((Bool) -> Void)? = nil) {
        let cleanIP = tvIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = readerMode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "menus"
        let k = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let mod = modelId.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "gemma-4-26b-a4b-it"
        let g = gameName.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "GTA 6"

        guard let url = URL(string: "http://\(cleanIP):8765/?setconfig=1&mode=\(m)&key=\(k)&model=\(mod)&game=\(g)") else {
            completion?(false)
            return
        }
        URLSession.shared.dataTask(with: url) { _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            completion?(ok)
        }.resume()
    }

    private func sendTestSubtitle() {
        statusMessage = "جاري حفظ الإعدادات والاختبار..."
        syncConfigToTV { _ in
            let cleanIP = tvIP.trimmingCharacters(in: .whitespacesAndNewlines)
            let modeLabel = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "الترجمة العادية" : "الذكاء الاصطناعي"
            let encoded = "تم التحديث بنجاح (\(modeLabel))!".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Test"
            guard let url = URL(string: "http://\(cleanIP):8765/?text=\(encoded)") else {
                DispatchQueue.main.async { statusMessage = "عنوان IP غير صحيح" }
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 4

            URLSession.shared.dataTask(with: request) { _, response, error in
                DispatchQueue.main.async {
                    if let error = error {
                        statusMessage = "فشل الاتصال: \(error.localizedDescription)"
                    } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        statusMessage = "تم الحفظ والإرسال بنجاح (\(modeLabel))!"
                    } else {
                        statusMessage = "استجابة غير متوقعة من التلفزيون"
                    }
                }
            }.resume()
        }
    }
}

struct BroadcastPickerRepresentable: UIViewRepresentable {
    let bundleId: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        picker.preferredExtension = bundleId
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
