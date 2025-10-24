package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"sync"
	"time"

	natsclient "github.com/devghori1264/aerophoenix/flyd-sim/internal/nats"
	proto "github.com/devghori1264/aerophoenix/flyd-sim/internal/proto"
	"github.com/devghori1264/aerophoenix/flyd-sim/internal/server"
)

type Handler struct {
	srv       *server.Server
	publisher *natsclient.Publisher

	mu          sync.RWMutex
	partitioned map[string]bool
	latencyMs   map[string]int
}

func NewHTTPHandlerWithPublisher(srv *server.Server, p *natsclient.Publisher) http.Handler {
	h := &Handler{
		srv:         srv,
		publisher:   p,
		partitioned: make(map[string]bool),
		latencyMs:   make(map[string]int),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/ping", h.handlePing)
	mux.HandleFunc("/create", h.handleCreate)
	mux.HandleFunc("/get", h.handleGet)

	mux.HandleFunc("/chaos/partition", h.handlePartition)
	mux.HandleFunc("/chaos/heal", h.handleHeal)
	mux.HandleFunc("/chaos/latency", h.handleLatency)

	return mux
}

func (h *Handler) handlePing(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"msg": "pong from flyd-sim http"})
}

func (h *Handler) handleCreate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name   string `json:"name"`
		Region string `json:"region"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON payload")
		return
	}
	if req.Name == "" || req.Region == "" {
		writeError(w, http.StatusBadRequest, "name and region required")
		return
	}

	if h.isPartitioned(req.Region) {
		writeError(w, http.StatusServiceUnavailable, "region partitioned")
		return
	}

	ctx := r.Context()
	res, err := h.srv.CreateMachine(ctx, &proto.CreateRequest{
		Name:   req.Name,
		Region: req.Region,
	})
	if err != nil {
		log.Printf("[create] internal error: %v", err)
		writeError(w, http.StatusInternalServerError, "failed to create machine")
		return
	}

	if h.publisher != nil {
		ev := map[string]interface{}{
			"event":  "machine.created",
			"id":     res.Id,
			"name":   req.Name,
			"region": req.Region,
			"time":   time.Now().Unix(),
		}
		payload, _ := json.Marshal(ev)
		if err := h.publisher.Publish(ctx, "machines.events", payload); err != nil {
			log.Printf("[create] publish failed: %v", err)
		}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"id":     res.Id,
		"status": res.Status,
	})
}

func (h *Handler) handleGet(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "id required")
		return
	}

	ctx := r.Context()
	machine, err := h.srv.GetMachine(ctx, &proto.GetRequest{Id: id})
	if err != nil {
		writeError(w, http.StatusNotFound, "machine not found")
		return
	}

	region := machine.Region
	if h.isPartitioned(region) {
		writeError(w, http.StatusServiceUnavailable, "region partitioned")
		return
	}

	if delay := h.getLatencyMs(region); delay > 0 {
		time.Sleep(time.Duration(delay) * time.Millisecond)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"id":     machine.Id,
		"status": machine.Status,
	})
}

func (h *Handler) handlePartition(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Region string `json:"region"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	if body.Region == "" {
		writeError(w, http.StatusBadRequest, "region required")
		return
	}

	h.mu.Lock()
	h.partitioned[body.Region] = true
	h.mu.Unlock()

	writeJSON(w, http.StatusOK, map[string]string{
		"status": "partitioned",
		"region": body.Region,
	})
}

func (h *Handler) handleHeal(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Region string `json:"region"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	if body.Region == "" {
		writeError(w, http.StatusBadRequest, "region required")
		return
	}

	h.mu.Lock()
	delete(h.partitioned, body.Region)
	delete(h.latencyMs, body.Region)
	h.mu.Unlock()

	writeJSON(w, http.StatusOK, map[string]string{
		"status": "healed",
		"region": body.Region,
	})
}

func (h *Handler) handleLatency(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Region    string `json:"region"`
		LatencyMs int    `json:"latency_ms"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	if body.Region == "" {
		writeError(w, http.StatusBadRequest, "region required")
		return
	}
	if body.LatencyMs < 0 {
		writeError(w, http.StatusBadRequest, "latency_ms must be non-negative")
		return
	}

	h.mu.Lock()
	h.latencyMs[body.Region] = body.LatencyMs
	h.mu.Unlock()

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":     "latency_set",
		"region":     body.Region,
		"latency_ms": body.LatencyMs,
	})
}

func (h *Handler) isPartitioned(region string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.partitioned[region]
}

func (h *Handler) getLatencyMs(region string) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.latencyMs[region]
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
	log.Printf("[HTTP %d] %s", status, msg)
}

var (
	ErrRegionRequired = errors.New("region required")
)
