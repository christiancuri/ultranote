// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'

import { applyAppearance } from './appearance'
import { filterSlashItems, slashTitle, SLASH_ITEMS } from './editor/slash/items'
import { DICTIONARIES, getLocale, LOCALES, onLocaleChange, setLocale, t, type MessageKey } from './i18n'

afterEach(() => setLocale('en'))

describe('i18n', () => {
  it('dictionaries have identical, non-empty key sets', () => {
    const keys = Object.keys(DICTIONARIES.en).sort()
    for (const locale of LOCALES) {
      expect(Object.keys(DICTIONARIES[locale]).sort()).toEqual(keys)
      for (const key of keys) expect(DICTIONARIES[locale][key as MessageKey]).not.toBe('')
    }
    for (const item of SLASH_ITEMS) {
      expect(keys).toContain(`slash.${item.id}.title`)
      expect(keys).toContain(`slash.${item.id}.description`)
    }
  })

  it('defaults to en, interpolates and falls back', () => {
    expect(getLocale()).toBe('en')
    expect(t('placeholder.heading', { level: 2 })).toBe('Heading 2')
    expect(t('placeholder.heading')).toBe('Heading {level}')
    expect(t('nope' as MessageKey)).toBe('nope')
    const saved = DICTIONARIES['pt-BR']['slash.empty']
    delete (DICTIONARIES['pt-BR'] as Partial<Record<MessageKey, string>>)['slash.empty']
    setLocale('pt-BR')
    expect(t('slash.empty')).toBe('No results')
    DICTIONARIES['pt-BR']['slash.empty'] = saved
    expect(t('slash.empty')).toBe('Nenhum resultado')
  })

  it('setLocale is lenient and notifies only on change', () => {
    const listener = vi.fn()
    const stop = onLocaleChange(listener)
    setLocale('fr')
    setLocale(42)
    setLocale('en')
    expect(listener).not.toHaveBeenCalled()
    setLocale('pt-BR')
    expect(listener).toHaveBeenCalledWith('pt-BR')
    stop()
    setLocale('en')
    expect(listener).toHaveBeenCalledTimes(1)
  })

  it.each(LOCALES)('slash search matches both languages under %s', (locale) => {
    setLocale(locale)
    for (const query of ['titulo', 'título 1', 'heading', 'heading 1']) {
      expect(filterSlashItems(query)[0]?.id).toBe('h1')
    }
    expect(filterSlashItems('tabela')[0]?.id).toBe('table')
    expect(filterSlashItems('table')[0]?.id).toBe('table')
    expect(filterSlashItems('lista de tarefas')[0]?.id).toBe('todo')
    expect(filterSlashItems('to-do')[0]?.id).toBe('todo')
  })

  it('setAppearance locale switches the interface language', () => {
    const h1 = SLASH_ITEMS.find((item) => item.id === 'h1')!
    applyAppearance({ theme: 'system', locale: 'pt-BR' })
    expect(getLocale()).toBe('pt-BR')
    expect(slashTitle(h1)).toBe('Título 1')
    applyAppearance({ theme: 'system', locale: 'xx' as never })
    expect(getLocale()).toBe('pt-BR')
    applyAppearance({ theme: 'system' })
    expect(getLocale()).toBe('pt-BR')
    applyAppearance({ theme: 'system', locale: 'en' })
    expect(slashTitle(h1)).toBe('Heading 1')
  })
})
