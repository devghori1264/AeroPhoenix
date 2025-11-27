package commands

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/devghori1264/aerophoenix/cli/aeropctl/pkg/debugger"
	"github.com/fatih/color"
	"github.com/olekukonko/tablewriter"
	"golang.org/x/term"
)

type AttachOptions struct {
	Shell    string
	CWD      string
	Rows     int
	Cols     int
	NoResize bool
}

type InspectMetricsOptions struct {
	Follow   bool
	Interval int
}

type InspectThreadsOptions struct {
	ShowStacks bool
	SortBy     string
}

type InspectNetworkOptions struct {
	Listening bool
	Protocol  string
}

type InspectFDsOptions struct {
	ShowPaths bool
	Type      string
}

type InspectFSMOptions struct {
	History bool
	Limit   int
	Watch   bool
}

type Thread struct {
	TID        int      `json:"tid"`
	Name       string   `json:"name"`
	State      string   `json:"state"`
	CPUPct     float64  `json:"cpu_percent"`
	StackTrace []string `json:"stack_trace"`
}

func RunAttach(machineID string, opts AttachOptions) error {

	printAttachBanner(machineID, opts)

	rows, cols := opts.Rows, opts.Cols
	if !opts.NoResize {
		if fd := int(os.Stdout.Fd()); term.IsTerminal(fd) {
			width, height, err := term.GetSize(fd)
			if err == nil {
				rows, cols = height, width
			}
		}
	}

	client, err := debugger.NewClient(debugger.ClientConfig{
		ServerURL: globalFlags.BaseURL,
		MachineID: machineID,
		Token:     getAuthToken(),
	})
	if err != nil {
		return fmt.Errorf("failed to create debugger client: %w", err)
	}
	defer client.Close()

	if err := client.Join("shell", false); err != nil {
		return fmt.Errorf("failed to join debugger channel: %w", err)
	}

	successMsg := color.GreenString("✓") + " Connected to machine " +
		color.CyanString(machineID) + "\n"
	fmt.Fprint(os.Stderr, successMsg)
	fmt.Fprintf(os.Stderr, "Press %s to detach\n\n",
		color.YellowString("Ctrl+D"))

	return client.AttachShell(rows, cols)
}

func RunInspectMetrics(machineID string, opts InspectMetricsOptions) error {
	client, err := createDebuggerClient(machineID)
	if err != nil {
		return err
	}
	defer client.Close()

	if err := client.Join("inspect", false); err != nil {
		return fmt.Errorf("failed to join debugger channel: %w", err)
	}

	if opts.Follow {

		return streamMetrics(client, machineID, time.Duration(opts.Interval)*time.Second)
	}

	return displayMetricsSnapshot(client, machineID)
}

func RunInspectThreads(machineID string, opts InspectThreadsOptions) error {
	client, err := createDebuggerClient(machineID)
	if err != nil {
		return err
	}
	defer client.Close()

	if err := client.Join("inspect", false); err != nil {
		return err
	}

	if err := client.SendCommand("inspect.threads", nil); err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("timeout waiting for thread information")

		case msg := <-client.RecvChan():
			if msg.Event == "phx_reply" || msg.Event == "inspect.threads" {
				return displayThreads(msg.Payload, opts)
			}
		}
	}
}

func RunInspectNetwork(machineID string, opts InspectNetworkOptions) error {
	client, err := createDebuggerClient(machineID)
	if err != nil {
		return err
	}
	defer client.Close()

	if err := client.Join("inspect", false); err != nil {
		return err
	}

	if err := client.SendCommand("inspect.network", nil); err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("timeout waiting for network information")

		case msg := <-client.RecvChan():
			if msg.Event == "phx_reply" || strings.HasPrefix(msg.Event, "inspect.") {
				return displayNetworkConnections(msg.Payload, opts)
			}
		}
	}
}

func RunInspectFDs(machineID string, opts InspectFDsOptions) error {
	client, err := createDebuggerClient(machineID)
	if err != nil {
		return err
	}
	defer client.Close()

	if err := client.Join("inspect", false); err != nil {
		return err
	}

	if err := client.SendCommand("inspect.fds", nil); err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("timeout waiting for file descriptor information")

		case msg := <-client.RecvChan():
			if msg.Event == "phx_reply" || strings.HasPrefix(msg.Event, "inspect.") {
				return displayFileDescriptors(msg.Payload, opts)
			}
		}
	}
}

func RunInspectFSM(machineID string, opts InspectFSMOptions) error {
	client, err := createDebuggerClient(machineID)
	if err != nil {
		return err
	}
	defer client.Close()

	if err := client.Join("debug", false); err != nil {
		return err
	}

	if opts.Watch {
		return watchFSMState(client, machineID)
	}

	if err := client.SendCommand("debug.state", nil); err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("timeout waiting for FSM state")

		case msg := <-client.RecvChan():
			if msg.Event == "phx_reply" || msg.Event == "debug.state" {
				return displayFSMState(msg.Payload, opts)
			}
		}
	}
}

func createDebuggerClient(machineID string) (*debugger.Client, error) {
	return debugger.NewClient(debugger.ClientConfig{
		ServerURL: globalFlags.BaseURL,
		MachineID: machineID,
		Token:     getAuthToken(),
	})
}

func getAuthToken() string {

	return "debug_token_" + time.Now().Format("20060102")
}

func printAttachBanner(machineID string, opts AttachOptions) {
	banner := color.New(color.Bold, color.FgCyan)
	banner.Println("╭─────────────────────────────────────────────────────╮")
	banner.Println("│     AeroPhoenix Interactive Debugger v1.0          │")
	banner.Println("╰─────────────────────────────────────────────────────╯")
	fmt.Println()

	info := color.New(color.FgWhite)
	label := color.New(color.FgYellow)

	label.Print("  Machine ID: ")
	info.Println(machineID)

	label.Print("  Shell:      ")
	info.Println(opts.Shell)

	label.Print("  Working Dir:")
	info.Println(opts.CWD)

	label.Print("  Terminal:   ")
	info.Printf("%dx%d\n", opts.Cols, opts.Rows)

	fmt.Println()
}

func streamMetrics(client *debugger.Client, machineID string, interval time.Duration) error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	fmt.Print("\033[2J\033[H\033[?25l")
	defer fmt.Print("\033[?25h")

	return client.StreamMetrics(ctx, interval, func(metrics map[string]interface{}) {

		fmt.Print("\033[H")

		displayMetricsLive(machineID, metrics)
	})
}

func displayMetricsSnapshot(client *debugger.Client, machineID string) error {
	metrics, err := client.GetMetrics()
	if err != nil {
		return fmt.Errorf("failed to get metrics: %w", err)
	}

	return displayMetricsFormatted(machineID, metrics)
}

func displayMetricsLive(machineID string, metrics map[string]interface{}) {
	header := color.New(color.Bold, color.FgCyan)
	header.Printf("╭─ Machine Metrics: %s ─ %s ─╮\n",
		machineID, time.Now().Format("15:04:05"))
	fmt.Println()

	if cpu, ok := metrics["cpu"].(map[string]interface{}); ok {
		displayCPUMetrics(cpu)
	}

	fmt.Println()

	if mem, ok := metrics["memory"].(map[string]interface{}); ok {
		displayMemoryMetrics(mem)
	}

	fmt.Println()

	if io, ok := metrics["io"].(map[string]interface{}); ok {
		displayIOMetrics(io)
	}

	fmt.Println()

	if threads, ok := metrics["threads"].(map[string]interface{}); ok {
		displayThreadMetrics(threads)
	}

	fmt.Println()
	color.New(color.FgYellow).Println("Press Ctrl+C to exit")
}

func displayMetricsFormatted(machineID string, metrics map[string]interface{}) error {

	table := tablewriter.NewWriter(os.Stdout)
	table.SetHeader([]string{"Metric Category", "Details"})
	table.SetBorder(true)
	table.SetRowLine(true)

	if cpu, ok := metrics["cpu"].(map[string]interface{}); ok {
		cpuDetails := formatCPUDetails(cpu)
		table.Append([]string{"CPU", cpuDetails})
	}

	if mem, ok := metrics["memory"].(map[string]interface{}); ok {
		memDetails := formatMemoryDetails(mem)
		table.Append([]string{"Memory", memDetails})
	}

	if io, ok := metrics["io"].(map[string]interface{}); ok {
		ioDetails := formatIODetails(io)
		table.Append([]string{"I/O", ioDetails})
	}

	if net, ok := metrics["network"].(map[string]interface{}); ok {
		netDetails := formatNetworkDetails(net)
		table.Append([]string{"Network", netDetails})
	}

	if fds, ok := metrics["file_descriptors"].(map[string]interface{}); ok {
		fdDetails := formatFDDetails(fds)
		table.Append([]string{"File Descriptors", fdDetails})
	}

	table.Render()
	return nil
}

func displayCPUMetrics(cpu map[string]interface{}) {
	section := color.New(color.Bold, color.FgGreen)
	section.Println("CPU Metrics:")

	usage := getFloat(cpu, "usage_percent")
	userPct := getFloat(cpu, "user_percent")
	systemPct := getFloat(cpu, "system_percent")
	cores := getInt(cpu, "cores")

	fmt.Printf("  Total Usage:  %s\n", colorizePercentage(usage))
	fmt.Printf("  User:         %s\n", colorizePercentage(userPct))
	fmt.Printf("  System:       %s\n", colorizePercentage(systemPct))
	fmt.Printf("  Cores:        %d\n", cores)

	if loadAvg, ok := cpu["load_average"].([]interface{}); ok && len(loadAvg) >= 3 {
		fmt.Printf("  Load Avg:     %.2f, %.2f, %.2f\n",
			getFloatFromInterface(loadAvg[0]),
			getFloatFromInterface(loadAvg[1]),
			getFloatFromInterface(loadAvg[2]))
	}

	if throttled, ok := cpu["throttled"].(bool); ok && throttled {
		color.New(color.FgRed, color.Bold).Println("  ⚠ CPU THROTTLED")
	}
}

func displayMemoryMetrics(mem map[string]interface{}) {
	section := color.New(color.Bold, color.FgBlue)
	section.Println("Memory Metrics:")

	rss := getInt64(mem, "rss_bytes")
	vsz := getInt64(mem, "vsz_bytes")
	swap := getInt64(mem, "swap_bytes")
	pageFaults := getInt64(mem, "page_faults")

	fmt.Printf("  RSS:          %s\n", formatBytes(rss))
	fmt.Printf("  VSZ:          %s\n", formatBytes(vsz))
	fmt.Printf("  Swap:         %s\n", formatBytes(swap))
	fmt.Printf("  Page Faults:  %s\n", formatNumber(pageFaults))

	if limit, ok := mem["cgroup_limit_bytes"].(float64); ok && limit > 0 {
		fmt.Printf("  Memory Limit: %s\n", formatBytes(int64(limit)))
		usagePct := (float64(rss) / limit) * 100
		fmt.Printf("  Usage:        %s\n", colorizePercentage(usagePct))
	}

	oomScore := getInt(mem, "oom_score")
	if oomScore > 500 {
		color.New(color.FgRed, color.Bold).Printf("  OOM Score:    %d (HIGH RISK)\n", oomScore)
	} else {
		fmt.Printf("  OOM Score:    %d\n", oomScore)
	}
}

func displayIOMetrics(io map[string]interface{}) {
	section := color.New(color.Bold, color.FgMagenta)
	section.Println("I/O Metrics:")

	readBytes := getInt64(io, "read_bytes")
	writeBytes := getInt64(io, "write_bytes")
	readOps := getInt64(io, "read_ops")
	writeOps := getInt64(io, "write_ops")

	fmt.Printf("  Read:         %s (%s ops)\n",
		formatBytes(readBytes), formatNumber(readOps))
	fmt.Printf("  Write:        %s (%s ops)\n",
		formatBytes(writeBytes), formatNumber(writeOps))
}

func displayThreadMetrics(threads map[string]interface{}) {
	section := color.New(color.Bold, color.FgYellow)
	section.Println("Thread Metrics:")

	total := getInt(threads, "count")
	running := getInt(threads, "running")
	sleeping := getInt(threads, "sleeping")
	blocked := getInt(threads, "blocked")

	fmt.Printf("  Total:        %d\n", total)
	fmt.Printf("  Running:      %s\n", colorizeThreadState("R", running))
	fmt.Printf("  Sleeping:     %s\n", colorizeThreadState("S", sleeping))
	if blocked > 0 {
		fmt.Printf("  Blocked:      %s\n", colorizeThreadState("D", blocked))
	}
}

func displayThreads(payload map[string]interface{}, opts InspectThreadsOptions) error {
	threadsData, ok := payload["threads"].([]interface{})
	if !ok {
		return fmt.Errorf("invalid thread data format")
	}

	var threads []Thread
	for _, t := range threadsData {
		data, _ := json.Marshal(t)
		var thread Thread
		if err := json.Unmarshal(data, &thread); err == nil {
			threads = append(threads, thread)
		}
	}

	sortThreads(threads, opts.SortBy)

	table := tablewriter.NewWriter(os.Stdout)
	headers := []string{"TID", "Name", "State", "CPU %"}
	if opts.ShowStacks {
		headers = append(headers, "Stack Trace")
	}
	table.SetHeader(headers)
	table.SetBorder(true)

	for _, thread := range threads {
		row := []string{
			fmt.Sprintf("%d", thread.TID),
			thread.Name,
			colorizeState(thread.State),
			fmt.Sprintf("%.2f%%", thread.CPUPct),
		}

		if opts.ShowStacks && len(thread.StackTrace) > 0 {
			stack := strings.Join(thread.StackTrace[:min(3, len(thread.StackTrace))], "\n")
			row = append(row, stack)
		}

		table.Append(row)
	}

	table.Render()
	return nil
}

func displayNetworkConnections(payload map[string]interface{}, opts InspectNetworkOptions) error {
	connsData, ok := payload["connections"].([]interface{})
	if !ok {
		return fmt.Errorf("invalid network data format")
	}

	table := tablewriter.NewWriter(os.Stdout)
	table.SetHeader([]string{"Protocol", "Local Address", "Remote Address", "State"})
	table.SetBorder(true)

	for _, c := range connsData {
		conn, ok := c.(map[string]interface{})
		if !ok {
			continue
		}

		protocol := getString(conn, "protocol")
		if opts.Protocol != "" && !strings.EqualFold(protocol, opts.Protocol) {
			continue
		}

		state := getString(conn, "state")
		if opts.Listening && state != "LISTEN" {
			continue
		}

		localAddr := fmt.Sprintf("%s:%d",
			getString(conn, "local_addr"),
			getInt(conn, "local_port"))
		remoteAddr := fmt.Sprintf("%s:%d",
			getString(conn, "remote_addr"),
			getInt(conn, "remote_port"))

		table.Append([]string{
			strings.ToUpper(protocol),
			localAddr,
			remoteAddr,
			colorizeConnectionState(state),
		})
	}

	table.Render()
	return nil
}

func displayFileDescriptors(payload map[string]interface{}, opts InspectFDsOptions) error {
	fdsData, ok := payload["file_descriptors"].([]interface{})
	if !ok {
		return fmt.Errorf("invalid file descriptor data format")
	}

	table := tablewriter.NewWriter(os.Stdout)
	headers := []string{"FD", "Type"}
	if opts.ShowPaths {
		headers = append(headers, "Target")
	}
	table.SetHeader(headers)
	table.SetBorder(true)

	for _, f := range fdsData {
		fd, ok := f.(map[string]interface{})
		if !ok {
			continue
		}

		fdType := getString(fd, "type")
		if opts.Type != "" && !strings.EqualFold(fdType, opts.Type) {
			continue
		}

		row := []string{
			fmt.Sprintf("%d", getInt(fd, "fd")),
			colorizeFDType(fdType),
		}

		if opts.ShowPaths {
			row = append(row, getString(fd, "target"))
		}

		table.Append(row)
	}

	if summary, ok := payload["types"].(map[string]interface{}); ok {
		fmt.Println("\nSummary:")
		fmt.Printf("  Files:   %d\n", getInt(summary, "files"))
		fmt.Printf("  Sockets: %d\n", getInt(summary, "sockets"))
		fmt.Printf("  Pipes:   %d\n", getInt(summary, "pipes"))
		fmt.Printf("  Other:   %d\n", getInt(summary, "other"))
	}

	fmt.Println()
	table.Render()
	return nil
}

func displayFSMState(payload map[string]interface{}, opts InspectFSMOptions) error {
	state, ok := payload["state"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("invalid FSM state format")
	}

	header := color.New(color.Bold, color.FgCyan)
	header.Println("╭─ FSM State ─╮")
	fmt.Println()

	currentState := getString(state, "current_state")
	prevState := getString(state, "previous_state")

	fmt.Printf("  Current:  %s\n", colorizeState(currentState))
	fmt.Printf("  Previous: %s\n", colorizeState(prevState))

	if paused, ok := state["paused"].(bool); ok && paused {
		color.New(color.FgRed, color.Bold).Println("  Status:   ⏸ PAUSED")
	}

	if breakpoints, ok := state["breakpoints"].([]interface{}); ok && len(breakpoints) > 0 {
		fmt.Println("\n  Breakpoints:")
		for _, bp := range breakpoints {
			if bpMap, ok := bp.(map[string]interface{}); ok {
				bpState := getString(bpMap, "state")
				enabled := getBool(bpMap, "enabled")
				hitCount := getInt(bpMap, "hit_count")

				status := "✓"
				if !enabled {
					status = "✗"
				}

				fmt.Printf("    %s %s (hits: %d)\n", status, bpState, hitCount)
			}
		}
	}

	if opts.History {
		if history, ok := state["recent_transitions"].([]interface{}); ok && len(history) > 0 {
			fmt.Println("\n  Recent Transitions:")
			table := tablewriter.NewWriter(os.Stdout)
			table.SetHeader([]string{"Timestamp", "From", "To", "Event"})
			table.SetBorder(false)

			limit := min(opts.Limit, len(history))
			for i := 0; i < limit; i++ {
				if trans, ok := history[i].(map[string]interface{}); ok {
					table.Append([]string{
						getString(trans, "timestamp"),
						getString(trans, "from"),
						getString(trans, "to"),
						getString(trans, "event"),
					})
				}
			}

			table.Render()
		}
	}

	return nil
}

func watchFSMState(client *debugger.Client, machineID string) error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	fmt.Println("Watching FSM state changes... (Press Ctrl+C to exit)")

	for {
		select {
		case <-ctx.Done():
			return nil

		case msg := <-client.RecvChan():
			switch msg.Event {
			case "debug.breakpoint_hit":
				state := getString(msg.Payload, "state")
				color.New(color.FgRed, color.Bold).Printf("[%s] Breakpoint hit: %s\n",
					time.Now().Format("15:04:05"), state)

			case "debug.execution_continued":
				color.New(color.FgGreen).Printf("[%s] Execution resumed\n",
					time.Now().Format("15:04:05"))

			case "session.mode_changed":
				mode := getString(msg.Payload, "mode")
				fmt.Printf("[%s] Mode changed to: %s\n",
					time.Now().Format("15:04:05"), mode)
			}
		}
	}
}

func sortThreads(threads []Thread, sortBy string) {
	switch sortBy {
	case "cpu":
		sort.Slice(threads, func(i, j int) bool {
			return threads[i].CPUPct > threads[j].CPUPct
		})
	case "name":
		sort.Slice(threads, func(i, j int) bool {
			return threads[i].Name < threads[j].Name
		})
	case "state":
		sort.Slice(threads, func(i, j int) bool {
			return threads[i].State < threads[j].State
		})
	default:
		sort.Slice(threads, func(i, j int) bool {
			return threads[i].TID < threads[j].TID
		})
	}
}

func colorizePercentage(pct float64) string {
	value := fmt.Sprintf("%.1f%%", pct)
	switch {
	case pct >= 90:
		return color.RedString(value)
	case pct >= 70:
		return color.YellowString(value)
	default:
		return color.GreenString(value)
	}
}

func colorizeState(state string) string {
	colors := map[string]*color.Color{
		"running":   color.New(color.FgGreen, color.Bold),
		"stopped":   color.New(color.FgRed),
		"starting":  color.New(color.FgYellow),
		"migrating": color.New(color.FgCyan),
		"R":         color.New(color.FgGreen),
		"S":         color.New(color.FgWhite),
		"D":         color.New(color.FgRed),
	}

	if c, ok := colors[state]; ok {
		return c.Sprint(state)
	}
	return state
}

func colorizeThreadState(state string, count int) string {
	value := fmt.Sprintf("%d", count)
	switch state {
	case "R":
		return color.GreenString(value)
	case "D":
		return color.RedString(value)
	default:
		return value
	}
}

func colorizeConnectionState(state string) string {
	colors := map[string]*color.Color{
		"ESTABLISHED": color.New(color.FgGreen),
		"LISTEN":      color.New(color.FgCyan),
		"TIME_WAIT":   color.New(color.FgYellow),
		"CLOSE_WAIT":  color.New(color.FgRed),
	}

	if c, ok := colors[state]; ok {
		return c.Sprint(state)
	}
	return state
}

func colorizeFDType(fdType string) string {
	colors := map[string]*color.Color{
		"file":   color.New(color.FgWhite),
		"socket": color.New(color.FgCyan),
		"pipe":   color.New(color.FgYellow),
		"device": color.New(color.FgMagenta),
	}

	if c, ok := colors[fdType]; ok {
		return c.Sprint(fdType)
	}
	return fdType
}

func formatBytes(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(bytes)/float64(div), "KMGTPE"[exp])
}

func formatNumber(n int64) string {
	if n < 1000 {
		return fmt.Sprintf("%d", n)
	}
	if n < 1000000 {
		return fmt.Sprintf("%.1fK", float64(n)/1000)
	}
	if n < 1000000000 {
		return fmt.Sprintf("%.1fM", float64(n)/1000000)
	}
	return fmt.Sprintf("%.1fG", float64(n)/1000000000)
}

func formatCPUDetails(cpu map[string]interface{}) string {
	usage := getFloat(cpu, "usage_percent")
	cores := getInt(cpu, "cores")
	return fmt.Sprintf("%.1f%% (%d cores)", usage, cores)
}

func formatMemoryDetails(mem map[string]interface{}) string {
	rss := getInt64(mem, "rss_bytes")
	return formatBytes(rss)
}

func formatIODetails(io map[string]interface{}) string {
	readBytes := getInt64(io, "read_bytes")
	writeBytes := getInt64(io, "write_bytes")
	return fmt.Sprintf("R: %s, W: %s", formatBytes(readBytes), formatBytes(writeBytes))
}

func formatNetworkDetails(net map[string]interface{}) string {
	connections := getInt(net, "connections")
	established := getInt(net, "established")
	return fmt.Sprintf("%d total, %d established", connections, established)
}

func formatFDDetails(fds map[string]interface{}) string {
	open := getInt(fds, "open")
	limit := getInt(fds, "limit_soft")
	return fmt.Sprintf("%d / %d", open, limit)
}

func getFloat(m map[string]interface{}, key string) float64 {
	if v, ok := m[key].(float64); ok {
		return v
	}
	return 0
}

func getFloatFromInterface(v interface{}) float64 {
	if f, ok := v.(float64); ok {
		return f
	}
	return 0
}

func getInt(m map[string]interface{}, key string) int {
	if v, ok := m[key].(float64); ok {
		return int(v)
	}
	return 0
}

func getInt64(m map[string]interface{}, key string) int64 {
	if v, ok := m[key].(float64); ok {
		return int64(v)
	}
	return 0
}

func getString(m map[string]interface{}, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

func getBool(m map[string]interface{}, key string) bool {
	if v, ok := m[key].(bool); ok {
		return v
	}
	return false
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
