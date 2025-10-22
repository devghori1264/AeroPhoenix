package main

import (
	"context"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/devghori1264/aerophoenix/flyd-sim/internal/api"
	"github.com/devghori1264/aerophoenix/flyd-sim/internal/server"
	"github.com/devghori1264/aerophoenix/flyd-sim/internal/storage"

	"google.golang.org/grpc"
)

func main() {
	addr := flag.String("grpc-addr", ":50051", "gRPC listen address")
	httpAddr := flag.String("http-addr", ":8080", "HTTP shim listen address")
	dbPath := flag.String("db", "./data/badger", "Badger DB path")
	flag.Parse()

	// Create storage
	store, err := storage.NewBadgerStore(*dbPath)
	if err != nil {
		log.Fatalf("failed to open badger store: %v", err)
	}
	defer store.Close()

	srv := server.New(store)

	// Start gRPC server
	lis, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("failed to listen on %s: %v", *addr, err)
	}
	grpcServer := grpc.NewServer()
	srv.RegisterGRPC(grpcServer)

	go func() {
		log.Printf("gRPC server listening on %s", *addr)
		if err := grpcServer.Serve(lis); err != nil {
			log.Fatalf("grpc serve error: %v", err)
		}
	}()

	// Start HTTP shim
	httpServer := &http.Server{
		Addr:    *httpAddr,
		Handler: api.NewHTTPHandler(srv),
	}
	go func() {
		log.Printf("HTTP shim listening on %s", *httpAddr)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("http listen: %v", err)
		}
	}()

	// Metrics endpoint
	go func() {
		mux := http.NewServeMux()
		api.RegisterMetrics(mux)
		log.Printf("Prometheus metrics available on :9090/metrics")
		if err := http.ListenAndServe(":9090", mux); err != nil && err != http.ErrServerClosed {
			log.Fatalf("metrics server: %v", err)
		}
	}()

	// Graceful shutdown
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	log.Printf("shutdown initiated")

	// graceful stop grpc
	grpcServer.GracefulStop()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(ctx); err != nil {
		log.Printf("http server shutdown error: %v", err)
	}
	store.Close()
	log.Println("shutdown complete")
}
