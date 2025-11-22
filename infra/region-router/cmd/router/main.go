package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/mux"
	consulapi "github.com/hashicorp/consul/api"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/sony/gobreaker"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

type Region struct {
	Name             string
	HTTPEndpoint     string
	GRPCEndpoint     string
	Healthy          bool
	LastHealthCheck  time.Time
	AverageLatencyMs float64
	CircuitBreaker   *gobreaker.CircuitBreaker
	GRPCConnPool     *grpc.ClientConn
	mu               sync.RWMutex
}

type RegionRouter struct {
	regions        map[string]*Region
	consul         *consulapi.Client
	logger         *zap.Logger
	mu             sync.RWMutex
	healthInterval time.Duration
	latencyAware   bool
	circuitBreaker bool
}

var (
	requestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "router_requests_total",
		Help: "Total number of routed requests",
	}, []string{"region", "method", "status"})

	requestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "router_request_duration_seconds",
		Help:    "Request duration in seconds",
		Buckets: prometheus.ExponentialBuckets(0.001, 2, 15),
	}, []string{"region", "method"})

	regionHealth = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "router_region_health",
		Help: "Region health status (1=healthy, 0=unhealthy)",
	}, []string{"region"})

	regionLatency = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "router_region_latency_milliseconds",
		Help: "Average region latency in milliseconds",
	}, []string{"region"})
)

func main() {

	logger, _ := zap.NewProduction()
	defer logger.Sync()

	logger.Info("Starting AeroPhoenix Region Router",
		zap.String("version", "1.0.0"),
		zap.String("build", time.Now().Format(time.RFC3339)),
	)

	consulConfig := consulapi.DefaultConfig()
	if addr := os.Getenv("CONSUL_HTTP_ADDR"); addr != "" {
		consulConfig.Address = addr
	}

	consul, err := consulapi.NewClient(consulConfig)
	if err != nil {
		logger.Fatal("Failed to connect to Consul", zap.Error(err))
	}

	router := &RegionRouter{
		regions:        make(map[string]*Region),
		consul:         consul,
		logger:         logger,
		healthInterval: parseEnvDuration("HEALTH_CHECK_INTERVAL", 10*time.Second),
		latencyAware:   parseEnvBool("LATENCY_AWARE_ROUTING", true),
		circuitBreaker: parseEnvBool("ENABLE_CIRCUIT_BREAKER", true),
	}

	if err := router.discoverRegions(); err != nil {
		logger.Fatal("Failed to discover regions", zap.Error(err))
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go router.healthCheckLoop(ctx)
	go router.latencyMonitorLoop(ctx)

	httpRouter := mux.NewRouter()

	httpRouter.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		healthy := router.countHealthyRegions() > 0
		if healthy {
			w.WriteHeader(http.StatusOK)
			fmt.Fprintf(w, `{"status":"healthy","regions":%d}`, router.countHealthyRegions())
		} else {
			w.WriteHeader(http.StatusServiceUnavailable)
			fmt.Fprintf(w, `{"status":"unhealthy","regions":0}`)
		}
	})

	httpRouter.Handle("/metrics", promhttp.Handler())

	httpRouter.HandleFunc("/regions", router.handleRegionStatus)

	httpRouter.PathPrefix("/v1/").Handler(router.createRegionalProxy())

	httpServer := &http.Server{
		Addr:         ":8000",
		Handler:      httpRouter,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	go func() {
		logger.Info("HTTP router listening", zap.String("address", ":8000"))
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Fatal("HTTP server failed", zap.Error(err))
		}
	}()

	grpcListener, err := net.Listen("tcp", ":50050")
	if err != nil {
		logger.Fatal("Failed to listen on gRPC port", zap.Error(err))
	}

	grpcServer := grpc.NewServer(
		grpc.UnaryInterceptor(router.grpcUnaryInterceptor),
	)

	go func() {
		logger.Info("gRPC router listening", zap.String("address", ":50050"))
		if err := grpcServer.Serve(grpcListener); err != nil {
			logger.Fatal("gRPC server failed", zap.Error(err))
		}
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	logger.Info("Shutting down gracefully...")

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shutdownCancel()

	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		logger.Error("HTTP server shutdown error", zap.Error(err))
	}

	grpcServer.GracefulStop()

	logger.Info("Shutdown complete")
}

func (r *RegionRouter) discoverRegions() error {
	services, _, err := r.consul.Catalog().Service("flyd-sim", "", nil)
	if err != nil {
		return fmt.Errorf("consul service query failed: %w", err)
	}

	if len(services) == 0 {
		r.logger.Warn("No services found in Consul, using static configuration")
		return r.discoverRegionsStatic()
	}

	for _, service := range services {
		region := service.ServiceMeta["region"]
		if region == "" {
			region = service.ServiceID
		}

		httpEndpoint := fmt.Sprintf("http://%s:%d", service.ServiceAddress, service.ServicePort)
		grpcEndpoint := fmt.Sprintf("%s:%s", service.ServiceAddress, service.ServiceMeta["grpc_port"])

		r.registerRegion(region, httpEndpoint, grpcEndpoint)
	}

	r.logger.Info("Discovered regions from Consul", zap.Int("count", len(r.regions)))
	return nil
}

func (r *RegionRouter) discoverRegionsStatic() error {
	staticRegions := map[string]struct {
		HTTP string
		GRPC string
	}{
		"us-east-1":  {HTTP: "http://flyd-sim-us-east-1:8080", GRPC: "flyd-sim-us-east-1:50051"},
		"us-west-2":  {HTTP: "http://flyd-sim-us-west-2:8083", GRPC: "flyd-sim-us-west-2:50054"},
		"eu-west-1":  {HTTP: "http://flyd-sim-eu-west-1:8081", GRPC: "flyd-sim-eu-west-1:50052"},
		"ap-south-1": {HTTP: "http://flyd-sim-ap-south-1:8082", GRPC: "flyd-sim-ap-south-1:50053"},
	}

	for region, endpoints := range staticRegions {
		r.registerRegion(region, endpoints.HTTP, endpoints.GRPC)
	}

	r.logger.Info("Configured static regions", zap.Int("count", len(r.regions)))
	return nil
}

func (r *RegionRouter) registerRegion(name, httpEndpoint, grpcEndpoint string) {
	r.mu.Lock()
	defer r.mu.Unlock()

	cbSettings := gobreaker.Settings{
		Name:        fmt.Sprintf("region-%s", name),
		MaxRequests: 5,
		Interval:    10 * time.Second,
		Timeout:     30 * time.Second,
		ReadyToTrip: func(counts gobreaker.Counts) bool {
			failureRatio := float64(counts.TotalFailures) / float64(counts.Requests)
			return counts.Requests >= 3 && failureRatio >= 0.6
		},
		OnStateChange: func(name string, from gobreaker.State, to gobreaker.State) {
			r.logger.Info("Circuit breaker state changed",
				zap.String("region", name),
				zap.String("from", from.String()),
				zap.String("to", to.String()),
			)
		},
	}

	grpcConn, err := grpc.Dial(
		grpcEndpoint,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(100*1024*1024)),
		grpc.WithKeepaliveParams(keepalive.ClientParameters{
			Time:                30 * time.Second,
			Timeout:             10 * time.Second,
			PermitWithoutStream: true,
		}),
	)
	if err != nil {
		r.logger.Warn("Failed to create gRPC connection pool",
			zap.String("region", name),
			zap.Error(err),
		)
		grpcConn = nil
	}

	region := &Region{
		Name:            name,
		HTTPEndpoint:    httpEndpoint,
		GRPCEndpoint:    grpcEndpoint,
		Healthy:         true,
		LastHealthCheck: time.Now(),
		CircuitBreaker:  gobreaker.NewCircuitBreaker(cbSettings),
		GRPCConnPool:    grpcConn,
	}

	r.regions[name] = region

	r.logger.Info("Registered region",
		zap.String("region", name),
		zap.String("http", httpEndpoint),
		zap.String("grpc", grpcEndpoint),
	)
}

func (r *RegionRouter) selectOptimalRegion(preference string) *Region {
	r.mu.RLock()
	defer r.mu.RUnlock()

	if preference != "" {
		if region, ok := r.regions[preference]; ok {
			region.mu.RLock()
			healthy := region.Healthy
			region.mu.RUnlock()
			if healthy {
				return region
			}
		}
	}

	if r.latencyAware {
		var bestRegion *Region
		var lowestLatency float64 = 999999

		for _, region := range r.regions {
			region.mu.RLock()
			healthy := region.Healthy
			latency := region.AverageLatencyMs
			region.mu.RUnlock()

			if healthy && (bestRegion == nil || latency < lowestLatency) {
				bestRegion = region
				lowestLatency = latency
			}
		}

		if bestRegion != nil {
			return bestRegion
		}
	}

	for _, region := range r.regions {
		region.mu.RLock()
		healthy := region.Healthy
		region.mu.RUnlock()
		if healthy {
			return region
		}
	}

	return nil
}

func (r *RegionRouter) createRegionalProxy() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		start := time.Now()

		preferredRegion := req.Header.Get("X-Preferred-Region")
		if preferredRegion == "" {
			preferredRegion = req.URL.Query().Get("region")
		}

		region := r.selectOptimalRegion(preferredRegion)
		if region == nil {
			http.Error(w, "No healthy regions available", http.StatusServiceUnavailable)
			return
		}

		target, _ := url.Parse(region.HTTPEndpoint)
		proxy := httputil.NewSingleHostReverseProxy(target)

		proxy.ErrorHandler = func(w http.ResponseWriter, httpReq *http.Request, err error) {
			r.logger.Error("Proxy error",
				zap.String("region", region.Name),
				zap.Error(err),
			)

			region.mu.Lock()
			region.Healthy = false
			region.mu.Unlock()

			http.Error(w, "Region unavailable", http.StatusBadGateway)
		}

		req.Header.Set("X-Routed-Region", region.Name)
		req.Header.Set("X-Router-Version", "1.0.0")

		if r.circuitBreaker {
			_, err := region.CircuitBreaker.Execute(func() (interface{}, error) {
				proxy.ServeHTTP(w, req)
				return nil, nil
			})
			if err != nil {
				http.Error(w, "Circuit breaker open", http.StatusServiceUnavailable)
				return
			}
		} else {
			proxy.ServeHTTP(w, req)
		}

		duration := time.Since(start)
		requestDuration.WithLabelValues(region.Name, req.Method).Observe(duration.Seconds())
		requestsTotal.WithLabelValues(region.Name, req.Method, "200").Inc()
	})
}

func (r *RegionRouter) healthCheckLoop(ctx context.Context) {
	ticker := time.NewTicker(r.healthInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			r.performHealthChecks()
		}
	}
}

func (r *RegionRouter) performHealthChecks() {
	r.mu.RLock()
	regions := make([]*Region, 0, len(r.regions))
	for _, region := range r.regions {
		regions = append(regions, region)
	}
	r.mu.RUnlock()

	var wg sync.WaitGroup
	for _, region := range regions {
		wg.Add(1)
		go func(reg *Region) {
			defer wg.Done()
			r.checkRegionHealth(reg)
		}(region)
	}
	wg.Wait()
}

func (r *RegionRouter) checkRegionHealth(region *Region) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	healthURL := fmt.Sprintf("%s/ping", region.HTTPEndpoint)
	req, err := http.NewRequestWithContext(ctx, "GET", healthURL, nil)
	if err != nil {
		r.markUnhealthy(region, err)
		return
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		r.markUnhealthy(region, err)
		return
	}
	defer resp.Body.Close()

	region.mu.Lock()
	wasUnhealthy := !region.Healthy
	region.Healthy = resp.StatusCode == http.StatusOK
	region.LastHealthCheck = time.Now()
	region.mu.Unlock()

	if region.Healthy {
		regionHealth.WithLabelValues(region.Name).Set(1)
		if wasUnhealthy {
			r.logger.Info("Region recovered", zap.String("region", region.Name))
		}
	} else {
		regionHealth.WithLabelValues(region.Name).Set(0)
	}
}

func (r *RegionRouter) markUnhealthy(region *Region, err error) {
	region.mu.Lock()
	wasHealthy := region.Healthy
	region.Healthy = false
	region.LastHealthCheck = time.Now()
	region.mu.Unlock()

	regionHealth.WithLabelValues(region.Name).Set(0)

	if wasHealthy {
		r.logger.Warn("Region became unhealthy",
			zap.String("region", region.Name),
			zap.Error(err),
		)
	}
}

func (r *RegionRouter) latencyMonitorLoop(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			r.measureRegionalLatencies()
		}
	}
}

func (r *RegionRouter) measureRegionalLatencies() {
	r.mu.RLock()
	regions := make([]*Region, 0, len(r.regions))
	for _, region := range r.regions {
		regions = append(regions, region)
	}
	r.mu.RUnlock()

	for _, region := range regions {
		go r.measureRegionLatency(region)
	}
}

func (r *RegionRouter) measureRegionLatency(region *Region) {
	start := time.Now()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	pingURL := fmt.Sprintf("%s/ping", region.HTTPEndpoint)
	req, err := http.NewRequestWithContext(ctx, "GET", pingURL, nil)
	if err != nil {
		return
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return
	}
	defer resp.Body.Close()

	latencyMs := float64(time.Since(start).Milliseconds())

	region.mu.Lock()

	if region.AverageLatencyMs == 0 {
		region.AverageLatencyMs = latencyMs
	} else {
		alpha := 0.3
		region.AverageLatencyMs = alpha*latencyMs + (1-alpha)*region.AverageLatencyMs
	}
	region.mu.Unlock()

	regionLatency.WithLabelValues(region.Name).Set(region.AverageLatencyMs)
}

func (r *RegionRouter) handleRegionStatus(w http.ResponseWriter, req *http.Request) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	type RegionStatus struct {
		Name             string  `json:"name"`
		Healthy          bool    `json:"healthy"`
		HTTPEndpoint     string  `json:"http_endpoint"`
		GRPCEndpoint     string  `json:"grpc_endpoint"`
		AverageLatencyMs float64 `json:"average_latency_ms"`
		LastHealthCheck  string  `json:"last_health_check"`
		CircuitState     string  `json:"circuit_state"`
	}

	status := make([]RegionStatus, 0, len(r.regions))
	for _, region := range r.regions {
		region.mu.RLock()
		s := RegionStatus{
			Name:             region.Name,
			Healthy:          region.Healthy,
			HTTPEndpoint:     region.HTTPEndpoint,
			GRPCEndpoint:     region.GRPCEndpoint,
			AverageLatencyMs: region.AverageLatencyMs,
			LastHealthCheck:  region.LastHealthCheck.Format(time.RFC3339),
			CircuitState:     region.CircuitBreaker.State().String(),
		}
		region.mu.RUnlock()
		status = append(status, s)
	}

	response := map[string]interface{}{
		"regions": status,
		"total":   len(r.regions),
		"healthy": r.countHealthyRegions(),
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(response)
}

func (r *RegionRouter) countHealthyRegions() int {
	r.mu.RLock()
	defer r.mu.RUnlock()

	count := 0
	for _, region := range r.regions {
		region.mu.RLock()
		if region.Healthy {
			count++
		}
		region.mu.RUnlock()
	}
	return count
}

func (r *RegionRouter) grpcUnaryInterceptor(
	ctx context.Context,
	req interface{},
	info *grpc.UnaryServerInfo,
	handler grpc.UnaryHandler,
) (interface{}, error) {

	md, ok := metadata.FromIncomingContext(ctx)
	var preferredRegion string
	if ok {
		if regions := md.Get("x-preferred-region"); len(regions) > 0 {
			preferredRegion = regions[0]
		}
	}

	region := r.selectOptimalRegion(preferredRegion)
	if region == nil {
		return nil, status.Error(codes.Unavailable, "no healthy regions available")
	}

	region.mu.Lock()
	conn := region.GRPCConnPool
	if conn == nil {

		newConn, err := grpc.Dial(
			region.GRPCEndpoint,
			grpc.WithTransportCredentials(insecure.NewCredentials()),
			grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(100*1024*1024)),
			grpc.WithKeepaliveParams(keepalive.ClientParameters{
				Time:                30 * time.Second,
				Timeout:             10 * time.Second,
				PermitWithoutStream: true,
			}),
		)
		if err != nil {
			region.mu.Unlock()
			r.logger.Error("Failed to dial region",
				zap.String("region", region.Name),
				zap.Error(err),
			)
			return nil, status.Error(codes.Unavailable, "failed to connect to region")
		}
		region.GRPCConnPool = newConn
		conn = newConn
	}
	region.mu.Unlock()

	var result interface{}
	if r.circuitBreaker {
		cbResult, cbErr := region.CircuitBreaker.Execute(func() (interface{}, error) {

			outCtx := metadata.AppendToOutgoingContext(ctx, "x-routed-region", region.Name)

			err := conn.Invoke(outCtx, info.FullMethod, req, &result)
			return result, err
		})

		if cbErr != nil {
			return nil, status.Error(codes.Unavailable, "circuit breaker open or request failed")
		}
		result = cbResult
	} else {
		outCtx := metadata.AppendToOutgoingContext(ctx, "x-routed-region", region.Name)
		if err := conn.Invoke(outCtx, info.FullMethod, req, &result); err != nil {
			return nil, err
		}
	}

	return result, nil
}

func parseEnvDuration(key string, defaultValue time.Duration) time.Duration {
	if val := os.Getenv(key); val != "" {
		if d, err := time.ParseDuration(val); err == nil {
			return d
		}
	}
	return defaultValue
}

func parseEnvBool(key string, defaultValue bool) bool {
	if val := os.Getenv(key); val != "" {
		return val == "true" || val == "1" || val == "yes"
	}
	return defaultValue
}
