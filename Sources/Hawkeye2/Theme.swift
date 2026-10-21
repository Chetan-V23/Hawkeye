import SwiftUI

enum Palette {
    static let background = Color(hex: 0x151917)
    static let sidebar = Color(hex: 0x1A1F1C)
    static let card = Color(hex: 0x202722)
    static let line = Color.white.opacity(0.085)
    static let text = Color(hex: 0xE9EADF)
    static let muted = Color(hex: 0x8C998F)
    static let green = Color(hex: 0xC7E5AC)
    static let orange = Color(hex: 0xE8B58A)
    static let blue = Color(hex: 0x8FAFEA)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .semibold))
            .tracking(1.7).foregroundStyle(Palette.muted)
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Palette.green.opacity(configuration.isPressed ? 0.15 : 0.07),
                        in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(Palette.green)
    }
}
