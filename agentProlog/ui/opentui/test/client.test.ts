import { expect, test } from "bun:test"
import { ProtocolClient } from "../src/client.ts"
import { type NdjsonTransport, SwiplFixtureTransport } from "../src/transport.ts"
import { type ClientFrame, PROTOCOL } from "../src/protocol.ts"

class MemoryTransport implements NdjsonTransport {
  private controller!: ReadableStreamDefaultController<string>
  private readonly stream = new ReadableStream<string>({ start: (controller) => { this.controller = controller } })
  readonly sent: ClientFrame[] = []
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
    this.sent.push(frame)
    if (frame.kind === "negotiate") {
      this.controller.enqueue(JSON.stringify({ protocol: PROTOCOL, kind: "result", session_id: "s1", request_id: frame.request_id, status: "ok", payload: {} }))
      this.controller.enqueue(JSON.stringify({
        protocol: PROTOCOL, kind: "snapshot", session_id: "s1", snapshot_id: "snap", at_seq: 0,
        state: { status: "idle", run: null, messages: [], tools: [], approvals: [], questions: [], subagents: [], verification: [], usage: {}, traces: [], indeterminate_effects: [], extensions: [] },
      }))
    } else {
      this.controller.enqueue(JSON.stringify({ protocol: PROTOCOL, kind: "result", session_id: "s1", request_id: frame.request_id, status: "ok", payload: { accepted: true } }))
      this.controller.enqueue(JSON.stringify({ protocol: PROTOCOL, kind: "event", session_id: "s1", seq: 1, event_id: "e1", event_type: "trace", payload: { caused: frame.command }, caused_by: frame.request_id }))
    }
  }

  async close(): Promise<void> {
    this.controller.close()
  }
}

test("correlates commands independently from event sequence", async () => {
  const transport = new MemoryTransport()
  const client = new ProtocolClient(transport)
  await client.connect()
  await Bun.sleep(0)
  expect(client.view?.session_id).toBe("s1")
  const result = await client.command("session.cancel", {})
  expect(result.status).toBe("ok")
  await Bun.sleep(0)
  expect(client.view?.at_seq).toBe(1)
  const command = transport.sent.find((frame) => frame.kind === "command")
  expect(command && "request_id" in command ? command.request_id : undefined).toBeDefined()
  expect(command && "seq" in command).toBe(false)
  await client.close()
})

test("spawns the real SWI fixture, replays, and issues a correlated command", async () => {
  expect(Bun.which("swipl")).not.toBeNull()
  const transport = new SwiplFixtureTransport()
  const client = new ProtocolClient(transport)
  const result = await client.connect()
  expect(result.status).toBe("ok")

  for (let attempt = 0; attempt < 100 && client.view?.at_seq !== 24; attempt++) await Bun.sleep(5)
  expect(client.view?.at_seq).toBe(24)
  expect(client.view?.messages[0]?.text).toBe("I will inspect the authority path.")
  expect(client.view?.extensions).toHaveLength(1)

  const commandResult = await client.command("approval.decide", {
    approval_id: "approval_1",
    decision: "allow_once",
  })
  expect(commandResult.status).toBe("ok")
  for (let attempt = 0; attempt < 100 && client.view?.at_seq !== 25; attempt++) await Bun.sleep(5)
  expect(client.view?.at_seq).toBe(25)
  expect(client.view?.approvals[0]?.decision).toBe("allow_once")

  await client.close()
})
