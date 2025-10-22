package server

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/devghori1264/aerophoenix/flyd-sim/internal/models"
	proto "github.com/devghori1264/aerophoenix/flyd-sim/internal/proto"
	"github.com/devghori1264/aerophoenix/flyd-sim/internal/storage"
	"github.com/google/uuid"
	"google.golang.org/grpc"
)

// Server implements the machine service and orchestrates FSMs.
type Server struct {
	proto.UnimplementedMachineServiceServer
	store storage.Store
	mu    sync.RWMutex
	// in-memory cache of machines to avoid hot DB on reads; persisted in store.
	cache map[string]*models.Machine
	// operations mutex per machine id
	opMu sync.Map
}

// New creates a new server instance.
func New(store storage.Store) *Server {
	return &Server{
		store: store,
		cache: make(map[string]*models.Machine),
	}
}

// RegisterGRPC registers the gRPC handlers.
func (s *Server) RegisterGRPC(gs *grpc.Server) {
	proto.RegisterMachineServiceServer(gs, s)
}

// ---------- gRPC handlers ----------

// Ping handler (for connectivity test)
func (s *Server) Ping(ctx context.Context, req *proto.PingRequest) (*proto.PingResponse, error) {
	return &proto.PingResponse{Msg: "pong from flyd-sim"}, nil
}

// CreateMachine creates a new simulated machine.
func (s *Server) CreateMachine(ctx context.Context, req *proto.CreateRequest) (*proto.CreateResponse, error) {
	if req.Name == "" {
		return nil, errors.New("name required")
	}
	if req.Region == "" {
		return nil, errors.New("region required")
	}

	m := &models.Machine{
		ID:        uuid.NewString(),
		Name:      req.Name,
		Region:    req.Region,
		Status:    "pending",
		Version:   1,
		CreatedAt: time.Now().UTC(),
		UpdatedAt: time.Now().UTC(),
		Metadata:  map[string]string{},
	}

	if err := s.store.SaveMachine(ctx, m); err != nil {
		return nil, fmt.Errorf("save: %w", err)
	}

	// spawn background startup routine
	go s.transitionToRunning(m.ID)

	return &proto.CreateResponse{Id: m.ID, Status: m.Status}, nil
}

// GetMachine fetches a machine by ID.
func (s *Server) GetMachine(ctx context.Context, req *proto.GetRequest) (*proto.GetResponse, error) {
	m, err := s.getMachineCached(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	return &proto.GetResponse{Id: m.ID, Status: m.Status}, nil
}

// StartMachine sets a machine’s status to running.
func (s *Server) StartMachine(ctx context.Context, req *proto.ActionRequest) (*proto.ActionResponse, error) {
	if req.Id == "" {
		return nil, errors.New("id required")
	}
	return s.performAction(ctx, req.Id, "start")
}

// StopMachine sets a machine’s status to stopped.
func (s *Server) StopMachine(ctx context.Context, req *proto.ActionRequest) (*proto.ActionResponse, error) {
	if req.Id == "" {
		return nil, errors.New("id required")
	}
	return s.performAction(ctx, req.Id, "stop")
}

// performAction is idempotent and guarded per-machine.
func (s *Server) performAction(ctx context.Context, id, action string) (*proto.ActionResponse, error) {
	_ = s.acquireOpLock(id)
	defer s.releaseOpLock(id)

	m, err := s.getMachineCached(ctx, id)
	if err != nil {
		return nil, err
	}

	switch action {
	case "start":
		if m.Status == "running" {
			return &proto.ActionResponse{Result: "already running"}, nil
		}
		m.Status = "running"
	case "stop":
		if m.Status == "stopped" {
			return &proto.ActionResponse{Result: "already stopped"}, nil
		}
		m.Status = "stopped"
	default:
		return nil, errors.New("unknown action")
	}

	m.Version++
	m.UpdatedAt = time.Now().UTC()

	if err := s.store.SaveMachine(ctx, m); err != nil {
		return nil, err
	}

	s.mu.Lock()
	s.cache[m.ID] = m
	s.mu.Unlock()

	return &proto.ActionResponse{Result: "ok"}, nil
}

// transitionToRunning simulates a machine boot process.
func (s *Server) transitionToRunning(id string) {
	_ = s.acquireOpLock(id)
	defer s.releaseOpLock(id)

	ctx := context.Background()
	m, err := s.store.GetMachine(ctx, id)
	if err != nil {
		return // log silently
	}

	if m.Status == "terminated" {
		return
	}

	time.Sleep(500 * time.Millisecond) // simulate startup time
	m.Status = "running"
	m.Version++
	m.UpdatedAt = time.Now().UTC()
	_ = s.store.SaveMachine(ctx, m)

	s.mu.Lock()
	s.cache[m.ID] = m
	s.mu.Unlock()
}

// getMachineCached returns a machine (from cache or store).
func (s *Server) getMachineCached(ctx context.Context, id string) (*models.Machine, error) {
	s.mu.RLock()
	if m, ok := s.cache[id]; ok {
		s.mu.RUnlock()
		return m, nil
	}
	s.mu.RUnlock()

	m, err := s.store.GetMachine(ctx, id)
	if err != nil {
		return nil, err
	}

	s.mu.Lock()
	s.cache[id] = m
	s.mu.Unlock()

	return m, nil
}

// acquireOpLock ensures only one op per machine at a time.
func (s *Server) acquireOpLock(id string) *sync.Mutex {
	v, _ := s.opMu.LoadOrStore(id, &sync.Mutex{})
	mtx := v.(*sync.Mutex)
	mtx.Lock()
	return mtx
}

// releaseOpLock releases the op lock.
func (s *Server) releaseOpLock(id string) {
	v, ok := s.opMu.Load(id)
	if !ok {
		return
	}
	mtx := v.(*sync.Mutex)
	mtx.Unlock()
}
