/**
 * Interface language of the editor. The host pushes the locale through
 * `setAppearance({ locale })`; views subscribe with `onLocaleChange` and
 * re-render. No dependencies: two flat dictionaries with the same keys.
 */
export type Locale = 'en' | 'pt-BR'

export const LOCALES: readonly Locale[] = ['en', 'pt-BR']

const en = {
  'editor.label': 'Note',
  'placeholder.paragraph': "Type '/' for commands",
  'placeholder.heading': 'Heading {level}',

  'slash.label': 'Insert block',
  'slash.empty': 'No results',
  'slash.text.title': 'Text',
  'slash.text.description': 'Plain paragraph',
  'slash.h1.title': 'Heading 1',
  'slash.h1.description': 'Large section title',
  'slash.h2.title': 'Heading 2',
  'slash.h2.description': 'Medium section title',
  'slash.h3.title': 'Heading 3',
  'slash.h3.description': 'Small section title',
  'slash.bullet.title': 'Bullet list',
  'slash.bullet.description': 'Simple bulleted list',
  'slash.numbered.title': 'Numbered list',
  'slash.numbered.description': 'List with numbers',
  'slash.todo.title': 'To-do list',
  'slash.todo.description': 'Track tasks with checkboxes',
  'slash.table.title': 'Table',
  'slash.table.description': '3 × 3 table with a header row',
  'slash.code.title': 'Code block',
  'slash.code.description': 'Code with syntax highlighting',
  'slash.mermaid.title': 'Mermaid diagram',
  'slash.mermaid.description': 'Flowchart, sequence, and more',
  'slash.quote.title': 'Quote',
  'slash.quote.description': 'Capture a quotation',
  'slash.divider.title': 'Divider',
  'slash.divider.description': 'Horizontal line',
  'slash.image.title': 'Image',
  'slash.image.description': 'Insert an image file',

  'format.bold': 'Bold (⌘B)',
  'format.italic': 'Italic (⌘I)',
  'format.strike': 'Strikethrough (⌘⇧S)',
  'format.code': 'Code (⌘E)',
  'format.link': 'Link',
  'format.linkTitle': 'Link (⌘K)',

  'link.placeholder': 'Paste or type a link…',
  'link.inputLabel': 'Link URL',
  'link.apply': 'Apply',
  'link.removeTitle': 'Remove link',
  'link.remove': 'Remove',
  'link.edit': 'Edit',

  'table.rowAbove.label': '↑ Row',
  'table.rowAbove.title': 'Add row above',
  'table.rowBelow.label': '↓ Row',
  'table.rowBelow.title': 'Add row below',
  'table.colLeft.label': '← Column',
  'table.colLeft.title': 'Add column to the left',
  'table.colRight.label': 'Column →',
  'table.colRight.title': 'Add column to the right',
  'table.delRow.label': '− Row',
  'table.delRow.title': 'Delete row',
  'table.delCol.label': '− Column',
  'table.delCol.title': 'Delete column',
  'table.header.label': 'Header',
  'table.header.title': 'Toggle header row',
  'table.delTable.label': 'Delete table',
  'table.delTable.title': 'Delete table',

  'mermaid.edit': 'Edit',
  'mermaid.done': 'Done',
  'mermaid.empty': 'Empty diagram.',
  'mermaid.failed': 'Could not render the diagram.',

  'image.readFailed': 'Could not read the file',

  'slash.ai.title': 'Ask AI',
  'slash.ai.description': 'Write or edit with AI',
  'format.askAI': 'Ask AI',
  'format.askAITitle': 'Ask AI (⌘J)',
  'ai.label': 'Ask AI',
  'ai.placeholder': 'Ask AI anything…',
  'ai.placeholderFollowUp': 'Tell AI what to do next…',
  'ai.send': 'Send',
  'ai.stop': 'Stop',
  'ai.thinking': 'Thinking…',
  'ai.stopped': 'Stopped.',
  'ai.failed': 'Something went wrong.',
  'ai.openSettings': 'Open Settings',
  'ai.replace': 'Replace selection',
  'ai.insertBelow': 'Insert below',
  'ai.copy': 'Copy',
  'ai.copied': 'Copied',
  'ai.retry': 'Try again',
  'ai.discard': 'Discard',
  'ai.primaryHint': '⌘↩',
  'ai.provider': 'Answered by {provider}',
  'ai.action.improve': 'Improve writing',
  'ai.action.grammar': 'Fix spelling & grammar',
  'ai.action.shorter': 'Make shorter',
  'ai.action.longer': 'Make longer',
  'ai.action.summarize': 'Summarize',
  'ai.action.translate': 'Translate',
  'ai.action.explain': 'Explain',
  'ai.action.continue': 'Continue writing',
  'ai.action.summarizeNote': 'Summarize note',
  'ai.action.brainstorm': 'Brainstorm ideas',
  'ai.action.outline': 'Outline',
  'ai.translateTo': 'Translate to {language}',
  'ai.language.English': 'English',
  'ai.language.Portuguese': 'Portuguese',
  'ai.language.Spanish': 'Spanish',
  'ai.language.French': 'French',
  'ai.language.German': 'German',
  'ai.language.Italian': 'Italian',
  'ai.language.Japanese': 'Japanese',
}

export type MessageKey = keyof typeof en

const ptBR: Record<MessageKey, string> = {
  'editor.label': 'Nota',
  'placeholder.paragraph': "Digite '/' para comandos",
  'placeholder.heading': 'Título {level}',

  'slash.label': 'Inserir bloco',
  'slash.empty': 'Nenhum resultado',
  'slash.text.title': 'Texto',
  'slash.text.description': 'Parágrafo simples',
  'slash.h1.title': 'Título 1',
  'slash.h1.description': 'Título de seção grande',
  'slash.h2.title': 'Título 2',
  'slash.h2.description': 'Título de seção médio',
  'slash.h3.title': 'Título 3',
  'slash.h3.description': 'Título de seção pequeno',
  'slash.bullet.title': 'Lista com marcadores',
  'slash.bullet.description': 'Lista simples com marcadores',
  'slash.numbered.title': 'Lista numerada',
  'slash.numbered.description': 'Lista com números',
  'slash.todo.title': 'Lista de tarefas',
  'slash.todo.description': 'Acompanhe tarefas com caixas de seleção',
  'slash.table.title': 'Tabela',
  'slash.table.description': 'Tabela 3 × 3 com linha de cabeçalho',
  'slash.code.title': 'Bloco de código',
  'slash.code.description': 'Código com destaque de sintaxe',
  'slash.mermaid.title': 'Diagrama Mermaid',
  'slash.mermaid.description': 'Fluxograma, sequência e mais',
  'slash.quote.title': 'Citação',
  'slash.quote.description': 'Registre uma citação',
  'slash.divider.title': 'Divisor',
  'slash.divider.description': 'Linha horizontal',
  'slash.image.title': 'Imagem',
  'slash.image.description': 'Inserir um arquivo de imagem',

  'format.bold': 'Negrito (⌘B)',
  'format.italic': 'Itálico (⌘I)',
  'format.strike': 'Tachado (⌘⇧S)',
  'format.code': 'Código (⌘E)',
  'format.link': 'Link',
  'format.linkTitle': 'Link (⌘K)',

  'link.placeholder': 'Cole ou digite um link…',
  'link.inputLabel': 'URL do link',
  'link.apply': 'Aplicar',
  'link.removeTitle': 'Remover link',
  'link.remove': 'Remover',
  'link.edit': 'Editar',

  'table.rowAbove.label': '↑ Linha',
  'table.rowAbove.title': 'Adicionar linha acima',
  'table.rowBelow.label': '↓ Linha',
  'table.rowBelow.title': 'Adicionar linha abaixo',
  'table.colLeft.label': '← Coluna',
  'table.colLeft.title': 'Adicionar coluna à esquerda',
  'table.colRight.label': 'Coluna →',
  'table.colRight.title': 'Adicionar coluna à direita',
  'table.delRow.label': '− Linha',
  'table.delRow.title': 'Excluir linha',
  'table.delCol.label': '− Coluna',
  'table.delCol.title': 'Excluir coluna',
  'table.header.label': 'Cabeçalho',
  'table.header.title': 'Alternar linha de cabeçalho',
  'table.delTable.label': 'Excluir tabela',
  'table.delTable.title': 'Excluir tabela',

  'mermaid.edit': 'Editar',
  'mermaid.done': 'Concluir',
  'mermaid.empty': 'Diagrama vazio.',
  'mermaid.failed': 'Não foi possível renderizar o diagrama.',

  'image.readFailed': 'Não foi possível ler o arquivo',

  'slash.ai.title': 'Perguntar à IA',
  'slash.ai.description': 'Escreva ou edite com IA',
  'format.askAI': 'Perguntar à IA',
  'format.askAITitle': 'Perguntar à IA (⌘J)',
  'ai.label': 'Perguntar à IA',
  'ai.placeholder': 'Pergunte qualquer coisa à IA…',
  'ai.placeholderFollowUp': 'Diga à IA o que fazer em seguida…',
  'ai.send': 'Enviar',
  'ai.stop': 'Parar',
  'ai.thinking': 'Pensando…',
  'ai.stopped': 'Interrompido.',
  'ai.failed': 'Algo deu errado.',
  'ai.openSettings': 'Abrir Ajustes',
  'ai.replace': 'Substituir seleção',
  'ai.insertBelow': 'Inserir abaixo',
  'ai.copy': 'Copiar',
  'ai.copied': 'Copiado',
  'ai.retry': 'Tentar de novo',
  'ai.discard': 'Descartar',
  'ai.primaryHint': '⌘↩',
  'ai.provider': 'Respondido por {provider}',
  'ai.action.improve': 'Melhorar a escrita',
  'ai.action.grammar': 'Corrigir ortografia e gramática',
  'ai.action.shorter': 'Encurtar',
  'ai.action.longer': 'Expandir',
  'ai.action.summarize': 'Resumir',
  'ai.action.translate': 'Traduzir',
  'ai.action.explain': 'Explicar',
  'ai.action.continue': 'Continuar escrevendo',
  'ai.action.summarizeNote': 'Resumir a nota',
  'ai.action.brainstorm': 'Gerar ideias',
  'ai.action.outline': 'Criar estrutura',
  'ai.translateTo': 'Traduzir para {language}',
  'ai.language.English': 'Inglês',
  'ai.language.Portuguese': 'Português',
  'ai.language.Spanish': 'Espanhol',
  'ai.language.French': 'Francês',
  'ai.language.German': 'Alemão',
  'ai.language.Italian': 'Italiano',
  'ai.language.Japanese': 'Japonês',
}

export const DICTIONARIES: Record<Locale, Record<MessageKey, string>> = { en, 'pt-BR': ptBR }

type Listener = (locale: Locale) => void

const listeners = new Set<Listener>()
let current: Locale = 'en'

export function isLocale(value: unknown): value is Locale {
  return typeof value === 'string' && (LOCALES as readonly string[]).includes(value)
}

export function getLocale(): Locale {
  return current
}

/** Switches the interface language. Unknown values are ignored. */
export function setLocale(locale: unknown): void {
  if (!isLocale(locale) || locale === current) return
  current = locale
  for (const listener of listeners) listener(locale)
}

/** Calls `listener` whenever the locale changes. Returns an unsubscribe function. */
export function onLocaleChange(listener: Listener): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

/** The message in `locale` (default: current), with `{name}` placeholders filled. Falls back to English, then the key. */
export function t(key: MessageKey, params?: Record<string, string | number>, locale: Locale = current): string {
  const template = DICTIONARIES[locale][key] ?? (en as Record<string, string>)[key] ?? key
  if (!params) return template
  return template.replace(/\{(\w+)\}/g, (match, name: string) => (name in params ? String(params[name]) : match))
}
