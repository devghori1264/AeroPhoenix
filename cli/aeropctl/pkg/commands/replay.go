package commands

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"text/tabwriter"
	"time"
)

type Event struct {
	ID               string                 `json:"id"`
	EventType        string                 `json:"event_type"`
	EventVersion     int                    `json:"event_version"`
	AggregateID      string                 `json:"aggregate_id"`
	AggregateType    string                 `json:"aggregate_type"`
	AggregateVersion int                    `json:"aggregate_version"`
	Data             map[string]interface{} `json:"data"`
	Metadata         map[string]interface{} `json:"metadata"`
	CausationID      *string                `json:"causation_id"`
	CorrelationID    *string                `json:"correlation_id"`
	VectorClock      map[string]interface{} `json:"vector_clock"`
	Tags             []string               `json:"tags"`
	ActorID          *string                `json:"actor_id"`
	ActorType        *string                `json:"actor_type"`
	OccurredAt       time.Time              `json:"occurred_at"`
	RecordedAt       time.Time              `json:"recorded_at"`
}

type AggregateStats struct {
	AggregateID      string    `json:"aggregate_id"`
	AggregateType    string    `json:"aggregate_type"`
	EventCount       int       `json:"event_count"`
	LatestVersion    int       `json:"latest_version"`
	FirstEventAt     time.Time `json:"first_event_at"`
	LastEventAt      time.Time `json:"last_event_at"`
	UniqueEventTypes int       `json:"unique_event_types"`
	EventTypes       []string  `json:"event_types"`
}

type StateDiff struct {
	Added   map[string]interface{} `json:"added"`
	Removed map[string]interface{} `json:"removed"`
	Changed map[string]interface{} `json:"changed"`
}

type ReplayListOptions struct {
	JSON          bool
	AggregateType string
}

type ReplayShowOptions struct {
	JSON        bool
	Compact     bool
	FromVersion int
	ToVersion   int
	Since       string
	Until       string
	EventTypes  string
	Tags        string
	Limit       int
}

type ReplayRebuildOptions struct {
	JSON       bool
	ToVersion  int
	TimeTravel string
	NoSnapshot bool
	Validate   bool
}

type ReplayDiffOptions struct {
	JSON        bool
	FromVersion int
	ToVersion   int
}

type ReplaySearchOptions struct {
	JSON       bool
	EventTypes string
	Limit      int
}

type ReplayTraceOptions struct {
	JSON  bool
	Limit int
}

func RunReplayList(opts ReplayListOptions) error {

	stats := []AggregateStats{
		{
			AggregateID:      "550e8400-e29b-41d4-a716-446655440000",
			AggregateType:    "Machine",
			EventCount:       142,
			LatestVersion:    142,
			FirstEventAt:     time.Now().Add(-30 * 24 * time.Hour),
			LastEventAt:      time.Now().Add(-1 * time.Hour),
			UniqueEventTypes: 8,
			EventTypes:       []string{"machine_created", "machine_started", "machine_stopped", "config_updated"},
		},
		{
			AggregateID:      "650e8400-e29b-41d4-a716-446655440001",
			AggregateType:    "Machine",
			EventCount:       89,
			LatestVersion:    89,
			FirstEventAt:     time.Now().Add(-15 * 24 * time.Hour),
			LastEventAt:      time.Now().Add(-30 * time.Minute),
			UniqueEventTypes: 6,
			EventTypes:       []string{"machine_created", "machine_started", "migration_initiated", "migration_completed"},
		},
	}

	if opts.JSON {
		return json.NewEncoder(os.Stdout).Encode(stats)
	}

	printAggregateListTable(stats)
	return nil
}

func RunReplayShow(aggregateID string, opts ReplayShowOptions) error {

	events := []Event{
		{
			ID:               "evt-001",
			EventType:        "machine_created",
			AggregateID:      aggregateID,
			AggregateType:    "Machine",
			AggregateVersion: 1,
			Data: map[string]interface{}{
				"name":   "production-web-1",
				"region": "us-east",
				"config": map[string]interface{}{
					"cpu":    2,
					"memory": "4GB",
				},
			},
			Metadata: map[string]interface{}{
				"source": "api",
				"user":   "admin",
			},
			Tags:       []string{"production", "web"},
			OccurredAt: time.Now().Add(-24 * time.Hour),
			RecordedAt: time.Now().Add(-24 * time.Hour),
		},
		{
			ID:               "evt-002",
			EventType:        "machine_started",
			AggregateID:      aggregateID,
			AggregateType:    "Machine",
			AggregateVersion: 2,
			Data: map[string]interface{}{
				"started_at": time.Now().Add(-23 * time.Hour).Format(time.RFC3339),
			},
			Tags:       []string{"production"},
			OccurredAt: time.Now().Add(-23 * time.Hour),
			RecordedAt: time.Now().Add(-23 * time.Hour),
		},
		{
			ID:               "evt-003",
			EventType:        "config_updated",
			AggregateID:      aggregateID,
			AggregateType:    "Machine",
			AggregateVersion: 3,
			Data: map[string]interface{}{
				"config": map[string]interface{}{
					"cpu":    4,
					"memory": "8GB",
				},
			},
			Tags:       []string{"production", "scaling"},
			OccurredAt: time.Now().Add(-12 * time.Hour),
			RecordedAt: time.Now().Add(-12 * time.Hour),
		},
	}

	if opts.JSON {
		return json.NewEncoder(os.Stdout).Encode(events)
	}

	if opts.Compact {
		printEventsCompact(events)
	} else {
		printEventsTable(events)
	}

	return nil
}

func RunReplayRebuild(aggregateID string, opts ReplayRebuildOptions) error {

	state := map[string]interface{}{
		"id":      aggregateID,
		"name":    "production-web-1",
		"status":  "running",
		"region":  "us-east",
		"version": 142,
		"config": map[string]interface{}{
			"cpu":    4,
			"memory": "8GB",
		},
		"created_at": time.Now().Add(-30 * 24 * time.Hour).Format(time.RFC3339),
		"started_at": time.Now().Add(-29 * 24 * time.Hour).Format(time.RFC3339),
	}

	if opts.JSON {
		return json.NewEncoder(os.Stdout).Encode(state)
	}

	printStateTable(state, opts.ToVersion)
	return nil
}

func RunReplayDiff(aggregateID string, opts ReplayDiffOptions) error {

	diff := StateDiff{
		Added: map[string]interface{}{
			"migration_state": "completed",
		},
		Removed: map[string]interface{}{
			"target_region": "us-west",
		},
		Changed: map[string]interface{}{
			"status": map[string]interface{}{
				"from": "starting",
				"to":   "running",
			},
			"region": map[string]interface{}{
				"from": "us-east",
				"to":   "us-west",
			},
			"config": map[string]interface{}{
				"from": map[string]interface{}{"cpu": 2, "memory": "4GB"},
				"to":   map[string]interface{}{"cpu": 4, "memory": "8GB"},
			},
		},
	}

	if opts.JSON {
		return json.NewEncoder(os.Stdout).Encode(diff)
	}

	printDiffTable(diff, opts.FromVersion, opts.ToVersion)
	return nil
}

func RunReplaySearch(query string, opts ReplaySearchOptions) error {

	events := []Event{
		{
			ID:               "evt-042",
			EventType:        "health_check_failed",
			AggregateID:      "550e8400-e29b-41d4-a716-446655440000",
			AggregateType:    "Machine",
			AggregateVersion: 42,
			Data: map[string]interface{}{
				"error":    "connection timeout",
				"endpoint": "/health",
				"duration": 5000,
			},
			Tags:       []string{"error", "health"},
			OccurredAt: time.Now().Add(-2 * time.Hour),
			RecordedAt: time.Now().Add(-2 * time.Hour),
		},
	}

	if opts.JSON {
		return json.NewEncoder(os.Stdout).Encode(events)
	}

	fmt.Printf("\n🔍 Search results for: \"%s\"\n", query)
	fmt.Println(strings.Repeat("=", 60))
	printEventsTable(events)

	return nil
}

func RunReplayTrace(correlationID string, opts ReplayTraceOptions) error {

	events := []Event{
		{
			ID:            "evt-100",
			EventType:     "migration_initiated",
			AggregateID:   "550e8400-e29b-41d4-a716-446655440000",
			AggregateType: "Machine",
			CorrelationID: &correlationID,
			Data: map[string]interface{}{
				"target_region": "us-west",
			},
			OccurredAt: time.Now().Add(-1 * time.Hour),
		},
		{
			ID:            "evt-101",
			EventType:     "resource_allocated",
			AggregateID:   "650e8400-e29b-41d4-a716-446655440001",
			AggregateType: "Machine",
			CorrelationID: &correlationID,
			Data: map[string]interface{}{
				"resource_type": "compute",
				"region":        "us-west",
			},
			OccurredAt: time.Now().Add(-59 * time.Minute),
		},
		{
			ID:            "evt-102",
			EventType:     "migration_completed",
			AggregateID:   "550e8400-e29b-41d4-a716-446655440000",
			AggregateType: "Machine",
			CorrelationID: &correlationID,
			Data: map[string]interface{}{
				"target_region": "us-west",
				"duration_ms":   45000,
			},
			OccurredAt: time.Now().Add(-58 * time.Minute),
		},
	}

	if opts.JSON {
		return json.NewEncoder(os.Stdout).Encode(events)
	}

	fmt.Printf("\n🔗 Correlation trace: %s\n", correlationID)
	fmt.Println(strings.Repeat("=", 80))
	printTraceTable(events)

	return nil
}

func printAggregateListTable(stats []AggregateStats) {
	if len(stats) == 0 {
		fmt.Println("No aggregates found.")
		return
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
	defer w.Flush()

	fmt.Println("\n📊 Aggregates in Event Store")
	fmt.Println(strings.Repeat("=", 100))

	fmt.Fprintln(w, "\nAGGREGATE ID\tTYPE\tEVENTS\tVERSION\tFIRST EVENT\tLAST EVENT\tEVENT TYPES")
	fmt.Fprintln(w, "------------\t----\t------\t-------\t-----------\t----------\t-----------")

	for _, s := range stats {
		fmt.Fprintf(w, "%s\t%s\t%d\t%d\t%s\t%s\t%d types\n",
			s.AggregateID,
			s.AggregateType,
			s.EventCount,
			s.LatestVersion,
			formatTimestamp(s.FirstEventAt),
			formatTimestamp(s.LastEventAt),
			s.UniqueEventTypes,
		)
	}

	fmt.Fprintf(w, "\nTotal: %d aggregates\n", len(stats))
}

func printEventsTable(events []Event) {
	if len(events) == 0 {
		fmt.Println("\nNo events found.")
		return
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
	defer w.Flush()

	fmt.Fprintln(w, "\nVERSION\tTYPE\tOCCURRED AT\tTAGS\tDATA PREVIEW")
	fmt.Fprintln(w, "-------\t----\t-----------\t----\t------------")

	for _, e := range events {
		tagsStr := strings.Join(e.Tags, ",")
		if tagsStr == "" {
			tagsStr = "-"
		}
		dataPreview := formatDataPreview(e.Data)

		fmt.Fprintf(w, "v%d\t%s\t%s\t%s\t%s\n",
			e.AggregateVersion,
			e.EventType,
			formatTimestamp(e.OccurredAt),
			tagsStr,
			dataPreview,
		)
	}

	fmt.Fprintf(w, "\nTotal: %d events\n", len(events))
}

func printEventsCompact(events []Event) {
	if len(events) == 0 {
		fmt.Println("\nNo events found.")
		return
	}

	for _, e := range events {
		tags := ""
		if len(e.Tags) > 0 {
			tags = fmt.Sprintf(" [%s]", strings.Join(e.Tags, ","))
		}

		fmt.Printf("v%-4d %s %s%s %s\n",
			e.AggregateVersion,
			formatTimestamp(e.OccurredAt),
			e.EventType,
			tags,
			formatDataPreview(e.Data),
		)
	}

	fmt.Printf("\nTotal: %d events\n", len(events))
}

func printTraceTable(events []Event) {
	if len(events) == 0 {
		fmt.Println("\nNo events found in correlation chain.")
		return
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
	defer w.Flush()

	fmt.Fprintln(w, "\n#\tAGGREGATE ID\tTYPE\tOCCURRED AT\tDATA")
	fmt.Fprintln(w, "-\t------------\t----\t-----------\t----")

	for i, e := range events {
		fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\n",
			i+1,
			e.AggregateID[:8]+"...",
			e.EventType,
			formatTimestamp(e.OccurredAt),
			formatDataPreview(e.Data),
		)
	}

	fmt.Fprintf(w, "\nTotal: %d events in correlation chain\n", len(events))
}

func printStateTable(state map[string]interface{}, version int) {
	fmt.Println("\n📦 Reconstructed Aggregate State")
	fmt.Println(strings.Repeat("=", 60))

	if version > 0 {
		fmt.Printf("Version: %d\n", version)
		fmt.Println(strings.Repeat("-", 60))
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
	defer w.Flush()

	fmt.Fprintln(w, "\nFIELD\tVALUE")
	fmt.Fprintln(w, "-----\t-----")

	for k, v := range state {
		fmt.Fprintf(w, "%s\t%s\n", k, formatValue(v))
	}

	w.Flush()
	fmt.Println()
}

func printDiffTable(diff StateDiff, fromVersion, toVersion int) {
	fmt.Println("\n🔄 State Diff")
	fmt.Println(strings.Repeat("=", 60))
	fmt.Printf("From version %d → To version %d\n", fromVersion, toVersion)
	fmt.Println(strings.Repeat("-", 60))

	hasChanges := false

	if len(diff.Added) > 0 {
		hasChanges = true
		fmt.Println("\n✅ Added Fields:")
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
		fmt.Fprintln(w, "FIELD\tVALUE")
		for k, v := range diff.Added {
			fmt.Fprintf(w, "%s\t%s\n", k, formatValue(v))
		}
		w.Flush()
	}

	if len(diff.Removed) > 0 {
		hasChanges = true
		fmt.Println("\n❌ Removed Fields:")
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
		fmt.Fprintln(w, "FIELD\tVALUE")
		for k, v := range diff.Removed {
			fmt.Fprintf(w, "%s\t%s\n", k, formatValue(v))
		}
		w.Flush()
	}

	if len(diff.Changed) > 0 {
		hasChanges = true
		fmt.Println("\n🔄 Changed Fields:")
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
		fmt.Fprintln(w, "FIELD\tFROM\tTO")
		for k, v := range diff.Changed {
			if changeMap, ok := v.(map[string]interface{}); ok {
				fmt.Fprintf(w, "%s\t%s\t%s\n",
					k,
					formatValue(changeMap["from"]),
					formatValue(changeMap["to"]),
				)
			}
		}
		w.Flush()
	}

	if !hasChanges {
		fmt.Println("\nℹ️  No differences found between versions.")
	}

	fmt.Println()
}

func formatTimestamp(t time.Time) string {
	now := time.Now()
	diff := now.Sub(t)

	if diff < time.Minute {
		return "just now"
	} else if diff < time.Hour {
		mins := int(diff.Minutes())
		return fmt.Sprintf("%dm ago", mins)
	} else if diff < 24*time.Hour {
		hours := int(diff.Hours())
		return fmt.Sprintf("%dh ago", hours)
	} else if diff < 7*24*time.Hour {
		days := int(diff.Hours() / 24)
		return fmt.Sprintf("%dd ago", days)
	}

	return t.Format("2006-01-02 15:04")
}

func formatDataPreview(data map[string]interface{}) string {
	if len(data) == 0 {
		return "{}"
	}

	var preview []string
	count := 0
	maxFields := 2

	for k, v := range data {
		if count >= maxFields {
			preview = append(preview, "...")
			break
		}
		preview = append(preview, fmt.Sprintf("%s: %s", k, formatValue(v)))
		count++
	}

	return "{" + strings.Join(preview, ", ") + "}"
}

func formatValue(v interface{}) string {
	switch val := v.(type) {
	case string:
		if len(val) > 40 {
			return val[:37] + "..."
		}
		return val
	case map[string]interface{}:
		if len(val) == 0 {
			return "{}"
		}

		keys := make([]string, 0, len(val))
		for k := range val {
			keys = append(keys, k)
			if len(keys) >= 2 {
				break
			}
		}
		if len(val) > 2 {
			return fmt.Sprintf("{%s, ...}", strings.Join(keys, ", "))
		}
		return fmt.Sprintf("{%s}", strings.Join(keys, ", "))
	case []interface{}:
		return fmt.Sprintf("[%d items]", len(val))
	case float64:

		if val == float64(int(val)) {
			return fmt.Sprintf("%d", int(val))
		}
		return fmt.Sprintf("%.2f", val)
	case bool:
		return fmt.Sprintf("%t", val)
	case nil:
		return "null"
	default:
		str := fmt.Sprintf("%v", v)
		if len(str) > 40 {
			return str[:37] + "..."
		}
		return str
	}
}
