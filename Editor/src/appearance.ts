/**
 * Theme, accent color and font size. Colors are CSS variables written with
 * `light-dark()`, so switching theme is only a matter of setting
 * `color-scheme` through the `data-theme` attribute on <html>.
 */
import { setLocale, type Locale } from './i18n'

export type ThemeSetting = 'light' | 'dark' | 'system'
export type ResolvedTheme = 'light' | 'dark'

export interface Appearance {
  theme: ThemeSetting
  accent?: string | null
  fontSize?: number | null
  /** Interface language; unknown values are ignored. */
  locale?: Locale | null
}

type Listener = (theme: ResolvedTheme) => void

const listeners = new Set<Listener>()
let setting: ThemeSetting = 'system'
let locked = false
let lastResolved: ResolvedTheme | null = null

function systemQuery(): MediaQueryList | null {
  return typeof matchMedia === 'function' ? matchMedia('(prefers-color-scheme: dark)') : null
}

/** The theme currently on screen. */
export function resolvedTheme(): ResolvedTheme {
  if (setting !== 'system') return setting
  return systemQuery()?.matches ? 'dark' : 'light'
}

function notifyIfChanged(): void {
  const next = resolvedTheme()
  if (next === lastResolved) return
  lastResolved = next
  for (const listener of listeners) listener(next)
}

function applyTheme(next: ThemeSetting): void {
  setting = next
  const root = document.documentElement
  if (next === 'system') delete root.dataset.theme
  else root.dataset.theme = next
  notifyIfChanged()
}

/** Applies an appearance pushed by the host. Ignored once the theme is locked (export). */
export function applyAppearance(appearance: Appearance): void {
  // The language applies even in export (no visible UI there, but harmless).
  if (appearance.locale != null) setLocale(appearance.locale)
  if (locked) return
  const root = document.documentElement
  if (appearance.theme === 'light' || appearance.theme === 'dark' || appearance.theme === 'system') {
    applyTheme(appearance.theme)
  }
  if (typeof appearance.accent === 'string' && CSS.supports('color', appearance.accent)) {
    root.style.setProperty('--accent', appearance.accent)
  } else if (appearance.accent === null) {
    root.style.removeProperty('--accent')
  }
  if (typeof appearance.fontSize === 'number' && Number.isFinite(appearance.fontSize)) {
    const size = Math.min(32, Math.max(10, appearance.fontSize))
    root.style.setProperty('--font-size', `${size}px`)
  } else if (appearance.fontSize === null) {
    root.style.removeProperty('--font-size')
  }
}

/** Export always renders light, whatever the app or the system uses. */
export function lockLightTheme(): void {
  applyTheme('light')
  locked = true
}

/** Calls `listener` whenever the theme on screen changes. Returns an unsubscribe function. */
export function onThemeChange(listener: Listener): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

/** Starts following the system theme. Call once at startup. */
export function initAppearance(): void {
  lastResolved = resolvedTheme()
  systemQuery()?.addEventListener('change', notifyIfChanged)
}
