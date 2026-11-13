import SwiftUI
import ReplayKit

struct ContentView: View {
    @AppStorage("tvIP", store: UserDefaults(suiteName: "group.com.tvtranslator.ipad"))
    private var tvIP: String = "192.168.0.138"

    @AppStorage("geminiKey", store: UserDefaults(suiteName: "group.com.tvtranslator.ipad"))
    private var geminiKey: String = ""

    @AppStorage("modelId", store: UserDefaults(suiteName: "group.com.tvtranslator.ipad"))
    private var modelId: String = "gemma-4-27b-it"

    @State private var statusMessage: String = "جاهز للتشغيل"

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("إعدادات التلفزيون")) {
                    TextField("عنوان IP التلفزيون", text: $tvIP)
                        .keyboardType(.URL)
                        .autocapitalization(.none)

                    Button("إرسال جملة اختبار للتلفزيون") {
                        sendTestSubtitle()
                    }
                }

                Section(header: Text("إعدادات الذكاء الاصطناعي (Google AI Studio)")) {
                    SecureField("مفتاح Gemini API (اختياري)", text: $geminiKey)
                    TextField("اسم الموديل", text: $modelId)
                        .autocapitalization(.none)
                    Text("اترك المفتاح فارغاً للترجمة السريعة المجانية، أو ضع مفتاح AI Studio مع موديل مثل gemma-4-27b-it لترجمة أدق للهجة الشوارع.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("تشغيل قارئ الشاشة")) {
                    HStack {
                        Text("اضغط الدائرة لبدء قراءة الترجمة:")
                        Spacer()
                        BroadcastPickerRepresentable(bundleId: "com.tvtranslator.GameTranslator.GameTranslatorBroadcast")
                            .frame(width: 56, height: 56)
                    }
                    Text("بعد الضغط، اختر «مترجم الشاشة» واضغط Start Broadcast، ثم افتح تطبيق PS Remote Play.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("الحالة")) {
                    Text(statusMessage)
                        .foregroundColor(.blue)
                }
            }
            .navigationTitle("مترجم GTA 6")
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func sendTestSubtitle() {
        let cleanIP = tvIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "http://\(cleanIP):8765/") else {
            statusMessage = "عنوان IP غير صحيح"
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = "تم الربط بنجاح مع الآيباد!".data(using: .utf8)
        statusMessage = "جاري الإرسال..."

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    statusMessage = "فشل الاتصال: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    statusMessage = "تم الإرسال بنجاح! تأكد من ظهور النص على التلفزيون."
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
