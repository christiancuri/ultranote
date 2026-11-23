/**
 * Renders Mermaid source to SVG. The `mermaid` package is large, so it is
 * loaded with a dynamic `import()` the first time a diagram shows up and ends
 * up in its own chunk.
 */
import type { ResolvedTheme } from '../appearance'
import { t } from '../i18n'

type Mermaid = (typeof import('mermaid'))['default']

export type MermaidResult = { ok: true; svg: string } | { ok: false; message: string }

const FONT_FAMILY = '-apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif'

let loading: Promise<Mermaid> | null = null
let configuredTheme: ResolvedTheme | null = null
let counter = 0
const pending = new Set<Promise<MermaidResult>>()

function load(): Promise<Mermaid> {
  loading ??= import('mermaid').then((module) => module.default)
  // A failed download must not poison every later attempt.
  loading.catch(() => {
    loading = null
  })
  return loading
}

function describe(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error)
  return message.trim() === '' ? t('mermaid.failed') : message.trim()
}

async function run(source: string, theme: ResolvedTheme): Promise<MermaidResult> {
  if (source.trim() === '') return { ok: false, message: t('mermaid.empty') }
  try {
    const mermaid = await load()
    if (configuredTheme !== theme) {
      mermaid.initialize({
        startOnLoad: false,
        // Strict: labels are sanitized and click handlers in diagrams are disabled.
        securityLevel: 'strict',
        // Report syntax errors by throwing instead of drawing an error diagram.
        suppressErrorRendering: true,
        theme: theme === 'dark' ? 'dark' : 'default',
        fontFamily: FONT_FAMILY,
      })
      configuredTheme = theme
    }
    counter += 1
    const { svg } = await mermaid.render(`ultranote-mermaid-${counter}`, source)
    return { ok: true, svg }
  } catch (error) {
    return { ok: false, message: describe(error) }
  }
}

/** Renders one diagram. Never rejects: failures come back as `{ ok: false }`. */
export function renderMermaid(source: string, theme: ResolvedTheme): Promise<MermaidResult> {
  const job = run(source, theme)
  pending.add(job)
  void job.then(() => pending.delete(job))
  return job
}

/** Resolves once no diagram is being rendered (each one finished or failed). */
export async function whenMermaidSettled(): Promise<void> {
  while (pending.size > 0) {
    await Promise.all([...pending])
  }
}
