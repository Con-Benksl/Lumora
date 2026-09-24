import Foundation
import SwiftUI

enum MarkdownBlock: Equatable {
    enum ColumnAlignment: Equatable {
        case leading
        case center
        case trailing
    }

    case paragraph(String)
    case heading(Int, String)
    case code(String)
    case quote(String)
    case unorderedList([String])
    case orderedList([String])
    case table(headers: [String], alignments: [ColumnAlignment], rows: [[String]])
    case divider
}

private final class MarkdownBlockCache: @unchecked Sendable {
    static let shared = MarkdownBlockCache()
    private let lock = NSLock()
    private var values: [String: [MarkdownBlock]] = [:]
    private let capacity = 100

    func blocks(for source: String) -> [MarkdownBlock] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = values[source] { return cached }
        let parsed = MarkdownBlockParser.parse(source)
        if values.count >= capacity { values.removeAll(keepingCapacity: true) }
        values[source] = parsed
        return parsed
    }
}

enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = codeFence(in: line) {
                index += 1
                var code: [String] = []
                while index < lines.count {
                    if closesFence(lines[index], fence: fence) {
                        index += 1
                        break
                    }
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            if let heading = heading(in: line) {
                blocks.append(.heading(heading.level, heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if isQuote(line) {
                var quote: [String] = []
                while index < lines.count, isQuote(lines[index]) {
                    quote.append(unquote(lines[index]))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: " ")))
                continue
            }

            if index + 1 < lines.count,
               let headers = tableCells(line),
               let separator = tableCells(lines[index + 1]),
               headers.count == separator.count,
               separator.allSatisfy(isTableSeparator) {
                let alignments = separator.map(tableAlignment)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let cells = tableCells(lines[index]), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(pad(cells, to: headers.count))
                    index += 1
                }
                blocks.append(.table(headers: headers, alignments: alignments, rows: rows))
                continue
            }

            if let item = listItem(line) {
                let ordered = item.ordered
                var items = [item.text]
                index += 1
                while index < lines.count, let next = listItem(lines[index]), next.ordered == ordered {
                    items.append(next.text)
                    index += 1
                }
                blocks.append(ordered ? .orderedList(items) : .unorderedList(items))
                continue
            }

            var paragraph = [trimmed]
            index += 1
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  !startsBlock(lines[index], nextLine: index + 1 < lines.count ? lines[index + 1] : nil) {
                paragraph.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
        }

        return blocks
    }

    private static func startsBlock(_ line: String, nextLine: String?) -> Bool {
        codeFence(in: line) != nil
            || heading(in: line) != nil
            || isDivider(line.trimmingCharacters(in: .whitespaces))
            || isQuote(line)
            || listItem(line) != nil
            || (nextLine.flatMap(tableCells) != nil && tableCells(line) != nil)
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        guard leadingSpaces <= 3 else { return nil }
        let content = line.dropFirst(leadingSpaces)
        let marks = content.prefix(while: { $0 == "#" })
        guard (1...6).contains(marks.count), content.dropFirst(marks.count).first?.isWhitespace == true else { return nil }
        let text = content.dropFirst(marks.count).trimmingCharacters(in: .whitespaces)
        return (marks.count, text)
    }

    private static func codeFence(in line: String) -> (marker: Character, length: Int)? {
        let content = line.drop(while: { $0 == " " })
        guard line.count - content.count <= 3, let marker = content.first, marker == "`" || marker == "~" else { return nil }
        let length = content.prefix(while: { $0 == marker }).count
        return length >= 3 ? (marker, length) : nil
    }

    private static func closesFence(_ line: String, fence: (marker: Character, length: Int)) -> Bool {
        let content = line.trimmingCharacters(in: .whitespaces)
        let run = content.prefix(while: { $0 == fence.marker })
        return run.count >= fence.length && content.dropFirst(run.count).allSatisfy(\.isWhitespace)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first, marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private static func isQuote(_ line: String) -> Bool {
        line.drop(while: { $0 == " " }).first == ">"
    }

    private static func unquote(_ line: String) -> String {
        var content = line.drop(while: { $0 == " " })
        if content.first == ">" { content = content.dropFirst() }
        if content.first == " " { content = content.dropFirst() }
        return String(content)
    }

    private static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        let content = line.drop(while: { $0 == " " })
        guard line.count - content.count <= 3 else { return nil }
        if let marker = content.first, marker == "-" || marker == "+" || marker == "*",
           content.dropFirst().first?.isWhitespace == true {
            return (false, String(content.dropFirst().drop(while: \.isWhitespace)))
        }
        let digits = content.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let afterDigits = content.dropFirst(digits.count)
        guard let marker = afterDigits.first, marker == "." || marker == ")",
              afterDigits.dropFirst().first?.isWhitespace == true else { return nil }
        return (true, String(afterDigits.dropFirst().drop(while: \.isWhitespace)))
    }

    private static func tableCells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var content = trimmed
        if content.first == "|" { content.removeFirst() }
        if content.last == "|" { content.removeLast() }
        return content.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\\|", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ cell: String) -> Bool {
        let value = cell.trimmingCharacters(in: .whitespaces)
        let stripped = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
    }

    private static func tableAlignment(_ cell: String) -> MarkdownBlock.ColumnAlignment {
        let value = cell.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix(":") && value.hasSuffix(":") { return .center }
        if value.hasSuffix(":") { return .trailing }
        return .leading
    }

    private static func pad(_ cells: [String], to count: Int) -> [String] {
        Array(cells.prefix(count)) + Array(repeating: "", count: max(0, count - cells.count))
    }
}

struct MarkdownText: View {
    let text: String
    let baseColor: Color
    let fontSize: CGFloat
    private let blocks: [MarkdownBlock]

    init(_ text: String, color: Color = .white.opacity(0.9), fontSize: CGFloat = 13) {
        self.text = text
        self.baseColor = color
        self.fontSize = fontSize
        self.blocks = MarkdownBlockCache.shared.blocks(for: text)
    }

    var body: some View {
        if blocks.isEmpty {
            SwiftUI.Text(text)
                .foregroundColor(baseColor)
                .font(.system(size: fontSize))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, baseColor: baseColor, fontSize: fontSize)
                }
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let baseColor: Color
    let fontSize: CGFloat

    @ViewBuilder
    var body: some View {
        switch block {
        case .paragraph(let text):
            inlineText(text)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            switch level {
            case 1: inlineText(text).bold().italic().underline()
            case 2: inlineText(text).bold()
            default: inlineText(text).bold().foregroundColor(baseColor.opacity(0.7))
            }
        case .code(let code):
            codeBlock(code)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(baseColor.opacity(0.4))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity, alignment: .top)
                inlineText(text)
                    .italic()
                    .foregroundColor(baseColor.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .unorderedList(let items):
            list(items, ordered: false)
        case .orderedList(let items):
            list(items, ordered: true)
        case .table(let headers, let alignments, let rows):
            table(headers: headers, alignments: alignments, rows: rows)
        case .divider:
            Divider()
                .background(baseColor.opacity(0.3))
                .padding(.vertical, 4)
        }
    }

    private func inlineText(_ source: String) -> SwiftUI.Text {
        let attributed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
        return SwiftUI.Text(attributed)
            .font(.system(size: fontSize))
            .foregroundColor(baseColor)
    }

    private func codeBlock(_ code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SwiftUI.Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .cornerRadius(6)
    }

    private func list(_ items: [String], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 6) {
                    SwiftUI.Text(ordered ? "\(index + 1)." : "•")
                        .font(.system(size: fontSize))
                        .foregroundColor(baseColor.opacity(0.6))
                        .frame(width: ordered ? 20 : 12, alignment: ordered ? .trailing : .center)
                    inlineText(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func table(
        headers: [String],
        alignments: [MarkdownBlock.ColumnAlignment],
        rows: [[String]]
    ) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    inlineText(header)
                        .bold()
                        .gridColumnAlignment(horizontalAlignment(index, alignments: alignments))
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                        inlineText(cell)
                            .gridColumnAlignment(horizontalAlignment(index, alignments: alignments))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func horizontalAlignment(
        _ index: Int,
        alignments: [MarkdownBlock.ColumnAlignment]
    ) -> HorizontalAlignment {
        guard index < alignments.count else { return HorizontalAlignment.leading }
        switch alignments[index] {
        case .leading: return HorizontalAlignment.leading
        case .center: return HorizontalAlignment.center
        case .trailing: return HorizontalAlignment.trailing
        }
    }
}
