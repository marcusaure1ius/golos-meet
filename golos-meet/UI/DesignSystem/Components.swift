import SwiftUI

// MARK: - GCard

/// Контейнер настроек: белый фон, рамка, скруглённые углы 12pt.
/// Разделители между строками рисует GSettingRow через showTopDivider.
struct GCard<Content: View>: View {
    @Environment(\.palette) var p
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(p.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(p.border, lineWidth: 1)
        )
    }
}

// MARK: - GSectionHeader

/// Подзаголовок секции: .sec-h (16 semibold) + опционально .sec-d (13.5 muted).
struct GSectionHeader: View {
    @Environment(\.palette) var p
    let title: String
    let desc: String?

    init(_ title: String, desc: String? = nil) {
        self.title = title
        self.desc = desc
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.16)
                .foregroundStyle(p.ink)
            if let desc {
                Text(desc)
                    .font(.system(size: 13.5))
                    .foregroundStyle(p.muted)
                    .lineSpacing(3.325) // line-height 1.45 → extra ≈ 3.3pt
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - GSettingRow

/// Строка настройки: .row — label 15/ink + опц. desc 13/muted слева, trailing справа.
/// Паддинг 15vt × 17hz. Разделитель рисуется сверху строки (по умолчанию `showTopDivider: true`).
/// **Важно**: для первой строки внутри `GCard` передавать `showTopDivider: false`, чтобы не появился лишний hairline у верхнего скругления карточки.
struct GSettingRow<Trailing: View>: View {
    @Environment(\.palette) var p
    let label: String
    let desc: String?
    let showTopDivider: Bool
    private let trailing: Trailing

    init(_ label: String,
         desc: String? = nil,
         showTopDivider: Bool = true,
         @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.desc = desc
        self.showTopDivider = showTopDivider
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(p.ink)
                if let desc {
                    Text(desc)
                        .font(.system(size: 13))
                        .foregroundStyle(p.muted)
                        .lineSpacing(3.185) // line-height 1.45
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 15)
        .overlay(alignment: .top) {
            if showTopDivider {
                Rectangle()
                    .fill(p.borderSoft)
                    .frame(height: 1)
            }
        }
    }
}

// MARK: - GKbd

/// Обозначение клавиш: SF Mono 12.5, фон selection, рамка border, radius 7. (.kbd)
struct GKbd: View {
    @Environment(\.palette) var p
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(p.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(p.selection)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(p.border, lineWidth: 1)
            )
    }
}

// MARK: - Button Styles

/// Кнопка с рамкой fieldBorder, прозрачный фон. (.btn.ghost)
struct GhostButton: ButtonStyle {
    @Environment(\.palette) var p

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .regular))
            .foregroundStyle(p.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(p.fieldBorder, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// Основная кнопка: фон btn, текст btnInk. (.btn.primary)
struct PrimaryButton: ButtonStyle {
    @Environment(\.palette) var p

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .regular))
            .foregroundStyle(p.btnInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(p.btn)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Деструктивная кнопка: текст danger, фон dangerBg. (.btn.danger)
struct DangerButton: ButtonStyle {
    @Environment(\.palette) var p

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .regular))
            .foregroundStyle(p.danger)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(p.dangerBg)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - GSelectLabel

/// Метка для Menu: рамка fieldBorder, шеврон, серый текст. (.select)
/// При наведении — лёгкий фон selection, как у нативных popUp-контролов.
struct GSelectLabel: View {
    @Environment(\.palette) var p
    let value: String
    @State private var hovering = false

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(p.ink)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(p.muted)
        }
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.vertical, 6)
        .frame(minWidth: 120)
        .background(hovering ? p.selection : p.card)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(p.fieldBorder, lineWidth: 1)
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - GRadioCard

/// Карточка-вариант: заголовок 15 bold, подпись 13 моно/muted, радио справа-сверху.
/// Выбранная — фон cardSel + синий радио. (.optcard / .optcard.sel)
struct GRadioCard<Trailing: View>: View {
    @Environment(\.palette) var p
    let title: String
    let subtitle: String
    let selected: Bool
    private let trailing: Trailing

    init(title: String,
         subtitle: String,
         selected: Bool,
         @ViewBuilder action: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.selected = selected
        self.trailing = action()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(p.ink)
                Text(subtitle)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(p.muted)
                    .lineSpacing(3.185)
                // EmptyView не занимает место — spacing не добавляется
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Отступ справа = 36 (16+17+3), чтобы текст не налезал на радио-кнопку
            .padding(.leading, 16)
            .padding(.trailing, 16 + 17 + 3)
            .padding(.vertical, 15)

            // Радио-кнопка 17×17, position: top 15, right 15 (.optcard .radio)
            ZStack {
                Circle()
                    .strokeBorder(selected ? p.accent : p.fieldBorder, lineWidth: 1.5)
                if selected {
                    // radial-gradient: accent 0–5px центр
                    Circle()
                        .fill(p.accent)
                        .frame(width: 9, height: 9)
                }
            }
            .frame(width: 17, height: 17)
            .padding(.top, 15)
            .padding(.trailing, 15)
        }
        // .frame перед .background — позволяет растянуть фон на всю доступную высоту
        // (используется в ModelsPane для карточек одинаковой высоты).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(selected ? p.cardSel : p.card)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(p.border, lineWidth: 1)
        )
    }
}

extension GRadioCard where Trailing == EmptyView {
    init(title: String, subtitle: String, selected: Bool) {
        self.init(title: title, subtitle: subtitle, selected: selected, action: { EmptyView() })
    }
}

// MARK: - GNavRow

/// Строка навигации сайдбара: иконка SF Symbols + заголовок + опц. бейдж «скоро».
/// Иконки монохром тонким весом, foreground muted (selected → ink). (.navrow)
struct GNavRow: View {
    @Environment(\.palette) var p
    let icon: String
    let title: String
    let selected: Bool
    let disabled: Bool
    let soon: Bool

    init(icon: String,
         title: String,
         selected: Bool,
         disabled: Bool = false,
         soon: Bool = false) {
        self.icon = icon
        self.title = title
        self.selected = selected
        self.disabled = disabled
        self.soon = soon
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(iconColor)
                .frame(width: 18, height: 18)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(labelColor)
            Spacer(minLength: 0)
            if soon {
                Text("скоро")
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.muted2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .overlay(
                        Capsule()
                            .strokeBorder(p.border, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(selected ? p.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var iconColor: Color {
        if disabled { return p.muted2 }
        return selected ? p.ink : p.muted
    }

    private var labelColor: Color {
        disabled ? p.muted2 : p.ink
    }
}
