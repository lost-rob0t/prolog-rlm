from __future__ import annotations

import asyncio
import json
import os
import sys
from collections.abc import Iterable
from typing import Any

from textual.app import App, ComposeResult
from textual.widgets import Footer, Header, Input, RichLog, Static


DEFAULT_MODEL = "deepseek-v4-flash"
DEFAULT_AGENTPROLOG_BIN = "agentprolog"


class DeepSeekHarness(App[None]):
    """Thin Textual frontend for the AgentProlog CLI."""

    TITLE = "AgentProlog DeepSeek Harness"
    SUB_TITLE = "prolog-rlm runtime / DeepSeek profile"

    CSS = """
    Screen {
        layout: vertical;
    }

    #transcript {
        height: 1fr;
        border: solid $accent;
        padding: 0 1;
    }

    #status {
        height: 1;
        padding: 0 1;
    }

    #prompt {
        dock: bottom;
    }
    """

    BINDINGS = [
        ("ctrl+c", "quit", "Quit"),
        ("ctrl+l", "clear_log", "Clear"),
    ]

    def compose(self) -> ComposeResult:
        yield Header()
        yield RichLog(id="transcript", wrap=True, markup=True)
        yield Static(self._ready_status(), id="status")
        yield Input(
            placeholder="Ask AgentProlog…",
            id="prompt",
        )
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#prompt", Input).focus()
        self.query_one("#transcript", RichLog).write(
            "[bold]AgentProlog[/] is using the DeepSeek profile. "
            "The TUI is presentation only; Prolog remains authoritative."
        )

    def action_clear_log(self) -> None:
        self.query_one("#transcript", RichLog).clear()

    async def on_input_submitted(self, event: Input.Submitted) -> None:
        prompt = event.value.strip()
        if not prompt:
            return

        event.input.value = ""
        event.input.disabled = True
        log = self.query_one("#transcript", RichLog)
        status = self.query_one("#status", Static)
        log.write(f"[bold cyan]you[/]: {prompt}")
        status.update("running AgentProlog…")

        try:
            result = await run_agentprolog(prompt)
            if result.returncode == 0:
                log.write(f"[bold green]agent[/]: {render_result(result.stdout)}")
                status.update(self._ready_status())
            else:
                detail = result.stderr.strip() or result.stdout.strip()
                log.write(f"[bold red]error[/]: {detail or 'AgentProlog failed'}")
                status.update(f"failed with exit {result.returncode}")
        except FileNotFoundError:
            log.write(
                "[bold red]error[/]: agentprolog executable not found. "
                "Set AGENTPROLOG_BIN or run through the Nix app."
            )
            status.update("agentprolog executable missing")
        except Exception as exc:  # UI boundary: report, do not crash the session.
            log.write(f"[bold red]error[/]: {exc!s}")
            status.update("request failed")
        finally:
            event.input.disabled = False
            event.input.focus()

    @staticmethod
    def _ready_status() -> str:
        model = os.environ.get("DEEPSEEK_MODEL", DEFAULT_MODEL)
        return f"ready · {model} · https://api.deepseek.com"


class AgentResult:
    def __init__(self, returncode: int, stdout: str, stderr: str) -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


async def run_agentprolog(prompt: str) -> AgentResult:
    agent_bin = os.environ.get("AGENTPROLOG_BIN", DEFAULT_AGENTPROLOG_BIN)
    model = os.environ.get("DEEPSEEK_MODEL", DEFAULT_MODEL)
    argv = [
        agent_bin,
        "ask",
        prompt,
        "--provider",
        "deepseek",
        "--model",
        model,
        "--json",
    ]

    process = await asyncio.create_subprocess_exec(
        *argv,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await process.communicate()
    return AgentResult(
        process.returncode,
        stdout.decode("utf-8", errors="replace"),
        stderr.decode("utf-8", errors="replace"),
    )


def render_result(stdout: str) -> str:
    lines = [line for line in stdout.splitlines() if line.strip()]
    if not lines:
        return "<no output>"

    try:
        payload = json.loads(lines[-1])
    except json.JSONDecodeError:
        return stdout.strip()

    text = find_text(payload)
    if text:
        return text
    return json.dumps(payload, indent=2, sort_keys=True)


def find_text(value: Any) -> str | None:
    if isinstance(value, dict):
        text = value.get("text")
        if isinstance(text, str) and text.strip():
            return text
        for candidate in value.values():
            found = find_text(candidate)
            if found:
                return found
    elif isinstance(value, Iterable) and not isinstance(value, (str, bytes)):
        for candidate in value:
            found = find_text(candidate)
            if found:
                return found
    return None


def main() -> None:
    if "--check" in sys.argv[1:]:
        print("agentprolog-deepseek-tui: ready")
        return
    DeepSeekHarness().run()


if __name__ == "__main__":
    main()
