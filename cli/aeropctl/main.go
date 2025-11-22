package main

import (
	"fmt"
	"os"
	"time"

	"github.com/devghori1264/aerophoenix/cli/aeropctl/pkg/commands"
	"github.com/spf13/cobra"
	"go.uber.org/zap"
)

var (
	logger       *zap.Logger
	baseURL      string
	outputFormat string
	noColor      bool
	timeout      time.Duration
)

func main() {
	logger, _ = zap.NewProduction()
	defer logger.Sync()

	rootCmd := &cobra.Command{
		Use:   "aeropctl",
		Short: "AeroPhoenix - Production-grade distributed machine orchestration CLI",
		Long: `aeropctl is a powerful command-line interface for managing machines across multiple regions
with advanced features including live migration, FSM state management, and real-time monitoring.

Built for the Fly.io platform with production-grade reliability and developer experience.`,
		Version: "1.0.0",
		PersistentPreRun: func(cmd *cobra.Command, args []string) {

			commands.SetGlobalFlags(&commands.GlobalFlags{
				BaseURL: baseURL,
				Output:  outputFormat,
				NoColor: noColor,
				Timeout: timeout,
			})
		},
	}

	rootCmd.PersistentFlags().StringVar(&baseURL, "url", "http://localhost:4000", "Orchestrator base URL")
	rootCmd.PersistentFlags().StringVarP(&outputFormat, "output", "o", "table", "Output format (table, json, yaml, wide)")
	rootCmd.PersistentFlags().BoolVar(&noColor, "no-color", false, "Disable colored output")
	rootCmd.PersistentFlags().DurationVar(&timeout, "timeout", 30*time.Second, "Request timeout")

	rootCmd.AddCommand(commands.ListCmd())
	rootCmd.AddCommand(commands.GetCmd())
	rootCmd.AddCommand(commands.CreateCmd())

	rootCmd.AddCommand(commands.ActionCmd("start"))
	rootCmd.AddCommand(commands.ActionCmd("stop"))
	rootCmd.AddCommand(commands.ActionCmd("restart"))
	rootCmd.AddCommand(commands.ActionCmd("destroy"))

	rootCmd.AddCommand(commands.MigrateCmd())
	rootCmd.AddCommand(commands.StateCmd())

	rootCmd.AddCommand(createLogsCmd())

	rootCmd.AddCommand(createAttachCmd())
	rootCmd.AddCommand(createInspectCmd())

	rootCmd.AddCommand(createReplayCmd())

	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func createLogsCmd() *cobra.Command {
	var (
		follow      bool
		tail        int
		since       string
		filter      string
		level       string
		jsonOutput  bool
		noTimestamp bool
		natsURL     string
	)

	cmd := &cobra.Command{
		Use:     "logs [machine-id]",
		Aliases: []string{"log", "tail"},
		Short:   "Stream machine logs with real-time filtering",
		Long: `Stream logs from a machine with advanced filtering and formatting.

Supports:
  - Real-time streaming via NATS JetStream
  - Historical log retrieval with --tail
  - Time-based filtering with --since
  - Regex pattern matching with --filter
  - Log level filtering (TRACE, DEBUG, INFO, WARN, ERROR, FATAL)
  - ANSI color preservation
  - JSON and structured output formats
  - Automatic log parsing for common formats`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return commands.RunLogs(args[0], commands.LogsOptions{
				Follow:      follow,
				Tail:        tail,
				Since:       since,
				Filter:      filter,
				Level:       level,
				JSONOutput:  jsonOutput,
				NoTimestamp: noTimestamp,
				NatsURL:     natsURL,
				NoColor:     noColor,
			})
		},
	}

	cmd.Flags().BoolVarP(&follow, "follow", "f", false, "Follow log output (stream continuously)")
	cmd.Flags().IntVarP(&tail, "tail", "n", 100, "Number of lines to show from the end (0 for all)")
	cmd.Flags().StringVar(&since, "since", "", "Show logs since timestamp (e.g., 2h, 30m, 2024-01-15T10:00:00Z)")
	cmd.Flags().StringVar(&filter, "filter", "", "Filter logs by regex pattern")
	cmd.Flags().StringVar(&level, "level", "", "Filter by minimum log level (TRACE|DEBUG|INFO|WARN|ERROR|FATAL)")
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output logs as JSON")
	cmd.Flags().BoolVar(&noTimestamp, "no-timestamp", false, "Hide timestamps in output")
	cmd.Flags().StringVar(&natsURL, "nats-url", "nats://localhost:4222", "NATS server URL")

	return cmd
}

func createAttachCmd() *cobra.Command {
	var (
		shell    string
		cwd      string
		rows     int
		cols     int
		noResize bool
	)

	cmd := &cobra.Command{
		Use:     "attach [machine-id]",
		Aliases: []string{"console", "shell", "exec"},
		Short:   "Attach to machine console with interactive shell",
		Long: `Opens an interactive debugging session to a machine with PTY emulation.

Features:
  - Full terminal emulation with ANSI support
  - Job control (Ctrl+C, Ctrl+Z, Ctrl+D)
  - Automatic terminal resizing
  - Session recording capabilities
  - Command history and autocomplete
  - UTF-8 and Unicode support

The session connects via WebSocket with production-grade reliability:
  - Auto-reconnection on network failures
  - Session persistence
  - Multi-user collaboration support

Example usage:
  # Attach with default shell (/bin/bash)
  aeropctl attach my-machine

  # Specify custom shell
  aeropctl attach my-machine --shell /bin/zsh

  # Set working directory
  aeropctl attach my-machine --cwd /app

  # Custom terminal size
  aeropctl attach my-machine --rows 40 --cols 120`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return commands.RunAttach(args[0], commands.AttachOptions{
				Shell:    shell,
				CWD:      cwd,
				Rows:     rows,
				Cols:     cols,
				NoResize: noResize,
			})
		},
	}

	cmd.Flags().StringVar(&shell, "shell", "/bin/bash", "Shell to execute")
	cmd.Flags().StringVar(&cwd, "cwd", "/root", "Working directory")
	cmd.Flags().IntVar(&rows, "rows", 24, "Terminal rows")
	cmd.Flags().IntVar(&cols, "cols", 80, "Terminal columns")
	cmd.Flags().BoolVar(&noResize, "no-resize", false, "Disable automatic terminal resizing")

	return cmd
}

func createInspectCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "inspect",
		Short: "Real-time machine inspection and debugging",
		Long: `Advanced inspection tools for debugging running machines.

Provides comprehensive visibility into:
  - Process metrics (CPU, memory, threads, I/O)
  - Network connections and traffic
  - File descriptors and open files
  - System calls and performance profiling
  - FSM state and transition history

All commands support real-time streaming with configurable refresh rates.`,
	}

	cmd.AddCommand(createInspectMetricsCmd())
	cmd.AddCommand(createInspectThreadsCmd())
	cmd.AddCommand(createInspectNetworkCmd())
	cmd.AddCommand(createInspectFDsCmd())
	cmd.AddCommand(createInspectFSMCmd())

	return cmd
}

func createInspectMetricsCmd() *cobra.Command {
	var (
		follow   bool
		interval int
	)

	cmd := &cobra.Command{
		Use:     "metrics [machine-id]",
		Aliases: []string{"cpu", "mem", "memory", "perf"},
		Short:   "Display real-time process metrics",
		Long: `Shows comprehensive process metrics including:

CPU Metrics:
  - User/system/total CPU usage percentages
  - Per-core utilization
  - Load averages (1m, 5m, 15m)
  - CPU throttling status

Memory Metrics:
  - RSS (Resident Set Size)
  - VSZ (Virtual Size)
  - Swap usage
  - Page faults (minor/major)
  - cgroup memory limits
  - OOM score

I/O Metrics:
  - Read/write bytes and operations
  - Disk IOPS and throughput

Thread Metrics:
  - Total thread count
  - Running/sleeping/blocked threads`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return commands.RunInspectMetrics(args[0], commands.InspectMetricsOptions{
				Follow:   follow,
				Interval: interval,
			})
		},
	}

	cmd.Flags().BoolVarP(&follow, "follow", "f", false, "Follow metrics in real-time")
	cmd.Flags().IntVarP(&interval, "interval", "i", 1, "Refresh interval in seconds (for --follow)")

	return cmd
}

func createInspectThreadsCmd() *cobra.Command {
	var (
		showStacks bool
		sortBy     string
	)

	cmd := &cobra.Command{
		Use:     "threads [machine-id]",
		Aliases: []string{"thread", "tasks"},
		Short:   "List process threads with detailed information",
		Long: `Displays all threads for the machine's primary process.

Shows:
  - Thread ID (TID)
  - Thread name
  - State (R=running, S=sleeping, D=blocked)
  - CPU usage per thread
  - Stack traces (with --stacks flag)

Useful for:
  - Identifying CPU-intensive threads
  - Debugging deadlocks and blocking issues
  - Understanding concurrency patterns`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return commands.RunInspectThreads(args[0], commands.InspectThreadsOptions{
				ShowStacks: showStacks,
				SortBy:     sortBy,
			})
		},
	}

	cmd.Flags().BoolVarP(&showStacks, "stacks", "s", false, "Show thread stack traces")
	cmd.Flags().StringVar(&sortBy, "sort", "tid", "Sort by: tid, name, cpu, state")

	return cmd
}

func createInspectNetworkCmd() *cobra.Command {
	var (
		listening bool
		protocol  string
	)

	cmd := &cobra.Command{
		Use:     "network [machine-id]",
		Aliases: []string{"net", "conn", "connections"},
		Short:   "Display active network connections",
		Long: `Shows all network connections for the machine.

Connection Details:
  - Local/remote addresses and ports
  - Connection state (ESTABLISHED, LISTEN, TIME_WAIT, etc.)
  - Protocol (TCP, UDP)
  - Associated inode

Filtering:
  - Show only listening ports with --listening
  - Filter by protocol with --protocol

Perfect for:
  - Debugging network connectivity issues
  - Identifying unexpected connections
  - Monitoring server endpoints`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return commands.RunInspectNetwork(args[0], commands.InspectNetworkOptions{
				Listening: listening,
				Protocol:  protocol,
			})
		},
	}

	cmd.Flags().BoolVarP(&listening, "listening", "l", false, "Show only listening ports")
	cmd.Flags().StringVarP(&protocol, "protocol", "p", "", "Filter by protocol (tcp, udp)")

	return cmd
}

func createInspectFDsCmd() *cobra.Command {
	var (
		showPaths bool
		fdType    string
	)

	cmd := &cobra.Command{
		Use:     "fds [machine-id]",
		Aliases: []string{"fd", "files", "descriptors"},
		Short:   "List open file descriptors",
		Long: `Shows all open file descriptors for the machine process.

File Descriptor Information:
  - FD number
  - Type (file, socket, pipe, device)
  - Target path or socket details
  - Soft/hard limits

Types:
  - Regular files
  - Network sockets
  - Unix sockets
  - Pipes and FIFOs
  - Character/block devices

Useful for:
  - Debugging file descriptor leaks
  - Checking resource limits
  - Understanding I/O patterns`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return commands.RunInspectFDs(args[0], commands.InspectFDsOptions{
				ShowPaths: showPaths,
				Type:      fdType,
			})
		},
	}

	cmd.Flags().BoolVarP(&showPaths, "paths", "p", false, "Show full paths for file descriptors")
	cmd.Flags().StringVarP(&fdType, "type", "t", "", "Filter by type (file, socket, pipe, device)")

	return cmd
}

func createInspectFSMCmd() *cobra.Command {
	var (
		history bool
		limit   int
		watch   bool
	)

	cmd := &cobra.Command{
		Use:     "fsm [machine-id]",
		Aliases: []string{"state", "transitions"},
		Short:   "Inspect FSM state and transition history",
		Long: `Shows the current Finite State Machine state and transition history.

FSM State Information:
  - Current state
  - Previous state
  - Transition count
  - Last transition timestamp
  - State duration
  - Breakpoints (if debug mode enabled)

Transition History:
  - From/to states
  - Event that triggered transition
  - Timestamp
  - Watch expression results

Debug Mode Features:
  - View active breakpoints
  - Inspect paused execution
  - See step-by-step transitions`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return commands.RunInspectFSM(args[0], commands.InspectFSMOptions{
				History: history,
				Limit:   limit,
				Watch:   watch,
			})
		},
	}

	cmd.Flags().BoolVar(&history, "history", false, "Show transition history")
	cmd.Flags().IntVarP(&limit, "limit", "l", 20, "Number of history entries to show")
	cmd.Flags().BoolVarP(&watch, "watch", "w", false, "Watch for state changes in real-time")

	return cmd
}

func createReplayCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "replay",
		Short: "Event replay and time-travel debugging",
		Long: `Advanced event sourcing commands for debugging and state reconstruction.

The replay command suite provides production-grade event sourcing capabilities:
  - List aggregates with event statistics
  - Show event streams for debugging
  - Reconstruct state at any point in time
  - Search events with full-text search
  - Trace distributed workflows via correlation IDs
  - Compute state diffs between versions

These commands enable powerful debugging workflows:
  1. Find aggregate → Show events → Identify issue
  2. Time-travel → Compare states → Root cause analysis
  3. Search errors → Trace correlation → Full workflow view`,
	}

	cmd.AddCommand(createReplayListCmd())
	cmd.AddCommand(createReplayShowCmd())
	cmd.AddCommand(createReplayRebuildCmd())
	cmd.AddCommand(createReplayDiffCmd())
	cmd.AddCommand(createReplaySearchCmd())
	cmd.AddCommand(createReplayTraceCmd())

	return cmd
}

func createReplayListCmd() *cobra.Command {
	var (
		jsonOutput bool
		aggType    string
	)

	cmd := &cobra.Command{
		Use:   "list",
		Short: "List aggregates with event statistics",
		Long: `Lists all aggregates in the event store with comprehensive statistics.

For each aggregate, displays:
  - Aggregate ID and type
  - Total event count
  - Latest version number
  - First and last event timestamps
  - Number of unique event types
  - Event type summary`,
		RunE: func(cmd *cobra.Command, args []string) error {
			return commands.RunReplayList(commands.ReplayListOptions{
				JSON:          jsonOutput,
				AggregateType: aggType,
			})
		},
	}

	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output in JSON format")
	cmd.Flags().StringVar(&aggType, "type", "", "Filter by aggregate type")

	return cmd
}

func createReplayShowCmd() *cobra.Command {
	var (
		jsonOutput  bool
		compact     bool
		fromVersion int
		toVersion   int
		since       string
		until       string
		eventTypes  string
		tags        string
		limit       int
	)

	cmd := &cobra.Command{
		Use:   "show [aggregate-id]",
		Short: "Show event stream for an aggregate",
		Long: `Displays the complete event stream for an aggregate with filtering options.

Events can be filtered by:
  - Version range (--from, --to)
  - Event types (--types)
  - Time range (--since, --until)
  - Tags (--tags)

Output formats:
  - Table view (default): Human-readable table
  - JSON view (--json): Full event details in JSON
  - Compact view (--compact): One line per event`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return commands.RunReplayShow(args[0], commands.ReplayShowOptions{
				JSON:        jsonOutput,
				Compact:     compact,
				FromVersion: fromVersion,
				ToVersion:   toVersion,
				Since:       since,
				Until:       until,
				EventTypes:  eventTypes,
				Tags:        tags,
				Limit:       limit,
			})
		},
	}

	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output in JSON format")
	cmd.Flags().BoolVar(&compact, "compact", false, "Compact output")
	cmd.Flags().IntVar(&fromVersion, "from", 0, "Start from version")
	cmd.Flags().IntVar(&toVersion, "to", 0, "End at version")
	cmd.Flags().StringVar(&since, "since", "", "Show events since timestamp")
	cmd.Flags().StringVar(&until, "until", "", "Show events until timestamp")
	cmd.Flags().StringVar(&eventTypes, "types", "", "Filter by event types (comma-separated)")
	cmd.Flags().StringVar(&tags, "tags", "", "Filter by tags (comma-separated)")
	cmd.Flags().IntVar(&limit, "limit", 1000, "Maximum number of events")

	return cmd
}

func createReplayRebuildCmd() *cobra.Command {
	var (
		jsonOutput  bool
		toVersion   int
		timeTravel  string
		noSnapshot  bool
		validateCmd bool
	)

	cmd := &cobra.Command{
		Use:   "rebuild [aggregate-id]",
		Short: "Reconstruct aggregate state from events",
		Long: `Rebuilds the aggregate state by replaying events from the event store.

Supports:
  - Snapshot optimization for fast replay
  - Point-in-time recovery to specific version
  - Time-travel to historical timestamp
  - State validation during reconstruction`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return commands.RunReplayRebuild(args[0], commands.ReplayRebuildOptions{
				JSON:       jsonOutput,
				ToVersion:  toVersion,
				TimeTravel: timeTravel,
				NoSnapshot: noSnapshot,
				Validate:   validateCmd,
			})
		},
	}

	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output in JSON format")
	cmd.Flags().IntVar(&toVersion, "version", 0, "Rebuild to specific version")
	cmd.Flags().StringVar(&timeTravel, "time", "", "Time-travel to timestamp (RFC3339)")
	cmd.Flags().BoolVar(&noSnapshot, "no-snapshot", false, "Disable snapshot optimization")
	cmd.Flags().BoolVar(&validateCmd, "validate", false, "Validate event stream consistency")

	return cmd
}

func createReplayDiffCmd() *cobra.Command {
	var (
		jsonOutput  bool
		fromVersion int
		toVersion   int
	)

	cmd := &cobra.Command{
		Use:   "diff [aggregate-id]",
		Short: "Compute state diff between versions",
		Long: `Computes the state difference between two versions of an aggregate.

The diff shows:
  - Fields added between versions
  - Fields removed between versions
  - Fields changed with before/after values`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return commands.RunReplayDiff(args[0], commands.ReplayDiffOptions{
				JSON:        jsonOutput,
				FromVersion: fromVersion,
				ToVersion:   toVersion,
			})
		},
	}

	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output in JSON format")
	cmd.Flags().IntVar(&fromVersion, "from", 0, "Start version (required)")
	cmd.Flags().IntVar(&toVersion, "to", 0, "End version (0 for current)")
	cmd.MarkFlagRequired("from")

	return cmd
}

func createReplaySearchCmd() *cobra.Command {
	var (
		jsonOutput bool
		eventTypes string
		limit      int
	)

	cmd := &cobra.Command{
		Use:   "search [query]",
		Short: "Search events with full-text search",
		Long: `Searches events using PostgreSQL full-text search across event data.

The search indexes:
  - Event data JSON fields
  - Event metadata
  - Tags`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return commands.RunReplaySearch(args[0], commands.ReplaySearchOptions{
				JSON:       jsonOutput,
				EventTypes: eventTypes,
				Limit:      limit,
			})
		},
	}

	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output in JSON format")
	cmd.Flags().StringVar(&eventTypes, "types", "", "Filter by event types (comma-separated)")
	cmd.Flags().IntVar(&limit, "limit", 100, "Maximum number of results")

	return cmd
}

func createReplayTraceCmd() *cobra.Command {
	var (
		jsonOutput bool
		limit      int
	)

	cmd := &cobra.Command{
		Use:   "trace [correlation-id]",
		Short: "Trace distributed workflow by correlation ID",
		Long: `Follows a distributed workflow across aggregates using correlation ID.

Shows all events that are part of the same logical workflow,
enabling end-to-end distributed tracing for debugging complex
multi-aggregate operations.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return commands.RunReplayTrace(args[0], commands.ReplayTraceOptions{
				JSON:  jsonOutput,
				Limit: limit,
			})
		},
	}

	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output in JSON format")
	cmd.Flags().IntVar(&limit, "limit", 1000, "Maximum number of events")

	return cmd
}
