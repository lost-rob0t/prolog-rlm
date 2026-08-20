import assert from 'node:assert/strict'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

import { PrologRlmBridgeClient } from './bridge-client.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const bridgeScript = resolve(here, '../bin/deepseek-prolog-bridge.pl')

test('real SWI bridge exposes lossless Prolog-owned sessions to the host transport', async () => {
  const root = await mkdtemp(join(tmpdir(), 'prolog-rlm-bridge-integration-'))
  const settingsPath = join(root, 'settings.json')
  const storePath = join(root, 'unused-memory-store.db')
  await writeFile(settingsPath, JSON.stringify({
    schema_version: 1,
    driver: 'prolog-rlm',
    history_mode: 'lossless_rlm',
    compaction: false,
    persist_sessions: false,
    provider: 'openrouter',
    model: 'openrouter/free',
    conversation_store: storePath,
  }))

  const client = new PrologRlmBridgeClient({
    script: bridgeScript,
    settingsPath,
    cwd: resolve(here, '../../..'),
  })

  try {
    const hello = await client.start()
    assert.equal(hello.canonical_agent_runtime, 'prolog-rlm')
    assert.equal(hello.history_mode, 'lossless_rlm')
    assert.equal(hello.compaction, false)

    const created = await client.request('session/create', {
      id: 'host-integration-session',
      metadata: { source: 'node-host-integration-test' },
    })
    assert.equal(created.session_id, 'host-integration-session')
    assert.equal(created.compaction, false)

    const sessions = await client.request('session/list', { limit: 8 })
    assert.equal(sessions.length, 1)
    assert.equal(sessions[0].session_id, 'host-integration-session')

    const settings = await client.request('settings/get')
    assert.equal(settings.driver, 'prolog-rlm')
    assert.equal(settings.history_mode, 'lossless_rlm')
    assert.equal(settings.compaction, false)
    assert.equal(settings.provider, 'openrouter')
  } finally {
    await client.close()
    await rm(root, { recursive: true, force: true })
  }
})
