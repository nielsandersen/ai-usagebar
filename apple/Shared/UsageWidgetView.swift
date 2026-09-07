import SwiftUI
import WidgetKit

/// Match the menu bar's 75% / 90% warning thresholds, with legible colors
/// in both appearances. Text cues remain meaningful in tinted widgets.
enum WidgetUsageStyle {
    static func color(_ percent: Int?, dark: Bool) -> Color {
        switch percent ?? 0 {
        case 90...: return dark ? Color(red: 1, green: 0.51, blue: 0.57) : Color(red: 0.70, green: 0.14, blue: 0.21)
        case 75..<90: return dark ? Color(red: 1, green: 0.82, blue: 0.40) : Color(red: 0.58, green: 0.38, blue: 0)
        default: return dark ? Color(red: 0.47, green: 0.60, blue: 1) : Color(red: 0.14, green: 0.33, blue: 0.84)
        }
    }
    static func warning(_ percent: Int?) -> String? {
        guard let percent else { return nil }
        if percent >= 100 { return "Limit reached" }
        if percent >= 90 { return "Near limit" }
        if percent >= 75 { return "High usage" }
        return nil
    }
}

struct UsageWidgetView: View {
    let entry: UsageEntry
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { familyOverride ?? environmentFamily }
    @Environment(\.colorScheme) private var colorScheme
    private func usageColor(_ percent: Int?) -> Color { WidgetUsageStyle.color(percent, dark: colorScheme == .dark) }
    var body: some View {
        Group {
            #if os(iOS)
            if family == .accessoryInline { inline }
            else if family == .accessoryRectangular { compact }
            else { home }
            #else
            home
            #endif
        }
        .privacySensitive()
    }
    private var home: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI Usage").font(.caption.weight(.semibold))
                Spacer()
                Image(systemName: "circle.dotted").foregroundStyle(usageColor(nil)).accessibilityHidden(true)
            }
            if let snapshot = entry.snapshot, !snapshot.providers.isEmpty {
                if family == .systemSmall { compact }
                else if family == .systemMedium { medium(snapshot) }
                else { large(snapshot) }
                Spacer(minLength: 0)
                footer(snapshot)
            } else {
                Spacer(minLength: 0)
                Image(systemName: "arrow.triangle.2.circlepath").font(.title2).foregroundStyle(.secondary)
                Text("Waiting for your Mac").font(.headline)
                Text("Open AI Usage Bar to connect widgets.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
    private var inline: some View {
        Group {
            if let p = entry.snapshot?.rankedProviders.first {
                Text("\(p.name) \(p.highestMetric.map { "\($0.percent)%" } ?? "—") · \(entry.snapshot!.isHealthy(at: entry.date) ? (WidgetUsageStyle.warning(p.highestMetric?.percent) ?? "Connected") : "Check app")")
            } else { Text("AI Usage · Open app to connect") }
        }
    }
    private var compact: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let snapshot = entry.snapshot, !snapshot.providers.isEmpty {
                ForEach(Array(snapshot.rankedProviders.prefix(2))) { p in
                    HStack(spacing: 6) {
                        Circle().trim(from: 0, to: CGFloat(p.highestMetric?.percent ?? 0) / 100)
                            .stroke(usageColor(p.highestMetric?.percent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90)).frame(width: 14, height: 14)
                        Text(p.name).lineLimit(1)
                        Spacer(minLength: 2)
                        if WidgetUsageStyle.warning(p.highestMetric?.percent) != nil {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                                .foregroundStyle(usageColor(p.highestMetric?.percent)).accessibilityHidden(true)
                        }
                        Text(p.highestMetric.map { "\($0.percent)%" } ?? p.balance ?? "—").monospacedDigit()
                            .foregroundStyle(usageColor(p.highestMetric?.percent))
                    }.font(.caption.weight(.medium))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibility(p))
                }
                if family != .systemSmall {
                    Text(snapshot.isHealthy(at: entry.date) ? (WidgetUsageStyle.warning(snapshot.rankedProviders.first?.highestMetric?.percent) ?? "Connected") : "Open app to check connections")
                        .font(.caption2).lineLimit(1)
                } else if snapshot.providers.count > 2 {
                    Text("+\(snapshot.providers.count - 2) more").font(.caption2).foregroundStyle(.secondary)
                }
            } else { Text("Open AI Usage Bar to connect").font(.caption) }
        }
    }
    private func medium(_ snapshot: UsageSnapshot) -> some View {
        HStack(spacing: 18) {
            if let p = snapshot.rankedProviders.first {
                donut(p, size: 82)
                VStack(alignment: .leading, spacing: 5) {
                    Text(p.name).font(.headline).lineLimit(1)
                    ForEach(Array(p.metrics.prefix(2).enumerated()), id: \.offset) { _, metric in
                        HStack {
                            Text(metric.label).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text("\(metric.percent)%").monospacedDigit().foregroundStyle(usageColor(metric.percent))
                        }.font(.caption)
                    }
                    if p.metrics.isEmpty { Text(p.balance ?? "Usage unavailable").font(.caption) }
                    if let warning = WidgetUsageStyle.warning(p.highestMetric?.percent) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption2)
                            .foregroundStyle(usageColor(p.highestMetric?.percent))
                    } else if snapshot.providers.count > 1 { Text("\(snapshot.providers.count - 1) other connections").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private func large(_ snapshot: UsageSnapshot) -> some View {
        VStack(spacing: 16) {
            ForEach(Array(snapshot.rankedProviders.prefix(3))) { p in
                HStack(spacing: 16) {
                    donut(p, size: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.name).font(.headline).lineLimit(1)
                        Text(p.highestMetric?.label ?? p.balance ?? "Usage unavailable").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let warning = WidgetUsageStyle.warning(p.highestMetric?.percent) {
                            Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption2)
                                .foregroundStyle(usageColor(p.highestMetric?.percent))
                        }
                        if p.displayHealth(at: entry.date) != .healthy {
                            Text(p.displayHealth(at: entry.date).phrase).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if snapshot.providers.count > 3 { Text("+\(snapshot.providers.count - 3) more connections").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func donut(_ p: ProviderUsage, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: 7)
            Circle().trim(from: 0, to: CGFloat(p.highestMetric?.percent ?? 0) / 100)
                .stroke(usageColor(p.highestMetric?.percent), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90)).widgetAccentable()
            VStack(spacing: 1) {
                Text(p.highestMetric.map { "\($0.percent)%" } ?? "—").font(size > 70 ? .title2.weight(.medium) : .subheadline.weight(.medium)).monospacedDigit().foregroundStyle(usageColor(p.highestMetric?.percent))
                if size > 70 { Text("used").font(.caption2).foregroundStyle(.secondary) }
            }
        }.frame(width: size, height: size)
        .accessibilityElement(children: .ignore).accessibilityLabel(accessibility(p))
    }
    private func footer(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(family == .systemSmall ? (snapshot.isHealthy(at: entry.date) ? "Connected" : "Needs attention") : snapshot.summary(at: entry.date), systemImage: snapshot.isHealthy(at: entry.date) ? "checkmark.circle" : "clock")
                .font(.caption2).lineLimit(2)
                .accessibilityLabel(snapshot.summary(at: entry.date))
            HStack(spacing: 3) {
                Text("Mac update")
                Text(snapshot.generatedAt, style: .relative)
                Text("ago")
            }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private func accessibility(_ p: ProviderUsage) -> String {
        "\(p.name), \(p.highestMetric.map { "\($0.label), \($0.percent) percent used, \(WidgetUsageStyle.warning($0.percent) ?? "Within limit")" } ?? "No quota data"), \(p.displayHealth(at: entry.date).phrase)"
    }
}
