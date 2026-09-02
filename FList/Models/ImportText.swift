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
        "what you need", "you will need",
        "מצרכים", "מצרך", "רכיבים", "מרכיבים",
        "ингредиенты", "ингредиент", "продукты", "продукт", "состав"
    ])

    private static let methodHeadings = normalizedHeadings([
        "method", "directions", "direction", "instructions", "instruction",
        "how to prepare", "preparation", "steps", "prepare",
        "אופן ההכנה", "אופן הכנה", "הכנה", "הוראות", "הוראות הכנה", "שלבים",
        "приготовление", "инструкция", "инструкции",
        "способ приготовления", "как приготовить", "шаги"
    ])

    private static let detailHeadings = normalizedHeadings([
        "description", "about",
        "תיאור",
        "описание"
    ])

    private static var headings: Set<String> {
        groceryHeadings.union(methodHeadings).union(detailHeadings)
    }

    static func recipe(
        from text: String,
        addedByName: String,
        addedByRecordName: String
    ) -> Recipe? {
        let lines = text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = lines.firstIndex(where: { !$0.isEmpty }) else { return nil }
        let title = lines[first]
        guard !title.isEmpty else { return nil }

        let blocks = paragraphBlocks(Array(lines[(first + 1)...]))
        var detail = ""
        var groceries: [RecipeGrocery] = []
        var methodBlocks: [String] = []
        var expectGroceries = false
        var expectMethod = false
        var expectDetail = false

        for block in blocks {
            if block.count == 1, isSectionHeading(block[0]) {
                expectGroceries = isHeading(block[0], in: groceryHeadings)
                expectMethod = isHeading(block[0], in: methodHeadings)
                expectDetail = isHeading(block[0], in: detailHeadings)
                continue
            }

            if expectMethod {
                methodBlocks.append(block.joined(separator: "\n"))
                continue
            }

            if expectDetail, detail.isEmpty {
                detail = block.joined(separator: "\n")
                expectDetail = false
                continue
            }

            if expectGroceries || isGroceryBlock(block) {
                groceries.append(contentsOf: groceryRows(from: block))
                expectGroceries = false
            } else if groceries.isEmpty, detail.isEmpty, methodBlocks.isEmpty {
                detail = block.joined(separator: "\n")
            } else {
                methodBlocks.append(block.joined(separator: "\n"))
            }
        }

        if groceries.isEmpty, !detail.isEmpty, methodBlocks.isEmpty {
            methodBlocks = [detail]
            detail = ""
        }

        return Recipe(
            title: title,
            detail: detail,
            method: methodBlocks.joined(separator: "\n\n"),
            groceries: groceries,
            addedByName: addedByName,
            addedByRecordName: addedByRecordName
        )
    }

    static func items(from text: String) -> [ImportedListItem] {
        var result: [ImportedListItem] = []
        var indexByKey: [String: Int] = [:]
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = stripPrefix(String(raw))
            guard !line.isEmpty, !isSectionHeading(line) else { continue }
            let parts = splitNameAndExtra(line)
            guard !parts.name.isEmpty else { continue }
            let key = ShortageItem.nameKey(parts.name)
            if let index = indexByKey[key] {
                if result[index].extra.isEmpty {
                    result[index].extra = parts.extra
                }
                continue
            }
            indexByKey[key] = result.count
            result.append(ImportedListItem(name: parts.name, extra: parts.extra))
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

    private static func groceryRows(from block: [String]) -> [RecipeGrocery] {
        block.compactMap { line -> RecipeGrocery? in
            let cleaned = stripPrefix(line)
            guard !cleaned.isEmpty, !isSectionHeading(cleaned) else { return nil }
            let parts = splitNameAndExtra(cleaned)
            guard !parts.name.isEmpty else { return nil }
            return RecipeGrocery(name: parts.name, amount: parts.extra)
        }
    }

    private static func normalizedHeadings(_ values: [String]) -> Set<String> {
        Set(values.map(normalizedHeading))
    }

    private static func normalizedHeading(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":：."))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: headingLocale)
    }

    private static func isHeading(_ line: String, in set: Set<String>) -> Bool {
        set.contains(normalizedHeading(line))
    }

    private static func looksLikeGrocery(_ line: String) -> Bool {
        let cleaned = stripPrefix(line)
        guard !cleaned.isEmpty, !isSectionHeading(cleaned) else { return false }
        let parts = splitNameAndExtra(cleaned)
        return !parts.name.isEmpty && !parts.extra.isEmpty
    }

    private static func isGroceryBlock(_ block: [String]) -> Bool {
        let rows = block
            .map(stripPrefix)
            .filter { !$0.isEmpty && !isSectionHeading($0) }
        return !rows.isEmpty && rows.allSatisfy(looksLikeGrocery)
    }

    private static func paragraphBlocks(_ lines: [String]) -> [[String]] {
        var blocks: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty {
                    blocks.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    private static func isSectionHeading(_ line: String) -> Bool {
        isHeading(line, in: headings)
    }

    private static func stripPrefix(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let bullets = CharacterSet(charactersIn: "-*•·–—")
        if let first = trimmed.unicodeScalars.first, bullets.contains(first) {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if let match = trimmed.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
            trimmed = String(trimmed[match.upperBound...])
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
