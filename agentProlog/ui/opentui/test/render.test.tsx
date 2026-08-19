import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import type { ProtocolClient } from "../src/client.ts"
import { App } from "../src/app.tsx"
import { initialView } from "../src/protocol.ts"

class StubClient {
  view = initialView("render_session")
  onView(listener: (view: ReturnType<typeof initialView>) => void) { listener(this.view); return () => {} }
  onError(_listener: (error: Error) => void) { return () => {} }
  async command() { return { protocol: "prolog_agent_ui_v1", kind: "result", session_id: "render_session", request_id: "r1", status: "ok", payload: {} } as const }
  async close() {}
}

test("renders without a real terminal", async () => {
  const setup = await testRender(() => <App client={new StubClient() as unknown as ProtocolClient} />, { width: 100, height: 30 })
  expect(setup).toBeDefined()
  setup.renderer.destroy()
})
