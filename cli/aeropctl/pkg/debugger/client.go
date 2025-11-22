package debugger

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"go.uber.org/zap"
	"golang.org/x/term"
)

type Client struct {
	conn      *websocket.Conn
	machineID string
	token     string
	logger    *zap.Logger

	sendCh    chan []byte
	recvCh    chan Message
	errorCh   chan error
	closeCh   chan struct{}
	closeOnce sync.Once

	originalTermState *term.State
	isRaw             bool
}

type Message struct {
	Event   string                 `json:"event"`
	Payload map[string]interface{} `json:"payload"`
	Ref     string                 `json:"ref,omitempty"`
}

type ClientConfig struct {
	ServerURL string
	MachineID string
	Token     string
	Logger    *zap.Logger
}

func NewClient(config ClientConfig) (*Client, error) {
	if config.Logger == nil {
		config.Logger, _ = zap.NewProduction()
	}

	client := &Client{
		machineID: config.MachineID,
		token:     config.Token,
		logger:    config.Logger,
		sendCh:    make(chan []byte, 256),
		recvCh:    make(chan Message, 256),
		errorCh:   make(chan error, 10),
		closeCh:   make(chan struct{}),
	}

	u, err := url.Parse(config.ServerURL)
	if err != nil {
		return nil, fmt.Errorf("invalid server URL: %w", err)
	}

	switch u.Scheme {
	case "http":
		u.Scheme = "ws"
	case "https":
		u.Scheme = "wss"
	}

	u.Path = "/socket/websocket"
	q := u.Query()
	q.Set("token", config.Token)
	q.Set("vsn", "2.0.0")
	u.RawQuery = q.Encode()

	conn, _, err := websocket.DefaultDialer.Dial(u.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to WebSocket: %w", err)
	}

	client.conn = conn

	client.logger.Info("WebSocket connected", zap.String("machine_id", config.MachineID))

	go client.readPump()
	go client.writePump()

	return client, nil
}

func (c *Client) Join(mode string, record bool) error {
	joinPayload := map[string]interface{}{
		"mode":   mode,
		"record": record,
	}

	payload, err := json.Marshal(joinPayload)
	if err != nil {
		return fmt.Errorf("failed to marshal join payload: %w", err)
	}

	msg := []byte(fmt.Sprintf(`[null,"1","debug:%s","phx_join",%s]`, c.machineID, string(payload)))

	select {
	case c.sendCh <- msg:

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		for {
			select {
			case <-ctx.Done():
				return fmt.Errorf("join timeout")
			case err := <-c.errorCh:
				return err
			case msg := <-c.recvCh:
				if msg.Event == "phx_reply" {
					return nil
				}
			}
		}

	case <-c.closeCh:
		return fmt.Errorf("client closed")
	}
}

func (c *Client) SendCommand(event string, payload map[string]interface{}) error {
	ref := fmt.Sprintf("%d", time.Now().UnixNano())

	cmd := []byte(fmt.Sprintf(`[null,"%s","debug:%s","%s",%s]`,
		ref, c.machineID, event, mustMarshalJSON(payload)))

	select {
	case c.sendCh <- cmd:
		return nil
	case <-c.closeCh:
		return fmt.Errorf("client closed")
	}
}

func (c *Client) AttachShell(rows, cols int) error {

	if err := c.setRawTerminal(); err != nil {
		return fmt.Errorf("failed to set raw terminal: %w", err)
	}
	defer c.restoreTerminal()

	if err := c.SendCommand("shell.attach", map[string]interface{}{
		"options": map[string]interface{}{
			"mode": "shell",
		},
	}); err != nil {
		return err
	}

	if err := c.SendCommand("shell.resize", map[string]interface{}{
		"rows": rows,
		"cols": cols,
	}); err != nil {
		return err
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGWINCH)
	defer signal.Stop(sigCh)

	inputCh := make(chan []byte, 100)
	go c.readStdin(ctx, inputCh)

	for {
		select {
		case <-ctx.Done():
			return nil

		case <-c.closeCh:
			return nil

		case sig := <-sigCh:
			switch sig {
			case syscall.SIGINT:

				c.SendCommand("shell.input", map[string]interface{}{
					"data": "\x03",
				})

			case syscall.SIGTERM:
				return nil

			case syscall.SIGWINCH:

				width, height, err := term.GetSize(int(os.Stdout.Fd()))
				if err == nil {
					c.SendCommand("shell.resize", map[string]interface{}{
						"rows": height,
						"cols": width,
					})
				}
			}

		case data := <-inputCh:

			c.SendCommand("shell.input", map[string]interface{}{
				"data": string(data),
			})

		case msg := <-c.recvCh:

			if err := c.handleShellMessage(msg); err != nil {
				c.logger.Error("Failed to handle shell message", zap.Error(err))
			}

		case err := <-c.errorCh:
			return err
		}
	}
}

func (c *Client) GetMetrics() (map[string]interface{}, error) {
	if err := c.SendCommand("inspect.metrics", nil); err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("metrics timeout")
		case msg := <-c.recvCh:
			if msg.Event == "phx_reply" {
				return msg.Payload, nil
			}
			if msg.Event == "inspect.metrics" {
				return msg.Payload, nil
			}
		case err := <-c.errorCh:
			return nil, err
		}
	}
}

func (c *Client) StreamMetrics(ctx context.Context, interval time.Duration, callback func(map[string]interface{})) error {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil

		case <-ticker.C:
			metrics, err := c.GetMetrics()
			if err != nil {
				c.logger.Error("Failed to get metrics", zap.Error(err))
				continue
			}
			callback(metrics)

		case <-c.closeCh:
			return nil
		}
	}
}

func (c *Client) RecvChan() <-chan Message {
	return c.recvCh
}

func (c *Client) Close() error {
	var err error
	c.closeOnce.Do(func() {
		close(c.closeCh)
		c.restoreTerminal()
		if c.conn != nil {
			err = c.conn.Close()
		}
	})
	return err
}

func (c *Client) readPump() {
	defer func() {
		c.Close()
	}()

	for {
		select {
		case <-c.closeCh:
			return
		default:
			_, message, err := c.conn.ReadMessage()
			if err != nil {
				if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
					c.errorCh <- fmt.Errorf("websocket read error: %w", err)
				}
				return
			}

			var raw []interface{}
			if err := json.Unmarshal(message, &raw); err != nil {
				c.logger.Warn("Failed to parse message", zap.Error(err))
				continue
			}

			if len(raw) < 5 {
				continue
			}

			event, ok := raw[3].(string)
			if !ok {
				continue
			}

			payload, ok := raw[4].(map[string]interface{})
			if !ok {
				payload = make(map[string]interface{})
			}

			msg := Message{
				Event:   event,
				Payload: payload,
			}

			if ref, ok := raw[1].(string); ok {
				msg.Ref = ref
			}

			select {
			case c.recvCh <- msg:
			case <-c.closeCh:
				return
			}
		}
	}
}

func (c *Client) writePump() {
	ticker := time.NewTicker(30 * time.Second)
	defer func() {
		ticker.Stop()
		c.Close()
	}()

	for {
		select {
		case <-c.closeCh:
			return

		case message := <-c.sendCh:
			if err := c.conn.WriteMessage(websocket.TextMessage, message); err != nil {
				c.errorCh <- fmt.Errorf("websocket write error: %w", err)
				return
			}

		case <-ticker.C:

			heartbeat := []byte(`[null,"heartbeat","phoenix","heartbeat",{}]`)
			if err := c.conn.WriteMessage(websocket.TextMessage, heartbeat); err != nil {
				c.errorCh <- fmt.Errorf("heartbeat error: %w", err)
				return
			}
		}
	}
}

func (c *Client) setRawTerminal() error {
	fd := int(os.Stdin.Fd())

	state, err := term.MakeRaw(fd)
	if err != nil {
		return err
	}

	c.originalTermState = state
	c.isRaw = true

	return nil
}

func (c *Client) restoreTerminal() {
	if c.isRaw && c.originalTermState != nil {
		fd := int(os.Stdin.Fd())
		term.Restore(fd, c.originalTermState)
		c.isRaw = false
	}
}

func (c *Client) readStdin(ctx context.Context, output chan<- []byte) {
	buf := make([]byte, 1024)

	for {
		select {
		case <-ctx.Done():
			return
		default:
			n, err := os.Stdin.Read(buf)
			if err != nil {
				return
			}

			if n > 0 {
				data := make([]byte, n)
				copy(data, buf[:n])

				select {
				case output <- data:
				case <-ctx.Done():
					return
				}
			}
		}
	}
}

func (c *Client) handleShellMessage(msg Message) error {
	switch msg.Event {
	case "shell.output":

		if data, ok := msg.Payload["data"].(string); ok {
			_, err := os.Stdout.WriteString(data)
			return err
		}

	case "error":
		if errMsg, ok := msg.Payload["message"].(string); ok {
			return fmt.Errorf("remote error: %s", errMsg)
		}
	}

	return nil
}

func mustMarshalJSON(v interface{}) string {
	data, err := json.Marshal(v)
	if err != nil {
		return "{}"
	}
	return string(data)
}
