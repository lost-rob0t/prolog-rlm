package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"charm.land/bubbles/v2/cursor"
	"charm.land/bubbles/v2/textarea"
	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

const (
	defaultAgentProlog = "agentprolog"
	defaultDeepSeekURL = "https://api.deepseek.com"
	defaultDeepSeekModel = "deepseek-v4-flash"
)

type agentResultMsg struct {
	output string
	err    error
}

type model struct {
	viewport viewport.Model
	textarea textarea.Model
	messages []string
	status   string
	model    string
	running  bool
}

func main() {
	if hasArg("--check") {
		fmt.Println("agentprolog-deepseek-tui: ready")
		return
	}

	if _, err := tea.NewProgram(initialModel()).Run(); err != nil {
		fmt.Fprintf(os.Stderr, "deepseek-harness: %v\n", err)
		os.Exit(1)
	}
}

func initialModel() model {
	ta := textarea.New()
	ta.Placeholder = "Ask AgentProlog…"
	ta.Prompt = "┃ "
	ta.CharLimit = 16000
	ta.SetWidth(80)
	ta.SetHeight(3)
	ta.SetVirtualCursor(false)
	ta.ShowLineNumbers = false
	ta.KeyMap.InsertNewline.SetEnabled(false)
	ta.Focus()

	styles := ta.Styles()
	styles.Focused.CursorLine = lipgloss.NewStyle()
	ta.SetStyles(styles)

	vp := viewport.New(
		viewport.WithWidth(80),
		viewport.WithHeight(20),
	)

	m := model{
		viewport: vp,
		textarea: ta,
		messages: []string{
			"AgentProlog DeepSeek Harness",
			"Bubble Tea UI; Prolog remains the authoritative runtime.",
		},
		status: "ready",
		model:  envOr("DEEPSEEK_MODEL", defaultDeepSeekModel),
	}
	m.refresh()
	return m
}

func (m model) Init() tea.Cmd {
	return textarea.Blink
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.resize(msg.Width, msg.Height)
		return m, nil

	case tea.KeyPressMsg:
		switch msg.String() {
		case "ctrl+c", "esc":
			return m, tea.Quit
		case "ctrl+l":
			m.messages = nil
			m.refresh()
			return m, nil
		case "enter":
			if m.running {
				return m, nil
			}

			prompt := strings.TrimSpace(m.textarea.Value())
			if prompt == "" {
				return m, nil
			}

			m.messages = append(m.messages, "you: "+prompt)
			m.textarea.Reset()
			m.running = true
			m.status = "running AgentProlog…"
			m.refresh()
			return m, runAgentProlog(prompt, m.model)
		}

	case agentResultMsg:
		m.running = false
		if msg.err != nil {
			m.messages = append(m.messages, "error: "+msg.err.Error())
			m.status = "request failed"
		} else {
			m.messages = append(m.messages, "agent: "+renderResult(msg.output))
			m.status = "ready"
		}
		m.refresh()
		return m, nil

	case cursor.BlinkMsg:
		var cmd tea.Cmd
		m.textarea, cmd = m.textarea.Update(msg)
		return m, cmd
	}

	var cmds []tea.Cmd
	if !m.running {
		var cmd tea.Cmd
		m.textarea, cmd = m.textarea.Update(msg)
		cmds = append(cmds, cmd)
	}

	var viewportCmd tea.Cmd
	m.viewport, viewportCmd = m.viewport.Update(msg)
	cmds = append(cmds, viewportCmd)
	return m, tea.Batch(cmds...)
}

func (m model) View() tea.View {
	header := fmt.Sprintf(
		"AgentProlog · DeepSeek · %s\n%s · %s\n\n",
		m.model,
		defaultDeepSeekURL,
		m.status,
	)
	viewportView := m.viewport.View()
	footer := "\nctrl+c quit · ctrl+l clear"

	v := tea.NewView(header + viewportView + "\n" + m.textarea.View() + footer)
	v.AltScreen = true

	if c := m.textarea.Cursor(); c != nil && !m.running {
		c.Y += lipgloss.Height(header + viewportView + "\n")
		v.Cursor = c
	}
	return v
}

func (m *model) resize(width, height int) {
	if width < 20 {
		width = 20
	}
	if height < 8 {
		height = 8
	}

	m.textarea.SetWidth(width)
	m.viewport.SetWidth(width)
	m.viewport.SetHeight(height - m.textarea.Height() - 5)
	m.refresh()
}

func (m *model) refresh() {
	content := strings.Join(m.messages, "\n\n")
	content = lipgloss.NewStyle().Width(m.viewport.Width()).Render(content)
	m.viewport.SetContent(content)
	m.viewport.GotoBottom()
}

func runAgentProlog(prompt, model string) tea.Cmd {
	return func() tea.Msg {
		agent := envOr("AGENTPROLOG_BIN", defaultAgentProlog)
		cmd := exec.Command(
			agent,
			"ask",
			prompt,
			"--provider",
			"deepseek",
			"--model",
			model,
			"--json",
		)
		output, err := cmd.CombinedOutput()
		text := strings.TrimSpace(string(output))
		if err != nil {
			if text == "" {
				return agentResultMsg{err: err}
			}
			return agentResultMsg{err: fmt.Errorf("%w: %s", err, text)}
		}
		return agentResultMsg{output: text}
	}
}

func renderResult(output string) string {
	if output == "" {
		return "<no output>"
	}

	lines := nonEmptyLines(output)
	if len(lines) == 0 {
		return "<no output>"
	}

	var value any
	if err := json.Unmarshal([]byte(lines[len(lines)-1]), &value); err != nil {
		return output
	}
	if text, ok := findText(value); ok {
		return text
	}

	pretty, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return output
	}
	return string(pretty)
}

func findText(value any) (string, bool) {
	switch value := value.(type) {
	case map[string]any:
		if text, ok := value["text"].(string); ok && strings.TrimSpace(text) != "" {
			return text, true
		}
		for _, child := range value {
			if text, ok := findText(child); ok {
				return text, true
			}
		}
	case []any:
		for _, child := range value {
			if text, ok := findText(child); ok {
				return text, true
			}
		}
	}
	return "", false
}

func nonEmptyLines(value string) []string {
	var lines []string
	for _, line := range strings.Split(value, "\n") {
		if strings.TrimSpace(line) != "" {
			lines = append(lines, line)
		}
	}
	return lines
}

func envOr(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func hasArg(want string) bool {
	for _, arg := range os.Args[1:] {
		if arg == want {
			return true
		}
	}
	return false
}
