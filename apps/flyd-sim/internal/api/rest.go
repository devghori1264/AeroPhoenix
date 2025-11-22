package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	natsclient "github.com/devghori1264/aerophoenix/flyd-sim/internal/nats"
	"github.com/devghori1264/aerophoenix/flyd-sim/internal/server"
	proto "github.com/devghori1264/aerophoenix/flyd-sim/proto"
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

	mux.HandleFunc("/migrate", h.handleMigrate)
	mux.HandleFunc("/migration/status", h.handleMigrationStatus)
	mux.HandleFunc("/migration/stream", h.handleMigrationStream)

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

func (h *Handler) handleMigrate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}

	var req struct {
		MachineID    string            `json:"machine_id"`
		TargetRegion string            `json:"target_region"`
		Strategy     string            `json:"strategy"`
		Options      *MigrationOptions `json:"options,omitempty"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
		return
	}

	if req.MachineID == "" {
		writeError(w, http.StatusBadRequest, "machine_id is required")
		return
	}
	if req.TargetRegion == "" {
		writeError(w, http.StatusBadRequest, "target_region is required")
		return
	}

	var strategy proto.MigrationStrategy
	switch req.Strategy {
	case "live_migration":
		strategy = proto.MigrationStrategy_LIVE_MIGRATION
	case "clone_and_redirect":
		strategy = proto.MigrationStrategy_CLONE_AND_REDIRECT
	case "", "stop_and_move":
		strategy = proto.MigrationStrategy_STOP_AND_MOVE
	default:
		writeError(w, http.StatusBadRequest, "invalid strategy: must be 'stop_and_move', 'live_migration', or 'clone_and_redirect'")
		return
	}

	var protoOptions *proto.MigrationOptions
	if req.Options != nil {
		protoOptions = &proto.MigrationOptions{
			TimeoutSeconds:        req.Options.TimeoutSeconds,
			PreserveIp:            req.Options.PreserveIP,
			SkipStateVerification: req.Options.SkipStateVerification,
			Metadata:              req.Options.Metadata,
		}
	}

	ctx := r.Context()
	resp, err := h.srv.MigrateMachine(ctx, &proto.MigrateRequest{
		MachineId:    req.MachineID,
		TargetRegion: req.TargetRegion,
		Strategy:     strategy,
		Options:      protoOptions,
	})

	if err != nil {
		log.Printf("[Migration] Failed to start migration for machine %s: %v", req.MachineID, err)
		writeError(w, http.StatusInternalServerError, "failed to start migration: "+err.Error())
		return
	}

	writeJSON(w, http.StatusAccepted, map[string]interface{}{
		"migration_id":          resp.MigrationId,
		"current_phase":         resp.CurrentPhase.String(),
		"message":               resp.Message,
		"estimated_duration_ms": resp.EstimatedDurationMs,
		"machine_id":            req.MachineID,
		"target_region":         req.TargetRegion,
		"strategy":              strategy.String(),
	})

	log.Printf("[Migration] Started migration %s for machine %s -> %s (strategy: %s)",
		resp.MigrationId, req.MachineID, req.TargetRegion, strategy.String())
}

func (h *Handler) handleMigrationStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "GET required")
		return
	}

	migrationID := r.URL.Query().Get("migration_id")
	if migrationID == "" {
		writeError(w, http.StatusBadRequest, "migration_id query parameter required")
		return
	}

	ctx := r.Context()
	status, err := h.srv.GetMigrationStatus(ctx, &proto.MigrationStatusRequest{
		MigrationId: migrationID,
	})

	if err != nil {
		log.Printf("[Migration] Failed to get status for migration %s: %v", migrationID, err)
		writeError(w, http.StatusNotFound, "migration not found: "+err.Error())
		return
	}

	steps := make([]map[string]interface{}, len(status.Steps))
	for i, step := range status.Steps {
		steps[i] = map[string]interface{}{
			"step_name":   step.StepName,
			"completed":   step.Completed,
			"duration_ms": step.DurationMs,
			"error":       step.Error,
		}
	}

	var progressPercent int32
	if status.TotalBytes > 0 {
		progressPercent = int32((status.BytesTransferred * 100) / status.TotalBytes)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"migration_id":      status.MigrationId,
		"phase":             status.Phase.String(),
		"state":             status.State.String(),
		"source_region":     status.SourceRegion,
		"target_region":     status.TargetRegion,
		"bytes_transferred": status.BytesTransferred,
		"total_bytes":       status.TotalBytes,
		"progress_percent":  progressPercent,
		"steps":             steps,
		"error_message":     status.ErrorMessage,
		"started_at":        status.StartedAt,
		"completed_at":      status.CompletedAt,
		"duration_seconds":  calculateDuration(status.StartedAt, status.CompletedAt),
	})
}

func (h *Handler) handleMigrationStream(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "GET required")
		return
	}

	migrationID := r.URL.Query().Get("migration_id")
	if migrationID == "" {
		writeError(w, http.StatusBadRequest, "migration_id query parameter required")
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming not supported")
		return
	}

	ctx := r.Context()

	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	log.Printf("[Migration] Started streaming for migration %s", migrationID)

	lastPhase := proto.MigrationPhase_PHASE_UNKNOWN
	for {
		select {
		case <-ctx.Done():
			log.Printf("[Migration] Stream closed for migration %s", migrationID)
			return
		case <-ticker.C:
			status, err := h.srv.GetMigrationStatus(ctx, &proto.MigrationStatusRequest{
				MigrationId: migrationID,
			})

			if err != nil {

				event := map[string]interface{}{
					"type":  "error",
					"error": err.Error(),
				}
				writeSSE(w, flusher, event)
				return
			}

			var progressPercent int32
			if status.TotalBytes > 0 {
				progressPercent = int32((status.BytesTransferred * 100) / status.TotalBytes)
			}

			event := map[string]interface{}{
				"type":              "progress",
				"migration_id":      status.MigrationId,
				"phase":             status.Phase.String(),
				"state":             status.State.String(),
				"progress_percent":  progressPercent,
				"bytes_transferred": status.BytesTransferred,
				"total_bytes":       status.TotalBytes,
				"timestamp":         time.Now().Unix(),
			}

			writeSSE(w, flusher, event)

			if status.State == proto.MigrationState_STATE_COMPLETED ||
				status.State == proto.MigrationState_STATE_FAILED ||
				status.State == proto.MigrationState_STATE_ROLLED_BACK {

				finalEvent := map[string]interface{}{
					"type":          "complete",
					"migration_id":  status.MigrationId,
					"final_state":   status.State.String(),
					"error_message": status.ErrorMessage,
				}
				writeSSE(w, flusher, finalEvent)
				log.Printf("[Migration] Stream completed for migration %s with state %s", migrationID, status.State.String())
				return
			}

			if status.Phase != lastPhase {
				log.Printf("[Migration] %s transitioned to phase %s", migrationID, status.Phase.String())
				lastPhase = status.Phase
			}
		}
	}
}

type MigrationOptions struct {
	TimeoutSeconds        int64             `json:"timeout_seconds,omitempty"`
	PreserveIP            bool              `json:"preserve_ip,omitempty"`
	SkipStateVerification bool              `json:"skip_state_verification,omitempty"`
	Metadata              map[string]string `json:"metadata,omitempty"`
}

func writeSSE(w http.ResponseWriter, flusher http.Flusher, data interface{}) {
	jsonData, err := json.Marshal(data)
	if err != nil {
		return
	}
	fmt.Fprintf(w, "data: %s\n\n", jsonData)
	flusher.Flush()
}

func calculateDuration(startedAt, completedAt int64) int64 {
	if completedAt == 0 || startedAt == 0 {
		return 0
	}
	return completedAt - startedAt
}

var (
	ErrRegionRequired = errors.New("region required")
)
