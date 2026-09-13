import Foundation

struct ImportedListItem: Identifiable, Hashable {
    var id: UUID
    var name: String
    var extra: String

    init(id: UUID = UUID(), name: String, extra: String = "") {
        self.id = id
        self.name = name
        self.extra = extra
    }
}

enum ImportText {
    /// Fixed locale so English / Hebrew / Russian headings match on any phone language.
    private static let headingLocale = Locale(identifier: "en_US_POSIX")

    private static let groceryHeadings = normalizedHeadings([
        "ingredients", "ingredient", "groceries", "grocery", "items",
        "what you need", "what you'll need", "you will need", "you need",
        "shopping list", "ingredient list",
        "מצרכים", "מצרך", "רכיבים", "מרכיבים", "המצרכים", "מה צריך", "מה שנצטרך",
        "ингредиенты", "ингредиент", "продукты", "продукт", "состав",
        "что нужно", "понадобится", "необходимые продукты"
    ])

    private static let methodHeadings = normalizedHeadings([
        "method", "directions", "direction", "instructions", "instruction",
        "how to prepare", "how to make", "how to cook", "preparation", "steps",
        "prepare", "procedure", "cooking",
        "אופן ההכנה", "אופן הכנה", "הכנה", "הוראות", "הוראות הכנה", "שלבים", "איך מכינים",
        "приготовление", "инструкция", "инструкции",
        "способ приготовления", "как приготовить", "как готовить", "шаги",
        "ход приготовления"
    ])

    private static let detailHeadings = normalizedHeadings([
        "description", "about",
        "תיאור",
        "описание"
    ])

    private static let shortExactHeadings = normalizedHeadings([
        "items", "item", "steps", "step", "prepare", "about",
        "grocery", "ingredient", "product", "продукт"
    ])

    private static let units: [String] = [
        "tablespoons", "tablespoon", "teaspoons", "teaspoon", "packages", "package",
        "ounces", "ounce", "pounds", "pound", "grams", "gram", "liters", "liter",
        "litres", "litre", "pinches", "pinch", "cloves", "clove", "sticks", "stick",
        "slices", "slice", "bunches", "bunch", "handful", "pieces", "piece",
        "sprigs", "sprig", "bottles", "bottle", "fillets", "fillet",
        "tbsp", "tbsps", "tsp", "tsps", "cups", "cup", "cans", "can", "pack",
        "bags", "bag", "jars", "jar", "boxes", "box", "heads", "head",
        "large", "small", "medium", "whole", "dash", "lbs", "lb", "oz",
        "kg", "mg", "ml", "cl", "g", "l",
        "כוסות", "כוס", "כפות", "כף", "כפיות", "כפית", "גרם", "קילו",
        "שיניים", "שן", "חבילות", "חבילה", "פרוסות", "פרוסה", "יחידות",
        "стаканов", "стакан", "зубчиков", "зубчик", "упаковка", "пучок",
        "банка", "штук", "шт", "ст.л", "ч.л"
    ].sorted { $0.count > $1.count }

    private static let methodVerbs: Set<String> = normalizedHeadings([
        "heat", "preheat", "mix", "stir", "whisk", "beat", "combine", "add", "pour",
        "cook", "bake", "fry", "saute", "sauté", "simmer", "boil", "bring", "reduce",
        "season", "serve", "place", "put", "remove", "transfer", "cover", "uncover",
        "let", "leave", "meanwhile", "then", "next", "finally", "drain", "rinse",
        "chop", "slice", "dice", "mince", "peel", "melt", "spread", "top", "garnish",
        "set", "turn", "flip", "fold", "knead", "roll", "cut", "line", "grease",
        "brush", "roast", "grill", "steam", "blend", "puree", "toast", "brown",
        "rest", "cool", "refrigerate", "soak", "marinate", "sprinkle", "drizzle",
        "toss", "coat", "arrange", "divide", "shape", "press", "continue",
        "using", "once", "after", "when", "while", "until", "repeat",
        "מחממים", "לחמם", "מחמם", "מערבבים", "לערבב", "מוסיפים", "להוסיף",
        "מבשלים", "לבשל", "אופים", "לאפות", "מטגנים", "לטגן", "חותכים", "לחתוך",
        "מגישים", "להגיש", "יוצקים", "שופכים", "מכסים", "מביאים", "מפזרים",
        "מחכים", "להמתין", "בינתיים", "ואז",
        "разогрейте", "разогреть", "смешайте", "смешать", "перемешайте",
        "добавьте", "добавить", "нарежьте", "нарезать", "выпекайте", "жарьте",
        "обжарьте", "варите", "выложите", "накройте", "подавайте", "вливайте",
        "влейте", "доведите", "посолите", "оставьте", "затем", "далее", "потом"
    ])

    private static let quantityRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^(?:(?:\d+\s+)?\d+\s*/\s*\d+|(?:\d+\s*)?[½¼¾⅓⅔⅛⅕⅖⅗⅘⅙⅚⅜⅝⅞]|\d+(?:[.,]\d+)?(?:\s*[–-]\s*\d+(?:[.,]\d+)?)?)"#
        )
    }()

    private static let stepRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^(step|שלב|шаг)\s*\d+"#, options: .caseInsensitive)
    }()

    private enum Section {
        case unknown, detail, groceries, method
    }

    private enum HeadingKind {
        case grocery, method, detail
    }

    static func recipe(
        from text: String,
        addedByName: String,
        addedByRecordName: String
    ) -> Recipe? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = lines.firstIndex(where: { !$0.isEmpty }) else { return nil }
        let title = lines[first]
        guard !title.isEmpty else { return nil }

        var section = Section.unknown
        var detailLines: [String] = []
        var groceries: [RecipeGrocery] = []
        var methodLines: [String] = []

        func consume(_ raw: String) {
            if isMetaLine(raw) { return }
            if let heading = splitHeading(raw) {
                switch heading.kind {
                case .grocery: section = .groceries
                case .method: section = .method
                case .detail: section = .detail
                }
                if !heading.remainder.isEmpty {
                    consume(heading.remainder)
                }
                return
            }

            switch section {
            case .groceries:
                let cleaned = stripPrefix(raw)
                if looksLikeMethod(raw), prefixRange(quantityRegex, in: cleaned) == nil {
                    methodLines.append(raw)
                    section = .method
                    return
                }
                if let grocery = parseGroceryLine(raw) {
                    groceries.append(grocery)
                }
            case .method:
                methodLines.append(raw)
            case .detail:
                if looksLikeGrocery(raw), let grocery = parseGroceryLine(raw) {
                    groceries.append(grocery)
                    section = .groceries
                } else if looksLikeMethod(raw) {
                    methodLines.append(raw)
                    section = .method
                } else {
                    detailLines.append(raw)
                }
            case .unknown:
                if looksLikeGrocery(raw), let grocery = parseGroceryLine(raw) {
                    groceries.append(grocery)
                    section = .groceries
                } else if looksLikeMethod(raw) {
                    methodLines.append(raw)
                    section = .method
                } else {
                    detailLines.append(raw)
                    section = .detail
                }
            }
        }

        var index = first + 1
        while index < lines.count {
            let line = lines[index]
            if line.isEmpty {
                if section == .method {
                    methodLines.append("")
                }
                index += 1
                continue
            }

            if section == .unknown || section == .detail {
                let next = nextNonEmpty(in: lines, after: index)
                let nextIsGrocery = next.map(looksLikeGrocery) ?? true
                let nextIsMethod = next.map(looksLikeMethod) ?? false
                if looksLikeGrocery(line), nextIsGrocery || nextIsMethod {
                    section = .groceries
                    consume(line)
                    index += 1
                    continue
                }
                let upcoming = upcomingNonEmpty(in: lines, from: index, limit: 3)
                if upcoming.count == 3, upcoming.allSatisfy(looksLikeShortItem) {
                    section = .groceries
                    consume(line)
                    index += 1
                    continue
                }
            }

            consume(line)
            index += 1
        }

        if groceries.isEmpty, !detailLines.isEmpty, methodLines.isEmpty {
            methodLines = detailLines
            detailLines = []
        }

        return Recipe(
            title: title,
            detail: joinedParagraphs(detailLines),
            method: joinedParagraphs(methodLines),
            groceries: groceries,
            addedByName: addedByName,
            addedByRecordName: addedByRecordName
        )
    }

    static func items(from text: String) -> [ImportedListItem] {
        var result: [ImportedListItem] = []
        var indexByKey: [String: Int] = [:]
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard splitHeading(line) == nil, !isMetaLine(line), !isSubheading(line) else { continue }
            let grocery = parseGroceryLine(line)
            let name = grocery?.name ?? ""
            let extra = grocery?.amount ?? ""
            guard !name.isEmpty else { continue }
            let key = ShortageItem.nameKey(name)
            if let index = indexByKey[key] {
                if result[index].extra.isEmpty {
                    result[index].extra = extra
                }
                continue
            }
            indexByKey[key] = result.count
            result.append(ImportedListItem(name: name, extra: extra))
        }
        return result
    }

    static func splitNameAndExtra(_ line: String) -> (name: String, extra: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = [" — ", " – ", " - ", " —", " –", " -", "—", "–", "־", ": ", " : ", "：", ":"]
        for separator in separators {
            if let range = trimmed.range(of: separator) {
                let name = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let extra = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return (name, extra) }
            }
        }
        if let range = trimmed.range(of: ", ") {
            let name = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let extra = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !extra.isEmpty {
                return (name, extra)
            }
        }
        return (trimmed, "")
    }

    private static func parseGroceryLine(_ line: String) -> RecipeGrocery? {
        let cleaned = stripPrefix(line)
        guard !cleaned.isEmpty, headingKind(cleaned) == nil, !isSubheading(cleaned) else { return nil }

        if let amountRange = prefixRange(quantityRegex, in: cleaned) {
            let qty = cleaned[amountRange].trimmingCharacters(in: .whitespaces)
            var rest = String(cleaned[amountRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            var unit = ""
            if let consumed = consumingUnit(rest) {
                unit = consumed.unit
                rest = consumed.rest
            }
            let amount = [qty, unit].filter { !$0.isEmpty }.joined(separator: " ")
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            if rest.isEmpty {
                return RecipeGrocery(name: cleaned, amount: "")
            }
            return RecipeGrocery(name: rest, amount: amount)
        }

        let parts = splitNameAndExtra(cleaned)
        guard !parts.name.isEmpty else { return nil }
        return RecipeGrocery(name: parts.name, amount: parts.extra)
    }

    private static func consumingUnit(_ rest: String) -> (unit: String, rest: String)? {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        guard let token = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "," }).first else {
            return nil
        }
        let tokenString = String(token)
        let foldedToken = folded(tokenString)
        for unit in units where folded(unit) == foldedToken {
            var dropped = trimmed
            if let range = dropped.range(of: tokenString) {
                dropped.removeSubrange(range)
            }
            return (
                tokenString,
                dropped.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            )
        }
        return nil
    }

    private static func splitHeading(_ line: String) -> (kind: HeadingKind, remainder: String)? {
        let stripped = stripMarkdown(line)
        if let colon = stripped.firstIndex(of: ":") ?? stripped.firstIndex(of: "：") {
            let left = String(stripped[..<colon])
            if let kind = headingKind(left) {
                let remainder = String(stripped[stripped.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (kind, remainder)
            }
        }
        guard let kind = headingKind(stripped) else { return nil }
        return (kind, "")
    }

    private static func headingKind(_ line: String) -> HeadingKind? {
        let stripped = stripMarkdown(line)
        if let colon = stripped.firstIndex(of: ":") ?? stripped.firstIndex(of: "：") {
            let left = String(stripped[..<colon])
            if let kind = matchHeading(normalizedHeading(left)) {
                return kind
            }
        }
        return matchHeading(normalizedHeading(stripped))
    }

    private static func matchHeading(_ key: String) -> HeadingKind? {
        guard !key.isEmpty else { return nil }
        if groceryHeadings.contains(key) { return .grocery }
        if methodHeadings.contains(key) { return .method }
        if detailHeadings.contains(key) { return .detail }
        if let kind = prefixHeading(key, groceryHeadings, .grocery) { return kind }
        if let kind = prefixHeading(key, methodHeadings, .method) { return kind }
        if let kind = prefixHeading(key, detailHeadings, .detail) { return kind }
        return nil
    }

    private static func prefixHeading(_ key: String, _ set: Set<String>, _ kind: HeadingKind) -> HeadingKind? {
        for heading in set {
            if shortExactHeadings.contains(heading) { continue }
            let prefixes = [heading + " ", heading + "(", heading + "—", heading + "-"]
            if prefixes.contains(where: { key.hasPrefix($0) }) {
                let extra = key.dropFirst(heading.count)
                if heading.count >= 8 || extra.count <= 28 {
                    return kind
                }
            }
        }
        return nil
    }

    private static func looksLikeGrocery(_ line: String) -> Bool {
        let cleaned = stripPrefix(line)
        guard !cleaned.isEmpty, headingKind(cleaned) == nil, !isMetaLine(cleaned) else { return false }
        if looksLikeMethod(cleaned), prefixRange(quantityRegex, in: cleaned) == nil {
            return false
        }
        if cleaned.count > 90 { return false }
        if !splitNameAndExtra(cleaned).extra.isEmpty { return true }
        if prefixRange(quantityRegex, in: cleaned) != nil { return true }
        if hasUnit(cleaned) { return true }
        let original = stripMarkdown(line)
        if let first = original.unicodeScalars.first, bullets.contains(first) { return true }
        return false
    }

    private static func looksLikeShortItem(_ line: String) -> Bool {
        if looksLikeGrocery(line) { return true }
        let cleaned = stripPrefix(line)
        guard !cleaned.isEmpty, headingKind(cleaned) == nil, !isMetaLine(cleaned), !looksLikeMethod(cleaned) else {
            return false
        }
        let words = cleaned.split(whereSeparator: \.isWhitespace)
        let first = folded(String(words.first ?? ""))
        let descriptionStarts: Set<String> = [
            "a", "an", "the", "this", "that", "from", "my", "our", "best", "very"
        ]
        if descriptionStarts.contains(first) { return false }
        return (1...4).contains(words.count) && cleaned.count <= 40 && !cleaned.hasSuffix(".")
    }

    private static func looksLikeMethod(_ line: String) -> Bool {
        let cleaned = stripPrefix(line)
        guard !cleaned.isEmpty, headingKind(cleaned) == nil else { return false }
        if prefixRange(stepRegex, in: folded(cleaned)) != nil { return true }
        let words = cleaned.split(whereSeparator: \.isWhitespace)
        if cleaned.hasSuffix("."), cleaned.count > 28 { return true }
        if cleaned.contains(". "), cleaned.count > 36 { return true }
        let verb = folded(String(words.first ?? "")).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        if methodVerbs.contains(verb), words.count >= 2 || cleaned.count > 18 {
            return true
        }
        return false
    }

    private static func isSubheading(_ line: String) -> Bool {
        let trimmed = stripPrefix(line)
        let body = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":："))
        let words = body.split(whereSeparator: \.isWhitespace)
        let foldedBody = folded(body)
        if trimmed.hasSuffix(":") || trimmed.hasSuffix("：") {
            if headingKind(body) != nil { return true }
            if (1...6).contains(words.count),
               prefixRange(quantityRegex, in: body) == nil,
               body.rangeOfCharacter(from: .decimalDigits) == nil {
                return true
            }
        }
        if foldedBody.hasPrefix("for the ") || foldedBody.hasPrefix("for ") || foldedBody.hasPrefix("для ") {
            return words.count <= 6 && body.rangeOfCharacter(from: .decimalDigits) == nil
        }
        return false
    }

    private static func isMetaLine(_ line: String) -> Bool {
        let key = normalizedHeading(line)
        guard key.count < 48 else { return false }
        let prefixes = [
            "serves", "serving", "yield", "prep time", "cook time", "total time",
            "calories", "nutrition",
            "מנות", "порц"
        ]
        if prefixes.contains(where: { key == $0 || key.hasPrefix($0 + " ") || key.hasPrefix($0 + ":") }) {
            return true
        }
        let timeWords = ["minute", "minutes", "hour", "hours", "דקות", "שעות", "минут", "час"]
        return prefixRange(quantityRegex, in: stripPrefix(line)) != nil
            && timeWords.contains(where: { key.contains($0) })
    }

    private static func hasUnit(_ text: String) -> Bool {
        let tokens = folded(text).split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        let unitSet = Set(units.map(folded))
        return tokens.contains { unitSet.contains($0) }
    }

    private static func nextNonEmpty(in lines: [String], after index: Int) -> String? {
        lines[(index + 1)...].first { !$0.isEmpty }
    }

    private static func upcomingNonEmpty(in lines: [String], from index: Int, limit: Int) -> [String] {
        var result: [String] = []
        var cursor = index
        while cursor < lines.count, result.count < limit {
            if !lines[cursor].isEmpty {
                result.append(lines[cursor])
            }
            cursor += 1
        }
        return result
    }

    private static func joinedParagraphs(_ lines: [String]) -> String {
        lines
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedHeadings(_ values: [String]) -> Set<String> {
        Set(values.map(normalizedHeading))
    }

    private static func normalizedHeading(_ line: String) -> String {
        stripMarkdown(line)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":：."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: headingLocale)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: headingLocale)
    }

    private static func stripMarkdown(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("#") {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "*_#"))
    }

    private static let bullets = CharacterSet(charactersIn: "-*•·–—▪‣●○□☐➢➤")

    private static func stripPrefix(_ line: String) -> String {
        var trimmed = stripMarkdown(line)
        if let first = trimmed.unicodeScalars.first, bullets.contains(first) {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if trimmed.hasPrefix("[ ]") || trimmed.lowercased().hasPrefix("[x]") {
            trimmed = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        if let match = trimmed.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
            trimmed = String(trimmed[match.upperBound...])
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func prefixRange(_ regex: NSRegularExpression, in text: String) -> Range<String.Index>? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.range.location == 0 else {
            return nil
        }
        return Range(match.range, in: text)
    }
}
