package api

import (
	"encoding/json"
	"log"
	"net/http"

	proto "github.com/devghori1264/aerophoenix/flyd-sim/internal/proto"
	"github.com/devghori1264/aerophoenix/flyd-sim/internal/server"
)

// NewHTTPHandler creates HTTP routes that map to gRPC-like endpoints.
// This is convenient for the Phoenix app to call via HTTP (simple).
func NewHTTPHandler(srv *server.Server) http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("/ping", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]string{"msg": "pong from flyd-sim http"})
	})
	m.HandleFunc("/create", func(w http.ResponseWriter, r *http.Request) {
		// minimal request parsing
		var req struct {
			Name   string `json:"name"`
			Region string `json:"region"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		if req.Name == "" || req.Region == "" {
			http.Error(w, "name and region required", http.StatusBadRequest)
			return
		}
		ctx := r.Context()
		res, err := srv.CreateMachine(ctx, &proto.CreateRequest{Name: req.Name, Region: req.Region})
		if err != nil {
			log.Printf("create error: %v", err)
			http.Error(w, "internal", http.StatusInternalServerError)
			return
		}
		resp := map[string]interface{}{"id": res.Id, "status": res.Status}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	})
	m.HandleFunc("/get", func(w http.ResponseWriter, r *http.Request) {
		id := r.URL.Query().Get("id")
		if id == "" {
			http.Error(w, "id required", http.StatusBadRequest)
			return
		}
		ctx := r.Context()
		res, err := srv.GetMachine(ctx, &proto.GetRequest{Id: id})
		if err != nil {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]interface{}{"id": res.Id, "status": res.Status})
	})
	// Add more endpoints as needed (start/stop/migrate)
	return m
}
