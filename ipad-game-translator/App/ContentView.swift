import SwiftUI
import ReplayKit

struct ContentView: View {
    @AppStorage("tvIP", store: UserDefaults(suiteName: "group.com.tvtranslator.ipad"))
    private var tvIP: String = "192.168.0.138"

    @AppStorage("geminiKey", store: UserDefaults(suiteName: "group.com.tvtranslator.ipad"))
    private var geminiKey: String = ""

    @AppStorage("modelId", store: UserDefaults(suiteName: "group.com.tvtranslator.ipad"))
    private var modelId: String = "gemma-4-27b-it"

    @AppStorage("readerMode", store: UserDefaults(suiteName: "group.com.tvtranslator.ipad"))
    private var readerMode: String = "subtitles"

    @State private var statusMessage: String = "جاهز للتشغيل"

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("وضع القارئ الذكي")) {
                    Picker("ماذا يترجم؟", selection: $readerMode) {
                        Text("النصوص والحوارات فقط (أسفل الشاشة)").tag("subtitles")
                        Text("القوائم والنصوص (فوق كل كلمة)").tag("menus")
                    }
                    .pickerStyle(.inline)
                }

                Section(header: Text("إعدادات التلفزيون")) {
                    TextField("عنوان IP التلفزيون", text: $tvIP)
                        .keyboardType(.URL)
                        .autocapitalization(.none)

                    Button("إرسال جملة اختبار للتلفزيون") {
                        sendTestSubtitle()
                    }
                }

                Section(header: Text("إعدادات الذكاء الاصطناعي (Google AI Studio)")) {
                    SecureField("مفتاح Gemini API (موصى به لترجمة أفضل)", text: $geminiKey)
                    TextField("اسم الموديل", text: $modelId)
                        .autocapitalization(.none)
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
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func sendTestSubtitle() {
        let cleanIP = tvIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = "تم التحديث بنجاح!".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Test"
        guard let url = URL(string: "http://\(cleanIP):8765/?text=\(encoded)") else {
            statusMessage = "عنوان IP غير صحيح"
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        statusMessage = "جاري الإرسال..."

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    statusMessage = "فشل الاتصال: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    statusMessage = "تم الإرسال بنجاح!"
                } else {
                    statusMessage = "استجابة غير متوقعة من التلفزيون"
                }
            }
        }.resume()
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
