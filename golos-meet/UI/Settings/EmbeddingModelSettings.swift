import SwiftUI
import AppKit
import Combine

@MainActor
final class EmbeddingModelSettingsModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var message = "Модель ещё не установлена."
    @Published private(set) var fraction: Double?
    @Published private(set) var failed = false
    private let installer: EmbeddingModelInstaller
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var restored = false

    init(installer: EmbeddingModelInstaller? = nil) {
        self.installer = installer ?? EmbeddingModelInstaller(root: AppPaths.appSupport.appendingPathComponent("embedding-models"))
    }

    func restore() {
        guard !restored, !busy else { return }
        restored = true
        run { installer in
            guard let folder = try await installer.installedFolder() else { return false }
            let encoder = try await E5TextEmbedding(folder: folder)
            _ = try await encoder.embed(["Проверка локальной модели"], purpose: .query)
            return true
        }
    }

    func install(from folder: URL? = nil) {
        guard !busy else { return }
        let id = UUID()
        operationID = id
        let report: @Sendable (EmbeddingInstallProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == id, self.busy else { return }
                self.message = progress.message
                self.fraction = progress.fraction
            }
        }
        run(id: id) { installer in
            _ = try await installer.install(from: folder) { progress in
                report(progress)
            }
            return true
        }
    }

    func cancel() {
        message = "Отменяем установку…"
        operation?.cancel()
    }

    private func run(id: UUID = UUID(), _ work: @escaping @Sendable (EmbeddingModelInstaller) async throws -> Bool) {
        operationID = id
        busy = true; failed = false; fraction = nil
        message = "Проверяем модель…"
        let wasReady = ready
        operation = Task { [installer] in
            do {
                ready = try await work(installer)
                message = ready ? "Модель проверена и готова к локальному расчёту." : "Модель ещё не установлена."
            } catch {
                ready = wasReady
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    message = wasReady ? "Установка отменена. Рабочая модель сохранена." : "Установка отменена. Можно повторить загрузку."
                } else {
                    failed = true
                    // Avoid presenting raw runtime errors containing absolute paths.
                    message = (error as? EmbeddingModelError)?.errorDescription
                        ?? "Не удалось установить или проверить модель. Проверьте файлы, свободное место и соединение, затем повторите."
                }
            }
            busy = false; fraction = nil; operation = nil
        }
    }
}

@MainActor
struct EmbeddingModelSettings: View {
    @Environment(\.palette) private var p
    @StateObject private var model: EmbeddingModelSettingsModel
    init(model: EmbeddingModelSettingsModel? = nil) {
        _model = StateObject(wrappedValue: model ?? EmbeddingModelSettingsModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GSectionHeader("Модель для поиска по смыслу", desc: "multilingual E5-small · русский и другие языки · 488 МБ")
            GCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Вычисления выполняются на этом Mac. Загрузка обращается к Hugging Face только за файлами модели; тексты документов и встреч остаются на компьютере.")
                        .foregroundStyle(p.muted)
                    HStack(spacing: 10) {
                        Button(model.ready ? "Загрузить заново" : "Скачать модель") { model.install() }
                            .buttonStyle(PrimaryButton())
                            .disabled(model.busy)
                        Button("Выбрать папку…") { chooseFolder() }
                            .buttonStyle(GhostButton())
                            .disabled(model.busy)
                        if model.busy {
                            Button("Отменить") { model.cancel() }.buttonStyle(GhostButton())
                        }
                    }
                    if model.busy {
                        ProgressView(value: model.fraction).progressViewStyle(.linear)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: model.failed ? "exclamationmark.triangle" : (model.ready ? "checkmark.circle" : "info.circle"))
                        Text(model.message).textSelection(.enabled)
                    }
                    .foregroundStyle(model.failed ? p.danger : p.ink)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(model.message)
                    Text("Для установки с диска выберите корневую папку этой версии E5-small: tokenizer.json, файлы конфигурации и onnx/model.onnx. Приложение проверит файлы и сохранит свою копию.")
                        .foregroundStyle(p.muted)
                    Text("Установленная модель работает без интернета.")
                        .foregroundStyle(p.muted)
                }
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { model.restore() }
    }

    private func chooseFolder() {
        guard !model.busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать папку"
        panel.message = "Папка multilingual-e5-small с tokenizer.json и onnx/model.onnx"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.install(from: folder)
    }
}
