#if DEBUG
/// The note the self-test round-trips and exports. It holds the constructs that broke the
/// Markdown probe (underscores, `<` and `&`, consecutive tables) and the ones that stress
/// export (a wide table, a Mermaid diagram, a code block longer than a page).
enum SelfTestFixture {
    /// Appears once, in the last line: export checks look for it on the last PDF page.
    static let sentinel = "ULTRANOTESENTINEL7F3A9C2E"

    static let markdown: String = [head, tables, diagram, codeBlock, lastLine].joined(separator: "\n\n") + "\n"

    private static let head = """
    # UltraNote self-test

    Texto com acentos: ação é útil, coração, über, naïve.

    An identifier such as snake_case_name stays as typed, and so does a comparison: a < b & c > d.

    ## Lists

    - First item
      - Nested item
        - Deeply nested item
      - Another nested item
    - Second item

    1. Step one
    2. Step two
       1. Sub-step

    ### Tasks

    - [ ] Open task
    - [x] Done task
    """

    private static let tables = """
    ## Wide table

    | Col 1 | Col 2 | Col 3 | Col 4 | Col 5 | Col 6 | Col 7 | Col 8 |
    | --- | --- | --- | --- | --- | --- | --- | --- |
    | a1 | a2 | a3 | a4 | a5 | a6 | a7 | a8 |
    | b1 | b2 | b3 | b4 | b5 | b6 | b7 | b8 |
    | c1 | c2 | c3 | c4 | c5 | c6 | c7 | c8 |

    ## Two small tables

    | Name | Value |
    | --- | --- |
    | alpha | 1 |

    | Key | Note |
    | --- | --- |
    | beta | 2 |
    """

    private static let diagram = """
    ## Diagram

    ```mermaid
    graph TD
      A[Start] --> B{Ready?}
      B -->|yes| C[Export]
      B -->|no| D[Wait]
      D --> B
    ```
    """

    /// A fenced block of 60 lines.
    private static let codeBlock: String = {
        let lines = (1...60).map { "let value\($0) = \($0) * \($0) // line \($0) of 60" }
        return (["## Long code block", "", "```swift"] + lines + ["```"]).joined(separator: "\n")
    }()

    private static let lastLine = "The fixture ends with this sentinel sentence: \(sentinel)."
}
#endif
