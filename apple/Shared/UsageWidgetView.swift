import SwiftUI
import WidgetKit

struct UsageWidgetView: View {
    let entry: UsageEntry
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { familyOverride ?? environmentFamily }
    private let ink = Color(red: 0.34, green: 0.43, blue: 0.49)
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
                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
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
                Text("\(p.name) \(p.highestMetric.map { "\($0.percent)%" } ?? "—") · \(entry.snapshot!.isHealthy(at: entry.date) ? "Connected" : "Check app")")
            } else { Text("AI Usage · Open app to connect") }
        }
    }
    private var compact: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let snapshot = entry.snapshot, !snapshot.providers.isEmpty {
                ForEach(Array(snapshot.rankedProviders.prefix(2))) { p in
                    HStack(spacing: 6) {
                        Circle().trim(from: 0, to: CGFloat(p.highestMetric?.percent ?? 0) / 100)
                            .stroke(style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90)).frame(width: 14, height: 14)
                        Text(p.name).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(p.highestMetric.map { "\($0.percent)%" } ?? p.balance ?? "—").monospacedDigit()
                    }.font(.caption.weight(.medium))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibility(p))
                }
                if family != .systemSmall {
                    Text(snapshot.isHealthy(at: entry.date) ? "Connected" : "Open app to check connections")
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
                            Text("\(metric.percent)%").monospacedDigit()
                        }.font(.caption)
                    }
                    if p.metrics.isEmpty { Text(p.balance ?? "Usage unavailable").font(.caption) }
                    if snapshot.providers.count > 1 { Text("\(snapshot.providers.count - 1) other connections").font(.caption2).foregroundStyle(.secondary) }
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
                .stroke(ink, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90)).widgetAccentable()
            VStack(spacing: 1) {
                Text(p.highestMetric.map { "\($0.percent)%" } ?? "—").font(size > 70 ? .title2.weight(.medium) : .subheadline.weight(.medium)).monospacedDigit()
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
        "\(p.name), \(p.highestMetric.map { "\($0.label), \($0.percent) percent used" } ?? "No quota data"), \(p.displayHealth(at: entry.date).phrase)"
    }
}
