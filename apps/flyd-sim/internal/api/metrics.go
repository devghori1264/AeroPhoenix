package api

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// RegisterMetrics registers Prometheus handler in provided mux
func RegisterMetrics(mux *http.ServeMux) {
	mux.Handle("/metrics", promhttp.Handler())
}
