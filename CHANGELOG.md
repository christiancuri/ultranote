# Changelog

All notable changes to UltraNote. Each `## <version>` section is used as the
GitHub Release notes and the in-app (Sparkle) update notes.

## 0.2.1

- **Writing code is much better.** In a code block, Tab and Shift+Tab indent and outdent (also several lines at once) instead of leaving the editor; Enter keeps the line's indentation and indents after `{`, `(`, `[` or `:`; a closing `}`, `)` or `]` outdents itself; blank lines stay inside the block; ⌘↩ continues below the block; pasted code keeps its line breaks; and autocorrect stays out of your code.
- **Pick a code block's language** from its corner label.
- **Typing ```js and Enter** now starts a code block reliably, also with keyboards where the backtick is a dead key.
- **`/code` finds Code block** first instead of Ask AI.
- **Fixed:** the **Open Settings** button on an Ask AI error now opens Settings › AI.

## 0.2.0

- **Ask AI inside your notes**, answered by the Claude Code or Codex (ChatGPT) app already installed on your Mac, with your own subscription. No API key, no account, no UltraNote server.
  - Type `/` and pick **Ask AI**, select text and click **✦ Ask AI**, or press ⌘J.
  - With a selection: improve writing, fix spelling and grammar, make shorter or longer, summarize, translate or explain. Without one: continue writing, summarize the note, brainstorm ideas or outline.
  - Ask anything in your own words and keep refining the answer in the same panel. The answer streams in; replace the selection, insert it below, copy it or try again (⌘↩ applies it).
- **Settings › AI**: turn AI on or off, choose Claude Code or Codex, the model, effort and Codex fast mode, whether the whole note is sent as context, and custom paths to the command-line tools.

## 0.1.0

First public release.

- **Notes as plain Markdown files** in a folder you choose (`~/Documents/UltraNote` by default). Edits save automatically, and changes made by other apps show up right away.
- **A rich editor** for headings, lists, to-do lists, tables, quotes, code blocks with syntax highlighting, links, images and Mermaid diagrams. Type `/` for the block menu or use Markdown shortcuts as you type.
- **Search** across every note from the sidebar, and **Find** (⌘F) inside the open note.
- **Export** to PDF (paginated or a single long page), PNG, plain text or Markdown, print, or copy the note as Markdown.
- **Light and dark themes**, an adjustable editor font size, and an English or Brazilian Portuguese interface.
- **Automatic updates** through Sparkle: UltraNote checks this repository's GitHub Releases every hour. Turn automatic checks off in Settings, or check any time with **UltraNote › Check for Updates…**.
