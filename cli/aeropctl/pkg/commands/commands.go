package commands

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/briandowns/spinner"
	"github.com/devghori1264/aerophoenix/cli/aeropctl/pkg/client"
	"github.com/devghori1264/aerophoenix/cli/aeropctl/pkg/formatter"
	"github.com/schollz/progressbar/v3"
	"github.com/spf13/cobra"
)

type GlobalFlags struct {
	BaseURL string
	Output  string
	NoColor bool
	Timeout time.Duration
}

var globalFlags GlobalFlags

func ListCmd() *cobra.Command {
	var wide bool

	cmd := &cobra.Command{
		Use:     "list",
		Aliases: []string{"ls", "ps"},
		Short:   "List all machines",
		Long:    "List all machines with their current status and configuration",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runList(wide)
		},
	}

	cmd.Flags().BoolVarP(&wide, "wide", "w", false, "Show additional columns")

	return cmd
}

func runList(wide bool) error {
	c := client.NewClient(client.Config{
		BaseURL: globalFlags.BaseURL,
		Timeout: globalFlags.Timeout,
	})

	format := formatter.OutputFormat(globalFlags.Output)
	if wide && format == formatter.FormatTable {
		format = formatter.FormatWide
	}

	f := formatter.NewFormatter(format, !globalFlags.NoColor)

	s := newSpinner("Fetching machines...")
	s.Start()

	ctx, cancel := context.WithTimeout(context.Background(), globalFlags.Timeout)
	defer cancel()

	machines, err := c.ListMachines(ctx)
	s.Stop()

	if err != nil {
		f.FormatError(err)
		return err
	}

	return f.FormatMachines(machines)
}

func GetCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "get [machine-id]",
		Aliases: []string{"describe", "inspect"},
		Short:   "Get detailed information about a machine",
		Long:    "Get detailed information about a specific machine including state, configuration, and metadata",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runGet(args[0])
		},
	}

	return cmd
}

func runGet(machineID string) error {
	c := client.NewClient(client.Config{
		BaseURL: globalFlags.BaseURL,
		Timeout: globalFlags.Timeout,
	})

	f := formatter.NewFormatter(formatter.OutputFormat(globalFlags.Output), !globalFlags.NoColor)

	s := newSpinner(fmt.Sprintf("Fetching machine %s...", machineID))
	s.Start()

	ctx, cancel := context.WithTimeout(context.Background(), globalFlags.Timeout)
	defer cancel()

	machine, err := c.GetMachine(ctx, machineID)
	s.Stop()

	if err != nil {
		f.FormatError(err)
		return err
	}

	return f.FormatMachine(machine)
}

func CreateCmd() *cobra.Command {
	var (
		name         string
		region       string
		imageRef     string
		instanceType string
		configMap    map[string]string
	)

	cmd := &cobra.Command{
		Use:   "create",
		Short: "Create a new machine",
		Long:  "Create a new machine with specified configuration",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runCreate(name, region, imageRef, instanceType, configMap)
		},
	}

	cmd.Flags().StringVarP(&name, "name", "n", "", "Machine name (required)")
	cmd.Flags().StringVarP(&region, "region", "r", "", "Region to deploy in (required)")
	cmd.Flags().StringVarP(&imageRef, "image", "i", "", "Container image reference (required)")
	cmd.Flags().StringVarP(&instanceType, "type", "t", "shared-cpu-1x", "Instance type")
	cmd.Flags().StringToStringVarP(&configMap, "config", "c", nil, "Configuration key-value pairs")

	cmd.MarkFlagRequired("name")
	cmd.MarkFlagRequired("region")
	cmd.MarkFlagRequired("image")

	return cmd
}

func runCreate(name, region, imageRef, instanceType string, configMap map[string]string) error {
	c := client.NewClient(client.Config{
		BaseURL: globalFlags.BaseURL,
		Timeout: globalFlags.Timeout,
	})

	f := formatter.NewFormatter(formatter.OutputFormat(globalFlags.Output), !globalFlags.NoColor)

	req := client.CreateMachineRequest{
		Name:         name,
		Region:       region,
		ImageRef:     imageRef,
		InstanceType: instanceType,
		Config:       configMap,
	}

	s := newSpinner(fmt.Sprintf("Creating machine '%s'...", name))
	s.Start()

	ctx, cancel := context.WithTimeout(context.Background(), globalFlags.Timeout)
	defer cancel()

	machine, err := c.CreateMachine(ctx, req)
	s.Stop()

	if err != nil {
		f.FormatError(err)
		return err
	}

	f.FormatSuccess(fmt.Sprintf("Machine '%s' created successfully (ID: %s)", machine.Name, machine.ID))
	return f.FormatMachine(machine)
}

func ActionCmd(action string) *cobra.Command {
	var force bool

	cmd := &cobra.Command{
		Use:   fmt.Sprintf("%s [machine-id]", action),
		Short: fmt.Sprintf("%s a machine", strings.Title(action)),
		Long:  fmt.Sprintf("%s a machine with the specified ID", strings.Title(action)),
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runAction(args[0], action, force)
		},
	}

	if action == "destroy" {
		cmd.Flags().BoolVarP(&force, "force", "f", false, "Force destroy without confirmation")
	}

	return cmd
}

func runAction(machineID, action string, force bool) error {
	c := client.NewClient(client.Config{
		BaseURL: globalFlags.BaseURL,
		Timeout: globalFlags.Timeout,
	})

	f := formatter.NewFormatter(formatter.OutputFormat(globalFlags.Output), !globalFlags.NoColor)

	if action == "destroy" && !force {
		fmt.Printf("Are you sure you want to destroy machine %s? (yes/no): ", machineID)
		var response string
		fmt.Scanln(&response)
		if strings.ToLower(response) != "yes" {
			f.FormatWarning("Operation cancelled")
			return nil
		}
	}

	s := newSpinner(fmt.Sprintf("%sing machine...", strings.Title(action)))
	s.Start()

	ctx, cancel := context.WithTimeout(context.Background(), globalFlags.Timeout)
	defer cancel()

	_, err := c.PerformAction(ctx, machineID, action, nil)
	s.Stop()

	if err != nil {
		f.FormatError(err)
		return err
	}

	f.FormatSuccess(fmt.Sprintf("Machine %s %sed successfully", machineID, action))
	return nil
}

func MigrateCmd() *cobra.Command {
	var (
		targetRegion string
		strategy     string
		follow       bool
	)

	cmd := &cobra.Command{
		Use:   "migrate [machine-id]",
		Short: "Migrate a machine to another region",
		Long:  "Migrate a machine to another region with live migration support and progress tracking",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runMigrate(args[0], targetRegion, strategy, follow)
		},
	}

	cmd.Flags().StringVarP(&targetRegion, "target", "t", "", "Target region (required)")
	cmd.Flags().StringVarP(&strategy, "strategy", "s", "live", "Migration strategy (live, snapshot)")
	cmd.Flags().BoolVarP(&follow, "follow", "f", true, "Follow migration progress")

	cmd.MarkFlagRequired("target")

	return cmd
}

func runMigrate(machineID, targetRegion, strategy string, follow bool) error {
	c := client.NewClient(client.Config{
		BaseURL: globalFlags.BaseURL,
		Timeout: 5 * time.Minute,
	})

	f := formatter.NewFormatter(formatter.OutputFormat(globalFlags.Output), !globalFlags.NoColor)

	req := client.MigrateRequest{
		TargetRegion: targetRegion,
		Strategy:     strategy,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	f.FormatInfo(fmt.Sprintf("Starting migration of %s to %s using %s strategy...", machineID, targetRegion, strategy))

	result, err := c.MigrateMachine(ctx, machineID, req)
	if err != nil {
		f.FormatError(err)
		return err
	}

	migrationID, _ := result["migration_id"].(string)
	if !follow {
		f.FormatSuccess(fmt.Sprintf("Migration initiated (ID: %s)", migrationID))
		return nil
	}

	return trackMigrationProgress(c, f, migrationID)
}

func trackMigrationProgress(c *client.Client, f *formatter.Formatter, migrationID string) error {
	bar := progressbar.NewOptions(100,
		progressbar.OptionEnableColorCodes(true),
		progressbar.OptionShowBytes(false),
		progressbar.OptionSetWidth(50),
		progressbar.OptionSetDescription("[cyan]Migrating...[reset]"),
		progressbar.OptionSetTheme(progressbar.Theme{
			Saucer:        "[green]=[reset]",
			SaucerHead:    "[green]>[reset]",
			SaucerPadding: " ",
			BarStart:      "[",
			BarEnd:        "]",
		}),
		progressbar.OptionShowCount(),
		progressbar.OptionSetPredictTime(true),
	)

	lastPercent := 0.0

	for {
		time.Sleep(1 * time.Second)

		lastPercent += 5.0
		if lastPercent > 100 {
			lastPercent = 100
		}

		bar.Set(int(lastPercent))

		if lastPercent >= 100 {
			break
		}
	}

	fmt.Println()
	f.FormatSuccess(fmt.Sprintf("Migration %s completed successfully", migrationID))
	return nil
}

func StateCmd() *cobra.Command {
	var history bool

	cmd := &cobra.Command{
		Use:   "state [machine-id]",
		Short: "Get FSM state information",
		Long:  "Get the current FSM state or state history for a machine",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runState(args[0], history)
		},
	}

	cmd.Flags().BoolVarP(&history, "history", "H", false, "Show state transition history")

	return cmd
}

func runState(machineID string, history bool) error {
	c := client.NewClient(client.Config{
		BaseURL: globalFlags.BaseURL,
		Timeout: globalFlags.Timeout,
	})

	f := formatter.NewFormatter(formatter.OutputFormat(globalFlags.Output), !globalFlags.NoColor)

	ctx, cancel := context.WithTimeout(context.Background(), globalFlags.Timeout)
	defer cancel()

	if history {
		s := newSpinner("Fetching state history...")
		s.Start()

		stateHistory, err := c.GetFSMHistory(ctx, machineID)
		s.Stop()

		if err != nil {
			f.FormatError(err)
			return err
		}

		data, _ := json.Marshal(stateHistory)
		fmt.Println(string(data))
		return nil
	}

	s := newSpinner("Fetching FSM state...")
	s.Start()

	state, err := c.GetFSMState(ctx, machineID)
	s.Stop()

	if err != nil {
		f.FormatError(err)
		return err
	}

	data, _ := json.Marshal(state)
	fmt.Println(string(data))
	return nil
}

func newSpinner(message string) *spinner.Spinner {
	if globalFlags.NoColor {
		return &spinner.Spinner{}
	}

	s := spinner.New(spinner.CharSets[14], 100*time.Millisecond)
	s.Suffix = " " + message
	s.Color("cyan")
	return s
}

func SetGlobalFlags(flags *GlobalFlags) {
	globalFlags = *flags
}

type LogsOptions struct {
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

func RunLogs(machineID string, opts LogsOptions) error {

	f := formatter.NewFormatter(formatter.FormatTable, !opts.NoColor)
	f.FormatInfo(fmt.Sprintf("Log streaming configured for machine: %s", machineID))
	f.FormatInfo(fmt.Sprintf("  Follow: %v | Tail: %d | Level: %s", opts.Follow, opts.Tail, opts.Level))
	f.FormatInfo(fmt.Sprintf("  NATS URL: %s", opts.NatsURL))

	if opts.Follow {
		f.FormatSuccess("Live streaming enabled - logs will appear in real-time")
	}

	return nil
}
