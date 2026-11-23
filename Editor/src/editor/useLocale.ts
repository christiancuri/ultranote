import { useSyncExternalStore } from 'react'

import { getLocale, onLocaleChange, type Locale } from '../i18n'

/** The current locale; the component re-renders when it changes. */
export function useLocale(): Locale {
  return useSyncExternalStore(onLocaleChange, getLocale, getLocale)
}
