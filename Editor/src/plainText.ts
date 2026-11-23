/**
 * Plain text of a document, for TXT export and `getText()`: top-level blocks
 * are separated by a blank line. Lists keep a light marker (`-`, `1.`, `[ ]`)
 * and their indentation, table rows become tab-separated lines, and a hard
 * break is a line break.
 */
import type { LooseNodeJSON } from './markdown'

function inlineText(node: LooseNodeJSON): string {
  if (node.type === 'text') return node.text ?? ''
  if (node.type === 'hardBreak') return '\n'
  if (node.type === 'image') return typeof node.attrs?.alt === 'string' ? node.attrs.alt : ''
  return (node.content ?? []).map(inlineText).join('')
}

function indent(text: string, prefix: string): string {
  return text
    .split('\n')
    .map((line) => (line === '' ? line : prefix + line))
    .join('\n')
}

function listText(node: LooseNodeJSON): string {
  const start = typeof node.attrs?.start === 'number' ? node.attrs.start : 1
  return (node.content ?? [])
    .map((item, index) => {
      let marker = '- '
      if (node.type === 'orderedList') marker = `${start + index}. `
      if (node.type === 'taskList') marker = item.attrs?.checked === true ? '[x] ' : '[ ] '
      const [first, ...rest] = (item.content ?? []).map((child) => blockText(child, true))
      const head = indent(first ?? '', ' '.repeat(marker.length)).slice(marker.length)
      const lines = [marker + head]
      for (const block of rest) lines.push(indent(block, ' '.repeat(marker.length)))
      return lines.join('\n')
    })
    .join('\n')
}

function blockText(node: LooseNodeJSON, nested = false): string {
  switch (node.type) {
    case 'paragraph':
    case 'heading':
      return inlineText(node)
    case 'codeBlock':
      return (node.content ?? []).map((child) => child.text ?? '').join('')
    case 'horizontalRule':
      return '---'
    case 'bulletList':
    case 'orderedList':
    case 'taskList':
      return listText(node)
    case 'table':
      return (node.content ?? [])
        .map((row) =>
          (row.content ?? [])
            .map((cell) => (cell.content ?? []).map((block) => inlineText(block).replace(/\n/g, ' ')).join(' '))
            .join('\t'),
        )
        .join('\n')
    case 'blockquote':
      return (node.content ?? []).map((child) => blockText(child, nested)).join(nested ? '\n' : '\n\n')
    default:
      return (node.content ?? []).map((child) => blockText(child, nested)).join('\n')
  }
}

export function plainText(doc: LooseNodeJSON): string {
  return (doc.content ?? [])
    .map((block) => blockText(block))
    .filter((text) => text.trim() !== '')
    .join('\n\n')
}
