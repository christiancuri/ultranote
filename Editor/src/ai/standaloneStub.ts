/**
 * `pnpm dev` only: plays the host for Ask AI so the panel can be tried in a
 * browser. Enables AI and streams a canned Markdown answer for every `aiAsk`.
 */
import { STANDALONE_POST_EVENT, type Bridge, type OutgoingMessages } from '../bridge'

export function installStandaloneAI(bridge: Bridge): void {
  void bridge.api.setAIState({ enabled: true, providerName: 'Dev stub' })
  const timers = new Map<string, ReturnType<typeof setInterval>>()

  window.addEventListener(STANDALONE_POST_EVENT, (event) => {
    const { type, payload } = (event as CustomEvent<{ type: keyof OutgoingMessages; payload: unknown }>).detail
    if (type === 'aiAsk') {
      const { requestId, instruction, selection } = payload as OutgoingMessages['aiAsk']
      if (instruction.toLowerCase().includes('fail')) {
        void bridge.api.aiEvent({
          requestId,
          type: 'failed',
          error: { code: 'notLoggedIn', message: 'Claude Code is not logged in.', canOpenSettings: true },
        })
        return
      }
      const answer = `**${instruction}**\n\n${selection ? `About: ${selection}\n\n` : ''}- First point\n- Second point with \`code\`\n\nDone.`
      const chunks = answer.match(/.{1,12}/gs) ?? []
      let sent = ''
      void bridge.api.aiEvent({ requestId, type: 'thinking' })
      const timer = setInterval(() => {
        const chunk = chunks.shift()
        if (chunk === undefined) {
          clearInterval(timer)
          timers.delete(requestId)
          void bridge.api.aiEvent({ requestId, type: 'completed', text: sent })
          return
        }
        sent += chunk
        void bridge.api.aiEvent({ requestId, type: 'delta', text: chunk })
      }, 60)
      timers.set(requestId, timer)
    } else if (type === 'aiCancel') {
      const { requestId } = payload as OutgoingMessages['aiCancel']
      clearInterval(timers.get(requestId))
      timers.delete(requestId)
      void bridge.api.aiEvent({ requestId, type: 'cancelled' })
    }
  })
}
