/**
 * Images go through the host: the editor never writes files. Pasted or dropped
 * image files are sent as `saveAttachment`; the slash item and native menu send
 * `pickImage`. Both replies are `{"path":"attachments/<file>"}` (null when
 * cancelled), and the image is inserted as `![](attachments/<file>)`, which the
 * host serves relative to `app://editor/`.
 *
 * Without a host (plain browser) the post resolves to null and nothing is inserted.
 */
import { Extension, type Editor } from '@tiptap/core'
import { NodeSelection, Plugin, PluginKey } from '@tiptap/pm/state'
import type { EditorView } from '@tiptap/pm/view'

import type { Host } from '../bridge'
import { t } from '../i18n'

/** The attachment path from a host reply, or null when it is missing or unsafe. */
export function attachmentPath(reply: unknown): string | null {
  if (typeof reply !== 'object' || reply === null || !('path' in reply)) return null
  const { path } = reply
  if (typeof path !== 'string' || !path.startsWith('attachments/')) return null
  if (path.split('/').some((part) => part === '..' || part === '')) return null
  return path
}

export function readAsBase64(file: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => {
      const result = typeof reader.result === 'string' ? reader.result : ''
      resolve(result.slice(result.indexOf(',') + 1))
    }
    reader.onerror = () => reject(reader.error ?? new Error(t('image.readFailed')))
    reader.readAsDataURL(file)
  })
}

/**
 * Inserts a block image after the block holding `at` (or the selection), never
 * splitting a paragraph; an empty paragraph is replaced. At a position between
 * blocks (a drop point), the image goes right there. The image ends selected.
 */
export function insertImageAt(editor: Editor, src: string, at?: number): boolean {
  const { state } = editor
  const type = state.schema.nodes.image
  if (!type) return false
  const image = type.create({ src, alt: '' })
  const $pos = at === undefined ? state.selection.$to : state.doc.resolve(Math.max(0, Math.min(at, state.doc.content.size)))

  let from = -1
  let to = -1
  if (at === undefined && state.selection instanceof NodeSelection) {
    from = to = state.selection.to
  } else if ($pos.parent.isTextblock && $pos.parent.content.size === 0 && $pos.depth > 0) {
    from = $pos.before()
    to = $pos.after()
  } else if (!$pos.parent.isTextblock) {
    from = to = $pos.pos
  }
  const tr = state.tr
  if (from >= 0 && tr.doc.resolve(from).parent.canReplaceWith(tr.doc.resolve(from).index(), tr.doc.resolve(to).indexAfter(), type)) {
    tr.replaceWith(from, to, image)
  } else {
    // After the nearest ancestor block whose parent accepts an image.
    from = -1
    for (let depth = $pos.depth; depth > 0; depth--) {
      const parent = $pos.node(depth - 1)
      const index = $pos.indexAfter(depth - 1)
      if (parent.canReplaceWith(index, index, type)) {
        from = $pos.after(depth)
        break
      }
    }
    if (from < 0) return false
    tr.insert(from, image)
  }
  tr.setSelection(NodeSelection.create(tr.doc, from)).scrollIntoView()
  editor.view.dispatch(tr)
  editor.commands.focus()
  return true
}

async function saveAndInsert(editor: Editor, host: Host, file: File, at?: number): Promise<boolean> {
  const base64 = await readAsBase64(file)
  const reply = await host.post('saveAttachment', { name: file.name || 'image.png', mime: file.type, base64 })
  const path = attachmentPath(reply)
  if (!path || editor.isDestroyed) return false
  return insertImageAt(editor, path, at)
}

/** Asks the host for an image (file picker) and inserts it. Resolves false when cancelled. */
export async function pickImage(editor: Editor, host: Host): Promise<boolean> {
  const path = attachmentPath(await host.post('pickImage', {}))
  if (!path || editor.isDestroyed) return false
  return insertImageAt(editor, path)
}

function imageFiles(list: FileList | null | undefined): File[] {
  return [...(list ?? [])].filter((file) => file.type.startsWith('image/'))
}

function report(host: Host, error: unknown): void {
  const message = error instanceof Error ? error.message : String(error)
  console.error('[ultranote] image', error)
  void host.post('log', { level: 'error', message: `Image attachment failed: ${message}` }).catch(() => undefined)
}

export interface ImageDropOptions {
  getHost: () => Host
}

/** Paste and drop of image files. Other pastes and drops are left alone. */
export const ImageDrop = Extension.create<ImageDropOptions>({
  name: 'imageDrop',

  addOptions() {
    return { getHost: () => ({ native: false, post: () => Promise.resolve(null) }) }
  },

  addProseMirrorPlugins() {
    const { editor } = this
    const host = (): Host => this.options.getHost()

    const handle = (files: File[], at?: number): void => {
      void (async () => {
        let position = at
        for (const file of files) {
          try {
            if (await saveAndInsert(editor, host(), file, position)) position = undefined
          } catch (error) {
            report(host(), error)
          }
        }
      })()
    }

    return [
      new Plugin({
        key: new PluginKey('imageDrop'),
        props: {
          handlePaste(_view, event) {
            const files = imageFiles(event.clipboardData?.files)
            if (files.length === 0) return false
            handle(files)
            return true
          },
          handleDrop(view: EditorView, event: DragEvent, _slice, moved) {
            if (moved) return false
            const files = imageFiles(event.dataTransfer?.files)
            if (files.length === 0) return false
            const at = view.posAtCoords({ left: event.clientX, top: event.clientY })?.pos
            handle(files, at)
            return true
          },
        },
      }),
    ]
  },
})
