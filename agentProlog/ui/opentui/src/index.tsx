import { render } from "@opentui/solid"
import { ProtocolClient } from "./client.ts"
import { SwiplFixtureTransport } from "./transport.ts"
import { App } from "./app.tsx"

const transport = new SwiplFixtureTransport()
const client = new ProtocolClient(transport)

client.onError((error) => console.error(error))
await client.connect()

await render(() => <App client={client} />, {
  exitOnCtrlC: false,
  targetFps: 30,
})
