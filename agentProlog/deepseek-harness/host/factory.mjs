import { createRequire } from 'node:module'
import { fileURLToPath, pathToFileURL } from 'node:url'

import { PrologRlmBridgeClient } from './bridge-client.mjs'

const DEFAULT_BRIDGE_SCRIPT = fileURLToPath(new URL('../bin/deepseek-prolog-bridge.pl', import.meta.url))
const profileRequire = createRequire(new URL('../profile/package.json', import.meta.url))
const importFromProfile = async (specifier) => import(pathToFileURL(profileRequire.resolve(specifier)).href)

export class UnsupportedPrologSemanticError extends Error {
  constructor(operation, detail) {
    super(`Prolog-RLM DeepSeek Harness adapter does not implement ${operation}`)
    this.name = 'UnsupportedPrologSemanticError'
    this.operation = operation
    this.detail = detail
  }
}

const defaultRuntimeLoader = async () => {
  const [{ Inbox, emitAgentEvent }, { createScope }] = await Promise.all([
    importFromProfile('@deepseek-ai/dsh-agent'),
    importFromProfile('@deepseek-ai/dsh-scope'),
  ])
  return { Inbox, emitAgentEvent, createScope }
}

const errorFailure = (error) => ({
  message: error instanceof Error ? error.message : String(error),
  code: 'PROLOG_RLM_BRIDGE',
})

const textContent = (message) => {
  if (!Array.isArray(message?.content)) {
    throw new UnsupportedPrologSemanticError('non-array message content', message)
  }
  const chunks = []
  for (const block of message.content) {
    if (block?.type !== 'text' || typeof block.text !== 'string') {
      throw new UnsupportedPrologSemanticError('non-text user content', block)
    }
    chunks.push(block.text)
  }
  return chunks.join('')
}

const messageId = (message, prefix) => {
  const sequence = message?.sequence
  return Number.isSafeInteger(sequence) && sequence >= 0
    ? `prolog-rlm:${prefix}:${sequence}`
    : crypto.randomUUID()
}

const projectAssistantMessage = (turn) => {
  const assistant = turn?.assistant
  const content = assistant?.content
  const route = turn?.route
  if (typeof content !== 'string' || typeof route?.provider !== 'string' || typeof route?.model !== 'string') {
    throw new UnsupportedPrologSemanticError('assistant result projection', turn)
  }
  return Object.freeze({
    id: messageId(assistant, 'assistant'),
    role: 'assistant',
    content: Object.freeze([{ type: 'text', text: content }]),
    source: Object.freeze({ kind: 'model', provider: route.provider, model: route.model }),
  })
}

const projectHistoricalMessage = (message) => {
  if (typeof message?.content !== 'string') {
    throw new UnsupportedPrologSemanticError('historical non-text message', message)
  }
  if (message.role === 'user') {
    return Object.freeze({
      id: messageId(message, 'user'),
      role: 'user',
      content: Object.freeze([{ type: 'text', text: message.content }]),
      source: Object.freeze({ kind: 'user' }),
    })
  }
  if (message.role === 'assistant') {
    const route = message.route
    if (typeof route?.provider !== 'string' || typeof route?.model !== 'string') {
      throw new UnsupportedPrologSemanticError('historical assistant route provenance', message)
    }
    return Object.freeze({
      id: messageId(message, 'assistant'),
      role: 'assistant',
      content: Object.freeze([{ type: 'text', text: message.content }]),
      source: Object.freeze({ kind: 'model', provider: route.provider, model: route.model }),
    })
  }
  throw new UnsupportedPrologSemanticError('historical message role', message)
}

const timestampMs = (value, fallback = 0) => {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return fallback
  const milliseconds = Math.floor(value * 1000)
  return Number.isSafeInteger(milliseconds) ? milliseconds : fallback
}

const projectHistorySeed = (messages) => {
  if (!Array.isArray(messages)) {
    throw new UnsupportedPrologSemanticError('historical message list', messages)
  }
  const events = []
  let seq = 0
  let turn = 0
  const push = (type, time, data, surface = false) => {
    events.push(Object.freeze({
      type,
      seq: seq++,
      time,
      data,
      ...(surface ? { surfaceOp: 'append' } : {}),
    }))
  }

  for (let index = 0; index < messages.length;) {
    const user = messages[index]
    const assistant = messages[index + 1]
    if (user?.role !== 'user' || assistant?.role !== 'assistant') {
      throw new UnsupportedPrologSemanticError('historical turn pairing', { index, user, assistant })
    }
    turn += 1
    const step = 1
    const userTime = timestampMs(user.created_at)
    const assistantTime = timestampMs(assistant.created_at, userTime)
    push('turn/start', userTime, { turn })
    push('step/start', userTime, { turn, step })
    push('user/message', userTime, projectHistoricalMessage(user), true)
    push('assistant/message', assistantTime, {
      turn,
      step,
      message: projectHistoricalMessage(assistant),
    }, true)
    push('step/end', assistantTime, { turn, step })
    push('turn/end', assistantTime, { turn, reason: { kind: 'completed' } })
    index += 2
  }
  return Object.freeze(events)
}

const resumedSessionMeta = (opened) => {
  const meta = {}
  const createdAt = timestampMs(opened?.created_at, Date.now())
  meta.createdAt = createdAt
  const cwd = opened?.metadata?.cwd
  if (typeof cwd === 'string' && cwd.length > 0) meta.cwd = cwd
  return meta
}

const abortedReason = (cause) => ({ kind: 'aborted', reason: cause ?? { kind: 'user' } })

export class PrologBackedAgent {
  #bridge
  #emit
  #scope
  #status = 'idle'
  #activity
  #activeController
  #activeCancelCause
  #disposed = false
  #turn

  constructor({ baseCtx, id, options, session, bridge, Inbox, emitAgentEvent, createScope }) {
    this.id = id
    this.options = Object.freeze({ ...options })
    this.session = session
    this.#bridge = bridge
    this.#emit = (name, payload) => emitAgentEvent(baseCtx, this, name, payload)
    this.#scope = createScope(baseCtx, this)
    this.ctx = this.#scope.ctx.extend({ agent: this })
    this.inbox = new Inbox(session, {
      inserted: (message) => this.#emit('agent/inbox/inserted', { message }),
      claimed: (message, turn) => this.#emit('agent/inbox/claimed', { message, turn }),
      discarded: (message) => this.#emit('agent/inbox/discarded', { message }),
    })
    this.#turn = session.events.findLast?.((event) => event.type === 'turn/start')?.data?.turn ?? 0
  }

  get status() {
    return this.#status
  }

  get scope() {
    return this.#scope
  }

  send(message, target, wakeup) {
    this.#assertLive()
    if (target !== 'next-turn' || wakeup !== true) {
      throw new UnsupportedPrologSemanticError('send target/wakeup semantics', { target, wakeup })
    }
    textContent(message)
    this.inbox.append('next-turn', message)
    this.#wake()
  }

  followup(message) {
    this.send(message, 'next-turn', true)
  }

  steer(message) {
    throw new UnsupportedPrologSemanticError('steer', message)
  }

  inject(message) {
    throw new UnsupportedPrologSemanticError('inject', message)
  }

  runMaintenance() {
    throw new UnsupportedPrologSemanticError('runMaintenance')
  }

  cancel(cause, options = {}) {
    if (this.#activity === undefined) return
    if (this.#activeCancelCause === undefined) this.#activeCancelCause = cause
    if (options.keepInbox !== true) this.inbox.clear()
    this.#activeController?.abort(cause)
  }

  async whenIdle() {
    for (;;) {
      const activity = this.#activity
      if (activity === undefined) return
      await activity
      if (this.#activity === undefined) return
    }
  }

  async dispose() {
    if (this.#disposed) return
    this.#disposed = true
    this.cancel({ kind: 'disposed' })
    await this.whenIdle()
    await this.#scope.dispose()
  }

  #assertLive() {
    if (this.#disposed) throw new Error(`agent "${this.id}" is disposed`)
  }

  #setStatus(status) {
    if (this.#status === status) return
    this.#status = status
    this.#emit('agent/status', { status })
  }

  #wake() {
    if (this.#activity !== undefined) return
    this.#setStatus('running')
    const activity = this.#drive()
    this.#activity = activity
    void activity.finally(() => {
      if (this.#activity !== activity) return
      this.#activity = undefined
      this.#setStatus('idle')
      if (!this.#disposed && this.inbox.hasPending) this.#wake()
    })
  }

  async #drive() {
    while (!this.#disposed && this.inbox.nextTurn.length > 0) {
      await this.#driveOne()
    }
  }

  async #driveOne() {
    const turn = ++this.#turn
    const step = 1
    const claimed = this.inbox.claim('next-turn', turn)
    if (claimed.length !== 1) {
      throw new UnsupportedPrologSemanticError('multi-message step projection', claimed)
    }
    const message = claimed[0]
    const content = textContent(message)
    const controller = new AbortController()
    this.#activeController = controller
    this.#activeCancelCause = undefined

    this.session.append('turn/start', { turn })
    this.session.append('step/start', { turn, step })
    this.session.append('user/message', message, { surfaceOp: 'append' })

    try {
      let run
      try {
        run = await this.#bridge.runTurn(String(this.id), content, { signal: controller.signal })
      } catch (error) {
        if (controller.signal.aborted) {
          this.session.append('step/end', { turn, step })
          this.session.append('turn/end', { turn, reason: abortedReason(this.#activeCancelCause) })
          return
        }
        const failure = errorFailure(error)
        this.session.append('step/end', { turn, step })
        this.session.append('turn/end', { turn, reason: { kind: 'error', error: failure } })
        this.#emit('agent/error', { turn, step, error })
        return
      }

      if (run?.state === 'cancelled' || controller.signal.aborted) {
        this.session.append('step/end', { turn, step })
        this.session.append('turn/end', { turn, reason: abortedReason(this.#activeCancelCause) })
        return
      }
      if (run?.state !== 'completed' || run.turn === undefined) {
        const error = new Error(`unexpected Prolog-RLM run result state: ${String(run?.state)}`)
        const failure = errorFailure(error)
        this.session.append('step/end', { turn, step })
        this.session.append('turn/end', { turn, reason: { kind: 'error', error: failure } })
        this.#emit('agent/error', { turn, step, error })
        return
      }

      const assistant = projectAssistantMessage(run.turn)
      this.session.append(
        'assistant/message',
        { turn, step, message: assistant },
        { surfaceOp: 'append' },
      )
      this.session.append('step/end', { turn, step })
      this.session.append('turn/end', { turn, reason: { kind: 'completed' } })
    } finally {
      this.#activeController = undefined
      this.#activeCancelCause = undefined
    }
  }
}

export class PrologAgentFactory {
  #ctx
  #config
  #runtimeLoader
  #bridgeFactory
  #bridge
  #disposed = false
  #handles = new Set()

  constructor(ctx, config = {}, dependencies = {}) {
    this.#ctx = ctx
    this.#config = { ...config }
    this.#runtimeLoader = dependencies.runtimeLoader ?? defaultRuntimeLoader
    this.#bridgeFactory = dependencies.bridgeFactory ?? ((bridgeOptions) => new PrologRlmBridgeClient(bridgeOptions))
  }

  async createAgent(ownerCtx, options) {
    this.#assertActive()
    ownerCtx.fiber?.assertActive?.()
    if (options.signal?.aborted) throw options.signal.reason ?? new Error('agent creation aborted')
    if (options.seed !== undefined && options.seed.length > 0) {
      throw new UnsupportedPrologSemanticError('seeded/forked session creation', { sessionId: options.sessionId })
    }

    const [runtime, bridge] = await Promise.all([this.#runtimeLoader(), this.#getBridge()])
    const session = this.#ctx.sessions.prepare(
      options.sessionId,
      options.meta === undefined ? undefined : { meta: options.meta },
    )
    return this.#publish(ownerCtx, {
      id: options.sessionId,
      session,
      agentOptions: options.agentOptions ?? {},
      setup: options.setup,
      signal: options.signal,
      source: 'startup',
      runtime,
      bridge,
      beforePublish: async () => {
        await bridge.request('session/create', {
          id: String(options.sessionId),
          metadata: {
            source: 'deepseek-harness',
            ...(options.meta?.cwd === undefined ? {} : { cwd: options.meta.cwd }),
          },
        })
      },
    })
  }

  async resume(ownerCtx, options) {
    this.#assertActive()
    ownerCtx.fiber?.assertActive?.()
    if (options.signal?.aborted) throw options.signal.reason ?? new Error('agent resume aborted')

    const [runtime, bridge] = await Promise.all([this.#runtimeLoader(), this.#getBridge()])
    const id = options.resumeSessionId
    const [opened, messages] = await Promise.all([
      bridge.request('session/open', { session_id: String(id) }),
      bridge.request('session/messages', { session_id: String(id), limit: 'all' }),
    ])
    const seed = projectHistorySeed(messages)
    const session = this.#ctx.sessions.prepare(id, {
      seed,
      meta: resumedSessionMeta(opened),
    })
    return this.#publish(ownerCtx, {
      id,
      session,
      agentOptions: options.agentOptions ?? {},
      setup: options.setup,
      signal: options.signal,
      source: 'resume',
      runtime,
      bridge,
    })
  }

  async #publish(ownerCtx, details) {
    const {
      id,
      session,
      agentOptions,
      setup,
      signal,
      source,
      runtime,
      bridge,
      beforePublish,
    } = details
    const agent = new PrologBackedAgent({
      baseCtx: this.#ctx,
      id,
      options: agentOptions,
      session,
      bridge,
      ...runtime,
    })

    let detachSession
    let detachAgent
    let disposing
    let unfollowOwner = () => {}
    const dispose = async (ownerTriggered = false) => {
      if (disposing !== undefined) return disposing
      disposing = (async () => {
        try {
          await agent.dispose()
        } finally {
          try {
            detachAgent?.()
            detachSession?.()
          } finally {
            this.#handles.delete(dispose)
            if (!ownerTriggered) await unfollowOwner()
          }
        }
      })()
      return disposing
    }

    this.#handles.add(dispose)
    unfollowOwner = ownerCtx.effect?.(() => () => {
      if (disposing !== undefined) return
      return dispose(true)
    }, `prologRlm.lifecycle(${id})`) ?? (() => {})

    try {
      const setupCommit = await setup?.(agent.ctx)
      if (signal?.aborted) throw signal.reason ?? new Error('agent creation aborted')
      setupCommit?.commit?.()
      await beforePublish?.()
      if (signal?.aborted) throw signal.reason ?? new Error('agent creation aborted')

      detachSession = agent.ctx.sessions.enter(session)
      detachAgent = this.#ctx.agents.enter(agent, ownerCtx.agent)
      agent.ctx.sessions.announce(session)
      this.#ctx.agents.announce(agent)
      runtime.emitAgentEvent(this.#ctx, agent, 'agent/session-start', { source })
      return { agent, dispose }
    } catch (error) {
      await dispose()
      throw error
    }
  }

  async dispose() {
    if (this.#disposed) return
    this.#disposed = true
    await Promise.allSettled([...this.#handles].map((dispose) => dispose()))
    this.#handles.clear()
    await this.#bridge?.close()
  }

  async #getBridge() {
    if (this.#bridge !== undefined) return this.#bridge
    const bridge = this.#bridgeFactory({
      script: this.#config.script ?? DEFAULT_BRIDGE_SCRIPT,
      settingsPath: this.#config.settingsPath,
      cwd: this.#config.cwd,
      env: this.#config.env,
    })
    const hello = await bridge.start()
    if (hello?.canonical_agent_runtime !== 'prolog-rlm' || hello?.history_mode !== 'lossless_rlm' || hello?.compaction !== false) {
      await bridge.close().catch(() => {})
      throw new Error('Prolog-RLM bridge refused required lossless authority contract')
    }
    this.#bridge = bridge
    return bridge
  }

  #assertActive() {
    if (this.#disposed) throw new Error('Prolog-RLM agent factory is disposed')
  }
}

export default function prologRlmAgentFactoryPlugin(ctx, config = {}) {
  const factory = new PrologAgentFactory(ctx, config)
  ctx.effect(() => () => factory.dispose(), 'prolog-rlm agent factory bridge')
  ctx.effect(() => ctx.agents.setFactory(factory), 'prolog-rlm agent factory')
}
