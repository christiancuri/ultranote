# Sprint notes — week 47

Quick summary of what changed in `editor_bridge.ts` and why.

## Decisions

1. Keep **Markdown** as the storage format.
2. Serialize through one adapter:
   - parse with `micromark`
   - write with `mdast-util-to-markdown`
3. Export from a hidden web view.

> Reminder: `setNote` must not echo a `contentChanged` back.

## Open tasks

- [x] Round-trip corpus
- [ ] Wide table in PDF export
  - [ ] landscape option?
- [ ] Mermaid error state

## Data

| Step | Time (ms) | Notes |
| :--- | ---: | --- |
| parse | 12 | 40 kB note |
| serialize | 9 | same note |

```mermaid
graph LR
  MD[Markdown] --> Doc[Document] --> MD
```

```swift
let url = URL(string: "app://editor/index.html?mode=export")!
webView.load(URLRequest(url: url))
```

---

See https://example.com/ultra_note/release_notes for the full list, or ask at team@example.com.
