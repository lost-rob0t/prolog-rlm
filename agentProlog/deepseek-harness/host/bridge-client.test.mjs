import assert from 'node:assert/strict'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { PrologRlmBridgeClient, PrologRlmBridgeError } from './bridge-client.mjs'

async function mockBridge() {
  const root = await mkdtemp(join(tmpdir(), 'prolog-rlm-bridge-mock-'))
  const script = join(root, 'mock.mjs')
  await writeFile(script, `
import { createInterface } from 'node:readline'
const rl = createInterface({ input: process.stdin, crlfDelay: Infinity })
const runs = new Map()
let nextRun = 0
const send = (value) => process.stdout.write(JSON.stringify(value) + '\\n')
rl.on('line', (line) => {
  const request = JSON.parse(line)
  const response = (result) => send({
    protocol: 'prolog_rlm_deepseek_bridge_v1',
    request_id: request.request_id,
    ok: true,
    result,
  })
  if (request.command === 'hello') return response({ canonical_agent_runtime: 'prolog-rlm' })
  if (request.command === 'slow') return setTimeout(() => response({ command: 'slow' }), 30)
  if (request.command === 'fast') return response({ command: 'fast' })
  if (request.command === 'fail') return send({
    protocol: 'prolog_rlm_deepseek_bridge_v1',
    request_id: request.request_id,
    ok: false,
    error: { kind: 'expected-test-failure' },
  })
  if (request.command === 'malformed') return process.stdout.write('not-json\\n')
  if (request.command === 'session/turn/start') {
    const runId = 'mock-run-' + String(++nextRun)
    runs.set(runId, { state: 'pending', polls: 0 })
    return response({ run_id: runId, state: 'pending' })
  }
  if (request.command === 'run/cancel') {
    const run = runs.get(request.payload.run_id)
    if (run !== undefined) run.state = 'cancelled'
    return response({ run_id: request.payload.run_id, state: 'cancelled' })
  }
  if (request.command === 'run/status') {
    const run = runs.get(request.payload.run_id)
    if (run === undefined) return response({ run_id: request.payload.run_id, state: 'missing' })
    if (run.state === 'pending') {
      run.polls += 1
      if (run.polls > 1) run.state = 'completed'
    }
    return response({ run_id: request.payload.run_id, state: run.state })
  }
  if (request.command === 'run/result') {
    const run = runs.get(request.payload.run_id)
    const state = run?.state ?? 'missing'
    runs.delete(request.payload.run_id)
    return response({ run_id: request.payload.run_id, state, turn: state === 'completed' ? { assistant: { content: 'done' } } : undefined })
  }
  response({ command: request.command })
})
`)
  return {
    root,
    client: new PrologRlmBridgeClient({ command: process.execPath, args: [script] }),
  }
}

test('correlates out-of-order NDJSON responses without inventing semantics', async () => {
  const { root, client } = await mockBridge()
  try {
    const hello = await client.start()
    assert.equal(hello.canonical_agent_runtime, 'prolog-rlm')
    const [slow, fast] = await Promise.all([
      client.request('slow'),
      client.request('fast'),
    ])
    assert.equal(slow.command, 'slow')
    assert.equal(fast.command, 'fast')
  } finally {
    await client.close()
    await rm(root, { recursive: true, force: true })
  }
})

test('preserves structured Prolog request failures', async () => {
  const { root, client } = await mockBridge()
  try {
    await client.start()
    await assert.rejects(
      client.request('fail'),
      (error) => {
        assert.ok(error instanceof PrologRlmBridgeError)
        assert.deepEqual(error.detail, { kind: 'expected-test-failure' })
        return true
      },
    )
  } finally {
    await client.close()
    await rm(root, { recursive: true, force: true })
  }
})

test('fails closed on malformed bridge output', async () => {
  const { root, client } = await mockBridge()
  try {
    await client.start()
    await assert.rejects(
      client.request('malformed'),
      (error) => error instanceof PrologRlmBridgeError,
    )
  } finally {
    await client.close()
    await rm(root, { recursive: true, force: true })
  }
})

test('runTurn waits for the Prolog-owned terminal result', async () => {
  const { root, client } = await mockBridge()
  try {
    await client.start()
    const result = await client.runTurn('session-1', 'hello', { pollIntervalMs: 1 })
    assert.equal(result.state, 'completed')
    assert.equal(result.turn.assistant.content, 'done')
  } finally {
    await client.close()
    await rm(root, { recursive: true, force: true })
  }
})

test('an aborted host signal cancels the Prolog-owned run', async () => {
  const { root, client } = await mockBridge()
  try {
    await client.start()
    const run = await client.startTurn('session-1', 'hello')
    const controller = new AbortController()
    controller.abort(new Error('test cancellation'))
    const result = await client.waitForRun(run.run_id, {
      signal: controller.signal,
      pollIntervalMs: 1,
    })
    assert.equal(result.state, 'cancelled')
  } finally {
    await client.close()
    await rm(root, { recursive: true, force: true })
  }
})
