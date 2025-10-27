package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/spf13/cobra"
	"go.uber.org/zap"
)

var (
	logger  *zap.SugaredLogger
	natsURL string
	orchURL string
)

func main() {
	zl, _ := zap.NewProduction()
	defer zl.Sync()
	logger = zl.Sugar()

	root := &cobra.Command{
		Use:   "aeropctl",
		Short: "AeroPhoenix CLI — control & observe machines",
		PersistentPreRun: func(cmd *cobra.Command, args []string) {
			natsURL = os.Getenv("NATS_URL")
			if natsURL == "" {
				natsURL = "nats://localhost:4222"
			}
			orchURL = os.Getenv("ORCHESTRATOR_URL")
			if orchURL == "" {
				orchURL = "http://localhost:4001"
			}
		},
	}

	root.AddCommand(listCmd())
	root.AddCommand(inspectCmd())
	root.AddCommand(tailCmd())

	if err := root.Execute(); err != nil {
		logger.Fatalf("command failed: %v", err)
	}
}

func listCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List machines from Orchestrator",
		Run: func(cmd *cobra.Command, args []string) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := doList(ctx); err != nil {
				logger.Errorf("list failed: %v", err)
				os.Exit(1)
			}
		},
	}
}

func doList(ctx context.Context) error {
	reqURL := fmt.Sprintf("%s/api/v1/machines", orchURL)
	logger.Infof("Fetching %s", reqURL)
	reqCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(reqCtx, "GET", reqURL, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("unexpected status %d", resp.StatusCode)
	}
	var machines []map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&machines); err != nil {
		return err
	}
	for _, m := range machines {
		fmt.Printf("%s\t%s\t%s\n", m["id"], m["name"], m["region"])
	}
	return nil
}

func inspectCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "inspect [id]",
		Short: "Fetch detailed info for a machine",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			id := args[0]
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := doInspect(ctx, id); err != nil {
				logger.Errorf("inspect failed: %v", err)
				os.Exit(1)
			}
		},
	}
}

func doInspect(ctx context.Context, id string) error {
	reqURL := fmt.Sprintf("%s/api/v1/machines/%s", orchURL, id)
	reqCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(reqCtx, "GET", reqURL, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("unexpected status %d", resp.StatusCode)
	}
	var machine map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&machine); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(machine, "", "  ")
	fmt.Println(string(b))
	return nil
}

func tailCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "tail",
		Short: "Tail live machine events & UI actions via NATS",
		Run: func(cmd *cobra.Command, args []string) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			c := make(chan os.Signal, 1)
			signal.Notify(c, os.Interrupt)
			go func() {
				<-c
				cancel()
			}()
			if err := doTail(ctx); err != nil {
				logger.Errorf("tail failed: %v", err)
				os.Exit(1)
			}
		},
	}
}

func doTail(ctx context.Context) error {
	nc, err := nats.Connect(natsURL)
	if err != nil {
		return err
	}
	defer nc.Drain()

	//js, _ := nc.JetStream()
	mch := make(chan *nats.Msg, 128)
	_, err = nc.ChanSubscribe("machines.events", mch)
	if err != nil {
		return err
	}
	_, err = nc.ChanSubscribe("ui.actions", mch)
	if err != nil {
		return err
	}

	logger.Infof("Listening for machines.events and ui.actions on %s", natsURL)
	for {
		select {
		case <-ctx.Done():
			return nil
		case msg := <-mch:
			fmt.Printf("[%s] %s\n", msg.Subject, string(msg.Data))
		}
	}
}
