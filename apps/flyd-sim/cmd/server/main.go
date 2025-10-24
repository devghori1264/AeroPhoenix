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
	natsclient "github.com/devghori1264/aerophoenix/flyd-sim/internal/nats"
	"github.com/devghori1264/aerophoenix/flyd-sim/internal/server"
	"github.com/devghori1264/aerophoenix/flyd-sim/internal/storage"

	"google.golang.org/grpc"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/otel"
	stdout "go.opentelemetry.io/otel/exporters/stdout/stdouttrace"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

func initTracer() (*sdktrace.TracerProvider, error) {
	exp, err := stdout.New(stdout.WithPrettyPrint())
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exp))
	otel.SetTracerProvider(tp)
	return tp, nil
}

func main() {
	grpcAddr := flag.String("grpc-addr", ":50051", "gRPC listen address")
	httpAddr := flag.String("http-addr", ":8080", "HTTP shim listen address")
	metricsAddr := flag.String("metrics-addr", ":9090", "Metrics listen address")
	dbPath := flag.String("db", "./data/badger", "Badger DB path")
	natsURL := flag.String("nats", "nats://nats:4222", "NATS URL")
	flag.Parse()

	tp, err := initTracer()
	if err != nil {
		log.Printf("otel init error: %v", err)
	}
	defer func() {
		if tp != nil {
			_ = tp.Shutdown(context.Background())
		}
	}()

	store, err := storage.NewBadgerStore(*dbPath)
	if err != nil {
		log.Fatalf("failed to open badger store: %v", err)
	}
	defer store.Close()

	pub, err := natsclient.NewPublisher(*natsURL)
	if err != nil {
		log.Printf("warning: nats not connected: %v", err)
	}
	defer func() {
		if pub != nil {
			pub.Close()
		}
	}()

	srv := server.New(store, pub)

	lis, err := net.Listen("tcp", *grpcAddr)
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}
	grpcServer := grpc.NewServer()
	srv.RegisterGRPC(grpcServer)

	go func() {
		log.Printf("gRPC server listening on %s", *grpcAddr)
		if err := grpcServer.Serve(lis); err != nil {
			log.Fatalf("grpc serve error: %v", err)
		}
	}()

	httpHandler := api.NewHTTPHandlerWithPublisher(srv, pub)
	httpServer := &http.Server{Addr: *httpAddr, Handler: httpHandler}
	go func() {
		log.Printf("HTTP shim listening on %s", *httpAddr)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("http listen: %v", err)
		}
	}()

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		log.Printf("Prometheus metrics listening on %s/metrics", *metricsAddr)
		if err := http.ListenAndServe(*metricsAddr, nil); err != nil && err != http.ErrServerClosed {
			log.Fatalf("metrics listen: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	log.Printf("shutdown initiated")

	grpcServer.GracefulStop()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(ctx); err != nil {
		log.Printf("http server shutdown error: %v", err)
	}
	if pub != nil {
		pub.Close()
	}
	store.Close()
	log.Println("shutdown complete")
}
