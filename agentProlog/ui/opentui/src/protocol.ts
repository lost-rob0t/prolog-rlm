export const PROTOCOL = "prolog_agent_ui_v1" as const
export const SNAPSHOT_MAX_BYTES = 1_048_576
export const COLLECTION_MAX_ITEMS = 256

type JsonPrimitive = string | number | boolean | null
export type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue }
export type JsonObject = { [key: string]: JsonValue }

export type Extension = JsonObject & {
  namespace: string
  required: boolean
}

export type NegotiateFrame = {
  protocol: typeof PROTOCOL
  kind: "negotiate"
  request_id: string
  payload: {
    protocol_versions: string[]
    required_capabilities?: string[]
    optional_capabilities?: string[]
    resume_from?: number
  }
}

export type SnapshotState = {
  status: JsonValue
  run: JsonValue
  messages: JsonObject[]
  tools: JsonObject[]
  approvals: JsonObject[]
  questions: JsonObject[]
  subagents: JsonObject[]
  verification: JsonValue[]
  usage: JsonObject
  traces: JsonValue[]
  indeterminate_effects: JsonValue[]
  extensions: JsonValue[]
}

export type SnapshotFrame = {
  protocol: typeof PROTOCOL
  kind: "snapshot"
  session_id: string
  snapshot_id: string
  at_seq: number
  state: SnapshotState
}

export type EventFrame = {
  protocol: typeof PROTOCOL
  kind: "event"
  session_id: string
  seq: number
  event_id: string
  event_type: string
  payload: JsonObject
  caused_by?: string
  extension?: Extension
}

export type CommandFrame = {
  protocol: typeof PROTOCOL
  kind: "command"
  session_id: string
  request_id: string
  command: string
  payload: JsonObject
}

export type ResultFrame = {
  protocol: typeof PROTOCOL
  kind: "result"
  session_id: string
  request_id: string
  status: "ok" | "rejected"
  payload: JsonObject
}

export type ErrorFrame = {
  protocol: typeof PROTOCOL
  kind: "error"
  session_id: string
  request_id?: string
  code: string
  message: string
  details: JsonObject
}

export type ServerFrame = SnapshotFrame | EventFrame | ResultFrame | ErrorFrame
export type ClientFrame = NegotiateFrame | CommandFrame
export type Frame = ServerFrame | ClientFrame

export type UiView = {
  protocol: typeof PROTOCOL
  session_id: string
  at_seq: number
  status: JsonValue
  run: JsonValue
  messages: JsonObject[]
  tools: JsonObject[]
  approvals: JsonObject[]
  questions: JsonObject[]
  subagents: JsonObject[]
  verification: JsonValue[]
  usage: JsonObject
  traces: JsonValue[]
  indeterminate_effects: JsonValue[]
  extensions: JsonValue[]
}

const knownEventTypes = new Set([
  "run_started",
  "message_started",
  "text_delta",
  "message_completed",
  "tool_started",
  "tool_output",
  "tool_finished",
  "approval_required",
  "approval_resolved",
  "question_required",
  "question_answered",
  "subagent_started",
  "subagent_finished",
  "verification",
  "usage",
  "trace",
  "effect_indeterminate",
  "run_finished",
])

export class ProtocolError extends Error {
  readonly code: string
  readonly details: JsonObject

  constructor(code: string, details: JsonObject = {}) {
    super(`Invalid ${PROTOCOL} record: ${code}`)
    this.name = "ProtocolError"
    this.code = code
    this.details = details
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function object(value: unknown, field = "frame"): Record<string, unknown> {
  if (!isObject(value)) throw new ProtocolError("expected_object", { field })
  return value
}

function stringField(value: Record<string, unknown>, key: string): string {
  const field = value[key]
  if (typeof field !== "string") throw new ProtocolError("invalid_string_field", { field: key })
  return field
}

function idField(value: Record<string, unknown>, key: string): string {
  const field = stringField(value, key)
  if (field.length === 0 || field.length > 200) throw new ProtocolError("invalid_id", { field: key })
  return field
}

function integerField(value: Record<string, unknown>, key: string, minimum: number): number {
  const field = value[key]
  if (!Number.isInteger(field) || (field as number) < minimum) {
    throw new ProtocolError("invalid_integer_field", { field: key })
  }
  return field as number
}

function arrayField(value: Record<string, unknown>, key: string): unknown[] {
  const field = value[key]
  if (!Array.isArray(field)) throw new ProtocolError("invalid_list_field", { field: key })
  return field
}

function stringArray(value: unknown, field: string): string[] {
  if (!Array.isArray(value) || !value.every((item) => typeof item === "string")) {
    throw new ProtocolError("expected_string_list", { field })
  }
  return value
}

function jsonObject(value: unknown, field: string): JsonObject {
  if (!isObject(value)) throw new ProtocolError("invalid_object_field", { field })
  return value as JsonObject
}

function assertBounded(value: unknown): void {
  if (Array.isArray(value)) {
    if (value.length > COLLECTION_MAX_ITEMS) {
      throw new ProtocolError("snapshot_collection_too_large", {
        items: value.length,
        max_items: COLLECTION_MAX_ITEMS,
      })
    }
    for (const item of value) assertBounded(item)
    return
  }
  if (isObject(value)) {
    for (const item of Object.values(value)) assertBounded(item)
  }
}

function snapshotState(value: unknown): SnapshotState {
  const state = object(value, "state")
  assertBounded(state)
  const bytes = new TextEncoder().encode(JSON.stringify(state)).byteLength
  if (bytes > SNAPSHOT_MAX_BYTES) {
    throw new ProtocolError("snapshot_too_large", { bytes, max_bytes: SNAPSHOT_MAX_BYTES })
  }

  const messages = arrayField(state, "messages").map((item) => jsonObject(item, "messages"))
  const tools = arrayField(state, "tools").map((item) => jsonObject(item, "tools"))
  const approvals = arrayField(state, "approvals").map((item) => jsonObject(item, "approvals"))
  const questions = arrayField(state, "questions").map((item) => jsonObject(item, "questions"))
  const subagents = arrayField(state, "subagents").map((item) => jsonObject(item, "subagents"))

  if (!("status" in state)) throw new ProtocolError("invalid_snapshot_state", { missing: "status" })
  if (!("run" in state)) throw new ProtocolError("invalid_snapshot_state", { missing: "run" })

  return {
    status: state.status as JsonValue,
    run: state.run as JsonValue,
    messages,
    tools,
    approvals,
    questions,
    subagents,
    verification: arrayField(state, "verification") as JsonValue[],
    usage: jsonObject(state.usage, "usage"),
    traces: arrayField(state, "traces") as JsonValue[],
    indeterminate_effects: arrayField(state, "indeterminate_effects") as JsonValue[],
    extensions: arrayField(state, "extensions") as JsonValue[],
  }
}

export function decodeFrame(line: string): Frame {
  let parsed: unknown
  try {
    parsed = JSON.parse(line)
  } catch {
    throw new ProtocolError("ndjson_codec_error", { direction: "decode" })
  }
  return validateFrame(parsed)
}

export function encodeFrame(frame: ClientFrame): string {
  validateFrame(frame)
  return JSON.stringify(frame)
}

export function validateFrame(input: unknown): Frame {
  const frame = object(input)
  if (frame.protocol !== PROTOCOL) throw new ProtocolError("invalid_field", { field: "protocol" })
  const kind = stringField(frame, "kind")

  if (kind === "negotiate") {
    const requestId = idField(frame, "request_id")
    const payload = object(frame.payload, "payload")
    const versions = stringArray(payload.protocol_versions, "protocol_versions")
    if (!versions.includes(PROTOCOL)) throw new ProtocolError("protocol_version_not_offered")
    const required = payload.required_capabilities === undefined ? [] : stringArray(payload.required_capabilities, "required_capabilities")
    const optional = payload.optional_capabilities === undefined ? [] : stringArray(payload.optional_capabilities, "optional_capabilities")
    const resume = payload.resume_from === undefined ? undefined : integerField(payload, "resume_from", 0)
    return {
      protocol: PROTOCOL,
      kind,
      request_id: requestId,
      payload: {
        protocol_versions: versions,
        required_capabilities: required,
        optional_capabilities: optional,
        ...(resume === undefined ? {} : { resume_from: resume }),
      },
    }
  }

  if (kind === "snapshot") {
    return {
      protocol: PROTOCOL,
      kind,
      session_id: idField(frame, "session_id"),
      snapshot_id: idField(frame, "snapshot_id"),
      at_seq: integerField(frame, "at_seq", 0),
      state: snapshotState(frame.state),
    }
  }

  if (kind === "event") {
    const eventType = stringField(frame, "event_type")
    let extension: Extension | undefined
    if (!knownEventTypes.has(eventType)) {
      const raw = object(frame.extension, "extension")
      const namespace = stringField(raw, "namespace")
      if (typeof raw.required !== "boolean") throw new ProtocolError("invalid_extension", { event_type: eventType })
      if (raw.required) throw new ProtocolError("unsupported_required_extension", { event_type: eventType, namespace })
      extension = { namespace, required: false }
    } else if (frame.extension !== undefined) {
      const raw = object(frame.extension, "extension")
      if (typeof raw.required !== "boolean") throw new ProtocolError("invalid_extension", { event_type: eventType })
      extension = { namespace: stringField(raw, "namespace"), required: raw.required }
    }
    const causedBy = frame.caused_by === undefined ? undefined : idField(frame, "caused_by")
    return {
      protocol: PROTOCOL,
      kind,
      session_id: idField(frame, "session_id"),
      seq: integerField(frame, "seq", 1),
      event_id: idField(frame, "event_id"),
      event_type: eventType,
      payload: jsonObject(frame.payload, "payload"),
      ...(causedBy === undefined ? {} : { caused_by: causedBy }),
      ...(extension === undefined ? {} : { extension }),
    }
  }

  if (kind === "command") {
    return {
      protocol: PROTOCOL,
      kind,
      session_id: idField(frame, "session_id"),
      request_id: idField(frame, "request_id"),
      command: stringField(frame, "command"),
      payload: jsonObject(frame.payload, "payload"),
    }
  }

  if (kind === "result") {
    const status = stringField(frame, "status")
    if (status !== "ok" && status !== "rejected") {
      throw new ProtocolError("invalid_result_status", { status })
    }
    return {
      protocol: PROTOCOL,
      kind,
      session_id: idField(frame, "session_id"),
      request_id: idField(frame, "request_id"),
      status,
      payload: jsonObject(frame.payload, "payload"),
    }
  }

  if (kind === "error") {
    const requestId = frame.request_id === undefined ? undefined : idField(frame, "request_id")
    return {
      protocol: PROTOCOL,
      kind,
      session_id: idField(frame, "session_id"),
      ...(requestId === undefined ? {} : { request_id: requestId }),
      code: stringField(frame, "code"),
      message: stringField(frame, "message"),
      details: jsonObject(frame.details, "details"),
    }
  }

  throw new ProtocolError("unknown_frame_kind", { kind })
}

export function initialView(sessionId: string): UiView {
  return {
    protocol: PROTOCOL,
    session_id: sessionId,
    at_seq: 0,
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
  }
}

export function applySnapshot(frame: SnapshotFrame): UiView {
  return {
    protocol: PROTOCOL,
    session_id: frame.session_id,
    at_seq: frame.at_seq,
    ...frame.state,
  }
}

function id(value: JsonObject, key: string): string {
  const found = value[key]
  if (typeof found !== "string" || found.length === 0) throw new ProtocolError("replay_missing_id", { field: key })
  return found
}

function field(value: JsonObject, key: string): JsonValue {
  if (!(key in value)) throw new ProtocolError("replay_missing_field", { field: key })
  return value[key]!
}

function updateById(items: JsonObject[], itemId: string, fields: JsonObject): JsonObject[] {
  const index = items.findIndex((item) => item.id === itemId)
  if (index < 0) throw new ProtocolError("replay_missing_entity", { id: itemId })
  const next = items.slice()
  next[index] = { ...next[index], ...fields }
  return next
}

function upsertById(items: JsonObject[], item: JsonObject): JsonObject[] {
  const itemId = item.id
  if (typeof itemId !== "string") throw new ProtocolError("replay_missing_id", { field: "id" })
  const index = items.findIndex((candidate) => candidate.id === itemId)
  if (index < 0) return [...items, item]
  const next = items.slice()
  next[index] = item
  return next
}

function appendBounded<T>(items: T[], item: T): T[] {
  const next = [...items, item]
  return next.length <= COLLECTION_MAX_ITEMS ? next : next.slice(next.length - COLLECTION_MAX_ITEMS)
}

export function applyEvent(view: UiView, frame: EventFrame): UiView {
  if (view.session_id !== frame.session_id) {
    throw new ProtocolError("session_mismatch", { expected: view.session_id, actual: frame.session_id })
  }
  if (frame.seq <= view.at_seq) return view
  const expected = view.at_seq + 1
  if (frame.seq !== expected) throw new ProtocolError("sequence_gap", { expected, actual: frame.seq })

  const payload = frame.payload
  let next: UiView = view

  switch (frame.event_type) {
    case "run_started":
      next = { ...view, status: "running", run: payload }
      break
    case "message_started": {
      const messageId = id(payload, "message_id")
      const role = field(payload, "role")
      next = { ...view, messages: upsertById(view.messages, { id: messageId, role, text: "", status: "streaming" }) }
      break
    }
    case "text_delta": {
      const messageId = id(payload, "message_id")
      const delta = field(payload, "delta")
      if (typeof delta !== "string") throw new ProtocolError("invalid_string_field", { field: "delta" })
      const current = view.messages.find((item) => item.id === messageId)
      if (!current) throw new ProtocolError("replay_missing_entity", { id: messageId })
      const text = typeof current.text === "string" ? current.text : ""
      next = { ...view, messages: updateById(view.messages, messageId, { text: text + delta }) }
      break
    }
    case "message_completed": {
      const messageId = id(payload, "message_id")
      next = { ...view, messages: updateById(view.messages, messageId, { status: "complete" }) }
      break
    }
    case "tool_started": {
      const toolId = id(payload, "tool_id")
      next = { ...view, tools: upsertById(view.tools, { ...payload, id: toolId, status: "running" }) }
      break
    }
    case "tool_output": {
      const toolId = id(payload, "tool_id")
      next = { ...view, tools: updateById(view.tools, toolId, { output: field(payload, "output") }) }
      break
    }
    case "tool_finished": {
      const toolId = id(payload, "tool_id")
      next = { ...view, tools: updateById(view.tools, toolId, { status: "finished", outcome: field(payload, "outcome") }) }
      break
    }
    case "approval_required": {
      const approvalId = id(payload, "approval_id")
      next = { ...view, approvals: upsertById(view.approvals, { ...payload, id: approvalId, status: "pending" }) }
      break
    }
    case "approval_resolved": {
      const approvalId = id(payload, "approval_id")
      next = { ...view, approvals: updateById(view.approvals, approvalId, { ...payload, status: "resolved" }) }
      break
    }
    case "question_required": {
      const questionId = id(payload, "question_id")
      next = { ...view, questions: upsertById(view.questions, { ...payload, id: questionId, status: "pending" }) }
      break
    }
    case "question_answered": {
      const questionId = id(payload, "question_id")
      next = { ...view, questions: updateById(view.questions, questionId, { ...payload, status: "answered" }) }
      break
    }
    case "subagent_started": {
      const subagentId = id(payload, "subagent_id")
      next = { ...view, subagents: upsertById(view.subagents, { ...payload, id: subagentId, status: "running" }) }
      break
    }
    case "subagent_finished": {
      const subagentId = id(payload, "subagent_id")
      next = { ...view, subagents: updateById(view.subagents, subagentId, { ...payload, status: "finished" }) }
      break
    }
    case "verification":
      next = { ...view, verification: appendBounded(view.verification, payload) }
      break
    case "usage":
      next = { ...view, usage: payload }
      break
    case "trace":
      next = { ...view, traces: appendBounded(view.traces, payload) }
      break
    case "effect_indeterminate":
      next = { ...view, indeterminate_effects: appendBounded(view.indeterminate_effects, payload) }
      break
    case "run_finished": {
      const run = isObject(view.run) ? { ...(view.run as JsonObject), ...payload } : payload
      next = { ...view, status: "finished", run }
      break
    }
    default: {
      if (!frame.extension || frame.extension.required) {
        throw new ProtocolError("unsupported_required_extension", { event_type: frame.event_type })
      }
      next = {
        ...view,
        extensions: appendBounded(view.extensions, {
          event_type: frame.event_type,
          extension: frame.extension,
          payload,
        }),
      }
      break
    }
  }

  return { ...next, at_seq: frame.seq }
}

export function replay(snapshot: SnapshotFrame, events: EventFrame[]): UiView {
  return events.reduce(applyEvent, applySnapshot(snapshot))
}

let requestCounter = 0
export function nextRequestId(prefix = "req"): string {
  requestCounter += 1
  return `${prefix}_${Date.now().toString(36)}_${requestCounter.toString(36)}`
}

export function negotiateFrame(requestId: string, resumeFrom = 0): NegotiateFrame {
  return {
    protocol: PROTOCOL,
    kind: "negotiate",
    request_id: requestId,
    payload: {
      protocol_versions: [PROTOCOL],
      required_capabilities: ["streaming_text", "generic_tools"],
      optional_capabilities: ["approvals", "questions", "subagents", "verification", "usage", "traces", "indeterminate_effects", "optional_extensions"],
      resume_from: resumeFrom,
    },
  }
}

export function commandFrame(sessionId: string, requestId: string, command: string, payload: JsonObject): CommandFrame {
  return { protocol: PROTOCOL, kind: "command", session_id: sessionId, request_id: requestId, command, payload }
}
