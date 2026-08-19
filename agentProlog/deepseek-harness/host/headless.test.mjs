import assert from 'node:assert/strict'
import test from 'node:test'

import prologHeadlessRunner, { internals } from './headless.mjs'

const harness = ({ reason = { kind: 'completed' } } = {}) => {
  const log = []
  let exitCode
  let followupMessage
  let stdout = ''
  let stderr = ''
  let resolveExit
  const exited = new Promise((resolve) => { resolveExit = resolve })

  const session = { seq: 0, events: [] }
  const agent = {
    session,
    async whenIdle() {
      log.push('agent:idle')
    },
    followup(message) {
      followupMessage = message
      log.push('agent:followup')
      session.events.push(
        { type: 'turn/start', seq: 0, data: { turn: 1 } },
        { type: 'user/message', seq: 1, data: message },
        {
          type: 'assistant/message',
          seq: 2,
          data: {
            message: {
              content: [{ type: 'text', text: 'reply from prolog' }],
            },
          },
        },
        { type: 'turn/end', seq: 3, data: { turn: 1, reason } },
      )
      session.seq = 4
    },
  }

  const agents = {
    async create(options) {
      log.push('agents:create')
      assert.match(options.sessionId, /^session-/)
      assert.equal(options.meta.cwd, process.cwd())
      assert.deepEqual(options.agentOptions, {})
      return { agent }
    },
  }

  const loader = {
    async await() {
      log.push('loader:await')
    },
  }

  const ctx = {
    get(name) {
      if (name === 'loader') return loader
      if (name === 'agents') return agents
      if (name === 'appExit') {
        return (code) => {
          exitCode = code
          resolveExit(code)
        }
      }
      return undefined
    },
  }

  const previousStdout = internals.stdout
  const previousStderr = internals.stderr
  internals.stdout = { write(chunk) { stdout += String(chunk) } }
  internals.stderr = { write(chunk) { stderr += String(chunk) } }

  return {
    ctx,
    exited,
    log,
    get exitCode() { return exitCode },
    get followupMessage() { return followupMessage },
    get stdout() { return stdout },
    get stderr() { return stderr },
    restore() {
      internals.stdout = previousStdout
      internals.stderr = previousStderr
    },
  }
}

test('headless runner drives exactly one Prolog-backed agent turn', async () => {
  const h = harness()
  try {
    prologHeadlessRunner(h.ctx, { task: 'inspect this project' })
    await h.exited

    assert.equal(h.exitCode, 0)
    assert.equal(h.stdout, 'reply from prolog\n')
    assert.equal(h.stderr, '')
    assert.deepEqual(h.log, [
      'loader:await',
      'agents:create',
      'agent:idle',
      'agent:followup',
      'agent:idle',
    ])
    assert.equal(h.followupMessage.role, 'user')
    assert.equal(h.followupMessage.source.kind, 'user')
    assert.deepEqual(h.followupMessage.content, [{ type: 'text', text: 'inspect this project' }])
  } finally {
    h.restore()
  }
})

test('headless runner returns failure when the Prolog-backed turn fails', async () => {
  const h = harness({ reason: { kind: 'error', error: { code: 'PROLOG_RLM', message: 'turn failed' } } })
  try {
    prologHeadlessRunner(h.ctx, { task: 'fail intentionally' })
    await h.exited

    assert.equal(h.exitCode, 1)
    assert.equal(h.stdout, 'reply from prolog\n')
    assert.match(h.stderr, /PROLOG_RLM: turn failed/)
  } finally {
    h.restore()
  }
})

test('headless runner rejects an empty task before creating an agent', () => {
  const h = harness()
  try {
    assert.throws(
      () => prologHeadlessRunner(h.ctx, { task: '' }),
      /requires a non-empty task/,
    )
  } finally {
    h.restore()
  }
})
