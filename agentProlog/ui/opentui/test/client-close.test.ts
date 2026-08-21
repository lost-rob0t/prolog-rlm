import { expect, test } from "bun:test"
import { ProtocolClient } from "../src/client.ts"
import type { NdjsonTransport } from "../src/transport.ts"
import { type ClientFrame, PROTOCOL } from "../src/protocol.ts"

class PendingCommandTransport implements NdjsonTransport {
  private controller!: ReadableStreamDefaultController<string>
  private readonly stream = new ReadableStream<string>({ start: (controller) => { this.controller = controller } })
  readonly lines = this.iterate()

  private async *iterate() {
    const reader = this.stream.getReader()
    while (true) {
      const item = await reader.read()
      if (item.done) return
      yield item.value
    }
  }

  async send(line: string): Promise<void> {
    const frame = JSON.parse(line) as ClientFrame
    if (frame.kind !== "negotiate") return
    this.controller.enqueue(JSON.stringify({
      protocol: PROTOCOL,
      kind: "result",
      session_id: "s1",
      request_id: frame.request_id,
      status: "ok",
      payload: {},
    }))
    this.controller.enqueue(JSON.stringify({
      protocol: PROTOCOL,
      kind: "snapshot",
      session_id: "s1",
      snapshot_id: "snap",
      at_seq: 0,
      state: {
        status: "idle",
        run: null,
        messages: [],
        tools: [],
        approvals: [],
        questions: [],
        subagents: [],
        verification: [],
        usage: {},
        traces: [],
        indeterminate_effects: [],
        extensions: [],
      },
    }))
  }

  async close(): Promise<void> {
    this.controller.close()
  }
}

test("closing rejects correlated requests that are still pending", async () => {
  const transport = new PendingCommandTransport()
  const client = new ProtocolClient(transport)
  await client.connect()
  await Bun.sleep(0)
  expect(client.view?.session_id).toBe("s1")

  let rejection: unknown
  const pending = client.command("session.cancel", {}).catch((error) => {
    rejection = error
  })
  await Bun.sleep(0)

  await client.close()
  await pending

  expect(rejection).toBeInstanceOf(Error)
  expect((rejection as Error).message).toBe("transport_closed")
})
