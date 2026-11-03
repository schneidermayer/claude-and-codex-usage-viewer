import SwiftUI
import WidgetKit

enum CodexUsageViewerPalette {
    static let mint = Color(red: 0.24, green: 0.68, blue: 0.53)
    static let lilac = Color(red: 0.60, green: 0.47, blue: 0.85)
    static let apricot = Color(red: 0.88, green: 0.53, blue: 0.32)

    static func accent(for index: Int) -> Color {
        [mint, lilac, apricot][abs(index) % 3]
    }

    static func index(for accountID: String) -> Int {
        CodexUsageViewerConstants.accountIDs.firstIndex(of: accountID) ?? 0
    }
}

struct CodexUsageViewerMark: View {
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.primary.opacity(0.16), lineWidth: size * 0.035)
                .padding(size * 0.15)
            Circle()
                .fill(.primary.opacity(0.9))
                .frame(width: size * 0.19, height: size * 0.19)
            Circle()
                .fill(CodexUsageViewerPalette.mint)
                .frame(width: size * 0.20, height: size * 0.20)
                .offset(x: 0, y: -size * 0.34)
            Circle()
                .fill(CodexUsageViewerPalette.lilac)
                .frame(width: size * 0.16, height: size * 0.16)
                .offset(x: -size * 0.29, y: size * 0.18)
            Circle()
                .fill(CodexUsageViewerPalette.apricot)
                .frame(width: size * 0.16, height: size * 0.16)
                .offset(x: size * 0.29, y: size * 0.18)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct CodexUsageViewerQuotaTrack: View {
    var remaining: Int
    var accent: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.13))
                Capsule()
                    .fill(accent.gradient)
                    .frame(width: max(0, geometry.size.width * CGFloat(max(0, min(100, remaining))) / 100))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct CodexUsageViewerQuotaRing: View {
    var remaining: Int
    var accent: Color
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle().stroke(accent.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, remaining))) / 100)
                .stroke(accent.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

struct CodexUsageViewerResetTrack: View {
    var fractionRemaining: Double?
    var accent: Color
    var segments = 7
    var height: CGFloat = 6
    var spacing: CGFloat = 4
    var widgetAccentable = false

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<segments, id: \.self) { segment in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.075))
                        if let fractionRemaining {
                            Capsule()
                                .fill(accent)
                                .frame(width: geometry.size.width * min(1, max(0, fractionRemaining * Double(segments) - Double(segment))))
                                .widgetAccentable(widgetAccentable)
                        }
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct CodexUsageViewerEyebrow: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(1.8)
            .foregroundStyle(.secondary)
    }
}

enum CodexUsageViewerFormatting {
    static func reset(_ window: QuotaWindow, now: Date = .now) -> String {
        guard let reset = window.resetDate else { return "Reset time unavailable" }
        guard reset > now else { return "Reset passed · refresh to check" }
        let minutes = max(1, Int(ceil(reset.timeIntervalSince(now) / 60)))
        if minutes < 60 { return "Resets in \(minutes)m" }
        if minutes < 1_440 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? "Resets in \(hours)h" : "Resets in \(hours)h \(remainder)m"
        }
        return "Resets \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    static func updated(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Not updated yet" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "Updated just now" }
        if seconds < 3_600 { return "Updated \(seconds / 60)m ago" }
        if seconds < 86_400 { return "Updated \(seconds / 3_600)h ago" }
        return "Updated \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

/// Monochrome provider identifiers. Marks belong to their respective owners.
/// Sources: https://claude.com/icon.svg and https://developers.openai.com/favicon.svg
struct CodexUsageViewerProviderMark: Shape {
    var provider: AccountProvider

    func path(in rect: CGRect) -> Path {
        let source = provider == .claude ? Self.claude : Self.openAI
        let bounds = source.boundingRect
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        return source.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                                tx: rect.midX - bounds.midX * scale,
                                                ty: rect.midY - bounds.midY * scale))
    }

    private static let claude = Path { path in
        path.move(to: CGPoint(x: 52.4285, y: 162.873))
        for point in [
            CGPoint(x: 98.7844, y: 136.879), CGPoint(x: 99.5485, y: 134.602), CGPoint(x: 98.7844, y: 133.334),
            CGPoint(x: 96.4921, y: 133.334), CGPoint(x: 88.7237, y: 132.862), CGPoint(x: 62.2346, y: 132.153),
            CGPoint(x: 39.3113, y: 131.207), CGPoint(x: 17.0249, y: 130.026), CGPoint(x: 11.4214, y: 128.844),
            CGPoint(x: 6.2, y: 121.873), CGPoint(x: 6.7094, y: 118.447), CGPoint(x: 11.4214, y: 115.257),
            CGPoint(x: 18.171, y: 115.847), CGPoint(x: 33.0711, y: 116.911), CGPoint(x: 55.485, y: 118.447),
            CGPoint(x: 71.6586, y: 119.392), CGPoint(x: 95.728, y: 121.873), CGPoint(x: 99.5485, y: 121.873),
            CGPoint(x: 100.058, y: 120.337), CGPoint(x: 98.7844, y: 119.392), CGPoint(x: 97.7656, y: 118.447),
            CGPoint(x: 74.5877, y: 102.732), CGPoint(x: 49.4995, y: 86.1905), CGPoint(x: 36.3823, y: 76.62),
            CGPoint(x: 29.3779, y: 71.7757), CGPoint(x: 25.8121, y: 67.2858), CGPoint(x: 24.2839, y: 57.3608),
            CGPoint(x: 30.6515, y: 50.2716), CGPoint(x: 39.3113, y: 50.8623), CGPoint(x: 41.4763, y: 51.4531),
            CGPoint(x: 50.2636, y: 58.1879), CGPoint(x: 68.9842, y: 72.7209), CGPoint(x: 93.4357, y: 90.6804),
            CGPoint(x: 97.0015, y: 93.6343), CGPoint(x: 98.4374, y: 92.6652), CGPoint(x: 98.6571, y: 91.9801),
            CGPoint(x: 97.0015, y: 89.2625), CGPoint(x: 83.757, y: 65.2772), CGPoint(x: 69.621, y: 40.8192),
            CGPoint(x: 63.2534, y: 30.6579), CGPoint(x: 61.5978, y: 24.632)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 60.579, y: 17.4246), control1: CGPoint(x: 60.9565, y: 22.1032), control2: CGPoint(x: 60.579, y: 20.0111))
        for point in [
            CGPoint(x: 67.8381, y: 7.49965), CGPoint(x: 71.9133, y: 6.19995), CGPoint(x: 81.7193, y: 7.49965),
            CGPoint(x: 85.7946, y: 11.0443), CGPoint(x: 91.9074, y: 24.9865), CGPoint(x: 101.714, y: 46.8451),
            CGPoint(x: 116.996, y: 76.62), CGPoint(x: 121.453, y: 85.4816), CGPoint(x: 123.873, y: 93.6343),
            CGPoint(x: 124.764, y: 96.1155), CGPoint(x: 126.292, y: 96.1155), CGPoint(x: 126.292, y: 94.6976),
            CGPoint(x: 127.566, y: 77.9197), CGPoint(x: 129.858, y: 57.3608), CGPoint(x: 132.15, y: 30.8942),
            CGPoint(x: 132.915, y: 23.4505), CGPoint(x: 136.608, y: 14.4708), CGPoint(x: 143.994, y: 9.62643),
            CGPoint(x: 149.725, y: 12.344), CGPoint(x: 154.437, y: 19.0788), CGPoint(x: 153.8, y: 23.4505),
            CGPoint(x: 150.998, y: 41.6463), CGPoint(x: 145.522, y: 70.1215), CGPoint(x: 141.957, y: 89.2625),
            CGPoint(x: 143.994, y: 89.2625), CGPoint(x: 146.414, y: 86.7813), CGPoint(x: 156.093, y: 74.0206),
            CGPoint(x: 172.266, y: 53.698), CGPoint(x: 179.398, y: 45.6635), CGPoint(x: 187.803, y: 36.802),
            CGPoint(x: 193.152, y: 32.5484), CGPoint(x: 203.34, y: 32.5484), CGPoint(x: 210.726, y: 43.6549),
            CGPoint(x: 207.415, y: 55.1159), CGPoint(x: 196.972, y: 68.3492), CGPoint(x: 188.312, y: 79.5739),
            CGPoint(x: 175.896, y: 96.2095), CGPoint(x: 168.191, y: 109.585), CGPoint(x: 168.882, y: 110.689),
            CGPoint(x: 170.738, y: 110.53), CGPoint(x: 198.755, y: 104.504), CGPoint(x: 213.91, y: 101.787),
            CGPoint(x: 231.994, y: 98.7149), CGPoint(x: 240.144, y: 102.496), CGPoint(x: 241.036, y: 106.395),
            CGPoint(x: 237.852, y: 114.311), CGPoint(x: 218.495, y: 119.037), CGPoint(x: 195.826, y: 123.645),
            CGPoint(x: 162.07, y: 131.592), CGPoint(x: 161.696, y: 131.893), CGPoint(x: 162.137, y: 132.547),
            CGPoint(x: 177.36, y: 133.925), CGPoint(x: 183.855, y: 134.279), CGPoint(x: 199.774, y: 134.279),
            CGPoint(x: 229.447, y: 136.524), CGPoint(x: 237.215, y: 141.605), CGPoint(x: 241.8, y: 147.867),
            CGPoint(x: 241.036, y: 152.711), CGPoint(x: 229.065, y: 158.737), CGPoint(x: 213.019, y: 154.956),
            CGPoint(x: 175.45, y: 145.977), CGPoint(x: 162.587, y: 142.787), CGPoint(x: 160.805, y: 142.787),
            CGPoint(x: 160.805, y: 143.85), CGPoint(x: 171.502, y: 154.366), CGPoint(x: 191.242, y: 172.089),
            CGPoint(x: 215.82, y: 195.011), CGPoint(x: 217.094, y: 200.682), CGPoint(x: 213.91, y: 205.172),
            CGPoint(x: 210.599, y: 204.699), CGPoint(x: 188.949, y: 188.394), CGPoint(x: 180.544, y: 181.069),
            CGPoint(x: 161.696, y: 165.118), CGPoint(x: 160.422, y: 165.118), CGPoint(x: 160.422, y: 166.772),
            CGPoint(x: 164.752, y: 173.152), CGPoint(x: 187.803, y: 207.771), CGPoint(x: 188.949, y: 218.405),
            CGPoint(x: 187.294, y: 221.832), CGPoint(x: 181.308, y: 223.959), CGPoint(x: 174.813, y: 222.777),
            CGPoint(x: 161.187, y: 203.754), CGPoint(x: 147.305, y: 182.486), CGPoint(x: 136.098, y: 163.345),
            CGPoint(x: 134.745, y: 164.2), CGPoint(x: 128.075, y: 235.42), CGPoint(x: 125.019, y: 239.082),
            CGPoint(x: 117.887, y: 241.8), CGPoint(x: 111.902, y: 237.31), CGPoint(x: 108.718, y: 229.984),
            CGPoint(x: 111.902, y: 215.452), CGPoint(x: 115.722, y: 196.547), CGPoint(x: 118.779, y: 181.541),
            CGPoint(x: 121.58, y: 162.873), CGPoint(x: 123.291, y: 156.636), CGPoint(x: 123.14, y: 156.219),
            CGPoint(x: 121.773, y: 156.449), CGPoint(x: 107.699, y: 175.752), CGPoint(x: 86.304, y: 204.699),
            CGPoint(x: 69.3663, y: 222.777), CGPoint(x: 65.291, y: 224.431), CGPoint(x: 58.2867, y: 220.768),
            CGPoint(x: 58.9235, y: 214.27), CGPoint(x: 62.8713, y: 208.48), CGPoint(x: 86.304, y: 178.705),
            CGPoint(x: 100.44, y: 160.155), CGPoint(x: 109.551, y: 149.507), CGPoint(x: 109.462, y: 147.967),
            CGPoint(x: 108.959, y: 147.924), CGPoint(x: 46.6977, y: 188.512), CGPoint(x: 35.6182, y: 189.93),
            CGPoint(x: 30.7788, y: 185.44), CGPoint(x: 31.4156, y: 178.115), CGPoint(x: 33.7079, y: 175.752),
            CGPoint(x: 52.4285, y: 162.873)
        ] { path.addLine(to: point) }
        path.closeSubpath()
    }

    private static let openAI = Path { path in
        path.move(to: CGPoint(x: 9.94494, y: 9.59163))
        for point in [
            CGPoint(x: 9.94494, y: 8.13227)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 10.0985, y: 7.85575), control1: CGPoint(x: 9.94494, y: 8.00935), control2: CGPoint(x: 9.99105, y: 7.91713))
        for point in [
            CGPoint(x: 13.0327, y: 6.16599)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 14.3998, y: 5.8281), control1: CGPoint(x: 13.4321, y: 5.93558), control2: CGPoint(x: 13.9083, y: 5.8281))
        path.addCurve(to: CGPoint(x: 17.4108, y: 8.77751), control1: CGPoint(x: 16.2432, y: 5.8281), control2: CGPoint(x: 17.4108, y: 7.25677))
        path.addCurve(to: CGPoint(x: 17.3953, y: 9.13083), control1: CGPoint(x: 17.4108, y: 8.885), control2: CGPoint(x: 17.4108, y: 9.00792))
        for point in [
            CGPoint(x: 14.3537, y: 7.34884)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 13.8007, y: 7.34884), control1: CGPoint(x: 14.1694, y: 7.24135), control2: CGPoint(x: 13.985, y: 7.24135))
        for point in [
            CGPoint(x: 9.94494, y: 9.59163)
        ] { path.addLine(to: point) }
        path.closeSubpath()
        path.move(to: CGPoint(x: 16.7963, y: 15.2755))
        for point in [
            CGPoint(x: 16.7963, y: 11.7883)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 16.5197, y: 11.3121), control1: CGPoint(x: 16.7963, y: 11.5732), control2: CGPoint(x: 16.704, y: 11.4196))
        for point in [
            CGPoint(x: 12.664, y: 9.0693), CGPoint(x: 13.9236, y: 8.34725)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 14.2308, y: 8.34725), control1: CGPoint(x: 14.0311, y: 8.28587), control2: CGPoint(x: 14.1234, y: 8.28587))
        for point in [
            CGPoint(x: 17.165, y: 10.037)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 18.5782, y: 12.587), control1: CGPoint(x: 18.0099, y: 10.5287), control2: CGPoint(x: 18.5782, y: 11.5732))
        path.addCurve(to: CGPoint(x: 16.7963, y: 15.2753), control1: CGPoint(x: 18.5782, y: 13.7544), control2: CGPoint(x: 17.887, y: 14.8298))
        for point in [
            CGPoint(x: 16.7963, y: 15.2755)
        ] { path.addLine(to: point) }
        path.closeSubpath()
        path.move(to: CGPoint(x: 9.03861, y: 12.2031))
        for point in [
            CGPoint(x: 7.77896, y: 11.4658)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 7.62535, y: 11.1893), control1: CGPoint(x: 7.67146, y: 11.4045), control2: CGPoint(x: 7.62535, y: 11.3122))
        for point in [
            CGPoint(x: 7.62535, y: 7.8098)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 10.5902, y: 4.92176), control1: CGPoint(x: 7.62535, y: 6.16613), control2: CGPoint(x: 8.88501, y: 4.92176))
        path.addCurve(to: CGPoint(x: 12.3415, y: 5.52089), control1: CGPoint(x: 11.2354, y: 4.92176), control2: CGPoint(x: 11.8344, y: 5.13689))
        for point in [
            CGPoint(x: 9.31526, y: 7.27218)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 9.03875, y: 7.74841), control1: CGPoint(x: 9.13097, y: 7.37968), control2: CGPoint(x: 9.03875, y: 7.53328))
        for point in [
            CGPoint(x: 9.03875, y: 12.2033), CGPoint(x: 9.03861, y: 12.2031)
        ] { path.addLine(to: point) }
        path.closeSubpath()
        path.move(to: CGPoint(x: 11.75, y: 13.77))
        for point in [
            CGPoint(x: 9.94494, y: 12.7562), CGPoint(x: 9.94494, y: 10.6056), CGPoint(x: 11.75, y: 9.59178),
            CGPoint(x: 13.5549, y: 10.6056), CGPoint(x: 13.5549, y: 12.7562), CGPoint(x: 11.75, y: 13.77)
        ] { path.addLine(to: point) }
        path.closeSubpath()
        path.move(to: CGPoint(x: 12.9098, y: 18.44))
        path.addCurve(to: CGPoint(x: 11.1585, y: 17.8409), control1: CGPoint(x: 12.2645, y: 18.44), control2: CGPoint(x: 11.6655, y: 18.2249))
        for point in [
            CGPoint(x: 14.1847, y: 16.0896)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 14.4612, y: 15.6134), control1: CGPoint(x: 14.369, y: 15.9821), control2: CGPoint(x: 14.4612, y: 15.8285))
        for point in [
            CGPoint(x: 14.4612, y: 11.1585), CGPoint(x: 15.7363, y: 11.8958)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 15.8899, y: 12.1723), control1: CGPoint(x: 15.8438, y: 11.9572), control2: CGPoint(x: 15.8899, y: 12.0494))
        for point in [
            CGPoint(x: 15.8899, y: 15.5519)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 12.9098, y: 18.44), control1: CGPoint(x: 15.8899, y: 17.1955), control2: CGPoint(x: 14.6148, y: 18.44))
        path.closeSubpath()
        path.move(to: CGPoint(x: 9.26901, y: 15.0144))
        for point in [
            CGPoint(x: 6.33486, y: 13.3246)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 4.92161, y: 10.7746), control1: CGPoint(x: 5.4899, y: 12.833), control2: CGPoint(x: 4.92161, y: 11.7885))
        path.addCurve(to: CGPoint(x: 6.71886, y: 8.0863), control1: CGPoint(x: 4.92161, y: 9.59177), control2: CGPoint(x: 5.62824, y: 8.53183))
        for point in [
            CGPoint(x: 6.71886, y: 11.5887)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 6.99538, y: 12.065), control1: CGPoint(x: 6.71886, y: 11.8039), control2: CGPoint(x: 6.81109, y: 11.9575))
        for point in [
            CGPoint(x: 10.8359, y: 14.2923), CGPoint(x: 9.57621, y: 15.0144)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 9.26901, y: 15.0144), control1: CGPoint(x: 9.46872, y: 15.0758), control2: CGPoint(x: 9.37649, y: 15.0758))
        path.closeSubpath()
        path.move(to: CGPoint(x: 9.10013, y: 17.5337))
        path.addCurve(to: CGPoint(x: 6.08919, y: 14.6149), control1: CGPoint(x: 7.36426, y: 17.5337), control2: CGPoint(x: 6.08919, y: 16.2279))
        path.addCurve(to: CGPoint(x: 6.11988, y: 14.2462), control1: CGPoint(x: 6.08919, y: 14.492), control2: CGPoint(x: 6.1046, y: 14.3691))
        for point in [
            CGPoint(x: 9.1461, y: 15.9975)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 9.69912, y: 15.9975), control1: CGPoint(x: 9.33039, y: 16.105), control2: CGPoint(x: 9.51483, y: 16.105))
        for point in [
            CGPoint(x: 13.5549, y: 13.7702), CGPoint(x: 13.5549, y: 15.2295)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 13.4013, y: 15.506), control1: CGPoint(x: 13.5549, y: 15.3524), control2: CGPoint(x: 13.5088, y: 15.4446))
        for point in [
            CGPoint(x: 10.4671, y: 17.1958)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 9.09999, y: 17.5337), control1: CGPoint(x: 10.0677, y: 17.4262), control2: CGPoint(x: 9.59148, y: 17.5337))
        for point in [
            CGPoint(x: 9.10013, y: 17.5337)
        ] { path.addLine(to: point) }
        path.closeSubpath()
        path.move(to: CGPoint(x: 12.9098, y: 19.3616))
        path.addCurve(to: CGPoint(x: 16.6735, y: 16.2893), control1: CGPoint(x: 14.7685, y: 19.3616), control2: CGPoint(x: 16.32, y: 18.0406))
        path.addCurve(to: CGPoint(x: 19.5, y: 12.5872), control1: CGPoint(x: 18.3939, y: 15.8438), control2: CGPoint(x: 19.5, y: 14.2308))
        path.addCurve(to: CGPoint(x: 18.2096, y: 9.71454), control1: CGPoint(x: 19.5, y: 11.5118), control2: CGPoint(x: 19.0391, y: 10.4673))
        path.addCurve(to: CGPoint(x: 18.3326, y: 8.74682), control1: CGPoint(x: 18.2864, y: 9.39192), control2: CGPoint(x: 18.3326, y: 9.0693))
        path.addCurve(to: CGPoint(x: 14.4921, y: 4.90634), control1: CGPoint(x: 18.3326, y: 6.55014), control2: CGPoint(x: 16.5505, y: 4.90634))
        path.addCurve(to: CGPoint(x: 13.2785, y: 5.10605), control1: CGPoint(x: 14.0774, y: 4.90634), control2: CGPoint(x: 13.6779, y: 4.96772))
        path.addCurve(to: CGPoint(x: 10.5902, y: 4), control1: CGPoint(x: 12.5872, y: 4.43011), control2: CGPoint(x: 11.6347, y: 4))
        path.addCurve(to: CGPoint(x: 6.8265, y: 7.07232), control1: CGPoint(x: 8.7314, y: 4), control2: CGPoint(x: 7.17996, y: 5.32103))
        path.addCurve(to: CGPoint(x: 4, y: 10.7745), control1: CGPoint(x: 5.10605, y: 7.51786), control2: CGPoint(x: 4, y: 9.13083))
        path.addCurve(to: CGPoint(x: 5.29035, y: 13.6471), control1: CGPoint(x: 4, y: 11.8498), control2: CGPoint(x: 4.4608, y: 12.8944))
        path.addCurve(to: CGPoint(x: 5.16743, y: 14.6148), control1: CGPoint(x: 5.21354, y: 13.9697), control2: CGPoint(x: 5.16743, y: 14.2923))
        path.addCurve(to: CGPoint(x: 9.00792, y: 18.4552), control1: CGPoint(x: 5.16743, y: 16.8114), control2: CGPoint(x: 6.94941, y: 18.4552))
        path.addCurve(to: CGPoint(x: 10.2215, y: 18.2556), control1: CGPoint(x: 9.42261, y: 18.4552), control2: CGPoint(x: 9.82204, y: 18.3939))
        path.addCurve(to: CGPoint(x: 12.9098, y: 19.3616), control1: CGPoint(x: 10.9127, y: 18.9315), control2: CGPoint(x: 11.8651, y: 19.3616))
        path.closeSubpath()
    }

}
