import { createRoot } from 'react-dom/client'

import { initAppearance, lockLightTheme } from './appearance'
import type { Bridge } from './bridge'
import { Editor } from './editor/Editor'
import type { EditorMode } from './editor/extensions'
import './styles/editor.css'
import './styles/menus.css'
import './styles/ai.css'

const mode: EditorMode = new URLSearchParams(window.location.search).get('mode') === 'export' ? 'export' : 'edit'

document.documentElement.dataset.mode = mode
initAppearance()
if (mode === 'export') lockLightTheme()

/** Outside the app (plain browser, `pnpm dev`), open a sample note so there is something to edit. */
async function loadStandaloneDemo(bridge: Bridge): Promise<void> {
  if (window.webkit?.messageHandlers?.ultranote || mode !== 'edit') return
  const { default: markdown } = await import('./demo-note.md?raw')
  await bridge.api.setNote({ noteId: 'standalone-demo', markdown })
  if (import.meta.env.DEV) {
    const { installStandaloneAI } = await import('./ai/standaloneStub')
    installStandaloneAI(bridge)
  }
}

function onBridge(bridge: Bridge): void {
  void loadStandaloneDemo(bridge)
}

const root = document.getElementById('root')
if (!root) throw new Error('Missing #root element')
createRoot(root).render(<Editor mode={mode} onBridge={onBridge} />)
