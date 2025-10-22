package tests

import (
	"context"
	"os"
	"testing"
	"time"

	proto "github.com/devghori1264/aerophoenix/flyd-sim/internal/proto"
	"github.com/devghori1264/aerophoenix/flyd-sim/internal/server"
	"github.com/devghori1264/aerophoenix/flyd-sim/internal/storage"
)

func TestCreateStartStopSequence(t *testing.T) {
	path := "./testdata/badger"
	os.RemoveAll(path)
	store, err := storage.NewBadgerStore(path)
	if err != nil {
		t.Fatalf("open badger: %v", err)
	}
	defer store.Close()

	s := server.New(store)
	ctx := context.Background()
	// create
	createRes, err := s.CreateMachine(ctx, &proto.CreateRequest{Name: "web", Region: "eu"})
	if err != nil {
		t.Fatalf("create err: %v", err)
	}
	id := createRes.Id
	// wait for startup simulation
	time.Sleep(700 * time.Millisecond)
	// get
	gRes, err := s.GetMachine(ctx, &proto.GetRequest{Id: id})
	if err != nil {
		t.Fatalf("get err: %v", err)
	}
	if gRes.Status != "running" {
		t.Fatalf("expected running got %s", gRes.Status)
	}
	// stop
	_, err = s.StopMachine(ctx, &proto.ActionRequest{Id: id})
	if err != nil {
		t.Fatalf("stop err: %v", err)
	}
	// fetch and check stopped
	gr, _ := s.GetMachine(ctx, &proto.GetRequest{Id: id})
	if gr.Status != "stopped" {
		t.Fatalf("expected stopped got %s", gr.Status)
	}
}
