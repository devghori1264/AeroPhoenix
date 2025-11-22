package formatter

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/devghori1264/aerophoenix/cli/aeropctl/pkg/client"
	"github.com/fatih/color"
	"github.com/olekukonko/tablewriter"
	"gopkg.in/yaml.v3"
)

type OutputFormat string

const (
	FormatTable OutputFormat = "table"
	FormatJSON  OutputFormat = "json"
	FormatYAML  OutputFormat = "yaml"
	FormatWide  OutputFormat = "wide"
)

type Formatter struct {
	format OutputFormat
	writer io.Writer
	colors bool
}

func NewFormatter(format OutputFormat, colors bool) *Formatter {
	return &Formatter{
		format: format,
		writer: os.Stdout,
		colors: colors && isTerminal(),
	}
}

func isTerminal() bool {
	fileInfo, _ := os.Stdout.Stat()
	return (fileInfo.Mode() & os.ModeCharDevice) != 0
}

func (f *Formatter) FormatMachines(machines []client.Machine) error {
	switch f.format {
	case FormatJSON:
		return f.formatJSON(machines)
	case FormatYAML:
		return f.formatYAML(machines)
	case FormatWide:
		return f.formatMachinesWide(machines)
	default:
		return f.formatMachinesTable(machines)
	}
}

func (f *Formatter) FormatMachine(machine *client.Machine) error {
	switch f.format {
	case FormatJSON:
		return f.formatJSON(machine)
	case FormatYAML:
		return f.formatYAML(machine)
	default:
		return f.formatMachineDetailed(machine)
	}
}

func (f *Formatter) formatMachinesTable(machines []client.Machine) error {
	if len(machines) == 0 {
		f.printColored(color.FgYellow, "No machines found\n")
		return nil
	}

	table := tablewriter.NewWriter(f.writer)
	table.SetHeader([]string{"ID", "Name", "Region", "Status", "Created"})
	table.SetBorder(false)
	table.SetHeaderLine(false)
	table.SetColumnSeparator("")
	table.SetHeaderAlignment(tablewriter.ALIGN_LEFT)
	table.SetAlignment(tablewriter.ALIGN_LEFT)

	if f.colors {
		table.SetHeaderColor(
			tablewriter.Colors{tablewriter.Bold, tablewriter.FgCyanColor},
			tablewriter.Colors{tablewriter.Bold, tablewriter.FgCyanColor},
			tablewriter.Colors{tablewriter.Bold, tablewriter.FgCyanColor},
			tablewriter.Colors{tablewriter.Bold, tablewriter.FgCyanColor},
			tablewriter.Colors{tablewriter.Bold, tablewriter.FgCyanColor},
		)
	}

	for _, m := range machines {
		status := f.colorizeStatus(m.Status)
		created := formatTime(m.CreatedAt)

		table.Append([]string{
			truncateString(m.ID, 12),
			m.Name,
			m.Region,
			status,
			created,
		})
	}

	table.Render()
	return nil
}

func (f *Formatter) formatMachinesWide(machines []client.Machine) error {
	if len(machines) == 0 {
		f.printColored(color.FgYellow, "No machines found\n")
		return nil
	}

	table := tablewriter.NewWriter(f.writer)
	table.SetHeader([]string{"ID", "Name", "Region", "Status", "Type", "Private IP", "Restarts", "Created", "Last Seen"})
	table.SetBorder(false)
	table.SetHeaderLine(false)
	table.SetColumnSeparator("  ")
	table.SetHeaderAlignment(tablewriter.ALIGN_LEFT)
	table.SetAlignment(tablewriter.ALIGN_LEFT)

	for _, m := range machines {
		table.Append([]string{
			truncateString(m.ID, 12),
			m.Name,
			m.Region,
			f.colorizeStatus(m.Status),
			m.InstanceType,
			m.PrivateIP,
			fmt.Sprintf("%d", m.RestartCount),
			formatTime(m.CreatedAt),
			formatTimeRelative(m.LastSeenAt),
		})
	}

	table.Render()
	return nil
}

func (f *Formatter) formatMachineDetailed(machine *client.Machine) error {
	f.printHeader("Machine Details")
	f.printKeyValue("ID", machine.ID)
	f.printKeyValue("Name", machine.Name)
	f.printKeyValue("Region", machine.Region)
	f.printKeyValue("Status", f.colorizeStatus(machine.Status))

	if machine.ImageRef != "" {
		f.printKeyValue("Image", machine.ImageRef)
	}
	if machine.InstanceType != "" {
		f.printKeyValue("Instance Type", machine.InstanceType)
	}
	if machine.PrivateIP != "" {
		f.printKeyValue("Private IP", machine.PrivateIP)
	}
	if machine.HealthCheckURL != "" {
		f.printKeyValue("Health Check", machine.HealthCheckURL)
	}

	f.printKeyValue("Restart Count", fmt.Sprintf("%d", machine.RestartCount))
	f.printKeyValue("Created At", formatTimeFull(machine.CreatedAt))

	if machine.UpdatedAt != "" {
		f.printKeyValue("Updated At", formatTimeFull(machine.UpdatedAt))
	}
	if machine.LastSeenAt != "" {
		f.printKeyValue("Last Seen", formatTimeRelative(machine.LastSeenAt))
	}

	if len(machine.Metadata) > 0 {
		fmt.Fprintln(f.writer)
		f.printHeader("Metadata")
		for k, v := range machine.Metadata {
			f.printKeyValue(k, fmt.Sprintf("%v", v))
		}
	}

	return nil
}

func (f *Formatter) formatJSON(data interface{}) error {
	enc := json.NewEncoder(f.writer)
	enc.SetIndent("", "  ")
	return enc.Encode(data)
}

func (f *Formatter) formatYAML(data interface{}) error {
	enc := yaml.NewEncoder(f.writer)
	defer enc.Close()
	return enc.Encode(data)
}

func (f *Formatter) FormatSuccess(message string) {
	if f.colors {
		color.New(color.FgGreen, color.Bold).Fprintf(f.writer, "✓ ")
	}
	fmt.Fprintln(f.writer, message)
}

func (f *Formatter) FormatError(err error) {
	if f.colors {
		color.New(color.FgRed, color.Bold).Fprintf(f.writer, "✗ Error: ")
		fmt.Fprintln(f.writer, err.Error())
	} else {
		fmt.Fprintf(f.writer, "Error: %v\n", err)
	}
}

func (f *Formatter) FormatWarning(message string) {
	if f.colors {
		color.New(color.FgYellow, color.Bold).Fprintf(f.writer, "⚠ ")
	}
	fmt.Fprintln(f.writer, message)
}

func (f *Formatter) FormatInfo(message string) {
	if f.colors {
		color.New(color.FgCyan).Fprintf(f.writer, "ℹ ")
	}
	fmt.Fprintln(f.writer, message)
}

func (f *Formatter) printHeader(text string) {
	if f.colors {
		color.New(color.Bold, color.Underline).Fprintln(f.writer, text)
	} else {
		fmt.Fprintln(f.writer, text)
		fmt.Fprintln(f.writer, strings.Repeat("=", len(text)))
	}
}

func (f *Formatter) printKeyValue(key, value string) {
	if f.colors {
		color.New(color.FgCyan).Fprintf(f.writer, "%-18s", key+":")
		fmt.Fprintln(f.writer, value)
	} else {
		fmt.Fprintf(f.writer, "%-18s%s\n", key+":", value)
	}
}

func (f *Formatter) printColored(c color.Attribute, format string, args ...interface{}) {
	if f.colors {
		color.New(c).Fprintf(f.writer, format, args...)
	} else {
		fmt.Fprintf(f.writer, format, args...)
	}
}

func (f *Formatter) colorizeStatus(status string) string {
	if !f.colors {
		return status
	}

	var c *color.Color
	switch strings.ToLower(status) {
	case "running":
		c = color.New(color.FgGreen, color.Bold)
	case "stopped", "suspended":
		c = color.New(color.FgYellow)
	case "error", "failed":
		c = color.New(color.FgRed, color.Bold)
	case "migrating", "starting", "stopping", "restarting":
		c = color.New(color.FgCyan)
	case "destroyed":
		c = color.New(color.FgHiBlack)
	default:
		c = color.New(color.FgWhite)
	}

	return c.Sprint(status)
}

func truncateString(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-2] + ".."
}

func formatTime(t string) string {
	if t == "" {
		return "-"
	}

	parsed, err := time.Parse(time.RFC3339, t)
	if err != nil {
		return t
	}

	return parsed.Format("2006-01-02 15:04")
}

func formatTimeFull(t string) string {
	if t == "" {
		return "-"
	}

	parsed, err := time.Parse(time.RFC3339, t)
	if err != nil {
		return t
	}

	return parsed.Format("2006-01-02 15:04:05 MST")
}

func formatTimeRelative(t string) string {
	if t == "" {
		return "-"
	}

	parsed, err := time.Parse(time.RFC3339, t)
	if err != nil {
		return t
	}

	duration := time.Since(parsed)

	switch {
	case duration < time.Minute:
		return "just now"
	case duration < time.Hour:
		mins := int(duration.Minutes())
		if mins == 1 {
			return "1 minute ago"
		}
		return fmt.Sprintf("%d minutes ago", mins)
	case duration < 24*time.Hour:
		hours := int(duration.Hours())
		if hours == 1 {
			return "1 hour ago"
		}
		return fmt.Sprintf("%d hours ago", hours)
	case duration < 7*24*time.Hour:
		days := int(duration.Hours() / 24)
		if days == 1 {
			return "1 day ago"
		}
		return fmt.Sprintf("%d days ago", days)
	default:
		return formatTime(t)
	}
}

func (f *Formatter) FormatMigrationProgress(progress *client.MigrationProgress) {
	if f.colors {
		var phaseColor *color.Color
		switch progress.Phase {
		case "preparing":
			phaseColor = color.New(color.FgYellow)
		case "snapshotting":
			phaseColor = color.New(color.FgCyan)
		case "transferring":
			phaseColor = color.New(color.FgBlue)
		case "validating":
			phaseColor = color.New(color.FgMagenta)
		case "completed":
			phaseColor = color.New(color.FgGreen, color.Bold)
		default:
			phaseColor = color.New(color.FgWhite)
		}

		phaseColor.Fprintf(f.writer, "[%s] ", progress.Phase)
		fmt.Fprintf(f.writer, "%.1f%% ", progress.ProgressPercent)

		if progress.Message != "" {
			color.New(color.FgHiBlack).Fprintf(f.writer, "- %s", progress.Message)
		}
		fmt.Fprintln(f.writer)
	} else {
		fmt.Fprintf(f.writer, "[%s] %.1f%%", progress.Phase, progress.ProgressPercent)
		if progress.Message != "" {
			fmt.Fprintf(f.writer, " - %s", progress.Message)
		}
		fmt.Fprintln(f.writer)
	}
}
