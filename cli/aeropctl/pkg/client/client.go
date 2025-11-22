package client

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

type Client struct {
	baseURL    string
	httpClient *http.Client
	maxRetries int
	retryDelay time.Duration
}

type Config struct {
	BaseURL    string
	Timeout    time.Duration
	MaxRetries int
	RetryDelay time.Duration
}

func NewClient(cfg Config) *Client {
	if cfg.Timeout == 0 {
		cfg.Timeout = 30 * time.Second
	}
	if cfg.MaxRetries == 0 {
		cfg.MaxRetries = 3
	}
	if cfg.RetryDelay == 0 {
		cfg.RetryDelay = time.Second
	}

	return &Client{
		baseURL: cfg.BaseURL,
		httpClient: &http.Client{
			Timeout: cfg.Timeout,
			Transport: &http.Transport{
				MaxIdleConns:        10,
				IdleConnTimeout:     30 * time.Second,
				DisableCompression:  false,
				DisableKeepAlives:   false,
				MaxIdleConnsPerHost: 10,
			},
		},
		maxRetries: cfg.MaxRetries,
		retryDelay: cfg.RetryDelay,
	}
}

type Machine struct {
	ID             string                 `json:"id"`
	Name           string                 `json:"name"`
	Region         string                 `json:"region"`
	Status         string                 `json:"status"`
	ImageRef       string                 `json:"image_ref,omitempty"`
	InstanceType   string                 `json:"instance_type,omitempty"`
	State          string                 `json:"state,omitempty"`
	PrivateIP      string                 `json:"private_ip,omitempty"`
	CreatedAt      string                 `json:"created_at,omitempty"`
	UpdatedAt      string                 `json:"updated_at,omitempty"`
	LastSeenAt     string                 `json:"last_seen_at,omitempty"`
	RestartCount   int                    `json:"restart_count,omitempty"`
	HealthCheckURL string                 `json:"health_check_url,omitempty"`
	Metadata       map[string]interface{} `json:"metadata,omitempty"`
}

type CreateMachineRequest struct {
	Name         string            `json:"name"`
	Region       string            `json:"region"`
	ImageRef     string            `json:"image_ref,omitempty"`
	InstanceType string            `json:"instance_type,omitempty"`
	Config       map[string]string `json:"config,omitempty"`
}

type MigrateRequest struct {
	TargetRegion string `json:"target_region"`
	Strategy     string `json:"strategy,omitempty"`
}

type MigrationProgress struct {
	MigrationID     string  `json:"migration_id"`
	Phase           string  `json:"phase"`
	ProgressPercent float64 `json:"progress_percent"`
	Message         string  `json:"message,omitempty"`
	State           string  `json:"state"`
}

type ActionRequest struct {
	Action string                 `json:"action"`
	Params map[string]interface{} `json:"params,omitempty"`
}

type APIError struct {
	StatusCode int
	Message    string
	Details    map[string]interface{}
}

func (e *APIError) Error() string {
	if e.Details != nil {
		return fmt.Sprintf("API error (status %d): %s - %v", e.StatusCode, e.Message, e.Details)
	}
	return fmt.Sprintf("API error (status %d): %s", e.StatusCode, e.Message)
}

func (c *Client) doRequest(ctx context.Context, method, path string, body interface{}) (*http.Response, error) {
	var lastErr error

	for attempt := 0; attempt <= c.maxRetries; attempt++ {
		if attempt > 0 {

			backoff := c.retryDelay * time.Duration(1<<uint(attempt-1))
			jitter := time.Duration(float64(backoff) * 0.3 * (0.5 + 0.5*float64(time.Now().UnixNano()%100)/100.0))
			time.Sleep(backoff + jitter)
		}

		resp, err := c.executeRequest(ctx, method, path, body)
		if err == nil {
			return resp, nil
		}

		lastErr = err

		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if apiErr, ok := err.(*APIError); ok && apiErr.StatusCode >= 400 && apiErr.StatusCode < 500 {
			return nil, err
		}
	}

	return nil, fmt.Errorf("request failed after %d retries: %w", c.maxRetries, lastErr)
}

func (c *Client) executeRequest(ctx context.Context, method, path string, body interface{}) (*http.Response, error) {
	url := c.baseURL + path

	var reqBody io.Reader
	if body != nil {
		jsonData, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal request body: %w", err)
		}
		reqBody = bytes.NewReader(jsonData)
	}

	req, err := http.NewRequestWithContext(ctx, method, url, reqBody)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "aeropctl/1.0")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}

	if resp.StatusCode >= 400 {
		defer resp.Body.Close()
		var errResp map[string]interface{}
		json.NewDecoder(resp.Body).Decode(&errResp)

		message := "unknown error"
		if msg, ok := errResp["error"].(string); ok {
			message = msg
		} else if msg, ok := errResp["message"].(string); ok {
			message = msg
		}

		return nil, &APIError{
			StatusCode: resp.StatusCode,
			Message:    message,
			Details:    errResp,
		}
	}

	return resp, nil
}

func (c *Client) ListMachines(ctx context.Context) ([]Machine, error) {
	resp, err := c.doRequest(ctx, "GET", "/api/v1/machines", nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var machines []Machine
	if err := json.NewDecoder(resp.Body).Decode(&machines); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return machines, nil
}

func (c *Client) GetMachine(ctx context.Context, id string) (*Machine, error) {
	resp, err := c.doRequest(ctx, "GET", fmt.Sprintf("/api/v1/machines/%s", id), nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var machine Machine
	if err := json.NewDecoder(resp.Body).Decode(&machine); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return &machine, nil
}

func (c *Client) CreateMachine(ctx context.Context, req CreateMachineRequest) (*Machine, error) {
	resp, err := c.doRequest(ctx, "POST", "/api/v1/machines", req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var machine Machine
	if err := json.NewDecoder(resp.Body).Decode(&machine); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return &machine, nil
}

func (c *Client) PerformAction(ctx context.Context, id string, action string, params map[string]interface{}) (map[string]interface{}, error) {
	req := ActionRequest{
		Action: action,
		Params: params,
	}

	resp, err := c.doRequest(ctx, "POST", fmt.Sprintf("/api/v1/machines/%s/action", id), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return result, nil
}

func (c *Client) MigrateMachine(ctx context.Context, id string, req MigrateRequest) (map[string]interface{}, error) {
	params := map[string]interface{}{
		"target_region": req.TargetRegion,
	}
	if req.Strategy != "" {
		params["strategy"] = req.Strategy
	}

	return c.PerformAction(ctx, id, "migrate", params)
}

func (c *Client) GetFSMState(ctx context.Context, id string) (map[string]interface{}, error) {
	resp, err := c.doRequest(ctx, "GET", fmt.Sprintf("/api/v1/fsm/%s/state", id), nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return result, nil
}

func (c *Client) GetFSMHistory(ctx context.Context, id string) (map[string]interface{}, error) {
	resp, err := c.doRequest(ctx, "GET", fmt.Sprintf("/api/v1/fsm/%s/history", id), nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return result, nil
}

func (c *Client) GetMachineMetrics(ctx context.Context, id string) (map[string]interface{}, error) {
	resp, err := c.doRequest(ctx, "GET", fmt.Sprintf("/api/v1/debug/metrics/%s", id), nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return result, nil
}

func (c *Client) GetMachineThreads(ctx context.Context, id string, stacks bool) ([]map[string]interface{}, error) {
	path := fmt.Sprintf("/api/v1/debug/threads/%s", id)
	if stacks {
		path += "?stacks=true"
	}

	resp, err := c.doRequest(ctx, "GET", path, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		Threads []map[string]interface{} `json:"threads"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return result.Threads, nil
}

func (c *Client) GetMachineNetwork(ctx context.Context, id string, listening bool, protocol string) ([]map[string]interface{}, error) {
	path := fmt.Sprintf("/api/v1/debug/network/%s", id)
	params := url.Values{}
	if listening {
		params.Set("listening", "true")
	}
	if protocol != "" {
		params.Set("protocol", protocol)
	}
	if len(params) > 0 {
		path += "?" + params.Encode()
	}

	resp, err := c.doRequest(ctx, "GET", path, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		Connections []map[string]interface{} `json:"connections"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return result.Connections, nil
}

func (c *Client) GetMachineFDs(ctx context.Context, id string, fdType string) ([]map[string]interface{}, error) {
	path := fmt.Sprintf("/api/v1/debug/fds/%s", id)
	if fdType != "" {
		path += "?type=" + fdType
	}

	resp, err := c.doRequest(ctx, "GET", path, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		FileDescriptors []map[string]interface{} `json:"file_descriptors"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return result.FileDescriptors, nil
}

func (c *Client) ListAggregates(ctx context.Context, aggregateType string) ([]map[string]interface{}, error) {
	path := "/api/v1/events/aggregates"
	if aggregateType != "" {
		path += "?type=" + aggregateType
	}

	resp, err := c.doRequest(ctx, "GET", path, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		Aggregates []map[string]interface{} `json:"aggregates"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return result.Aggregates, nil
}

func (c *Client) GetEventStream(ctx context.Context, aggregateID string, opts map[string]string) ([]map[string]interface{}, error) {
	path := fmt.Sprintf("/api/v1/events/%s", aggregateID)

	params := url.Values{}
	for k, v := range opts {
		params.Set(k, v)
	}
	if len(params) > 0 {
		path += "?" + params.Encode()
	}

	resp, err := c.doRequest(ctx, "GET", path, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		Events []map[string]interface{} `json:"events"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return result.Events, nil
}

func (c *Client) RebuildAggregateState(ctx context.Context, aggregateID string, toVersion int, timeTravel string, noSnapshot bool) (map[string]interface{}, error) {
	path := fmt.Sprintf("/api/v1/events/%s/rebuild", aggregateID)

	params := url.Values{}
	if toVersion > 0 {
		params.Set("version", fmt.Sprintf("%d", toVersion))
	}
	if timeTravel != "" {
		params.Set("time", timeTravel)
	}
	if noSnapshot {
		params.Set("no_snapshot", "true")
	}
	if len(params) > 0 {
		path += "?" + params.Encode()
	}

	resp, err := c.doRequest(ctx, "POST", path, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return result, nil
}

func (c *Client) GetStateDiff(ctx context.Context, aggregateID string, fromVersion, toVersion int) (map[string]interface{}, error) {
	path := fmt.Sprintf("/api/v1/events/%s/diff?from=%d&to=%d", aggregateID, fromVersion, toVersion)

	resp, err := c.doRequest(ctx, "GET", path, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return result, nil
}

func (c *Client) SearchEvents(ctx context.Context, query string, eventTypes string, limit int) ([]map[string]interface{}, error) {
	params := url.Values{}
	params.Set("q", query)
	if eventTypes != "" {
		params.Set("types", eventTypes)
	}
	if limit > 0 {
		params.Set("limit", fmt.Sprintf("%d", limit))
	}

	path := "/api/v1/events/search?" + params.Encode()

	resp, err := c.doRequest(ctx, "GET", path, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		Events []map[string]interface{} `json:"events"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return result.Events, nil
}

func (c *Client) TraceCorrelation(ctx context.Context, correlationID string, limit int) ([]map[string]interface{}, error) {
	path := fmt.Sprintf("/api/v1/events/correlation/%s", correlationID)
	if limit > 0 {
		path += fmt.Sprintf("?limit=%d", limit)
	}

	resp, err := c.doRequest(ctx, "GET", path, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		Events []map[string]interface{} `json:"events"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return result.Events, nil
}
