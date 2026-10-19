import SwiftUI

/// 局部尼尔风主题。只用在换源、段评、评论这类信息面板上，不覆盖全局设置。
struct NieRPalette {
    let isDark: Bool

    init(_ scheme: ColorScheme) {
        self.isDark = scheme == .dark
    }

    var background: Color { color(isDark ? "#191A18" : "#E7DFCF") }
    var panel: Color { color(isDark ? "#232420" : "#F0E9DC") }
    var panelRaised: Color { color(isDark ? "#2B2C27" : "#F5EFE4") }
    var ink: Color { color(isDark ? "#E9E1D2" : "#1E1D1A") }
    var muted: Color { color(isDark ? "#9C9588" : "#6E675C") }
    var line: Color { color(isDark ? "#4A4841" : "#B9AE9B") }
    var accent: Color { color(isDark ? "#D05A49" : "#A63A2E") }
    var accentSoft: Color { accent.opacity(isDark ? 0.22 : 0.13) }
    var warning: Color { color(isDark ? "#D2A24C" : "#8C6428") }
    var grid: Color { ink.opacity(isDark ? 0.035 : 0.045) }

    private func color(_ hex: String) -> Color {
        Color(hex: hex) ?? .gray
    }
}

struct NieRBackdrop: View {
    let palette: NieRPalette

    var body: some View {
        ZStack {
            palette.background
            Canvas { context, size in
                let spacing: CGFloat = 28
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += spacing
                }
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += spacing
                }
                context.stroke(path, with: .color(palette.grid), lineWidth: 0.5)

                var scan = Path()
                var sy: CGFloat = 0
                while sy <= size.height {
                    scan.move(to: CGPoint(x: 0, y: sy))
                    scan.addLine(to: CGPoint(x: size.width, y: sy))
                    sy += 4
                }
                context.stroke(scan, with: .color(palette.ink.opacity(0.012)), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
    }
}

struct NieRSheetHeader: View {
    let palette: NieRPalette
    let kicker: String
    let title: String
    let subtitle: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(kicker)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundColor(palette.accent)
                    Text(title)
                        .font(.system(size: 27, weight: .bold))
                        .foregroundColor(palette.ink)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(palette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    HStack(spacing: 5) {
                        Rectangle()
                            .fill(palette.accent)
                            .frame(width: 5, height: 5)
                        Text("关闭")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(palette.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .overlay(
                        Rectangle()
                            .stroke(palette.accent.opacity(0.55), lineWidth: 0.7)
                    )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 4) {
                Rectangle()
                    .fill(palette.accent)
                    .frame(width: 32, height: 2)
                Rectangle()
                    .fill(palette.line)
                    .frame(height: 0.5)
                Rectangle()
                    .fill(palette.ink.opacity(0.7))
                    .frame(width: 4, height: 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

struct NieRSectionTitle: View {
    let palette: NieRPalette
    let index: String
    let title: String
    let trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(palette.accent)
                .frame(width: 2, height: 12)
            Text(index)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(palette.accent)
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(palette.muted)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(palette.muted)
            }
        }
    }
}

struct NieRPanel<Content: View>: View {
    let palette: NieRPalette
    var raised: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(12)
            .background(raised ? palette.panelRaised : palette.panel)
            .overlay(
                Rectangle()
                    .stroke(palette.line.opacity(0.8), lineWidth: 0.7)
            )
            .overlay(alignment: .topLeading) { cornerMarks }
    }

    private var cornerMarks: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(palette.accent)
                .frame(width: 10, height: 1.5)
            Rectangle()
                .fill(palette.accent)
                .frame(width: 1.5, height: 10)
        }
    }
}

struct NieRDivider: View {
    let palette: NieRPalette

    var body: some View {
        Rectangle()
            .fill(palette.line.opacity(0.65))
            .frame(height: 0.6)
    }
}

struct NieRBadge: View {
    let palette: NieRPalette
    let text: String
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.6)
            .foregroundColor(filled ? palette.background : palette.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(filled ? palette.accent : palette.accentSoft)
            .overlay(
                Rectangle()
                    .stroke(palette.accent.opacity(filled ? 0 : 0.5), lineWidth: 0.6)
            )
    }
}

struct NieRScanBar: View {
    let palette: NieRPalette
    let progress: Double
    var segments: Int = 16

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { index in
                let threshold = Double(index + 1) / Double(segments)
                Rectangle()
                    .fill(progress >= threshold ? palette.accent : palette.line.opacity(0.35))
                    .frame(height: 3)
            }
        }
    }
}

struct NieRCornerFrame: ViewModifier {
    let palette: NieRPalette

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                Rectangle()
                    .fill(palette.line.opacity(0.7))
                    .frame(width: 18, height: 0.6)
            }
            .overlay(alignment: .bottomTrailing) {
                Rectangle()
                    .fill(palette.line.opacity(0.7))
                    .frame(width: 18, height: 0.6)
            }
    }
}

extension View {
    func nierCornerFrame(_ palette: NieRPalette) -> some View {
        modifier(NieRCornerFrame(palette: palette))
    }
}
