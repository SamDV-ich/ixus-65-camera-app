import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: CameraModel?
    private var terminating = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        if model?.busy == true {
            let alert = NSAlert(); alert.messageText = "Дождитесь завершения операции с камерой"; alert.informativeText = "Сейчас выполняется команда или скачивается фотография."; alert.runModal()
            return .terminateCancel
        }
        guard let model = model else { return .terminateNow }
        terminating = true
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
@main struct IXUSCameraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = CameraModel()
    var body: some Scene {
        WindowGroup("IXUS Camera") {
            CameraView(model: model).onAppear { delegate.model = model; model.start() }.onDisappear { model.stopLive() }
        }
        .defaultSize(width: 980, height: 700)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
struct CameraView: View {
    @ObservedObject var model: CameraModel
    @State private var confirmRelease = false
    @FocusState private var focusEditing: Bool
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "camera.fill").font(.title).foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("Canon IXUS 65").font(.title2.bold())
                    HStack {
                        Circle().fill(model.state != nil ? Color.green : (model.connectionKind == "occupied" ? Color.orange : Color.gray)).frame(width: 8, height: 8)
                        Text(model.connection).foregroundColor(.secondary)
                    }
                    if let state = model.state {
                        HStack {
                            Image(systemName: (state.batteryPercent ?? 50) < 15 ? "battery.0" : "battery.75")
                            if let percent = state.batteryPercent { Text("≈ \(percent)%") }
                            Text("\(Double(state.battery)/1000, specifier: "%.2f") В")
                            Text("• \(state.modeName)")
                        }.font(.callout).foregroundColor((state.batteryPercent ?? 100) < 15 ? .orange : .secondary)
                        .help("Примерный заряд по напряжению и порогам батареи в CHDK.")
                    }
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if model.connectionKind == "occupied" || model.connectionKind == "unavailable" {
                    Button("Освободить подключение…") { confirmRelease = true }.disabled(model.busy)
                }
                Button(model.state == nil ? "Подключить" : "Обновить") { model.perform("status") }.disabled(model.busy)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.92))
                        if let image = model.preview {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(8)
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "camera.viewfinder").font(.system(size: 46))
                                Text("Здесь появится снимок или Live View")
                            }.foregroundColor(.white.opacity(0.6))
                        }
                    }.frame(minWidth: 420, minHeight: 360)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let stale = model.live && (model.lastFrameAt.map { context.date.timeIntervalSince($0) > 3 } ?? true)
                                HStack {
                                    Circle().fill(model.live ? (stale ? Color.orange : Color.green) : Color.gray).frame(width: 8, height: 8)
                                    Text(stale ? "Live View • ожидание изображения" : model.previewLabel)
                                }
                            }
                        }
                        Spacer()
                        Button(model.live ? "Остановить Live View" : "Live View") { model.live ? model.stopLive() : model.startLive() }
                            .disabled(model.busy || model.state == nil || !model.liveSupported)
                    }
                    if let photo = model.lastPhoto {
                        Button("Показать последний JPEG в Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo]) }
                    }
                }
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                    SectionHelpHeader(title: "Съёмка", explanation: "JPEG сохраняется в выбранную папку на Mac. Оригинал остаётся на SD-карте.")
                    Button(action: { model.capture() }) { Label("Снять и сохранить", systemImage: "camera.fill").frame(maxWidth: .infinity).padding(.vertical, 8) }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || model.state == nil || !model.selectedMode.isPhoto)
                    if model.state?.record == false { Button("Режим съёмки") { model.perform("record") } }
                    Divider()
                    HStack {
                        Picker("Режим", selection: Binding(get: { model.mode }, set: { model.select("mode", value: $0) })) {
                            ForEach(model.availableModes) { item in Text(item.title).tag(item.id) }
                            if !model.availableModes.contains(where: { $0.id == model.mode }) {
                                Text(model.selectedMode.title).tag(model.mode)
                            }
                        }
                        HelpButton(title: "Режим: \(model.selectedMode.title)", explanation: model.selectedMode.explanation)
                    }
                    HStack {
                        Picker("Вспышка", selection: Binding(get: { model.flash }, set: { model.select("flash", value: $0) })) {
                            Text("Авто").tag(0); Text("Включена").tag(1); Text("Выключена").tag(2)
                        }

                    }
                    HStack {
                        Picker("Зум", selection: Binding(get: { model.zoom }, set: { model.select("zoom", value: $0) })) { ForEach(0..<7) { Text("\($0 + 1) / 7").tag($0) } }

                    }
                    }
                    Divider()
                    Group {
                    SectionHelpHeader(title: "Подсветка экрана камеры", explanation: "Переключатель задаёт поведение приложения, а не показывает фактическое состояние экрана. Команда повторяется примерно раз в секунду и после настроек. При смене режима подсветка может кратко загореться. Во время длительной операции выключение откладывается. При выходе подсветка включается обратно.")
                    Toggle("Держать подсветку выключенной", isOn: Binding(
                        get: { model.keepBacklightOff },
                        set: { model.perform("display", value: $0 ? 0 : 1) }
                    )).disabled(!model.displaySupported)
                    }
                    Divider()
                    SectionHelpHeader(title: "Фокус", explanation: "Введите дистанцию в миллиметрах и нажмите Enter или перейдите к другому полю — значение применится автоматически.\n\nДистанция приблизительная. Для проверки резкости используйте предпросмотр. Кнопка «Автофокус» снимает фиксацию фокуса.")
                    HStack {
                        TextField("Дистанция, мм", text: Binding(get: { model.focusText }, set: { model.editFocus($0) })).frame(width: 100).focused($focusEditing).onSubmit { focusEditing = false }
                            .onChange(of: focusEditing) { editing in
                                if editing { model.focusEditing = true } else { model.finishFocusEditing() }
                            }
                        Text("мм").foregroundColor(.secondary)

                    }
                    Button("Автофокус") { model.perform("autofocus") }
                    if let state = model.state {
                        Text("\(state.aflock == 1 ? "Фокус зафиксирован" : "Автофокус") • камера сообщает \(state.focus) мм").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                }.frame(width: 310).disabled(model.busy || model.state == nil)
            }
            HStack {
                Image(systemName: "folder")
                Text(model.folder.path).lineLimit(1).truncationMode(.middle).foregroundColor(.secondary)
                Spacer(); Button("Выбрать папку…", action: { model.chooseFolder() }).disabled(model.busy)
            }
            Text(model.message).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            DisclosureGroup("Журнал") {
                ScrollView { Text(model.events.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 80)
            }
        }.padding(22).frame(minWidth: 900, minHeight: 650)
        .alert("Освободить подключение камеры?", isPresented: $confirmRelease) {
            Button("Отмена", role: .cancel) {}
            Button("Освободить и подключиться") { model.perform("reclaim") }
        } message: {
            Text("Будет принудительно остановлена системная служба импорта фотографий macOS. Текущий импорт может прерваться. Другие приложения нужно закрыть самостоятельно. Передать их открытый сеанс этому приложению невозможно.")
        }
        .alert("Камера", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Понятно") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

struct SectionHelpHeader: View {
    let title: String
    let explanation: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            HelpButton(title: title, explanation: explanation)
            Spacer(minLength: 0)
        }
    }
}

struct HelpButton: View {
    let title: String
    let explanation: String
    @State private var showingHelp = false
    var body: some View {
        Button { showingHelp.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 16))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
        .accessibilityLabel("Пояснение: \(title)")
        .popover(isPresented: $showingHelp) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button { showingHelp = false } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Закрыть пояснение")
                }
                Text(explanation).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 320)
        }
    }
}
