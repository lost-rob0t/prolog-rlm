package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"charm.land/bubbles/v2/cursor"
	"charm.land/bubbles/v2/textarea"
	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

const (
	defaultDeepSeekURL   = "https://api.deepseek.com"
	defaultDeepSeekModel = "deepseek-v4-flash"
	pollInterval         = 100 * time.Millisecond
)

type agentSubmitMsg struct {
	client *protocolClient
	err    error
}

type agentPollMsg struct {
	state    string
	terminal protocolFrame
	err      error
}

type agentCancelMsg struct {
	terminal protocolFrame
	err      error
}

type pollTickMsg struct{}

type model struct {
	viewport   viewport.Model
	textarea   textarea.Model
	messages   []string
	status     string
	model      string
	running    bool
	cancelling bool
	client     *protocolClient
}

func main() {
	if hasArg("--check") {
		fmt.Println("agentprolog-deepseek-tui: ready")
		return
	}

	final, err := tea.NewProgram(initialModel()).Run()
	if finalModel, ok := final.(model); ok && finalModel.client != nil {
		if closeErr := finalModel.client.close(); closeErr != nil && err == nil {
			err = closeErr
		}
	}
	if err != nil {
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
			"prolog_agent_ui_v1 frontend; Prolog remains the authoritative runtime.",
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
		case "ctrl+c":
			return m, tea.Quit
		case "esc":
			if m.running && !m.cancelling && m.client != nil {
				m.cancelling = true
				m.status = "cancelling AgentProlog…"
				m.refresh()
				return m, cancelAgent(m.client)
			}
			if !m.running {
				return m, tea.Quit
			}
			return m, nil
		case "ctrl+l":
			m.messages = nil
			m.refresh()
			return m, nil
		case "enter":
			if m.running || m.cancelling {
				return m, nil
			}

			prompt := strings.TrimSpace(m.textarea.Value())
			if prompt == "" {
				return m, nil
			}

			m.messages = append(m.messages, "you: "+prompt)
			m.textarea.Reset()
			m.running = true
			m.status = "submitting to AgentProlog…"
			m.refresh()
			return m, submitAgent(m.client, prompt, m.model)
		}

	case agentSubmitMsg:
		if msg.client != nil {
			m.client = msg.client
		}
		if msg.err != nil {
			m.running = false
			m.cancelling = false
			m.messages = append(m.messages, "error: "+msg.err.Error())
			m.status = "request failed"
			m.refresh()
			return m, nil
		}
		m.status = "running AgentProlog…"
		m.refresh()
		return m, pollAfter()

	case pollTickMsg:
		if !m.running || m.cancelling || m.client == nil {
			return m, nil
		}
		return m, pollAgent(m.client)

	case agentPollMsg:
		if !m.running || m.cancelling {
			return m, nil
		}
		if msg.err != nil {
			m.running = false
			m.messages = append(m.messages, "error: "+msg.err.Error())
			m.status = "request failed"
			m.refresh()
			return m, nil
		}
		switch msg.state {
		case "running":
			m.status = "running AgentProlog…"
			return m, pollAfter()
		case "completed":
			m.running = false
			m.messages = append(m.messages, "agent: "+renderProtocolFrame(msg.terminal))
			m.status = "ready"
		case "cancelled":
			m.running = false
			m.messages = append(m.messages, "agent: <cancelled>")
			m.status = "ready"
		case "idle":
			m.running = false
			m.messages = append(m.messages, "error: AgentProlog run disappeared")
			m.status = "request failed"
		}
		m.refresh()
		return m, nil

	case agentCancelMsg:
		m.running = false
		m.cancelling = false
		if msg.err != nil {
			m.messages = append(m.messages, "error: "+msg.err.Error())
			m.status = "cancel failed"
		} else {
			m.messages = append(m.messages, "agent: <cancelled>")
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
	if !m.running && !m.cancelling {
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
	footer := "\nctrl+c quit · ctrl+l clear · esc quit"
	if m.running {
		footer = "\nctrl+c quit · ctrl+l clear · esc cancel"
	}

	v := tea.NewView(header + viewportView + "\n" + m.textarea.View() + footer)
	v.AltScreen = true

	if c := m.textarea.Cursor(); c != nil && !m.running && !m.cancelling {
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

func submitAgent(client *protocolClient, prompt, model string) tea.Cmd {
	return func() tea.Msg {
		if client == nil {
			var err error
			client, err = newProtocolClient()
			if err != nil {
				return agentSubmitMsg{err: err}
			}
		}
		if err := client.submit(prompt, model); err != nil {
			return agentSubmitMsg{client: client, err: err}
		}
		return agentSubmitMsg{client: client}
	}
}

func pollAfter() tea.Cmd {
	return tea.Tick(pollInterval, func(time.Time) tea.Msg {
		return pollTickMsg{}
	})
}

func pollAgent(client *protocolClient) tea.Cmd {
	return func() tea.Msg {
		state, terminal, err := client.poll()
		return agentPollMsg{state: state, terminal: terminal, err: err}
	}
}

func cancelAgent(client *protocolClient) tea.Cmd {
	return func() tea.Msg {
		terminal, err := client.cancel()
		return agentCancelMsg{terminal: terminal, err: err}
	}
}

func renderProtocolFrame(frame protocolFrame) string {
	if frame == nil {
		return "<no output>"
	}
	if text, ok := findText(frame); ok {
		return text
	}
	pretty, err := json.MarshalIndent(frame, "", "  ")
	if err != nil {
		return "<unrenderable result>"
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
