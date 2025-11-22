package logs

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/fatih/color"
	"github.com/nats-io/nats.go"
)

type LogLevel string

const (
	LevelTrace LogLevel = "TRACE"
	LevelDebug LogLevel = "DEBUG"
	LevelInfo  LogLevel = "INFO"
	LevelWarn  LogLevel = "WARN"
	LevelError LogLevel = "ERROR"
	LevelFatal LogLevel = "FATAL"
)

type LogEntry struct {
	Timestamp time.Time              `json:"timestamp"`
	Level     LogLevel               `json:"level"`
	MachineID string                 `json:"machine_id"`
	Source    string                 `json:"source"`
	Message   string                 `json:"message"`
	Metadata  map[string]interface{} `json:"metadata,omitempty"`
	Raw       string                 `json:"raw,omitempty"`
}

type Config struct {
	MachineID    string
	Follow       bool
	Tail         int
	Since        time.Time
	Until        time.Time
	Filter       string
	LevelFilter  LogLevel
	ColorEnabled bool
	JSONOutput   bool
	Timestamps   bool
	NatsURL      string
}

type Streamer struct {
	nc           *nats.Conn
	config       Config
	filterRegex  *regexp.Regexp
	levelColors  map[LogLevel]*color.Color
	sourceColors map[string]*color.Color
	writer       io.Writer
}

func NewStreamer(config Config) (*Streamer, error) {

	levelColors := map[LogLevel]*color.Color{
		LevelTrace: color.New(color.FgHiBlack),
		LevelDebug: color.New(color.FgCyan),
		LevelInfo:  color.New(color.FgGreen),
		LevelWarn:  color.New(color.FgYellow, color.Bold),
		LevelError: color.New(color.FgRed, color.Bold),
		LevelFatal: color.New(color.FgRed, color.Bold, color.BgWhite),
	}

	sourceColors := map[string]*color.Color{
		"stdout": color.New(color.FgWhite),
		"stderr": color.New(color.FgRed),
		"system": color.New(color.FgCyan),
	}

	s := &Streamer{
		config:       config,
		levelColors:  levelColors,
		sourceColors: sourceColors,
		writer:       os.Stdout,
	}

	if config.Filter != "" {
		regex, err := regexp.Compile(config.Filter)
		if err != nil {
			return nil, fmt.Errorf("invalid filter regex '%s': %w", config.Filter, err)
		}
		s.filterRegex = regex
	}

	nc, err := nats.Connect(config.NatsURL,
		nats.Name("aeropctl-logs"),
		nats.ReconnectWait(2*time.Second),
		nats.MaxReconnects(10),
		nats.DisconnectErrHandler(func(nc *nats.Conn, err error) {
			if err != nil {
				fmt.Fprintf(os.Stderr, "NATS disconnected: %v\n", err)
			}
		}),
		nats.ReconnectHandler(func(nc *nats.Conn) {
			fmt.Fprintf(os.Stderr, "NATS reconnected to %s\n", nc.ConnectedUrl())
		}),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to NATS at %s: %w", config.NatsURL, err)
	}

	s.nc = nc
	return s, nil
}

func (s *Streamer) Stream(ctx context.Context) error {
	defer s.nc.Close()

	subject := fmt.Sprintf("logs.%s", s.config.MachineID)

	if s.config.Tail > 0 {
		if err := s.fetchHistoricalLogs(ctx, subject); err != nil {

			fmt.Fprintf(os.Stderr, "Warning: could not fetch historical logs: %v\n", err)
		}
	}

	if !s.config.Follow {
		return nil
	}

	return s.streamLiveLogs(ctx, subject)
}

func (s *Streamer) fetchHistoricalLogs(ctx context.Context, subject string) error {
	js, err := s.nc.JetStream()
	if err != nil {

		return nil
	}

	streamName := fmt.Sprintf("LOGS_%s", strings.ToUpper(s.config.MachineID))

	_, err = js.StreamInfo(streamName)
	if err != nil {

		return nil
	}

	consumerConfig := nats.ConsumerConfig{
		AckPolicy:  nats.AckNonePolicy,
		MaxDeliver: 1,
	}

	if !s.config.Since.IsZero() {
		consumerConfig.DeliverPolicy = nats.DeliverByStartTimePolicy
		consumerConfig.OptStartTime = &s.config.Since
	} else {
		consumerConfig.DeliverPolicy = nats.DeliverLastPerSubjectPolicy
	}

	sub, err := js.PullSubscribe(subject, "", consumerConfig)
	if err != nil {
		return fmt.Errorf("failed to create pull subscription: %w", err)
	}
	defer sub.Unsubscribe()

	fetchCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	msgs, err := sub.Fetch(s.config.Tail, nats.Context(fetchCtx))
	if err != nil && err != nats.ErrTimeout {
		return fmt.Errorf("failed to fetch messages: %w", err)
	}

	for _, msg := range msgs {
		if err := s.processMessage(msg); err != nil {
			fmt.Fprintf(os.Stderr, "Error processing log entry: %v\n", err)
		}
		msg.Ack()
	}

	return nil
}

func (s *Streamer) streamLiveLogs(ctx context.Context, subject string) error {
	msgChan := make(chan *nats.Msg, 256)

	sub, err := s.nc.ChanSubscribe(subject, msgChan)
	if err != nil {
		return fmt.Errorf("failed to subscribe to %s: %w", subject, err)
	}
	defer sub.Unsubscribe()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case msg := <-msgChan:
			if err := s.processMessage(msg); err != nil {
				fmt.Fprintf(os.Stderr, "Error processing log entry: %v\n", err)
			}
		}
	}
}

func (s *Streamer) processMessage(msg *nats.Msg) error {
	entry := s.parseLogEntry(msg.Data)

	if !s.config.Since.IsZero() && entry.Timestamp.Before(s.config.Since) {
		return nil
	}
	if !s.config.Until.IsZero() && entry.Timestamp.After(s.config.Until) {
		return nil
	}

	if s.config.LevelFilter != "" && !s.shouldIncludeLevel(entry.Level) {
		return nil
	}

	if s.filterRegex != nil && !s.filterRegex.MatchString(entry.Message) {
		return nil
	}

	if s.config.JSONOutput {
		return s.writeJSON(entry)
	}
	return s.writeFormatted(entry)
}

func (s *Streamer) parseLogEntry(data []byte) LogEntry {

	var entry LogEntry
	if err := json.Unmarshal(data, &entry); err == nil {
		return entry
	}

	raw := string(data)
	entry = LogEntry{
		Timestamp: time.Now(),
		MachineID: s.config.MachineID,
		Source:    "stdout",
		Raw:       raw,
		Message:   raw,
		Metadata:  make(map[string]interface{}),
	}

	levelPattern := regexp.MustCompile(`^\[?(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL)\]?\s+(.+)$`)
	if matches := levelPattern.FindStringSubmatch(raw); len(matches) == 3 {
		entry.Level = LogLevel(strings.ToUpper(matches[1]))
		if entry.Level == "WARNING" {
			entry.Level = LevelWarn
		}
		entry.Message = matches[2]
		return entry
	}

	tsPattern := regexp.MustCompile(`^(\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\s+\[?(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL)\]?\s+(.+)$`)
	if matches := tsPattern.FindStringSubmatch(raw); len(matches) == 4 {
		if ts, err := time.Parse(time.RFC3339, matches[1]); err == nil {
			entry.Timestamp = ts
		} else if ts, err := time.Parse("2006-01-02 15:04:05", matches[1]); err == nil {
			entry.Timestamp = ts
		}
		entry.Level = LogLevel(strings.ToUpper(matches[2]))
		if entry.Level == "WARNING" {
			entry.Level = LevelWarn
		}
		entry.Message = matches[3]
		return entry
	}

	var jsonLog map[string]interface{}
	if err := json.Unmarshal(data, &jsonLog); err == nil {
		if msg, ok := jsonLog["message"].(string); ok {
			entry.Message = msg
		} else if msg, ok := jsonLog["msg"].(string); ok {
			entry.Message = msg
		}

		if level, ok := jsonLog["level"].(string); ok {
			entry.Level = LogLevel(strings.ToUpper(level))
		}

		if ts, ok := jsonLog["timestamp"].(string); ok {
			if t, err := time.Parse(time.RFC3339, ts); err == nil {
				entry.Timestamp = t
			}
		}

		entry.Metadata = jsonLog
		return entry
	}

	entry.Level = LevelInfo
	return entry
}

func (s *Streamer) shouldIncludeLevel(level LogLevel) bool {
	levelPriority := map[LogLevel]int{
		LevelTrace: 0,
		LevelDebug: 1,
		LevelInfo:  2,
		LevelWarn:  3,
		LevelError: 4,
		LevelFatal: 5,
	}

	entryPriority, ok := levelPriority[level]
	if !ok {
		return true
	}

	filterPriority, ok := levelPriority[s.config.LevelFilter]
	if !ok {
		return true
	}

	return entryPriority >= filterPriority
}

func (s *Streamer) writeJSON(entry LogEntry) error {
	return json.NewEncoder(s.writer).Encode(entry)
}

func (s *Streamer) writeFormatted(entry LogEntry) error {
	var output strings.Builder

	if s.config.Timestamps {
		timestamp := entry.Timestamp.Format("2006-01-02 15:04:05.000")
		if s.config.ColorEnabled {
			output.WriteString(color.New(color.FgHiBlack).Sprint(timestamp))
		} else {
			output.WriteString(timestamp)
		}
		output.WriteString(" ")
	}

	levelStr := fmt.Sprintf("[%-5s]", entry.Level)
	if s.config.ColorEnabled {
		if c, ok := s.levelColors[entry.Level]; ok {
			output.WriteString(c.Sprint(levelStr))
		} else {
			output.WriteString(levelStr)
		}
	} else {
		output.WriteString(levelStr)
	}
	output.WriteString(" ")

	if entry.Source != "" {
		sourceStr := fmt.Sprintf("[%s]", entry.Source)
		if s.config.ColorEnabled {
			if c, ok := s.sourceColors[entry.Source]; ok {
				output.WriteString(c.Sprint(sourceStr))
			} else {
				output.WriteString(sourceStr)
			}
		} else {
			output.WriteString(sourceStr)
		}
		output.WriteString(" ")
	}

	message := entry.Message
	if entry.Raw != "" && s.config.ColorEnabled && containsANSI(entry.Raw) {
		message = entry.Raw
	}
	output.WriteString(message)

	if len(entry.Metadata) > 0 {
		metaJSON, _ := json.Marshal(entry.Metadata)
		if s.config.ColorEnabled {
			output.WriteString(" ")
			output.WriteString(color.New(color.FgHiBlack).Sprintf("meta=%s", string(metaJSON)))
		} else {
			output.WriteString(fmt.Sprintf(" meta=%s", string(metaJSON)))
		}
	}

	output.WriteString("\n")
	_, err := s.writer.Write([]byte(output.String()))
	return err
}

func ParseSinceDuration(since string) (time.Time, error) {
	if since == "" {
		return time.Time{}, nil
	}

	duration, err := time.ParseDuration(since)
	if err == nil {
		return time.Now().Add(-duration), nil
	}

	timestamp, err := time.Parse(time.RFC3339, since)
	if err == nil {
		return timestamp, nil
	}

	timestamp, err = time.Parse("2006-01-02", since)
	if err == nil {
		return timestamp, nil
	}

	return time.Time{}, fmt.Errorf("invalid since format: %s (use duration like '2h' or RFC3339 timestamp)", since)
}

func containsANSI(s string) bool {
	return strings.Contains(s, "\x1b[")
}

func StripANSI(input string) string {
	ansiPattern := regexp.MustCompile(`\x1b\[[0-9;]*m`)
	return ansiPattern.ReplaceAllString(input, "")
}
