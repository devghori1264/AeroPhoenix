package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"

	"github.com/nats-io/nats.go"
)

var flydBase = "http://localhost:8080"
var natsURL = "nats://localhost:4222"

func usage() {
	fmt.Println("aeropctl commands:")
	fmt.Println("  create --name NAME --region REGION")
	fmt.Println("  get --id ID")
	fmt.Println("  ping")
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	cmd := os.Args[1]
	switch cmd {
	case "ping":
		doPing()
	case "create":
		createCmd()
	case "get":
		getCmd()
	default:
		usage()
	}
}

func doPing() {
	resp, err := http.Get(flydBase + "/ping")
	if err != nil {
		fmt.Println("error:", err)
		return
	}
	defer resp.Body.Close()
	io.Copy(os.Stdout, resp.Body)
}

func createCmd() {
	fs := flag.NewFlagSet("create", flag.ExitOnError)
	name := fs.String("name", "", "app name")
	region := fs.String("region", "us-east", "region")
	fs.Parse(os.Args[2:])
	if *name == "" {
		fmt.Println("name required")
		return
	}
	body := map[string]string{"name": *name, "region": *region}
	bs, _ := json.Marshal(body)
	resp, err := http.Post(flydBase+"/create", "application/json", bytes.NewBuffer(bs))
	if err != nil {
		fmt.Println("http error:", err)
		return
	}
	defer resp.Body.Close()
	var out map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&out)
	fmt.Printf("response: %v\n", out)

	nc, err := nats.Connect(natsURL)
	if err == nil {
		defer nc.Drain()
		ev := map[string]interface{}{"event": "cli.create", "name": *name, "region": *region}
		b, _ := json.Marshal(ev)
		_ = nc.Publish("cli.events", b)
	}
}

func getCmd() {
	fs := flag.NewFlagSet("get", flag.ExitOnError)
	id := fs.String("id", "", "machine id")
	fs.Parse(os.Args[2:])
	if *id == "" {
		fmt.Println("id required")
		return
	}
	resp, err := http.Get(flydBase + "/get?id=" + *id)
	if err != nil {
		fmt.Println("http error:", err)
		return
	}
	defer resp.Body.Close()
	var out map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&out)
	fmt.Printf("response: %v\n", out)
}
