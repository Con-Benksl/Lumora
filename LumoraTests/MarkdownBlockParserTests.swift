import XCTest
@testable import Lumora

final class MarkdownBlockParserTests: XCTestCase {
    func testParsesHeadingsParagraphsQuotesAndLists() {
        let blocks = MarkdownBlockParser.parse("""
        # Heading

        First paragraph
        continued here.

        > Quoted text
        > on two lines

        - one
        - two

        1. first
        2. second
        """)

        XCTAssertEqual(blocks, [
            .heading(1, "Heading"),
            .paragraph("First paragraph continued here."),
            .quote("Quoted text on two lines"),
            .unorderedList(["one", "two"]),
            .orderedList(["first", "second"])
        ])
    }

    func testParsesFencedCodeAndAlignedTables() {
        let blocks = MarkdownBlockParser.parse("""
        ```swift
        let answer = 42
        ```

        | Name | Count | Note |
        |:-----|------:|:----:|
        | item | 3 | ok |
        """)

        XCTAssertEqual(blocks, [
            .code("let answer = 42"),
            .table(
                headers: ["Name", "Count", "Note"],
                alignments: [.leading, .trailing, .center],
                rows: [["item", "3", "ok"]]
            )
        ])
    }
}
