package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
)

const (
	protocolVersion        = "prolog_agent_ui_v1"
	defaultAgentPrologUI   = "agentprolog-ui"
)

type protocolFrame map[string]any

type protocolClient struct {
	cmd       *exec.Cmd
	stdin     io.WriteCloser
	scanner   *bufio.Scanner
	stderr    bytes.Buffer
	sessionID string
	nextReq   int
	mu        sync.Mutex
}

func newProtocolClient() (*protocolClient, error) {
	binary := envOr("AGENTPROLOG_UI_BIN", defaultAgentPrologUI)
	cmd := exec.Command(binary)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("agentprolog-ui stdin: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return nil, fmt.Errorf("agentprolog-ui stdout: %w", err)
	}

	client := &protocolClient{
		cmd:     cmd,
		stdin:   stdin,
		scanner: bufio.NewScanner(stdout),
		nextReq: 1,
	}
	client.scanner.Buffer(make([]byte, 64*1024), 2*1024*1024)
	cmd.Stderr = &client.stderr

	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		return nil, fmt.Errorf("start agentprolog-ui: %w", err)
	}
	if err := client.negotiate(); err != nil {
		_ = client.close()
		return nil, err
	}
	return client, nil
}

func (c *protocolClient) negotiate() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	requestID := c.requestIDLocked()
	frame := protocolFrame{
		"protocol":   protocolVersion,
		"kind":       "negotiate",
		"request_id": requestID,
		"payload": protocolFrame{
			"protocol_versions":     []string{protocolVersion},
			"required_capabilities": []string{},
			"optional_capabilities": []string{"mouse"},
		},
	}
	if err := c.writeFrameLocked(frame); err != nil {
		return err
	}

	result, err := c.readFrameLocked()
	if err != nil {
		return err
	}
	if err := requireResult(result, requestID); err != nil {
		return err
	}
	if sessionID, ok := result["session_id"].(string); ok && sessionID != "" {
		c.sessionID = sessionID
	} else {
		return fmt.Errorf("negotiate result missing session_id")
	}

	snapshot, err := c.readFrameLocked()
	if err != nil {
		return err
	}
	if snapshot["kind"] != "snapshot" {
		return fmt.Errorf("negotiate expected snapshot, got %v", snapshot["kind"])
	}
	return nil
}

func (c *protocolClient) submit(query, model string) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	requestID := c.requestIDLocked()
	frame := c.commandFrame(requestID, "run.submit", protocolFrame{
		"query":    query,
		"provider": "deepseek",
		"model":    model,
	})
	if err := c.writeFrameLocked(frame); err != nil {
		return err
	}

	result, err := c.readFrameLocked()
	if err != nil {
		return err
	}
	if err := requireResult(result, requestID); err != nil {
		return err
	}
	started, err := c.readFrameLocked()
	if err != nil {
		return err
	}
	if started["event_type"] != "run_started" {
		return fmt.Errorf("submit expected run_started, got %v", started["event_type"])
	}
	return nil
}

func (c *protocolClient) poll() (string, protocolFrame, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	requestID := c.requestIDLocked()
	if err := c.writeFrameLocked(c.commandFrame(requestID, "session.poll", protocolFrame{})); err != nil {
		return "", nil, err
	}
	result, err := c.readFrameLocked()
	if err != nil {
		return "", nil, err
	}
	if err := requireResult(result, requestID); err != nil {
		return "", nil, err
	}

	payload, ok := result["payload"].(map[string]any)
	if !ok {
		return "", nil, fmt.Errorf("poll result missing payload")
	}
	state, _ := payload["state"].(string)
	switch state {
	case "running", "idle":
		return state, nil, nil
	case "completed", "cancelled":
		terminal, err := c.readFrameLocked()
		if err != nil {
			return "", nil, err
		}
		if terminal["event_type"] != "run_finished" {
			return "", nil, fmt.Errorf("poll expected run_finished, got %v", terminal["event_type"])
		}
		return state, terminal, nil
	default:
		return "", nil, fmt.Errorf("unknown poll state %q", state)
	}
}

func (c *protocolClient) cancel() (protocolFrame, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	requestID := c.requestIDLocked()
	if err := c.writeFrameLocked(c.commandFrame(requestID, "session.cancel", protocolFrame{})); err != nil {
		return nil, err
	}
	result, err := c.readFrameLocked()
	if err != nil {
		return nil, err
	}
	if err := requireResult(result, requestID); err != nil {
		return nil, err
	}
	terminal, err := c.readFrameLocked()
	if err != nil {
		return nil, err
	}
	if terminal["event_type"] != "run_finished" {
		return nil, fmt.Errorf("cancel expected run_finished, got %v", terminal["event_type"])
	}
	return terminal, nil
}

func (c *protocolClient) close() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.stdin != nil {
		_ = c.stdin.Close()
		c.stdin = nil
	}
	if c.cmd == nil {
		return nil
	}
	if err := c.cmd.Wait(); err != nil {
		if text := strings.TrimSpace(c.stderr.String()); text != "" {
			return fmt.Errorf("agentprolog-ui: %w: %s", err, text)
		}
		return fmt.Errorf("agentprolog-ui: %w", err)
	}
	c.cmd = nil
	return nil
}

func (c *protocolClient) commandFrame(requestID, command string, payload protocolFrame) protocolFrame {
	return protocolFrame{
		"protocol":   protocolVersion,
		"kind":       "command",
		"session_id": c.sessionID,
		"request_id": requestID,
		"command":    command,
		"payload":    payload,
	}
}

func (c *protocolClient) requestIDLocked() string {
	requestID := fmt.Sprintf("req_%d", c.nextReq)
	c.nextReq++
	return requestID
}

func (c *protocolClient) writeFrameLocked(frame protocolFrame) error {
	data, err := json.Marshal(frame)
	if err != nil {
		return fmt.Errorf("encode protocol frame: %w", err)
	}
	data = append(data, '\n')
	if _, err := c.stdin.Write(data); err != nil {
		return fmt.Errorf("write agentprolog-ui: %w", err)
	}
	return nil
}

func (c *protocolClient) readFrameLocked() (protocolFrame, error) {
	if c.scanner.Scan() {
		var frame protocolFrame
		if err := json.Unmarshal(c.scanner.Bytes(), &frame); err != nil {
			return nil, fmt.Errorf("decode agentprolog-ui frame: %w", err)
		}
		if frame["protocol"] != protocolVersion {
			return nil, fmt.Errorf("unexpected protocol %v", frame["protocol"])
		}
		if frame["kind"] == "error" {
			return nil, fmt.Errorf("agentprolog-ui error: %s", frameError(frame))
		}
		return frame, nil
	}
	if err := c.scanner.Err(); err != nil {
		return nil, fmt.Errorf("read agentprolog-ui: %w", err)
	}
	if text := strings.TrimSpace(c.stderr.String()); text != "" {
		return nil, fmt.Errorf("agentprolog-ui closed: %s", text)
	}
	return nil, fmt.Errorf("agentprolog-ui closed unexpectedly")
}

func requireResult(frame protocolFrame, requestID string) error {
	if frame["kind"] != "result" {
		return fmt.Errorf("expected result frame, got %v", frame["kind"])
	}
	if frame["request_id"] != requestID {
		return fmt.Errorf("request correlation mismatch: got %v want %s", frame["request_id"], requestID)
	}
	if frame["status"] != "ok" {
		return fmt.Errorf("request rejected: %s", frameError(frame))
	}
	return nil
}

func frameError(frame protocolFrame) string {
	if message, ok := frame["message"].(string); ok && message != "" {
		return message
	}
	if payload, ok := frame["payload"].(map[string]any); ok {
		if code, ok := payload["code"].(string); ok && code != "" {
			return code
		}
	}
	data, err := json.Marshal(frame)
	if err != nil {
		return "unknown protocol error"
	}
	return string(data)
}
