import { describe, expect, test } from "bun:test"
import { readFile } from "node:fs/promises"
import { resolve } from "node:path"
import { fileURLToPath } from "node:url"
import {
  ProtocolError,
  applyEvent,
  applySnapshot,
  decodeFrame,
  initialView,
  replay,
  type EventFrame,
  type SnapshotFrame,
} from "../src/protocol.ts"

const repoRoot = resolve(fileURLToPath(new URL("../../../../", import.meta.url)))

async function golden(): Promise<[SnapshotFrame, EventFrame[]]> {
  const text = await readFile(resolve(repoRoot, "agentProlog/fixtures/prolog_agent_ui_v1_session.ndjson"), "utf8")
  const frames = text.trim().split("\n").map(decodeFrame)
  const snapshot = frames[0]
  if (!snapshot || snapshot.kind !== "snapshot") throw new Error("golden fixture missing snapshot")
  const events = frames.slice(1)
  if (!events.every((frame) => frame.kind === "event")) throw new Error("golden fixture contains non-event")
  return [snapshot, events as EventFrame[]]
}

describe("prolog_agent_ui_v1 presentation reducer", () => {
  test("replays the canonical golden coding session", async () => {
    const [snapshot, events] = await golden()
    const view = replay(snapshot, events)
    expect(view.at_seq).toBe(24)
    expect(view.status).toBe("finished")
    expect(view.messages[0]?.text).toBe("I will inspect the authority path.")
    expect(view.tools).toHaveLength(3)
    expect(view.tools.find((tool) => tool.name === "mystery_linter")?.status).toBe("finished")
    expect(view.approvals[0]?.status).toBe("resolved")
    expect(view.questions[0]?.status).toBe("answered")
    expect(view.verification).toHaveLength(1)
    expect(view.indeterminate_effects).toHaveLength(1)
    expect(view.extensions).toHaveLength(1)
    expect((view.run as Record<string, unknown>).run_id).toBe("run_fixture_1")
    expect((view.run as Record<string, unknown>).outcome).toBeDefined()
  })

  test("deduplicates overlap and rejects sequence gaps", () => {
    const view = initialView("s1")
    const snapshot: SnapshotFrame = {
      protocol: "prolog_agent_ui_v1",
      kind: "snapshot",
      session_id: "s1",
      snapshot_id: "snap",
      at_seq: 0,
      state: {
        status: "idle", run: null, messages: [], tools: [], approvals: [], questions: [], subagents: [],
        verification: [], usage: {}, traces: [], indeterminate_effects: [], extensions: [],
      },
    }
    const base = applySnapshot(snapshot)
    expect(view.session_id).toBe(base.session_id)
    const event: EventFrame = {
      protocol: "prolog_agent_ui_v1", kind: "event", session_id: "s1", seq: 1, event_id: "e1",
      event_type: "trace", payload: { marker: 1 },
    }
    const once = applyEvent(base, event)
    expect(applyEvent(once, event)).toEqual(once)
    expect(() => applyEvent(base, { ...event, seq: 2, event_id: "e2" })).toThrow(ProtocolError)
  })

  test("fails closed on required unknown extensions", () => {
    const line = JSON.stringify({
      protocol: "prolog_agent_ui_v1", kind: "event", session_id: "s1", seq: 1, event_id: "e1",
      event_type: "future_authority", payload: {}, extension: { namespace: "future.required", required: true },
    })
    expect(() => decodeFrame(line)).toThrow(ProtocolError)
  })

  test("counts snapshot size as UTF-8 bytes", () => {
    const huge = "💀".repeat(300_000)
    const line = JSON.stringify({
      protocol: "prolog_agent_ui_v1", kind: "snapshot", session_id: "s1", snapshot_id: "snap", at_seq: 0,
      state: {
        status: "idle", run: null, messages: [{ id: "m1", text: huge }], tools: [], approvals: [], questions: [],
        subagents: [], verification: [], usage: {}, traces: [], indeterminate_effects: [], extensions: [],
      },
    })
    expect(() => decodeFrame(line)).toThrow(ProtocolError)
  })
})
