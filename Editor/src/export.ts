/**
 * Export mode helpers: waiting until the read-only render is final, so the
 * host can print or snapshot it.
 */
import { whenMermaidSettled } from './extensions/mermaid-renderer'

/**
 * Waits for a layout pass. The export view lives in a window that is never shown, and
 * WebKit does not fire `requestAnimationFrame` there, so a short timer is the fallback.
 */
function nextFrame(): Promise<void> {
  return new Promise((resolve) => {
    const done = () => resolve()
    requestAnimationFrame(done)
    setTimeout(done, 50)
  })
}

/** Resolves once the image has loaded or failed, then once it is decoded (or cannot be). */
async function imageSettled(image: HTMLImageElement): Promise<void> {
  if (!image.complete) {
    await new Promise<void>((resolve) => {
      image.addEventListener('load', () => resolve(), { once: true })
      image.addEventListener('error', () => resolve(), { once: true })
    })
  }
  if (image.naturalWidth > 0) await image.decode().catch(() => undefined)
}

async function fontsSettled(): Promise<void> {
  if ('fonts' in document) await document.fonts.ready
}

/**
 * Resolves when everything inside `root` is final: fonts, images and every
 * Mermaid diagram (rendered or failed). Diagrams can add text (new fonts) and
 * images can change layout, so the checks run until a pass finds nothing new.
 */
export async function whenRenderSettled(root: HTMLElement): Promise<void> {
  for (let pass = 0; pass < 5; pass++) {
    await nextFrame()
    await whenMermaidSettled()
    const images = [...root.querySelectorAll('img')]
    await Promise.all(images.map(imageSettled))
    await fontsSettled()
    await nextFrame()
    const busy = root.querySelector('[data-mermaid-state="pending"]') !== null
    if (!busy && images.every((image) => image.complete)) return
  }
}
