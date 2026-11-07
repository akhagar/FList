import SwiftUI
import WidgetKit

@main
struct OurStockWidgets: WidgetBundle {
    var body: some Widget {
        NeededWidget()
        BuyingWidget()
    }
}

struct NeededWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetList.needed.kind, provider: StockTimelineProvider()) { entry in
            StockWidgetView(entry: entry, list: .needed)
        }
        .configurationDisplayName("Needed")
        .description("Your latest saved missing items. Tap to open the list.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct BuyingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetList.buying.kind, provider: StockTimelineProvider()) { entry in
            StockWidgetView(entry: entry, list: .buying)
        }
        .configurationDisplayName("To buy")
        .description("Your latest saved items you plan to buy. Tap to open the list.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StockEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot

    static var preview: Self {
        let items = ["Milk", "Eggs", "Bread"].map {
            WidgetSnapshot.Item(id: UUID(), name: String(localized: String.LocalizationValue($0)), quantity: 1)
        }
        return StockEntry(date: .now, snapshot: WidgetSnapshot(
            hasHousehold: true, householdName: String(localized: "Family list"),
            languageCode: Bundle.main.preferredLocalizations.first ?? "en",
            needed: .init(items: items), buying: .init(items: Array(items.prefix(2)))
        ))
    }
}

struct StockTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> StockEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (StockEntry) -> Void) {
        completion(context.isPreview ? .preview : StockEntry(date: .now, snapshot: WidgetSnapshotStore.shared.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StockEntry>) -> Void) {
        let entry = StockEntry(date: .now, snapshot: WidgetSnapshotStore.shared.load())
        // Re-read the local cache periodically as a fallback. This is a request,
        // not a timer: iOS decides when to run it. App saves also request reloads.
        completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(30 * 60))))
    }
}

struct StockWidgetView: View {
    let entry: StockEntry
    let list: WidgetList
    @Environment(\.widgetFamily) private var family
    @Environment(\.locale) private var systemLocale

    private var content: WidgetSnapshot.List { entry.snapshot.list(list) }
    private var title: LocalizedStringKey { list == .needed ? "Needed" : "To buy" }
    private var symbol: String { list == .needed ? "basket.fill" : "cart.fill" }
    private var accent: Color { Color(red: 0.18, green: 0.49, blue: 0.35) }
    private var locale: Locale {
        entry.snapshot.languageCode.isEmpty ? systemLocale : Locale(identifier: entry.snapshot.languageCode)
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label {
                    if entry.snapshot.hasHousehold {
                        Text("\(Text(title)) \(content.totalCount)")
                    } else {
                        Text("Open OurStock")
                    }
                } icon: { Image(systemName: symbol) }
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 1) {
                        Image(systemName: symbol).font(.caption)
                        if entry.snapshot.hasHousehold {
                            Text(content.totalCount, format: .number)
                                .font(.title3.bold())
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                        }
                    }
                }
                .accessibilityLabel(Text(title))
                .accessibilityValue(entry.snapshot.hasHousehold ? Text(content.totalCount, format: .number) : Text("Open OurStock"))
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Label { Text("\(Text(title)) · \(content.totalCount)") } icon: { Image(systemName: symbol) }
                        .font(.headline)
                    if !entry.snapshot.hasHousehold {
                        Text("Open OurStock to choose a list.")
                    } else if content.totalCount == 0 {
                        emptyMessage
                    } else {
                        ForEach(content.items.prefix(2)) { item in
                            Text(verbatim: item.name).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                homeScreen
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(list.url)
        .privacySensitive()
        .environment(\.locale, locale)
        .environment(\.layoutDirection, locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }

    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(title, systemImage: symbol)
                        .font(.subheadline.bold())
                        .foregroundStyle(accent)
                        .widgetAccentable()
                    Text(verbatim: entry.snapshot.householdName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .privacySensitive()
                }
                Spacer(minLength: 4)
                if entry.snapshot.hasHousehold {
                    Text(content.totalCount, format: .number)
                        .font(.title.bold())
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            if !entry.snapshot.hasHousehold {
                Spacer(minLength: 0)
                Text("Open OurStock to choose a list.")
                    .font(.caption)
            } else if content.totalCount == 0 {
                Spacer(minLength: 0)
                Label { emptyMessage } icon: { Image(systemName: "checkmark.circle") }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 5) {
                    ForEach(content.items.prefix(rowLimit)) { item in
                        HStack(spacing: 6) {
                            Text(verbatim: item.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if item.quantity > 1 {
                                Text(verbatim: "×\(item.quantity)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(family == .systemLarge ? .body : .caption)
                        .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if entry.snapshot.hasHousehold {
                if content.totalCount > rowLimit {
                    Text("\(content.totalCount - rowLimit) more")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Tap to open the list")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rowLimit: Int { family == .systemLarge ? 8 : 3 }

    private var emptyMessage: Text {
        list == .needed ? Text("Nothing missing") : Text("Nothing to buy")
    }
}

#Preview(as: .systemSmall) {
    NeededWidget()
} timeline: {
    StockEntry.preview
    StockEntry(date: .now, snapshot: .empty)
}

#Preview(as: .systemMedium) {
    BuyingWidget()
} timeline: {
    StockEntry.preview
}

#Preview(as: .accessoryRectangular) {
    NeededWidget()
} timeline: {
    StockEntry.preview
}
