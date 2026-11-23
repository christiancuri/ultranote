import { describe, expect, it } from 'vitest'

import { parseMarkdown } from './markdown'
import { plainText } from './plainText'

describe('plainText', () => {
  it('separates top-level blocks with a blank line and keeps list structure', () => {
    const markdown = [
      '# Title',
      '',
      'Para with **bold** and a [link](https://x.y).',
      '',
      '> quoted',
      '',
      '1. one',
      '2. two',
      '   - nested',
      '',
      '- [x] done',
      '- [ ] open',
      '',
      '```mermaid',
      'graph TD',
      '  A --> B',
      '```',
      '',
      '---',
      '',
    ].join('\n')
    expect(plainText(parseMarkdown(markdown))).toBe(
      [
        'Title',
        'Para with bold and a link.',
        'quoted',
        '1. one\n2. two\n   - nested',
        '[x] done\n[ ] open',
        'graph TD\n  A --> B',
        '---',
      ].join('\n\n'),
    )
  })

  it('is empty for an empty note', () => {
    expect(plainText(parseMarkdown(''))).toBe('')
  })
})
