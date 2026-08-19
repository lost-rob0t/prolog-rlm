import { fileURLToPath } from "node:url"
import { resolve } from "node:path"

export interface NdjsonTransport {
  readonly lines: AsyncIterable<string>
  send(line: string): Promise<void>
  close(): Promise<void>
}

async function* linesFromStream(stream: ReadableStream<Uint8Array>): AsyncIterable<string> {
  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let buffered = ""
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      buffered += decoder.decode(value, { stream: true })
      while (true) {
        const newline = buffered.indexOf("\n")
        if (newline < 0) break
        const line = buffered.slice(0, newline).replace(/\r$/, "")
        buffered = buffered.slice(newline + 1)
        if (line.length > 0) yield line
      }
    }
    buffered += decoder.decode()
    if (buffered.length > 0) yield buffered.replace(/\r$/, "")
  } finally {
    reader.releaseLock()
  }
}

export class SwiplFixtureTransport implements NdjsonTransport {
  readonly lines: AsyncIterable<string>
  private readonly process: Bun.Subprocess<"pipe", "pipe", "pipe">
  private closed = false

  constructor(repoRoot?: string) {
    const root = repoRoot ?? resolve(fileURLToPath(new URL("../../../../", import.meta.url)))
    this.process = Bun.spawn({
      cmd: ["swipl", "-q", "-s", "agentProlog/bin/prolog-agent-ui-fixture.pl"],
      cwd: root,
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    })
    this.lines = linesFromStream(this.process.stdout)
  }

  async send(line: string): Promise<void> {
    if (this.closed) throw new Error("transport_closed")
    this.process.stdin.write(`${line}\n`)
    await this.process.stdin.flush()
  }

  async close(): Promise<void> {
    if (this.closed) return
    this.closed = true
    this.process.stdin.end()
    await this.process.exited
  }

  get exitCode(): Promise<number> {
    return this.process.exited
  }
}
