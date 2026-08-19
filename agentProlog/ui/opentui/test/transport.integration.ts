import assert from "node:assert/strict"
import { ProtocolClient } from "../src/client.ts"
import { SwiplFixtureTransport } from "../src/transport.ts"

async function waitForSeq(client: ProtocolClient, seq: number, getError: () => Error | undefined): Promise<void> {
  const deadline = Date.now() + 3000
  while (client.view?.at_seq !== seq) {
    const error = getError()
    if (error) throw error
    if (Date.now() >= deadline) {
      throw new Error(`timed_out_waiting_for_seq(${seq}); actual=${client.view?.at_seq ?? "none"}`)
    }
    await Bun.sleep(5)
  }
}

assert.notEqual(Bun.which("swipl"), null, "swipl must be available")

const transport = new SwiplFixtureTransport()
const client = new ProtocolClient(transport)
let clientError: Error | undefined
client.onError((error) => { clientError = error })

try {
  const result = await client.connect()
  assert.equal(result.status, "ok")

  await waitForSeq(client, 24, () => clientError)
  assert.equal(client.view?.messages[0]?.text, "I will inspect the authority path.")
  assert.equal(client.view?.extensions.length, 1)

  const commandResult = await client.command("approval.decide", {
    approval_id: "approval_1",
    decision: "allow_once",
  })
  assert.equal(commandResult.status, "ok")

  await waitForSeq(client, 25, () => clientError)
  assert.equal(client.view?.approvals[0]?.decision, "allow_once")
  assert.equal(client.view?.at_seq, 25)
} finally {
  await client.close()
}
