import { randomUUID } from 'node:crypto'

export const name = 'prolog-headless-runner'
export const inject = ['agents']

const userMessage = (task) => Object.freeze({
  id: `prolog-rlm:user:${randomUUID()}`,
  role: 'user',
  content: Object.freeze([Object.freeze({ type: 'text', text: task })]),
  source: Object.freeze({ kind: 'user' }),
})

const summarize = (events, firstSeq) => {
  let started = false
  let text = ''
  let reason

  for (const event of events) {
    if (event.seq < firstSeq) continue
    if (event.type === 'turn/start') {
      started = true
      continue
    }
    if (!started) continue
    if (event.type === 'assistant/message') {
      const blocks = event.data?.message?.content
      if (Array.isArray(blocks)) {
        const joined = blocks
          .filter((block) => block?.type === 'text' && typeof block.text === 'string')
          .map((block) => block.text)
          .join('')
        if (joined !== '') text = joined
      }
    }
    if (event.type === 'turn/end') reason = event.data?.reason
  }

  return { text, reason }
}

const fail = (io, error) => {
  io.stderr.write(`agentProlog: ${error instanceof Error ? error.message : String(error)}\n`)
  io.exit(1)
}

const run = async (ctx, task, io) => {
  await ctx.get('loader')?.await()
  const agents = ctx.get('agents')
  if (agents === undefined) throw new Error('DeepSeek Harness agent registry is unavailable')

  const { agent } = await agents.create({
    sessionId: `session-${randomUUID()}`,
    meta: { cwd: process.cwd() },
    agentOptions: {},
  })

  await agent.whenIdle()
  const firstSeq = agent.session.seq
  agent.followup(userMessage(task))
  await agent.whenIdle()

  const outcome = summarize(agent.session.events, firstSeq)
  io.stdout.write(`${outcome.text}\n`)
  if (outcome.reason?.kind === 'error') {
    const detail = outcome.reason.error
    io.stderr.write(`agentProlog: ${detail?.code ?? 'AGENT_ERROR'}: ${detail?.message ?? 'agent turn failed'}\n`)
  }
  io.exit(outcome.reason?.kind === 'completed' ? 0 : 1)
}

export default function prologHeadlessRunner(ctx, config = {}) {
  const task = config.task
  if (typeof task !== 'string' || task.length === 0) {
    throw new Error('prolog-headless-runner requires a non-empty task')
  }
  const exit = ctx.get('appExit')
  if (exit === undefined) {
    throw new Error('prolog-headless-runner requires the DeepSeek Harness appExit service')
  }
  const io = { stdout: process.stdout, stderr: process.stderr, exit }
  void run(ctx, task, io).catch((error) => fail(io, error))
}
