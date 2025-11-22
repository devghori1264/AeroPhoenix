package main

import (
	"fmt"
	"testing"

	"github.com/sony/gobreaker"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/zap"
)

func TestRegionSelection(t *testing.T) {
	logger, _ := zap.NewDevelopment()
	router := &RegionRouter{
		regions: make(map[string]*Region),
		logger:  logger,
	}

	router.regions["us-east-1"] = &Region{
		Name:             "us-east-1",
		Healthy:          true,
		AverageLatencyMs: 50.0,
		CircuitBreaker:   gobreaker.NewCircuitBreaker(gobreaker.Settings{Name: "test-1"}),
	}

	router.regions["us-west-2"] = &Region{
		Name:             "us-west-2",
		Healthy:          false,
		AverageLatencyMs: 30.0,
		CircuitBreaker:   gobreaker.NewCircuitBreaker(gobreaker.Settings{Name: "test-2"}),
	}

	router.latencyAware = true
	region := router.selectOptimalRegion("")
	require.NotNil(t, region)
	assert.Equal(t, "us-east-1", region.Name)
}

func TestHealthyRegionCount(t *testing.T) {
	logger, _ := zap.NewDevelopment()
	router := &RegionRouter{
		regions: make(map[string]*Region),
		logger:  logger,
	}

	router.regions["region-1"] = &Region{Name: "region-1", Healthy: true}
	router.regions["region-2"] = &Region{Name: "region-2", Healthy: false}
	router.regions["region-3"] = &Region{Name: "region-3", Healthy: true}

	count := router.countHealthyRegions()
	assert.Equal(t, 2, count)
}

func BenchmarkRegionSelection(b *testing.B) {
	logger, _ := zap.NewDevelopment()
	router := &RegionRouter{
		regions:      make(map[string]*Region),
		logger:       logger,
		latencyAware: true,
	}

	for i := 0; i < 10; i++ {
		router.regions[fmt.Sprintf("region-%d", i)] = &Region{
			Name:             fmt.Sprintf("region-%d", i),
			Healthy:          i%2 == 0,
			AverageLatencyMs: float64(i * 10),
			CircuitBreaker:   gobreaker.NewCircuitBreaker(gobreaker.Settings{Name: fmt.Sprintf("cb-%d", i)}),
		}
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		router.selectOptimalRegion("")
	}
}
