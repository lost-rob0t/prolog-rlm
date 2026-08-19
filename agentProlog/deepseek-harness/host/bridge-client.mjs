import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { createInterface } from 'node:readline'

const PROTOCOL = 'prolog_rlm_deepseek_bridge_v1'

export class PrologRlmBridgeError extends Error {
  constructor(message, detail) {
    super(message)
    this.name = 'PrologRlmBridgeError'
    this.detail = detail
  }
}

/**
 * Transport-only client for the Prolog-RLM DeepSeek Harness bridge.
 *
 * This class owns subprocess framing and request correlation only. It does not
 * implement an agent loop, tools, permissions, context selection, or session
 * semantics; those remain in Prolog.
 */
export class PrologRlmBridgeClient {
  #command
  #args
  #cwd
  #env
  #child
  #lines
  #pending = new Map()
  #nextRequestId = 0
  #closing = false
  #closed = false
  #stderrTail = ''

  constructor({ command = 'swipl', args, script, settingsPath, cwd = process.cwd(), env = process.env } = {}) {
    if (!Array.isArray(args)) {
      if (typeof script !== 'string' || script.length === 0) {
        throw new TypeError('script is required when args are not supplied')
      }
      args = ['-q', '-s', script]
      if (settingsPath !== undefined) args.push('--', '--settings', settingsPath)
    }
    this.#command = command
    this.#args = [...args]
    this.#cwd = cwd
    this.#env = env
  }

  get running() {
    return this.#child !== undefined && !this.#closed
  }

  async start() {
    if (this.#child !== undefined) throw new Error('bridge client already started')
    const child = spawn(this.#command, this.#args, {
      cwd: this.#cwd,
      env: this.#env,
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    this.#child = child

    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk) => {
      this.#stderrTail = `${this.#stderrTail}${chunk}`.slice(-8192)
    })

    this.#lines = createInterface({ input: child.stdout, crlfDelay: Infinity })
    this.#lines.on('line', (line) => this.#acceptLine(line))
    child.once('exit', (code, signal) => this.#onExit(code, signal))
    child.once('error', (error) => this.#failAll(error))

    await once(child, 'spawn')
    return this.request('hello', {})
  }

  request(command, payload = {}) {
    if (!this.running || this.#child?.stdin.destroyed) {
      return Promise.reject(new Error('bridge client is not running'))
    }
    if (typeof command !== 'string' || command.length === 0) {
      return Promise.reject(new TypeError('command must be a non-empty string'))
    }
    if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
      return Promise.reject(new TypeError('payload must be a JSON object'))
    }

    const requestId = String(++this.#nextRequestId)
    const wire = JSON.stringify({ request_id: requestId, command, payload }) + '\n'
    return new Promise((resolve, reject) => {
      this.#pending.set(requestId, { resolve, reject })
      this.#child.stdin.write(wire, 'utf8', (error) => {
        if (error === null || error === undefined) return
        const pending = this.#pending.get(requestId)
        if (pending === undefined) return
        this.#pending.delete(requestId)
        pending.reject(error)
      })
    })
  }

  async close() {
    if (this.#closed) return
    this.#closing = true
    const child = this.#child
    if (child === undefined) {
      this.#closed = true
      return
    }
    if (!child.stdin.destroyed) child.stdin.end()
    if (child.exitCode === null && child.signalCode === null) await once(child, 'exit')
    this.#closed = true
    this.#lines?.close()
  }

  #acceptLine(line) {
    if (line.trim() === '') return
    let response
    try {
      response = JSON.parse(line)
      if (response === null || typeof response !== 'object' || Array.isArray(response)) {
        throw new Error('bridge response is not an object')
      }
      if (response.protocol !== PROTOCOL) {
        throw new Error(`unexpected bridge protocol: ${String(response.protocol)}`)
      }
      if (typeof response.request_id !== 'string') {
        throw new Error('bridge response lacks a string request_id')
      }
    } catch (error) {
      this.#failAll(new PrologRlmBridgeError(`invalid bridge response: ${error.message}`, line))
      this.#child?.kill('SIGTERM')
      return
    }

    const pending = this.#pending.get(response.request_id)
    if (pending === undefined) {
      this.#failAll(new PrologRlmBridgeError(`uncorrelated bridge response: ${response.request_id}`, response))
      this.#child?.kill('SIGTERM')
      return
    }
    this.#pending.delete(response.request_id)
    if (response.ok === true) {
      pending.resolve(response.result)
      return
    }
    pending.reject(new PrologRlmBridgeError('Prolog-RLM bridge request failed', response.error))
  }

  #onExit(code, signal) {
    this.#closed = true
    this.#lines?.close()
    if (this.#closing && this.#pending.size === 0) return
    const suffix = this.#stderrTail.trim() === '' ? '' : `\nstderr:\n${this.#stderrTail.trim()}`
    this.#failAll(new Error(`Prolog-RLM bridge exited (code=${String(code)}, signal=${String(signal)})${suffix}`))
  }

  #failAll(error) {
    for (const pending of this.#pending.values()) pending.reject(error)
    this.#pending.clear()
  }
}

export { PROTOCOL as PROLOG_RLM_DEEPSEEK_BRIDGE_PROTOCOL }
