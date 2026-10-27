import SwiftUI
import UIKit
import IBoardTheme

extension ThemeColor {
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
    }
}

extension FontWeightToken {
    var swiftUI: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

/// Live preview built only from the theme model (no keyboard code), so what you edit is what the model says.
/// `photo` is the pre-sized backdrop image when the variant uses a photo. Backdrop `systemMaterial` is drawn as a
/// neutral stand-in because the real system glass is only drawn by iOS inside the keyboard (P-22).
struct ThemePreviewView: View {
    let variant: ThemeVariant
    let appearance: ThemeAppearance
    var photo: UIImage?

    private let rows: [[String]] = [
        Array("qwertyuiop").map(String.init),
        Array("asdfghjkl").map(String.init),
        ["shift"] + Array("zxcvbnm").map(String.init) + ["del"],
    ]

    var body: some View {
        VStack(spacing: 6) {
            strip
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(row, id: \.self) { key in
                        keyView(key)
                    }
                }
            }
            HStack(spacing: 5) {
                keyView("123", flex: 1.4)
                keyView("space", flex: 5)
                keyView("return", flex: 1.6, action: true)
            }
        }
        .padding(8)
        .background(backdrop)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .bottomTrailing) { trailSample }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyboard preview")
    }

    private var strip: some View {
        HStack {
            ForEach(["Hello", "Hi", "Hey"], id: \.self) { s in
                Text(s).font(.footnote).foregroundStyle(variant.labels.strip.swiftUI).frame(maxWidth: .infinity)
                if s != "Hey" { Rectangle().fill(variant.strip.separator.swiftUI).frame(width: 0.5, height: 18) }
            }
        }
        .padding(.vertical, 6)
        .background(variant.strip.kind == .plain ? Color.clear : variant.strip.background.swiftUI)
    }

    private func keyView(_ key: String, flex: CGFloat = 1, action: Bool = false) -> some View {
        let k = variant.keys
        let isAction = action || key == "shift" || key == "del"
        let fill = (isAction ? k.actionFill : k.fill).swiftUI.opacity(k.opacity)
        let label = isAction && action ? variant.labels.actionKey : variant.labels.key
        let shape = RoundedRectangle(cornerRadius: k.cornerRadius)
        return Text(symbol(key))
            .font(.system(size: key.count == 1 ? min(variant.fonts.letterSize, 22) : 12,
                          weight: variant.fonts.weight.swiftUI))
            .foregroundStyle(label.swiftUI)
            .frame(minWidth: key.count == 1 ? 0 : 44 * flex, maxWidth: key.count == 1 ? 36 : .infinity, minHeight: 34)
            .layoutPriority(Double(flex))
            .background(shape.fill(fill))
            .overlay(shape.stroke(k.borderColor.swiftUI, lineWidth: k.borderWidth))
            .shadow(color: k.shadowColor.swiftUI, radius: k.shadowRadius, x: 0, y: k.shadowOffsetY)
    }

    private func symbol(_ key: String) -> String {
        switch key {
        case "shift": "\u{21E7}"
        case "del": "\u{232B}"
        case "space": ""
        default: key
        }
    }

    @ViewBuilder private var backdrop: some View {
        let b = variant.backdrop
        ZStack {
            switch b.kind {
            case .systemMaterial:
                Rectangle().fill(appearance == .light ? Color(white: 0.82) : Color(white: 0.17))
            case .solid:
                Rectangle().fill(b.solid.swiftUI)
            case .gradient:
                LinearGradient(colors: b.gradient.map(\.swiftUI), startPoint: .top, endPoint: .bottom)
                    .rotationEffect(.degrees(b.gradientAngle - 90))
                    .scaleEffect(1.5)
            case .photo:
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFill().blur(radius: b.blurRadius)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.4))
                }
            }
            if b.kind == .photo || b.kind == .gradient { Color.black.opacity(variant.dim) }
        }
        .opacity(b.kind == .systemMaterial ? 1 : variant.translucency * 0.5 + 0.5)
    }

    private var trailSample: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 40)); p.addQuadCurve(to: CGPoint(x: 70, y: 0), control: CGPoint(x: 20, y: -10))
        }
        .stroke(variant.swipeTrail.color.swiftUI, style: StrokeStyle(lineWidth: variant.swipeTrail.width, lineCap: .round))
        .frame(width: 70, height: 40)
        .padding(14)
        .allowsHitTesting(false)
    }
}
