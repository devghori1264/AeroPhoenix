package logs

import (
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/devghori1264/aerophoenix/cli/aeropctl/pkg/formatter"
	"github.com/fatih/color"
	"github.com/nats-io/nats.go"
)

type StreamOptions struct {
	Follow      bool
	Tail        int
	Since       string
	Filter      string
	Level       string
	JSONOutput  bool
	NoTimestamp bool
	NatsURL     string
	NoColor     bool
}

type LogLevel int

const (
	LevelTrace LogLevel = iota
	LevelDebug
	LevelInfo
	LevelWarn
	LevelError
	LevelFatal
)

var levelColors = map[LogLevel]*color.Color{
	LevelTrace: color.New(color.FgHiBlack),
	LevelDebug: color.New(color.FgCyan),
	LevelInfo:  color.New(color.FgGreen),
	LevelWarn:  color.New(color.FgYellow),
	LevelError: color.New(color.FgRed),
	LevelFatal: color.New(color.FgHiRed, color.Bold),
}

var levelNames = map[LogLevel]string{
	LevelTrace: "TRACE",
	LevelDebug: "DEBUG",
	LevelInfo:  "INFO",
	LevelWarn:  "WARN",
	LevelError: "ERROR",
	LevelFatal: "FATAL",
}

type LogEntry struct {
	Timestamp time.Time              `json:"timestamp"`
	Level     LogLevel               `json:"level"`
	Message   string                 `json:"message"`
	Source    string                 `json:"source"`
	Machine   string                 `json:"machine"`
	Fields    map[string]interface{} `json:"fields,omitempty"`
}

type Streamer struct {
	nc        *nats.Conn
	js        nats.JetStreamContext
	filter    *regexp.Regexp
	minLevel  LogLevel
	opts      StreamOptions
	formatter *formatter.Formatter
	msgBuffer chan *nats.Msg
	doneCh    chan struct{}
	errCh     chan error
}

func NewStreamer(machineID string, opts StreamOptions) (*Streamer, error) {

	nc, err := nats.Connect(opts.NatsURL,
		nats.Name("aeropctl-logs"),
		nats.RetryOnFailedConnect(true),
		nats.MaxReconnects(-1),
		nats.ReconnectWait(time.Second),
		nats.DisconnectErrHandler(func(nc *nats.Conn, err error) {
			if err != nil {
				fmt.Fprintf(os.Stderr, "Disconnected from NATS: %v\n", err)
			}
		}),
		nats.ReconnectHandler(func(nc *nats.Conn) {
			fmt.Fprintf(os.Stderr, "Reconnected to NATS at %s\n", nc.ConnectedUrl())
		}),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to NATS at %s: %w", opts.NatsURL, err)
	}

	js, err := nc.JetStream()
	if err != nil {
		nc.Close()
		return nil, fmt.Errorf("failed to create JetStream context: %w", err)
	}

	var filter *regexp.Regexp
	if opts.Filter != "" {
		filter, err = regexp.Compile(opts.Filter)
		if err != nil {
			nc.Close()
			return nil, fmt.Errorf("invalid filter regex: %w", err)
		}
	}

	minLevel := parseLevelFilter(opts.Level)

	format := formatter.FormatTable
	if opts.JSONOutput {
		format = formatter.FormatJSON
	}
	f := formatter.NewFormatter(format, !opts.NoColor)

	return &Streamer{
		nc:        nc,
		js:        js,
		filter:    filter,
		minLevel:  minLevel,
		opts:      opts,
		formatter: f,
		msgBuffer: make(chan *nats.Msg, 256),
		doneCh:    make(chan struct{}),
		errCh:     make(chan error, 1),
	}, nil
}

func (s *Streamer) Stream(machineID string) error {
	defer s.Close()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go s.processMessages()

	if s.opts.Tail > 0 {
		if err := s.fetchHistoricalLogs(machineID); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: Failed to fetch historical logs: %v\n", err)
		}
	}

	if s.opts.Follow {
		subject := fmt.Sprintf("logs.%s.>", machineID)
		sub, err := s.nc.Subscribe(subject, func(msg *nats.Msg) {
			select {
			case s.msgBuffer <- msg:
			case <-s.doneCh:
				return
			}
		})
		if err != nil {
			return fmt.Errorf("failed to subscribe to %s: %w", subject, err)
		}
		defer sub.Unsubscribe()

		fmt.Fprintf(os.Stderr, "📡 Streaming logs from %s (press Ctrl+C to stop)...\n\n", machineID)

		select {
		case <-sigCh:
			fmt.Fprintf(os.Stderr, "\n\n✋ Stopping log stream...\n")
			return nil
		case err := <-s.errCh:
			return err
		}
	}

	return nil
}

func (s *Streamer) fetchHistoricalLogs(machineID string) error {
	streamName := fmt.Sprintf("LOGS_%s", strings.ToUpper(strings.ReplaceAll(machineID, "-", "_")))

	_, err := s.js.StreamInfo(streamName)
	if err != nil {

		return nil
	}

	consumerName := fmt.Sprintf("aeropctl_%d", time.Now().UnixNano())

	sub, err := s.js.PullSubscribe(
		fmt.Sprintf("logs.%s.>", machineID),
		consumerName,
		nats.AckExplicit(),
		nats.DeliverAll(),
	)
	if err != nil {
		return fmt.Errorf("failed to create pull subscription: %w", err)
	}
	defer sub.Unsubscribe()

	fetchCount := s.opts.Tail
	if fetchCount == 0 {
		fetchCount = 10000
	}

	messages, err := sub.Fetch(fetchCount, nats.MaxWait(3*time.Second))
	if err != nil && err != nats.ErrTimeout {
		return fmt.Errorf("failed to fetch historical logs: %w", err)
	}

	for _, msg := range messages {
		s.processMessage(msg)
		msg.Ack()
	}

	return nil
}

func (s *Streamer) processMessages() {
	for {
		select {
		case msg := <-s.msgBuffer:
			s.processMessage(msg)
		case <-s.doneCh:
			return
		}
	}
}

func (s *Streamer) processMessage(msg *nats.Msg) {
	entry, err := s.parseLogEntry(msg)
	if err != nil {

		return
	}

	if entry.Level < s.minLevel {
		return
	}

	if s.filter != nil && !s.filter.MatchString(entry.Message) {
		return
	}

	if s.opts.Since != "" {
		since, err := parseDuration(s.opts.Since)
		if err == nil && time.Since(entry.Timestamp) > since {
			return
		}
	}

	s.displayLogEntry(entry)
}

func (s *Streamer) parseLogEntry(msg *nats.Msg) (*LogEntry, error) {
	var entry LogEntry

	if err := json.Unmarshal(msg.Data, &entry); err == nil {
		return &entry, nil
	}

	entry.Timestamp = time.Now()
	entry.Level = LevelInfo
	entry.Message = string(msg.Data)
	entry.Source = extractSourceFromSubject(msg.Subject)

	entry.Level = extractLevelFromMessage(entry.Message)

	return &entry, nil
}

func (s *Streamer) displayLogEntry(entry *LogEntry) {
	if s.opts.JSONOutput {
		data, _ := json.Marshal(entry)
		fmt.Println(string(data))
		return
	}

	var parts []string

	levelStr := levelNames[entry.Level]
	if !s.opts.NoColor {
		levelStr = levelColors[entry.Level].Sprint(levelStr)
	}
	parts = append(parts, fmt.Sprintf("[%s]", levelStr))

	if !s.opts.NoTimestamp {
		ts := entry.Timestamp.Format("15:04:05.000")
		parts = append(parts, fmt.Sprintf("[%s]", ts))
	}

	if entry.Source != "" {
		parts = append(parts, fmt.Sprintf("[%s]", entry.Source))
	}

	parts = append(parts, entry.Message)

	fmt.Println(strings.Join(parts, " "))

	if len(entry.Fields) > 0 && !s.opts.JSONOutput {
		for k, v := range entry.Fields {
			fmt.Printf("  %s: %v\n", k, v)
		}
	}
}

func (s *Streamer) Close() error {
	close(s.doneCh)
	if s.nc != nil {
		s.nc.Close()
	}
	return nil
}

func parseLevelFilter(level string) LogLevel {
	switch strings.ToUpper(level) {
	case "TRACE":
		return LevelTrace
	case "DEBUG":
		return LevelDebug
	case "INFO":
		return LevelInfo
	case "WARN", "WARNING":
		return LevelWarn
	case "ERROR":
		return LevelError
	case "FATAL", "CRITICAL":
		return LevelFatal
	default:
		return LevelTrace
	}
}

func extractSourceFromSubject(subject string) string {
	parts := strings.Split(subject, ".")
	if len(parts) >= 3 {
		return parts[2]
	}
	return "unknown"
}

func extractLevelFromMessage(msg string) LogLevel {
	upper := strings.ToUpper(msg)
	if strings.Contains(upper, "FATAL") || strings.Contains(upper, "CRITICAL") {
		return LevelFatal
	}
	if strings.Contains(upper, "ERROR") {
		return LevelError
	}
	if strings.Contains(upper, "WARN") {
		return LevelWarn
	}
	if strings.Contains(upper, "DEBUG") {
		return LevelDebug
	}
	if strings.Contains(upper, "TRACE") {
		return LevelTrace
	}
	return LevelInfo
}

func parseDuration(s string) (time.Duration, error) {

	if d, err := time.ParseDuration(s); err == nil {
		return d, nil
	}

	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return time.Since(t), nil
	}

	return 0, fmt.Errorf("invalid duration or timestamp: %s", s)
}
