import { For, Show, createMemo, createSignal, onCleanup, onMount } from "solid-js"
import { useKeyboard, useRenderer } from "@opentui/solid"
import type { ProtocolClient } from "./client.ts"
import type { JsonObject, JsonValue, UiView } from "./protocol.ts"

function short(value: JsonValue | undefined): string {
  if (value === undefined) return ""
  if (typeof value === "string") return value
  return JSON.stringify(value)
}

function pending(items: JsonObject[]): JsonObject | undefined {
  return items.find((item) => item.status === "pending")
}

function choiceAt(item: JsonObject | undefined, index: number): string | undefined {
  const choices = item?.choices
  return Array.isArray(choices) && typeof choices[index] === "string" ? choices[index] : undefined
}

export function App(props: { client: ProtocolClient }) {
  const renderer = useRenderer()
  const [view, setView] = createSignal<UiView | undefined>(props.client.view)
  const [error, setError] = createSignal<string | undefined>()
  const [commandStatus, setCommandStatus] = createSignal<string>("")

  onMount(() => {
    const offView = props.client.onView(setView)
    const offError = props.client.onError((cause) => setError(cause.message))
    onCleanup(() => {
      offView()
      offError()
    })
  })

  const approval = createMemo(() => pending(view()?.approvals ?? []))
  const question = createMemo(() => pending(view()?.questions ?? []))
  const task = createMemo(() => {
    const run = view()?.run
    if (!run || typeof run !== "object" || Array.isArray(run)) return ""
    return short((run as JsonObject).task)
  })

  async function send(command: string, payload: JsonObject) {
    try {
      setCommandStatus(`sending ${command}`)
      const result = await props.client.command(command, payload)
      setCommandStatus(`${command}: ${result.status}`)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause))
    }
  }

  useKeyboard((key) => {
    if (key.name === "escape" || key.name === "q") {
      void props.client.close().finally(() => renderer.destroy())
      return
    }
    if (key.name === "c") {
      void send("session.cancel", {})
      return
    }

    const currentApproval = approval()
    if (currentApproval) {
      const index = key.name === "1" ? 0 : key.name === "2" ? 1 : key.name === "3" ? 2 : -1
      if (index >= 0) {
        const decision = choiceAt(currentApproval, index)
        if (decision && typeof currentApproval.approval_id === "string") {
          void send("approval.decide", { approval_id: currentApproval.approval_id, decision })
        }
        return
      }
    }

    const currentQuestion = question()
    if (currentQuestion) {
      const index = key.name === "1" ? 0 : key.name === "2" ? 1 : -1
      if (index >= 0) {
        const answer = choiceAt(currentQuestion, index)
        if (answer && typeof currentQuestion.question_id === "string") {
          void send("question.answer", { question_id: currentQuestion.question_id, answer })
        }
      }
    }
  })

  return (
    <box flexDirection="column" width="100%" height="100%" padding={1} gap={1}>
      <box borderStyle="rounded" padding={1} flexDirection="column">
        <text>PrologAgent · prolog_agent_ui_v1</text>
        <text>{`task=${task() || "fixture session"}`}</text>
        <text>{`status=${short(view()?.status)} seq=${view()?.at_seq ?? 0} ${commandStatus()}`}</text>
        <Show when={error()}>{(message) => <text>{`ERROR ${message()}`}</text>}</Show>
      </box>

      <box flexDirection="row" gap={1} flexGrow={1}>
        <box borderStyle="rounded" padding={1} flexDirection="column" flexGrow={2}>
          <text>Conversation</text>
          <For each={view()?.messages ?? []}>
            {(message) => <text>{`${short(message.role)}: ${short(message.text)}`}</text>}
          </For>
        </box>

        <box borderStyle="rounded" padding={1} flexDirection="column" flexGrow={1}>
          <text>Activity</text>
          <For each={view()?.tools ?? []}>
            {(tool) => <text>{`tool ${short(tool.name)} · ${short(tool.status)}`}</text>}
          </For>
          <For each={view()?.subagents ?? []}>
            {(agent) => <text>{`subagent ${short(agent.id)} · ${short(agent.status)}`}</text>}
          </For>
          <For each={view()?.verification ?? []}>
            {(verification) => <text>{`verify ${short(verification)}`}</text>}
          </For>
        </box>
      </box>

      <Show when={approval()}>
        {(item) => (
          <box borderStyle="rounded" padding={1} flexDirection="column">
            <text>{`Approval ${short(item().approval_id)} · ${short(item().diff)}`}</text>
            <text>{`[1] ${choiceAt(item(), 0) ?? ""}  [2] ${choiceAt(item(), 1) ?? ""}  [3] ${choiceAt(item(), 2) ?? ""}`}</text>
          </box>
        )}
      </Show>

      <Show when={question()}>
        {(item) => (
          <box borderStyle="rounded" padding={1} flexDirection="column">
            <text>{`Question: ${short(item().prompt)}`}</text>
            <text>{`[1] ${choiceAt(item(), 0) ?? ""}  [2] ${choiceAt(item(), 1) ?? ""}`}</text>
          </box>
        )}
      </Show>

      <box borderStyle="rounded" padding={1} flexDirection="column">
        <text>{`usage ${short(view()?.usage)} · effects=${view()?.indeterminate_effects.length ?? 0} · traces=${view()?.traces.length ?? 0} · extensions=${view()?.extensions.length ?? 0}`}</text>
        <Show when={view()?.indeterminate_effects.at(-1)}>
          {(effect) => <text>{`indeterminate ${short(effect())}`}</text>}
        </Show>
        <Show when={view()?.traces.at(-1)}>
          {(trace) => <text>{`trace ${short(trace())}`}</text>}
        </Show>
        <For each={(view()?.extensions ?? []).slice(-3)}>
          {(extension) => <text>{`extension ${short(extension)}`}</text>}
        </For>
        <text>q/esc quit · c cancel · numbered choices answer active approval/question</text>
      </box>
    </box>
  )
}
