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
        Settings {
            CameraSettingsView(model: model)
        }
    }
}
struct CameraView: View {
    @ObservedObject var model: CameraModel
    @State private var showingCameraMenu = false
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
                            PreviewImage(image: image, nativeSize: model.previewIsLive && model.previewNativeSize).padding(8)
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
                    }
                    if let photo = model.lastPhoto {
                        Button("Показать последний JPEG в Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo]) }
                    }
                }
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                    SectionHelpHeader(title: "Съёмка", explanation: "JPEG сохраняется в выбранную папку на Mac. Оригинал остаётся на SD-карте.")
                    Button(action: { model.capture() }) { Label("Снять • " + model.saving.destinationTitle, systemImage: "camera.fill").frame(maxWidth: .infinity).padding(.vertical, 8) }
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
                    if !model.options("flash").isEmpty {
                    HStack {
                        Picker("Вспышка", selection: Binding(get: { model.flash }, set: { model.select("flash", value: $0) })) {
                            ForEach(model.options("flash"), id: \.self) { value in
                                Text(value == 0 ? "Авто" : (value == 1 ? "Включена" : "Выключена")).tag(value)
                            }
                        }

                    }
                    }
                    if !model.options("zoom").isEmpty {
                    HStack {
                        Picker("Зум", selection: Binding(get: { model.zoom }, set: { model.select("zoom", value: $0) })) { ForEach(0..<7) { Text("\($0 + 1) / 7").tag($0) } }

                    }
                    }
                    }
                    Group {
                        CameraExposureControls(model: model)
                        Button("Все настройки камеры…") { showingCameraMenu = true }
                            .disabled(!model.liveSupported)
                    }
                    Divider()
                    SectionHelpHeader(title: "Фокус", explanation: "Выберите диапазон, затем нажмите «Навести резкость». Камера выполнит автофокусировку без снимка.\n\n«Зафиксировать» удерживает найденный фокус, чтобы камера не меняла его при съёмке. Отключите фиксацию для обычного автофокуса. Для пересъёмки плёнки удобно один раз навести резкость и зафиксировать её. Ручная дистанция находится в дополнительных настройках и является приблизительной.")
                    if !model.options("focusrange").isEmpty {
                        Picker("Диапазон", selection: Binding(get: { model.focusRange ?? -1 }, set: { model.select("focusrange", value: $0) })) {
                            ForEach(model.options("focusrange"), id: \.self) { value in
                                Text(value == 0 ? "Обычный" : (value == 1 ? "Макро" : "Бесконечность")).tag(value)
                            }
                            if let current = model.focusRange, !model.options("focusrange").contains(current) { Text("Другой (\(current))").tag(current) }
                            if model.focusRange == nil { Text("Недоступно").tag(-1) }
                        }.disabled(model.focusRange == nil)
                    }
                    Button("Навести резкость") { model.focusNow() }
                    if !model.options("focuslock").isEmpty {
                        Toggle("Зафиксировать фокус", isOn: Binding(
                            get: { model.state?.aflock == 1 },
                            set: { model.setFocusLocked($0) }
                        ))
                    }
                    Group {
                        if let problem = model.focusProblem {
                            Text(problem).font(.caption).foregroundColor(.orange)
                        }
                        if let state = model.state {
                            Label(state.aflock == 1 ? "Фокус зафиксирован" : "Автофокус при съёмке", systemImage: state.aflock == 1 ? "lock.fill" : "viewfinder")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if !model.options("focus").isEmpty {
                        DisclosureGroup("Ручная дистанция") {
                            HStack {
                                TextField("Дистанция, мм", text: Binding(get: { model.focusText }, set: { model.editFocus($0) }))
                                    .frame(width: 100).focused($focusEditing)
                                    .onSubmit { model.finishFocusEditing(); focusEditing = false }
                                    .onChange(of: focusEditing) { model.focusEditing = $0 }
                                Text("мм").foregroundColor(.secondary)
                                Button("Установить") { model.finishFocusEditing(); focusEditing = false }
                                HelpButton(title: "Ручная дистанция", explanation: "Приблизительная дистанция 100–10000 мм. Применяется по Enter или кнопке «Установить» и включает фиксацию фокуса. Это не измерение резкости; сначала попробуйте кнопку «Навести резкость».")
                            }.padding(.top, 6)
                        }
                    }
                    Spacer()
                }
                }.frame(width: 310).disabled(model.busy || model.state == nil)
            }
            HStack {
                Text(model.saving.destinationTitle).foregroundColor(.secondary)
                Spacer()
                if let photo = model.lastPhoto {
                    Button("Показать сохранённый файл") { NSWorkspace.shared.activateFileViewerSelecting([photo]) }
                }
            }
            Text(model.message).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            DisclosureGroup("Журнал") {
                ScrollView { Text(model.events.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 80)
            }
        }.padding(22).frame(minWidth: 900, minHeight: 650)
        .sheet(isPresented: $showingCameraMenu) {
            NativeCameraControls(model: model)
                .onAppear { model.setCameraMenu(true) }
                .onDisappear { model.setCameraMenu(false) }
        }
        .alert("Освободить подключение камеры?", isPresented: $confirmRelease) {
            Button("Отмена", role: .cancel) {}
            Button("Освободить и подключиться") { model.perform("reclaim") }
        } message: {
            Text("Будет принудительно остановлена системная служба импорта фотографий macOS. Текущий импорт может прерваться. Другие приложения нужно закрыть самостоятельно. Передать их открытый сеанс этому приложению невозможно.")
        }
        .alert("Камера", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Понятно") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

struct CameraExposureControls: View {
    @ObservedObject var model: CameraModel
    private func label(_ action: String, _ value: Int) -> String {
        switch action {
        case "iso": return value == 0 ? "Авто" : (value == 1 ? "Высокое авто" : String(value))
        case "wb": return [0:"Авто",1:"Дневной свет",2:"Облачно",3:"Лампа накаливания",4:"Люминесцентный",5:"Люминесцентный H",7:"Пользовательский"][value] ?? String(value)
        case "ev": return String(format: "%+.1f EV", Double(value) / 96)
        case "metering": return [0:"Оценочный",1:"Точечный",2:"Центровзвешенный"][value] ?? String(value)
        default: return String(value)
        }
    }
    var body: some View {
        ForEach(["iso", "wb", "ev", "metering"], id: \.self) { action in
            if !model.options(action).isEmpty, let current = model.state?.settings?[action] {
                Picker(["iso":"ISO", "wb":"Баланс белого", "ev":"Экспокоррекция", "metering":"Замер"][action]!, selection: Binding(
                    get: { model.state?.settings?[action] ?? current },
                    set: { model.select(action, value: $0) }
                )) {
                    ForEach(model.options(action), id: \.self) { value in Text(label(action, value)).tag(value) }
                    if !model.options(action).contains(current) { Text(label(action, current)).tag(current) }
                }
            }
        }
    }
}

struct NativeCameraControls: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var halfPressCombination = false
    private func key(_ title: String, _ value: Int) -> some View {
        Button(title) { model.perform("key", value: value + (halfPressCombination ? 100 : 0)) }.disabled(model.busy || model.state == nil)
    }
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Все настройки камеры").font(.title2.bold())
                HelpButton(title: "Штатное меню Canon", explanation: "Это экран и кнопки самой камеры. FUNC открывает параметры съёмки. MENU выполняет действие выбранного параметра или открывает главное меню после выхода из FUNC. Стрелки выбирают пункт и значение, SET подтверждает. Доступные функции определяет сама камера для выбранного режима.\n\nЗдесь доступны размер и качество JPEG, таймер и серия, замер, цветовые эффекты, баланс белого и другие параметры Canon. При закрытии приложение завершает открытое им меню через MENU или SET, без спуска затвора.")
                Spacer()
                Button("Готово") { dismiss() }.disabled(model.busy)
            }
            ZStack {
                Color.black
                if let image = model.preview { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            }.frame(width: 640, height: 480)
            HStack(spacing: 24) {
                VStack { key("MENU", 0); key("FUNC", 1); key("DISP.", 6) }
                VStack {
                    key("↑", 2).accessibilityLabel("Вверх")
                    HStack { key("←", 4).accessibilityLabel("Влево"); key("SET", 9); key("→", 5).accessibilityLabel("Вправо") }
                    key("↓", 3).accessibilityLabel("Вниз")
                }
                VStack { key("Зум +", 7); key("Зум −", 8) }
            }
            HStack {
                Toggle("Кнопки с полунажатием", isOn: $halfPressCombination).disabled(model.busy)
                HelpButton(title: "Комбинации кнопок Canon", explanation: "При включении приложение удерживает полунажатие только на время отправки выбранной кнопки, затем обязательно отпускает. Это позволяет использовать штатные комбинации Canon, например фиксацию экспозиции. Полное нажатие спуска здесь не отправляется; снимка не будет.")
                Spacer()
            }
            Text(model.message).font(.callout).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(24)
    }
}

struct PreviewSettingsView: View {
    @ObservedObject var model: CameraModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Предпросмотр и экран").font(.title2.bold())
            HStack {
                Toggle("Live View", isOn: Binding(
                    get: { model.liveEnabled }, set: { model.setLiveEnabled($0) }
                ))
                Spacer()
                HelpButton(title: "Live View", explanation: "Автоматически показывает изображение с камеры после подключения, если CHDK поддерживает Live View. Камера переводится в режим съёмки.\n\nНастройка применяется сразу и сохраняется для следующего запуска. При отключении остаётся последний кадр или снимок.")
            }
            Divider()
            SectionHelpHeader(title: "Предпросмотр", explanation: "Эти параметры меняют только Live View на Mac и не влияют на сохраняемые JPEG. «Больше деталей» сохраняет все горизонтальные отсчёты экранного буфера; улучшение на IXUS 65 ещё не проверено. Частота — верхний предел, реальная скорость зависит от камеры. Исходный размер показывает кадр без увеличения, с учётом пропорций экрана камеры.")
            Picker("Качество", selection: Binding(get: { model.previewDetailed }, set: { model.setPreviewDetailed($0) })) {
                Text("Быстрее").tag(false)
                Text("Больше деталей (экспериментально)").tag(true)
            }
            Picker("Частота обновления", selection: Binding(get: { model.previewFPS }, set: { model.setPreviewFPS($0) })) {
                Text("Максимальная").tag(0)
                ForEach([5, 10, 15], id: \.self) { Text("До \($0) кадров/с").tag($0) }
            }
            Picker("Отображение", selection: Binding(get: { model.previewNativeSize }, set: { model.setPreviewNativeSize($0) })) {
                Text("По размеру окна").tag(false)
                Text("Исходный размер").tag(true)
            }
            Divider()
            HStack {
                Toggle("Держать подсветку выключенной", isOn: Binding(
                    get: { model.backlightOffEnabled }, set: { model.setBacklightOffEnabled($0) }
                ))
                Spacer()
                HelpButton(title: "Подсветка экрана камеры", explanation: "Приложение выключает подсветку после подключения и повторяет команду примерно раз в секунду и после настроек. При смене режима подсветка может кратко загореться; во время длительной операции выключение откладывается.\n\nПри снятии флажка или выходе из приложения подсветка включается обратно. Настройка сохраняется для следующего запуска. Флажок показывает выбранное поведение, а не измеренный статус экрана.")
            }
        }
        .disabled(model.busy)
        .padding(24)
        .frame(width: 480)
    }
}

struct PreviewImage: View {
    let image: NSImage
    let nativeSize: Bool
    var body: some View {
        if nativeSize {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable()
                        .frame(width: image.size.width, height: image.size.height)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
            }
        } else {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        }
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

struct CameraSettingsView: View {
    @ObservedObject var model: CameraModel
    var body: some View {
        TabView {
            SaveSettingsView(model: model).tabItem { Label("Сохранение снимков", systemImage: "folder") }
            PreviewSettingsView(model: model).tabItem { Label("Предпросмотр", systemImage: "viewfinder") }
        }.padding(12).frame(width: 640, height: 680)
    }
}

struct SaveSettingsView: View {
    @ObservedObject var model: CameraModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Сохранение снимков").font(.title2.bold())
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Сохранять", selection: Binding(get: { model.saving.destination }, set: { model.setSaveDestination($0) })) {
                            Text("На камеру и Mac").tag(0)
                            Text("Только на камеру").tag(1)
                            Text("Только на Mac").tag(2)
                        }
                        if model.saving.destination == 2 {
                            Text("Оригиналы удаляются с карты только после скачивания и проверки всех файлов на Mac.").font(.caption).foregroundColor(.secondary)
                        }
                        if model.saving.destination != 1 {
                            Text(model.folder.path).textSelection(.enabled).lineLimit(2)
                            HStack {
                                Button("Выбрать папку…") { model.chooseFolder() }
                                Button("Открыть папку") { model.openSaveFolder() }
                            }
                        }
                    }.padding(6)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Формат", selection: $model.saving.format) {
                            Text("JPEG камеры (без преобразования)").tag("jpeg")
                            if model.saving.destination != 1 {
                                Text("PNG из JPEG").tag("png")
                                Text("TIFF из JPEG").tag("tiff")
                            }
                            Text("CHDK RAW + JPEG").tag("raw")
                            Text("DNG + JPEG").tag("dng")
                        }
                        if ["png", "tiff"].contains(model.saving.format) {
                            Toggle("Также сохранять оригинальный JPEG", isOn: $model.saving.keepJPEG)
                            Text("Преобразование не добавляет деталей к исходному JPEG.").font(.caption).foregroundColor(.secondary)
                        }
                        if ["raw", "dng"].contains(model.saving.format) {
                            Text("RAW/DNG на этой камере ещё не проверялись. Сохраняется также JPEG. Если формат недоступен в выбранном режиме, приложение сообщит об ошибке.").font(.caption).foregroundColor(.secondary)
                        }
                        Picker("Качество JPEG камеры", selection: $model.saving.quality) {
                            Text("Как на камере").tag(-1)
                            Text("Superfine — наилучшее").tag(0)
                            Text("Fine — высокое").tag(1)
                            Text("Normal — обычное").tag(2)
                        }
                        Picker("Размер JPEG камеры", selection: $model.saving.resolution) {
                            Text("Как на камере").tag(-1)
                            Text("L • 2816 × 2112").tag(0)
                            Text("M1 • 2272 × 1704").tag(1)
                            Text("M2 • 1600 × 1200").tag(2)
                            Text("S • 640 × 480").tag(4)
                            Text("W • 2816 × 1584").tag(8)
                        }
                        Text("Выбранные качество и размер используются для следующих снимков. Доступность зависит от режима камеры. RAW не зависит от сжатия JPEG.").font(.caption).foregroundColor(.secondary)
                        if let settings = model.state?.settings {
                            Text("С камеры: качество \(qualityName(settings["quality"])), размер \(resolutionName(settings["resolution"]))").font(.caption).foregroundColor(.secondary)
                        }
                    }.padding(6)
                }
                if model.saving.destination != 1 {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Имя файла", selection: $model.saving.naming) {
                                Text("Дата и время").tag("datetime")
                                Text("Оригинальное имя камеры").tag("original")
                                Text("Свой шаблон").tag("custom")
                            }
                            if model.saving.naming == "custom" {
                                TextField("Шаблон", text: $model.saving.template)
                                Text("{date}, {time}, {counter}, {original}. Префикс пишется обычным текстом: Product_{counter}").font(.caption).foregroundColor(.secondary)
                                TextField("Следующий номер", value: $model.saving.counter, format: .number).frame(maxWidth: 260)
                            }
                            Picker("Подпапки", selection: $model.saving.grouping) {
                                Text("Без подпапок").tag("none")
                                Text("По дням • 2026-11-12").tag("day")
                                Text("По месяцам • 2026-11").tag("month")
                            }
                            Text(model.saveExample).font(.caption.monospaced()).textSelection(.enabled)
                            Text("При совпадении имён добавляется номер. Существующие файлы не перезаписываются.").font(.caption).foregroundColor(.secondary)
                        }.padding(6)
                    }
                }
            }.padding(16)
        }.disabled(model.busy)
    }
    private func qualityName(_ value: Int?) -> String {
        [0: "Superfine", 1: "Fine", 2: "Normal"][value ?? -1] ?? "—"
    }
    private func resolutionName(_ value: Int?) -> String {
        [0: "L", 1: "M1", 2: "M2", 4: "S", 8: "W"][value ?? -1] ?? "—"
    }
}
