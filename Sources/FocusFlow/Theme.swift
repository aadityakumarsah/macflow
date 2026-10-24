import SwiftUI

enum AppTheme {
    static let green = Color(hex: 0x19784F)
    static let panel = Color.white
    static let elevated = Color(hex: 0xF5F7F2)
    static let workspace = Color(hex: 0xEDF1E9)
    static let line = Color.black.opacity(0.10)
}

extension View {
    func panelStyle(radius: CGFloat = 14) -> some View {
        self.background(AppTheme.panel, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(AppTheme.line))
    }
}

struct AppIconMark: View {
    var size: CGFloat = 28
    var body: some View {
        let packaged = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("FocusFlow_FocusFlow.bundle")) }
        if let url = (packaged ?? Bundle.module).url(forResource: "logo", withExtension: "png", subdirectory: "BrowserRecorder"), let logo = NSImage(contentsOf: url) {
            Image(nsImage: logo).resizable().scaledToFit().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        }
    }
}

struct BackgroundGradient: View {
    let style: BackgroundStyle
    var body: some View {
        switch style {
        case .aurora:
            LinearGradient(colors: [Color(hex: 0x7C3AED), Color(hex: 0xEC4899), Color(hex: 0xFB923C)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .sunset:
            LinearGradient(colors: [Color(hex: 0xFF512F), Color(hex: 0xDD2476), Color(hex: 0x6D28D9)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .ocean:
            LinearGradient(colors: [Color(hex: 0x06B6D4), Color(hex: 0x2563EB), Color(hex: 0x312E81)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .graphite:
            LinearGradient(colors: [Color(hex: 0x334155), Color(hex: 0x0F172A)], startPoint: .top, endPoint: .bottom)
        case .cream:
            LinearGradient(colors: [Color(hex: 0xFFF7ED), Color(hex: 0xFDE68A)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .none:
            Color.black
        }
    }
}

extension Color {
    init(hex: UInt) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}
