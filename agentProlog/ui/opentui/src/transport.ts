import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process"
import { createInterface } from "node:readline"
import { resolve } from "node:path"
import { fileURLToPath } from "node:url"

export interface NdjsonTransport {
  readonly lines: AsyncIterable<string>
  send(line: string): Promise<void>
  close(): Promise<void>
}

export class SwiplFixtureTransport implements NdjsonTransport {
  readonly lines: AsyncIterable<string>
  private readonly process: ChildProcessWithoutNullStreams
  private readonly exited: Promise<number>
  private stderrTail = ""
  private closed = false

  constructor(repoRoot?: string) {
    const root = repoRoot ?? resolve(fileURLToPath(new URL("../../../../", import.meta.url)))
    this.process = spawn(
      "swipl",
      ["-q", "-s", "agentProlog/bin/prolog-agent-ui-fixture.pl"],
      { cwd: root },
    )

    this.process.stderr.setEncoding("utf8")
    this.process.stderr.on("data", (chunk: string) => {
      this.stderrTail = `${this.stderrTail}${chunk}`.slice(-8192)
    })

    this.exited = new Promise<number>((resolveExit, rejectExit) => {
      this.process.once("error", rejectExit)
      this.process.once("exit", (code, signal) => {
        resolveExit(code ?? (signal === null ? 1 : 128))
      })
    })

    this.lines = this.readLines()
  }

  async send(line: string): Promise<void> {
    if (this.closed || this.process.stdin.destroyed) throw new Error("transport_closed")
    await new Promise<void>((resolveWrite, rejectWrite) => {
      this.process.stdin.write(`${line}\n`, (error) => {
        if (error) rejectWrite(error)
        else resolveWrite()
      })
    })
  }

  async close(): Promise<void> {
    if (this.closed) return
    this.closed = true
    if (!this.process.stdin.destroyed) this.process.stdin.end()
    await this.exited
  }

  get exitCode(): Promise<number> {
    return this.exited
  }

  private async *readLines(): AsyncIterable<string> {
    const reader = createInterface({ input: this.process.stdout, crlfDelay: Infinity })
    try {
      for await (const line of reader) {
        if (line.length > 0) yield line
      }
    } finally {
      reader.close()
    }

    const code = await this.exited
    if (!this.closed) {
      const detail = this.stderrTail.trim()
      throw new Error(detail.length > 0 ? `swipl_fixture_exited(${code}): ${detail}` : `swipl_fixture_exited(${code})`)
    }
  }
}
