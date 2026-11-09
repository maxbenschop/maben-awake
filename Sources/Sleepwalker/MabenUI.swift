import AppKit
import SwiftUI

/// The Maben look for the Settings window, matching awake.maben.gg: near-black
/// surfaces with hairline borders, white text in three strengths, and Awake
/// green as the only accent.
enum MB {
    static let bg = Color(red: 0.035, green: 0.035, blue: 0.04)          // window
    static let sidebar = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let card = Color(red: 0.075, green: 0.075, blue: 0.085)
    static let cardHover = Color(red: 0.095, green: 0.095, blue: 0.105)
    static let line = Color.white.opacity(0.075)
    static let lineStrong = Color.white.opacity(0.14)
    static let text = Color(white: 0.96)
    static let muted = Color(white: 0.64)
    static let dim = Color(white: 0.6)
    static let green = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let cold = Color(red: 0x64 / 255, green: 0xD2 / 255, blue: 0xFF / 255)
    static let orange = Color(red: 1, green: 0.62, blue: 0.2)
    static let radius: CGFloat = 12
}

/// Page layout: a title, one line under it, then the cards.
struct MBPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(MB.text)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(MB.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 22) { content }
                    .padding(.top, 22)
            }
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

/// A titled group of rows on one card.
struct MBSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MB.dim)
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(MBDividedLayout()) { content }
            }
            .background(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).fill(MB.card))
            .overlay(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).strokeBorder(MB.line))
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(MB.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// Puts a hairline between the rows of a section.
private struct MBDividedLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last {
                Rectangle().fill(MB.line).frame(height: 1).padding(.leading, 16)
            }
        }
    }
}

/// A row: optional icon tile, title, explanation, and a control on the right.
struct MBRow<Trailing: View>: View {
    var icon: String? = nil
    var image: NSImage? = nil
    var tint: Color = MB.text
    let title: String
    var detail: String? = nil
    /// Longer explanation behind an ⓘ button, so the row itself stays one line.
    var info: String? = nil
    @ViewBuilder var trailing: Trailing
    @State private var showInfo = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let image {
                MBIconTile(symbol: "", image: image)
            } else if let icon {
                MBIconTile(symbol: icon, tint: tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MB.text)
                    if let info {
                        Button { showInfo.toggle() } label: {
                            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(MB.dim)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                            Text(info)
                                .font(.system(size: 12))
                                .foregroundStyle(MB.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 260, alignment: .leading)
                                .padding(14)
                        }
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(MB.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
    }
}

extension MBRow where Trailing == EmptyView {
    init(icon: String? = nil, title: String, detail: String? = nil) {
        self.init(icon: icon, title: title, detail: detail) { EmptyView() }
    }
}

/// A rounded square with a symbol, like the tiles on the website.
struct MBIconTile: View {
    let symbol: String
    var image: NSImage? = nil
    var tint: Color = MB.text
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: size * 0.55, height: size * 0.55)
            } else if symbol == "maben.freeze" {
                FreezeGlyph(size: size * 0.5, lineWidth: 2)
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.43, weight: .semibold))
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(MB.line))
    }
}

/// A switch in Awake green, drawn by hand so it looks the same everywhere.
struct MBToggle: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? MB.green : Color.white.opacity(0.14))
                Circle().fill(isOn ? Color.black : MB.text).frame(width: 16, height: 16).padding(2)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
            .frame(width: 36, height: 20)
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : MB.line))
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle("", isOn: $isOn) }
    }
}

/// A row of options, one selected (like 5 · 10 · 20 · 30%).
struct MBSegmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = option } } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == option ? Color.black : MB.muted)
                        .frame(minWidth: 40)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selection == option ? MB.text : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MB.line))
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Status with a dot: green when it's in place.
struct MBStatus: View {
    enum Kind { case ok, warn, off }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(kind == .ok ? MB.green : kind == .warn ? MB.orange : MB.dim)
                .frame(width: 7, height: 7)
                .shadow(color: (kind == .ok ? MB.green : .clear).opacity(0.5), radius: 3)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(kind == .ok ? MB.text : kind == .warn ? MB.orange : MB.muted)
        }
    }
}

/// Buttons: white (the one action), quiet (secondary), and text links.
struct MBButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet, danger }
    var kind: Kind = .quiet
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(kind == .primary ? Color.black : kind == .danger ? Color(red: 1, green: 0.42, blue: 0.4) : MB.text)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(kind == .primary ? MB.text : Color.white.opacity(configuration.isPressed ? 0.14 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(kind == .primary ? Color.clear : MB.line)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == MBButtonStyle {
    static var mbPrimary: MBButtonStyle { MBButtonStyle(kind: .primary) }
    static var mbQuiet: MBButtonStyle { MBButtonStyle(kind: .quiet) }
    static var mbDanger: MBButtonStyle { MBButtonStyle(kind: .danger) }
}

/// A search field in the Maben style.
struct MBSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MB.dim)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(MB.text)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(MB.dim)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MB.line))
    }
}

/// A command with a copy button, shown in monospace.
struct MBCommandRow: View {
    let command: String
    let detail: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(command)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(MB.text)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(MB.dim)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copied ? MB.green : MB.muted)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// The "maben awake" lockup, built to the brand rules (README › Lockup):
/// the mark is 0.72 em tall with its bottom on the text baseline, 0.28 em from
/// the name; "maben" semibold, the product name regular and dimmer, as on the website.
struct MBWordmark: View {
    var size: CGFloat = 16

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.28) {
            GateMark()
                .fill(MB.text)
                .frame(width: size * 0.72 * 68 / 58, height: size * 0.72)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] }
            HStack(alignment: .firstTextBaseline, spacing: size * 0.24) {
                Text("maben").font(.system(size: size, weight: .semibold)).tracking(size * 0.01)
                Text("awake").font(.system(size: size, weight: .regular)).foregroundStyle(MB.dim)
            }
            .foregroundStyle(MB.text)
        }
        .fixedSize()
    }
}

/// The Maben Gate mark (brand/logo/maben-mark-black.svg, viewBox 16 22 68 58).
struct GateMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 68, sy = rect.height / 58
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + (x - 16) * sx, y: rect.minY + (y - 22) * sy) }
        var path = Path()
        path.move(to: p(16, 80))
        path.addLine(to: p(16, 46))
        path.addQuadCurve(to: p(40, 22), control: p(16, 22))
        path.addLine(to: p(60, 22))
        path.addQuadCurve(to: p(84, 46), control: p(84, 22))
        path.addLine(to: p(84, 80))
        for centre in [CGFloat(64), 36] {
            path.addLine(to: p(centre + 8, 80))
            path.addLine(to: p(centre + 8, 50))
            path.addArc(center: p(centre, 50), radius: 8 * sx, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
            path.addLine(to: p(centre - 8, 80))
        }
        path.closeSubpath()
        return path
    }
}
