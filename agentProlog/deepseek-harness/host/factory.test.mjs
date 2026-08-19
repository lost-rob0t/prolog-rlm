import assert from 'node:assert/strict'
import test from 'node:test'
import { PrologAgentFactory, UnsupportedPrologSemanticError } from './factory.mjs'

class FakeSession {
  constructor(id) { this.id = id; this.events = [] }
  append(type, data) { this.events.push({ type, data }); return this.events.at(-1) }
}

class FakeInbox {
  constructor(_session, notifications) {
    this.notifications = notifications
    this.nextTurn = []
    this.nextStep = []
  }
  get hasPending() { return this.nextTurn.length > 0 || this.nextStep.length > 0 }
  append(target, message) {
    this[target === 'next-turn' ? 'nextTurn' : 'nextStep'].push(message)
    this.notifications.inserted(message)
  }
  claim(target, turn) {
    const list = target === 'next-turn' ? this.nextTurn : this.nextStep
    const value = list.splice(0, target === 'next-turn' ? 1 : list.length)
    for (const message of value) this.notifications.claimed(message, turn)
    return value
  }
  clear() {
    for (const message of [...this.nextTurn, ...this.nextStep]) this.notifications.discarded(message)
    this.nextTurn = []
    this.nextStep = []
  }
}

const fakeCreateScope = (baseCtx) => ({
  ctx: { ...baseCtx, extend(values) { return { ...this, ...values } } },
  async dispose() { baseCtx.log.push('scope:dispose') },
})
const fakeEmitAgentEvent = (ctx, _agent, name, payload) => {
  ctx.log.push(`${name}:${payload.status ?? payload.source ?? ''}`)
}

class FakeBridge {
  constructor(log, { block = false, invalidHello = false } = {}) {
    this.log = log
    this.block = block
    this.invalidHello = invalidHello
  }
  async start() {
    this.log.push('bridge:start')
    return this.invalidHello
      ? { canonical_agent_runtime: 'generic', history_mode: 'summary', compaction: true }
      : { canonical_agent_runtime: 'prolog-rlm', history_mode: 'lossless_rlm', compaction: false }
  }
  async request(command, payload) {
    this.log.push(`bridge:${command}`)
    if (command === 'session/create') return { session_id: payload.id }
    throw new Error(`unexpected request ${command}`)
  }
  async runTurn(sessionId, content, { signal }) {
    this.log.push(`bridge:turn:${sessionId}:${content}`)
    if (!this.block) {
      return {
        state: 'completed',
        turn: {
          assistant: { content: `reply:${content}` },
          route: { provider: 'openrouter', model: 'test/model' },
        },
      }
    }
    return new Promise((resolve) => {
      const finish = () => resolve({ state: 'cancelled' })
      if (signal.aborted) return finish()
      signal.addEventListener('abort', finish, { once: true })
    })
  }
  async close() { this.log.push('bridge:close') }
}

function harness({ bridgeOptions } = {}) {
  const log = []
  const sessions = new Map()
  const agents = new Map()
  const ctx = {
    log,
    sessions: {
      prepare(id) { log.push(`session:prepare:${id}`); return new FakeSession(id) },
      enter(session) {
        log.push('session:enter')
        sessions.set(session.id, session)
        return () => { log.push('session:detach'); sessions.delete(session.id) }
      },
      announce() { log.push('session:announce') },
    },
    agents: {
      enter(agent) {
        log.push('agent:enter')
        agents.set(agent.id, agent)
        return () => { log.push('agent:detach'); agents.delete(agent.id) }
      },
      announce() { log.push('agent:announce') },
    },
  }
  const ownerCtx = {
    agent: undefined,
    effect(fn) {
      const disposer = fn()
      return async () => disposer?.()
    },
    fiber: { assertActive() {} },
  }
  const bridge = new FakeBridge(log, bridgeOptions)
  const factory = new PrologAgentFactory(ctx, {}, {
    bridgeFactory: () => bridge,
    runtimeLoader: async () => ({
      Inbox: FakeInbox,
      createScope: fakeCreateScope,
      emitAgentEvent: fakeEmitAgentEvent,
    }),
  })
  return { log, sessions, agents, ownerCtx, bridge, factory }
}

const user = (text) => ({
  id: crypto.randomUUID(),
  role: 'user',
  content: [{ type: 'text', text }],
  source: { kind: 'user' },
})

test('publishes only after canonical Prolog session creation', async () => {
  const { factory, ownerCtx, log } = harness()
  const handle = await factory.createAgent(ownerCtx, { sessionId: 's1' })
  assert.deepEqual(log.slice(0, 8), [
    'bridge:start',
    'session:prepare:s1',
    'bridge:session/create',
    'session:enter',
    'agent:enter',
    'session:announce',
    'agent:announce',
    'agent/session-start:startup',
  ])
  await handle.dispose()
  await factory.dispose()
})

test('followup drives one Prolog turn and projects completion', async () => {
  const { factory, ownerCtx } = harness()
  const { agent, dispose } = await factory.createAgent(ownerCtx, { sessionId: 's2' })
  agent.followup(user('hello'))
  await agent.whenIdle()
  assert.deepEqual(agent.session.events.map(event => event.type), [
    'turn/start',
    'step/start',
    'user/message',
    'assistant/message',
    'step/end',
    'turn/end',
  ])
  assert.equal(agent.session.events[3].data.message.content[0].text, 'reply:hello')
  assert.equal(agent.session.events[5].data.reason.kind, 'completed')
  await dispose()
  await factory.dispose()
})

test('cancel aborts the bridge-backed Prolog run', async () => {
  const { factory, ownerCtx } = harness({ bridgeOptions: { block: true } })
  const { agent, dispose } = await factory.createAgent(ownerCtx, { sessionId: 's3' })
  agent.followup(user('slow'))
  await new Promise(resolve => setImmediate(resolve))
  agent.cancel({ kind: 'user' })
  await agent.whenIdle()
  assert.equal(agent.session.events.at(-1).type, 'turn/end')
  assert.deepEqual(agent.session.events.at(-1).data.reason, {
    kind: 'aborted',
    reason: { kind: 'user' },
  })
  await dispose()
  await factory.dispose()
})

test('unsupported Harness semantics fail closed', async () => {
  const { factory, ownerCtx } = harness()
  const { agent, dispose } = await factory.createAgent(ownerCtx, { sessionId: 's4' })
  assert.throws(() => agent.steer(user('nope')), UnsupportedPrologSemanticError)
  assert.throws(() => agent.inject(user('nope')), UnsupportedPrologSemanticError)
  assert.throws(() => agent.runMaintenance(async () => {}), UnsupportedPrologSemanticError)
  assert.throws(
    () => agent.followup({ ...user('x'), content: [{ type: 'image', attachment: {} }] }),
    UnsupportedPrologSemanticError,
  )
  await assert.rejects(
    factory.resume(ownerCtx, { resumeSessionId: 's4' }),
    UnsupportedPrologSemanticError,
  )
  await dispose()
  await factory.dispose()
})

test('factory rejects a non-lossless or non-Prolog bridge', async () => {
  const { factory, ownerCtx, log } = harness({ bridgeOptions: { invalidHello: true } })
  await assert.rejects(
    factory.createAgent(ownerCtx, { sessionId: 's5' }),
    /lossless authority contract/,
  )
  assert.ok(log.includes('bridge:close'))
})
