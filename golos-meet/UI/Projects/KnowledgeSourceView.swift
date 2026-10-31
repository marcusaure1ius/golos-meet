import SwiftUI
import PDFKit

struct KnowledgeSourceView: View {
    let destination: KnowledgeSearchDestination
    let onBack: () -> Void
    @Environment(\.palette) private var p
    @State private var showText = false
    @State private var pdfError = false
    private var hit: KnowledgeSearchHit { destination.hit }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onBack) { Label("Результаты поиска", systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(p.link)
            Text(hit.source.title).font(.system(size: 26, weight: .semibold)).foregroundStyle(p.ink).lineLimit(2)
            Text(KnowledgeSearchLocation.label(hit.chunk)).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.link)
            Text("Проверенный снимок на \(destination.checkedAt.formatted(date: .abbreviated, time: .shortened)). Изменения источника после открытия здесь не отображаются.")
                .font(.system(size: 12)).foregroundStyle(p.muted)
            if destination.pdf != nil {
                Picker("Просмотр документа", selection: $showText) {
                    Text("Страница PDF").tag(false)
                    Text("Извлечённый текст").tag(true)
                }.pickerStyle(.segmented).fixedSize()
            }
            if let data = destination.pdf, !showText {
                if let page = hit.chunk.location.page, page > 0, !pdfError {
                    KnowledgePDFPage(data: data, page: page, failed: { pdfError = true }).id(hit.id)
                } else {
                    ContentUnavailableView("Страница недоступна", systemImage: "doc",
                                           description: Text("Не удалось открыть указанную страницу PDF. Выберите извлечённый текст или повторите импорт документа."))
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(destination.chunks) { chunk in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(KnowledgeSearchLocation.label(chunk)).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.muted)
                                    Text(chunk.text).font(.system(size: 14)).foregroundStyle(p.ink).textSelection(.enabled)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(chunk.id == hit.id ? p.selection : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .id(chunk.id)
                            }
                        }.padding(.vertical, 8)
                    }
                    .task(id: hit.id) { await Task.yield(); proxy.scrollTo(hit.id, anchor: .top) }
                }
            }
        }
        .padding(.horizontal, 56).padding(.top, 30).padding(.bottom, 20)
    }
}

/// PDFKit consumes the bytes whose hash was validated, not a mutable file URL.
private struct KnowledgePDFPage: NSViewRepresentable {
    let data: Data
    let page: Int
    let failed: () -> Void
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        guard let document = PDFDocument(data: data), let target = document.page(at: page - 1) else {
            DispatchQueue.main.async { failed() }; return view
        }
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        view.go(to: target)
        DispatchQueue.main.async { view.go(to: target) }
        return view
    }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}
