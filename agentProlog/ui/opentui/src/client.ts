import {
  type CommandFrame,
  type ErrorFrame,
  type EventFrame,
  type JsonObject,
  type ResultFrame,
  type SnapshotFrame,
  type UiView,
  ProtocolError,
  applyEvent,
  applySnapshot,
  commandFrame,
  decodeFrame,
  encodeFrame,
  negotiateFrame,
  nextRequestId,
} from "./protocol.ts"
import type { NdjsonTransport } from "./transport.ts"

type Pending = {
  resolve: (frame: ResultFrame) => void
  reject: (error: Error) => void
}

type ViewListener = (view: UiView) => void
type ErrorListener = (error: Error) => void

export class ProtocolClient {
  private viewValue: UiView | undefined
  private readonly pending = new Map<string, Pending>()
  private readonly viewListeners = new Set<ViewListener>()
  private readonly errorListeners = new Set<ErrorListener>()
  private readLoop: Promise<void> | undefined
  private closed = false

  constructor(private readonly transport: NdjsonTransport) {}

  get view(): UiView | undefined {
    return this.viewValue
  }

  onView(listener: ViewListener): () => void {
    this.viewListeners.add(listener)
    if (this.viewValue) listener(this.viewValue)
    return () => this.viewListeners.delete(listener)
  }

  onError(listener: ErrorListener): () => void {
    this.errorListeners.add(listener)
    return () => this.errorListeners.delete(listener)
  }

  async connect(resumeFrom = 0): Promise<ResultFrame> {
    if (!this.readLoop) this.readLoop = this.consume()
    const requestId = nextRequestId("negotiate")
    return this.request(negotiateFrame(requestId, resumeFrom))
  }

  async command(command: string, payload: JsonObject): Promise<ResultFrame> {
    const view = this.viewValue
    if (!view) throw new ProtocolError("session_not_ready")
    const requestId = nextRequestId("command")
    return this.request(commandFrame(view.session_id, requestId, command, payload))
  }

  async close(): Promise<void> {
    if (this.closed) return
    this.closed = true
    this.failAll(new Error("transport_closed"))
    await this.transport.close()
    await this.readLoop
  }

  private async request(frame: CommandFrame | ReturnType<typeof negotiateFrame>): Promise<ResultFrame> {
    if (this.closed) throw new Error("client_closed")
    const promise = new Promise<ResultFrame>((resolve, reject) => {
      this.pending.set(frame.request_id, { resolve, reject })
    })
    try {
      await this.transport.send(encodeFrame(frame))
    } catch (error) {
      this.pending.delete(frame.request_id)
      throw error
    }
    return promise
  }

  private async consume(): Promise<void> {
    try {
      for await (const line of this.transport.lines) {
        const frame = decodeFrame(line)
        if (frame.kind === "snapshot") this.acceptSnapshot(frame)
        else if (frame.kind === "event") this.acceptEvent(frame)
        else if (frame.kind === "result") this.acceptResult(frame)
        else if (frame.kind === "error") this.acceptError(frame)
        else throw new ProtocolError("unexpected_server_frame", { kind: frame.kind })
      }
      if (!this.closed) {
        const error = new Error("transport_exited")
        this.emitError(error)
        this.failAll(error)
      }
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error(String(error))
      this.emitError(normalized)
      this.failAll(normalized)
    }
  }

  private acceptSnapshot(frame: SnapshotFrame): void {
    this.viewValue = applySnapshot(frame)
    this.emitView()
  }

  private acceptEvent(frame: EventFrame): void {
    if (!this.viewValue) throw new ProtocolError("event_before_snapshot", { seq: frame.seq })
    this.viewValue = applyEvent(this.viewValue, frame)
    this.emitView()
  }

  private acceptResult(frame: ResultFrame): void {
    const pending = this.pending.get(frame.request_id)
    if (!pending) return
    this.pending.delete(frame.request_id)
    pending.resolve(frame)
  }

  private acceptError(frame: ErrorFrame): void {
    const error = new ProtocolError(frame.code, frame.details)
    if (frame.request_id) {
      const pending = this.pending.get(frame.request_id)
      if (pending) {
        this.pending.delete(frame.request_id)
        pending.reject(error)
        return
      }
    }
    this.emitError(error)
  }

  private emitView(): void {
    if (!this.viewValue) return
    for (const listener of this.viewListeners) listener(this.viewValue)
  }

  private emitError(error: Error): void {
    for (const listener of this.errorListeners) listener(error)
  }

  private failAll(error: Error): void {
    for (const pending of this.pending.values()) pending.reject(error)
    this.pending.clear()
  }
}
