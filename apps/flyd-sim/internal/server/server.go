package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/devghori1264/aerophoenix/flyd-sim/internal/models"
	natsclient "github.com/devghori1264/aerophoenix/flyd-sim/internal/nats"
	proto "github.com/devghori1264/aerophoenix/flyd-sim/internal/proto"
	"github.com/devghori1264/aerophoenix/flyd-sim/internal/storage"

	"github.com/google/uuid"
	"github.com/prometheus/client_golang/prometheus"
	"google.golang.org/grpc"
)

var (
	machineCreated = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "flyd_machine_created_total",
		Help: "Total number of machines created",
	})
	machineActions = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "flyd_machine_action_total",
		Help: "Counts of actions performed on machines",
	}, []string{"action"})
)

func init() {
	prometheus.MustRegister(machineCreated, machineActions)
}

type Server struct {
	proto.UnimplementedMachineServiceServer
	store     storage.Store
	mu        sync.RWMutex
	cache     map[string]*models.Machine
	opMu      sync.Map
	publisher *natsclient.Publisher
}

func New(store storage.Store, publisher *natsclient.Publisher) *Server {
	return &Server{
		store:     store,
		cache:     make(map[string]*models.Machine),
		publisher: publisher,
	}
}

func (s *Server) RegisterGRPC(gs *grpc.Server) {
	proto.RegisterMachineServiceServer(gs, s)
}

func (s *Server) Ping(ctx context.Context, _ *proto.PingRequest) (*proto.PingResponse, error) {
	return &proto.PingResponse{Msg: "pong from flyd-sim"}, nil
}

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

	machineCreated.Inc()
	machineActions.WithLabelValues("create").Inc()

	s.publishEvent(ctx, map[string]interface{}{
		"event":  "machine.created",
		"id":     m.ID,
		"name":   m.Name,
		"region": m.Region,
		"time":   time.Now().Unix(),
	})

	go s.transitionToRunning(m.ID)
	return &proto.CreateResponse{Id: m.ID, Status: m.Status}, nil
}

func (s *Server) GetMachine(ctx context.Context, req *proto.GetRequest) (*proto.GetResponse, error) {
	m, err := s.getMachineCached(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	return &proto.GetResponse{Id: m.ID, Status: m.Status, Region: m.Region}, nil
}

func (s *Server) StartMachine(ctx context.Context, req *proto.ActionRequest) (*proto.ActionResponse, error) {
	if req.Id == "" {
		return nil, errors.New("id required")
	}
	return s.performAction(ctx, req.Id, "start")
}

func (s *Server) StopMachine(ctx context.Context, req *proto.ActionRequest) (*proto.ActionResponse, error) {
	if req.Id == "" {
		return nil, errors.New("id required")
	}
	return s.performAction(ctx, req.Id, "stop")
}

func (s *Server) performAction(ctx context.Context, id, action string) (*proto.ActionResponse, error) {
	s.acquireOpLock(id)
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

	machineActions.WithLabelValues(action).Inc()
	s.publishEvent(ctx, map[string]interface{}{
		"event":  fmt.Sprintf("machine.%s", action),
		"id":     m.ID,
		"status": m.Status,
		"time":   time.Now().Unix(),
	})

	return &proto.ActionResponse{Result: "ok"}, nil
}

func (s *Server) transitionToRunning(id string) {
	s.acquireOpLock(id)
	defer s.releaseOpLock(id)

	ctx := context.Background()
	m, err := s.store.GetMachine(ctx, id)
	if err != nil {
		return
	}

	if m.Status == "terminated" {
		return
	}

	time.Sleep(500 * time.Millisecond)
	m.Status = "running"
	m.Version++
	m.UpdatedAt = time.Now().UTC()

	if err := s.store.SaveMachine(ctx, m); err == nil {
		s.mu.Lock()
		s.cache[m.ID] = m
		s.mu.Unlock()
	}

	s.publishEvent(ctx, map[string]interface{}{
		"event":  "machine.running",
		"id":     m.ID,
		"status": "running",
		"time":   time.Now().Unix(),
	})
}

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

func (s *Server) acquireOpLock(id string) *sync.Mutex {
	v, _ := s.opMu.LoadOrStore(id, &sync.Mutex{})
	mtx := v.(*sync.Mutex)
	mtx.Lock()
	return mtx
}

func (s *Server) releaseOpLock(id string) {
	v, ok := s.opMu.Load(id)
	if !ok {
		return
	}
	mtx := v.(*sync.Mutex)
	mtx.Unlock()
}

func (s *Server) publishEvent(ctx context.Context, ev map[string]interface{}) {
	if s.publisher == nil {
		return
	}
	data, err := json.Marshal(ev)
	if err != nil {
		return
	}
	_ = s.publisher.Publish(ctx, "machines.events", data)
}
