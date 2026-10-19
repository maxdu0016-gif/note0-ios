import Combine
import PencilKit
import SwiftUI
import UIKit

/// The four tools of the compact toolbar.
enum InkToolKind: String, CaseIterable, Identifiable {
    case pen, highlighter, eraser, lasso

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: L("笔")
        case .highlighter: L("荧光笔")
        case .eraser: L("橡皮")
        case .lasso: L("套索")
        }
    }

    var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        }
    }
}

enum EraserMode: String, CaseIterable, Identifiable {
    case stroke, partial
    var id: String { rawValue }
    var title: String { self == .stroke ? L("整笔擦除") : L("局部擦除") }
}

/// Every pen type PencilKit offers, with Chinese names.
struct PenStyle: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let inkType: PKInkingTool.InkType

    static let all: [PenStyle] = [
        PenStyle(id: "pen", title: L("钢笔"), systemImage: "pencil.tip", inkType: .pen),
        PenStyle(id: "monoline", title: L("圆珠笔"), systemImage: "pencil.line", inkType: .monoline),
        PenStyle(id: "fountainPen", title: L("书法笔"), systemImage: "signature", inkType: .fountainPen),
        PenStyle(id: "pencil", title: L("铅笔"), systemImage: "pencil", inkType: .pencil),
        PenStyle(id: "watercolor", title: L("水彩"), systemImage: "paintbrush", inkType: .watercolor),
        PenStyle(id: "crayon", title: L("蜡笔"), systemImage: "paintbrush.pointed", inkType: .crayon),
    ]

    static func named(_ id: String) -> PenStyle { all.first { $0.id == id } ?? all[0] }
}

/// Writing tools for one window, shared by both split-view panes.
///
/// By default the app shows its own compact toolbar (one slim row in the top
/// bar) driven by this object. "…" → "苹果原生工具栏" switches to Apple's
/// full palette instead; `picker` is that palette.
@MainActor
final class InkTools: NSObject, ObservableObject, PKToolPickerObserver {
    let picker = PKToolPicker()

    @Published var useSystemPalette: Bool { didSet { save() } }
    @Published private(set) var kind: InkToolKind = .pen
    @Published var penStyle: String { didSet { save() } }
    @Published var penColor: UIColor { didSet { save() } }
    @Published var penWidth: CGFloat { didSet { save() } }
    @Published var highlighterColor: UIColor { didSet { save() } }
    @Published var highlighterWidth: CGFloat { didSet { save() } }
    @Published var eraserMode: EraserMode { didSet { save() } }
    @Published var eraserWidth: CGFloat { didSet { save() } }
    @Published var rulerActive = false
    /// Draw a shape and hold the pencil still → it becomes a clean shape.
    @Published var shapeRecognition: Bool { didSet { save() } }
    /// Which tool's settings popover is open (also opened by Pencil double-tap
    /// when the system setting says "显示调色板").
    @Published var settingsShownFor: InkToolKind?
    @Published private var systemLassoSelected = false

    private var previousKind: InkToolKind = .pen
    private var lastPencilAction = Date.distantPast

    static let penWidths: ClosedRange<CGFloat> = 0.5...16
    static let highlighterWidths: ClosedRange<CGFloat> = 6...40
    static let eraserWidths: ClosedRange<CGFloat> = 4...60

    static let swatches: [UIColor] = [
        .black, UIColor(white: 0.42, alpha: 1), .systemBlue, .systemRed, .systemGreen, .systemOrange,
        .systemPurple, .systemBrown, .systemPink, .systemTeal, .systemYellow, .white,
    ]
    static let highlighterSwatches: [UIColor] = [
        .systemYellow, .systemGreen, .systemPink, .systemBlue, .systemOrange, .systemPurple,
    ]

    override init() {
        let d = UserDefaults.standard
        useSystemPalette = d.bool(forKey: Keys.systemPalette)
        penStyle = d.string(forKey: Keys.penStyle) ?? "pen"
        penColor = Self.color(d.string(forKey: Keys.penColor)) ?? .black
        penWidth = Self.width(d, Keys.penWidth, default: 2.5)
        highlighterColor = Self.color(d.string(forKey: Keys.highlighterColor)) ?? .systemYellow
        highlighterWidth = Self.width(d, Keys.highlighterWidth, default: 16)
        eraserMode = EraserMode(rawValue: d.string(forKey: Keys.eraserMode) ?? "") ?? .stroke
        eraserWidth = Self.width(d, Keys.eraserWidth, default: 16)
        shapeRecognition = d.object(forKey: Keys.shapes) as? Bool ?? true
        super.init()
        picker.addObserver(self)
    }

    /// True while the lasso is the active tool (shows "问 AI 选中的内容").
    var isLassoSelected: Bool { useSystemPalette ? systemLassoSelected : kind == .lasso }

    /// The tool the canvases should use in compact-toolbar mode.
    var tool: PKTool {
        switch kind {
        case .pen:
            return PKInkingTool(PenStyle.named(penStyle).inkType, color: penColor, width: penWidth)
        case .highlighter:
            return PKInkingTool(.marker, color: highlighterColor, width: highlighterWidth)
        case .eraser:
            return eraserMode == .stroke
                ? PKEraserTool(.vector)
                : PKEraserTool(.fixedWidthBitmap, width: eraserWidth)
        case .lasso:
            return PKLassoTool()
        }
    }

    /// Color shown on the color button (the pen's, unless the highlighter is active).
    var currentColor: UIColor { kind == .highlighter ? highlighterColor : penColor }

    func select(_ newKind: InkToolKind) {
        guard newKind != kind else { return }
        previousKind = kind
        kind = newKind
    }

    /// Picks a color; with the eraser or lasso active this goes back to the pen.
    func pickColor(_ color: UIColor) {
        if kind == .highlighter {
            highlighterColor = color
        } else {
            penColor = color
            select(.pen)
        }
    }

    // MARK: - Apple Pencil double-tap / squeeze

    /// Follows the user's choice in iPad Settings → Apple Pencil. Both split
    /// panes listen for the gesture, so a repeat within a moment is ignored.
    func handlePencil(_ action: UIPencilPreferredAction) {
        guard !useSystemPalette else { return } // Apple's palette handles it itself.
        let now = Date()
        guard now.timeIntervalSince(lastPencilAction) > 0.25 else { return }
        lastPencilAction = now

        switch action {
        case .switchEraser:
            if kind == .eraser {
                select(previousKind == .eraser ? .pen : previousKind)
            } else {
                select(.eraser)
            }
        case .switchPrevious:
            select(previousKind)
        case .ignore:
            break
        default:
            // "显示调色板" / "显示笔刷属性" and newer options: open this tool's settings.
            settingsShownFor = (kind == .lasso) ? .pen : kind
        }
    }

    // MARK: - Apple palette mode

    nonisolated func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
        Task { @MainActor in
            self.systemLassoSelected = self.picker.selectedTool is PKLassoTool
        }
    }

    // MARK: - Persistence

    private enum Keys {
        static let systemPalette = "note0.ink.systemPalette"
        static let penStyle = "note0.ink.penStyle"
        static let penColor = "note0.ink.penColor"
        static let penWidth = "note0.ink.penWidth"
        static let highlighterColor = "note0.ink.highlighterColor"
        static let highlighterWidth = "note0.ink.highlighterWidth"
        static let eraserMode = "note0.ink.eraserMode"
        static let eraserWidth = "note0.ink.eraserWidth"
        static let shapes = "note0.ink.shapeRecognition"
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(useSystemPalette, forKey: Keys.systemPalette)
        d.set(penStyle, forKey: Keys.penStyle)
        d.set(Self.hex(penColor), forKey: Keys.penColor)
        d.set(Double(penWidth), forKey: Keys.penWidth)
        d.set(Self.hex(highlighterColor), forKey: Keys.highlighterColor)
        d.set(Double(highlighterWidth), forKey: Keys.highlighterWidth)
        d.set(eraserMode.rawValue, forKey: Keys.eraserMode)
        d.set(Double(eraserWidth), forKey: Keys.eraserWidth)
        d.set(shapeRecognition, forKey: Keys.shapes)
    }

    private static func width(_ d: UserDefaults, _ key: String, default value: CGFloat) -> CGFloat {
        let stored = d.double(forKey: key)
        return stored > 0 ? CGFloat(stored) : value
    }

    nonisolated static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X%02X", byte(r), byte(g), byte(b), byte(a))
    }

    nonisolated static func color(_ hex: String?) -> UIColor? {
        guard let hex, hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((value >> 24) & 0xFF) / 255, green: CGFloat((value >> 16) & 0xFF) / 255,
            blue: CGFloat((value >> 8) & 0xFF) / 255, alpha: CGFloat(value & 0xFF) / 255
        )
    }
}

// MARK: - Compact toolbar

/// One slim row: pen, highlighter, eraser, lasso, color, ruler. Tapping the
/// active tool again opens its settings (pen type, thickness, eraser mode…).
struct InkToolBar: View {
    @ObservedObject var tools: InkTools
    @State private var showColors = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InkToolKind.allCases) { kind in
                toolButton(kind)
            }

            Divider().frame(height: 20).padding(.horizontal, 4)

            Button {
                showColors = true
            } label: {
                Circle()
                    .fill(Color(uiColor: tools.currentColor))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                    .frame(width: 22, height: 22)
                    .frame(width: 32, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("颜色"))
            .popover(isPresented: $showColors) {
                ColorPanel(tools: tools)
                    .presentationCompactAdaptation(.popover)
            }

            Button {
                tools.rulerActive.toggle()
            } label: {
                Image(systemName: "ruler")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 30)
                    .background(selectionBackground(tools.rulerActive))
                    .foregroundStyle(tools.rulerActive ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("尺子"))
        }
    }

    private func toolButton(_ kind: InkToolKind) -> some View {
        let selected = tools.kind == kind
        return Button {
            if selected, kind != .lasso {
                tools.settingsShownFor = kind
            } else {
                tools.select(kind)
            }
        } label: {
            Image(systemName: kind.systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 30)
                .background(selectionBackground(selected))
                .foregroundStyle(selected ? toolTint(kind) : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
        .popover(isPresented: Binding(
            get: { tools.settingsShownFor == kind },
            set: { if !$0, tools.settingsShownFor == kind { tools.settingsShownFor = nil } }
        )) {
            ToolSettingsPanel(tools: tools, kind: kind)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func toolTint(_ kind: InkToolKind) -> Color {
        switch kind {
        case .pen: Color(uiColor: InkTools.hex(tools.penColor).hasPrefix("FFFFFF") ? .label : tools.penColor)
        case .highlighter: Color(uiColor: tools.highlighterColor)
        default: .accentColor
        }
    }

    private func selectionBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Color.accentColor.opacity(0.14) : .clear)
    }
}

/// Settings for one tool, shown in a small popover.
struct ToolSettingsPanel: View {
    @ObservedObject var tools: InkTools
    let kind: InkToolKind

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch kind {
            case .pen:
                Text(L("笔型")).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 6), count: 3), spacing: 6) {
                    ForEach(PenStyle.all) { style in
                        Button {
                            tools.penStyle = style.id
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: style.systemImage).font(.system(size: 17))
                                Text(style.title).font(.caption2)
                            }
                            .frame(width: 64, height: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(tools.penStyle == style.id ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemFill))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                widthControl(value: $tools.penWidth, range: InkTools.penWidths, presets: [1, 2, 3.5, 6, 10], color: tools.penColor)
                Toggle(isOn: $tools.shapeRecognition) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("图形识别")).font(.subheadline)
                        Text(L("画完后笔尖停住不动，会出现虚线预览，抬笔就变成直线、圆、多边形或箭头"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            case .highlighter:
                widthControl(value: $tools.highlighterWidth, range: InkTools.highlighterWidths, presets: [8, 14, 20, 28, 36], color: tools.highlighterColor)
                Toggle(isOn: $tools.shapeRecognition) {
                    Text(L("图形识别（停住变直线）")).font(.subheadline)
                }
            case .eraser:
                Picker(L("擦除方式"), selection: $tools.eraserMode) {
                    ForEach(EraserMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if tools.eraserMode == .partial {
                    widthControl(value: $tools.eraserWidth, range: InkTools.eraserWidths, presets: [6, 12, 20, 32, 48], color: .gray)
                } else {
                    Text(L("碰到哪一笔就擦掉整笔")).font(.caption).foregroundStyle(.secondary)
                }
            case .lasso:
                Text(L("圈住内容后可以拖动、拷贝，或点 ✦ 问 AI")).font(.footnote)
            }
        }
        .padding(16)
        .frame(width: 236)
    }

    private func widthControl(value: Binding<CGFloat>, range: ClosedRange<CGFloat>, presets: [CGFloat], color: UIColor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("粗细")).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(presets, id: \.self) { preset in
                    Button {
                        value.wrappedValue = preset
                    } label: {
                        Circle()
                            .fill(Color(uiColor: InkTools.hex(color).hasPrefix("FFFFFF") ? .lightGray : color))
                            .frame(width: dotSize(preset, range), height: dotSize(preset, range))
                            .frame(width: 40, height: 34)
                            .background(
                                Circle()
                                    .strokeBorder(Color.accentColor, lineWidth: abs(value.wrappedValue - preset) < 0.01 ? 2 : 0)
                                    .frame(width: 32, height: 32)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            Slider(value: value, in: range)
        }
    }

    private func dotSize(_ width: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        let t = (width - range.lowerBound) / (range.upperBound - range.lowerBound)
        return 5 + t * 19
    }
}

/// Preset colors plus the system color picker for any color.
struct ColorPanel: View {
    @ObservedObject var tools: InkTools

    var body: some View {
        let swatches = tools.kind == .highlighter ? InkTools.highlighterSwatches : InkTools.swatches
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 10), count: 6), spacing: 10) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                    Button {
                        tools.pickColor(color)
                    } label: {
                        Circle()
                            .fill(Color(uiColor: color))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.accentColor, lineWidth: InkTools.hex(color) == InkTools.hex(tools.currentColor) ? 3 : 0)
                                    .padding(-4)
                            )
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorPicker(L("更多颜色"), selection: Binding(
                get: { Color(uiColor: tools.currentColor) },
                set: { tools.pickColor(UIColor($0)) }
            ))
            .font(.subheadline)
        }
        .padding(16)
        .frame(width: 256)
    }
}

/// Narrow windows: the same tools folded into three buttons.
struct InkToolMenu: View {
    @ObservedObject var tools: InkTools
    @State private var showColors = false
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(InkToolKind.allCases) { kind in
                    Button {
                        tools.select(kind)
                    } label: {
                        Label(kind.title, systemImage: tools.kind == kind ? "checkmark" : kind.systemImage)
                    }
                }
                Divider()
                Toggle(isOn: $tools.rulerActive) {
                    Label(L("尺子"), systemImage: "ruler")
                }
            } label: {
                Image(systemName: tools.kind.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 30)
            }
            .accessibilityLabel(L("书写工具"))

            Button {
                showColors = true
            } label: {
                Circle()
                    .fill(Color(uiColor: tools.currentColor))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                    .frame(width: 20, height: 20)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("颜色"))
            .popover(isPresented: $showColors) {
                ColorPanel(tools: tools).presentationCompactAdaptation(.popover)
            }

            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("笔型和粗细"))
            .popover(isPresented: Binding(
                get: { showSettings || tools.settingsShownFor != nil },
                set: { if !$0 { showSettings = false; tools.settingsShownFor = nil } }
            )) {
                ToolSettingsPanel(tools: tools, kind: tools.kind).presentationCompactAdaptation(.popover)
            }
        }
    }
}
