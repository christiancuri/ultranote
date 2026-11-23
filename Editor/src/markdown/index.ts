/**
 * The Markdown adapter: the only code that turns Markdown into an editor
 * document and back. Everything else (bridge, export, tests) calls the
 * functions exported here.
 *
 * Implementation: micromark + mdast (the parser and serializer behind remark),
 * mapped onto the TipTap schema by `fromMarkdown.ts` / `toMarkdown.ts`, with
 * inline marks canonicalized in `inline.ts`. `@tiptap/markdown` 3.34.0 is not
 * used: on the 14 canonical corpus files it rewrote all of them, 6 still changed
 * on a second pass, and it wrote `\_` and HTML entities.
 *
 * Guarantees (enforced by `corpus.test.ts`, `escaping.test.ts`, `fuzz.test.ts`):
 *   - after one pass, output is byte-stable and parses back to the same document;
 *   - no needless escapes; what must be escaped gets a backslash, not an entity;
 *   - fenced code keeps its language, info string and body byte-for-byte;
 *   - output ends with exactly one newline (an empty note is an empty file).
 *
 * Lossy by design (Markdown or the editor cannot hold it):
 *   - Raw HTML. Inline HTML stays as the literal text it was (`<kbd>` is saved
 *     as `\<kbd>`); `<br>` becomes a hard break; block HTML, comments included,
 *     becomes an ```html code block.
 *   - Merged cells (written as the cell plus empty cells), column widths, image
 *     sizes, link targets: GFM has no syntax for them. Resizing is off.
 *   - Cells hold one line of inline content: several paragraphs are joined
 *     with `<br>`. Hard breaks in headings become spaces.
 *   - Soft line breaks inside a paragraph become spaces (hard-wrapped text is
 *     joined into one line). Empty paragraphs are not stored.
 *   - Not parsed, kept as text: YAML front matter (read as a rule and a
 *     heading), footnotes, math, single-tilde strikethrough (`~x~`), and task
 *     checkboxes outside an unordered all-task list.
 *   - Style is normalized on the first save: `-` bullets (`*` only to keep two
 *     adjacent lists apart), `*em*`, `**strong**`, ATX headings, fenced code,
 *     `1.` numbering from the list's start, unpadded tables, tight lists,
 *     reference links inlined (definitions dropped), entities decoded to
 *     characters, needless escapes removed, CRLF to LF.
 *   - Emphasis CommonMark cannot place (marks changing inside one word,
 *     emphasized code glued to letters) keeps its marks through a character
 *     reference next to the marker, e.g. `wor&#x64;**`code`**`. This is the
 *     only case that writes an entity; it only arises from editor formatting.
 */
import { parseMarkdown } from './fromMarkdown'
import { serializeMarkdown } from './toMarkdown'

export { parseMarkdown } from './fromMarkdown'
export { serializeMarkdown } from './toMarkdown'
export type { DocJSON, LooseNodeJSON, MarkJSON, NodeJSON } from './types'

/** One pass through the adapter. Running it again on its own output changes nothing. */
export function normalizeMarkdown(markdown: string): string {
  return serializeMarkdown(parseMarkdown(markdown))
}
