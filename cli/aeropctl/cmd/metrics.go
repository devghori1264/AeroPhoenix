package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"
)

var metricsCmd = &cobra.Command{
	Use:   "metrics",
	Short: "Manage performance metrics and monitoring",
	Long: `Manage performance metrics, monitoring, alerts, SLAs, and dashboards.

The metrics system provides comprehensive observability including:
- High-frequency time-series metrics collection (100K+ metrics/sec)
- Real-time alerting with PromQL query evaluation
- SLA compliance tracking and error budget management
- Custom dashboards with multiple visualization types
- ML-based anomaly detection
- Auto-scaling based on predictive analytics

Examples:
  # List recent metrics
  aeropctl metrics list --service orchestrator_api --hours 1

  # Query specific metric with PromQL
  aeropctl metrics query 'avg(cpu_usage_percent{service="api"}) by (region)'

  # View alert rules
  aeropctl metrics alerts list

  # Check SLA compliance
  aeropctl metrics sla status --service orchestrator_api

  # Export dashboard
  aeropctl metrics dashboard export production_overview`,
}

const (
	metricsAPIBase = "/api/v1/metrics"
)

type MetricSample struct {
	ID         string            `json:"id"`
	MetricID   string            `json:"metric_id"`
	MetricName string            `json:"metric_name"`
	Value      float64           `json:"value"`
	Labels     map[string]string `json:"labels"`
	Timestamp  time.Time         `json:"timestamp"`
}

type AlertRule struct {
	ID            string   `json:"id"`
	Name          string   `json:"name"`
	Query         string   `json:"query"`
	Threshold     float64  `json:"threshold"`
	Operator      string   `json:"operator"`
	Severity      string   `json:"severity"`
	State         string   `json:"state"`
	Notifications []string `json:"notifications"`
}

type AlertInstance struct {
	ID         string     `json:"id"`
	RuleID     string     `json:"rule_id"`
	RuleName   string     `json:"rule_name"`
	State      string     `json:"state"`
	Value      float64    `json:"value"`
	FiredAt    time.Time  `json:"fired_at"`
	ResolvedAt *time.Time `json:"resolved_at,omitempty"`
	Message    string     `json:"message"`
}

type SLADefinition struct {
	ID                string  `json:"id"`
	Name              string  `json:"name"`
	Service           string  `json:"service"`
	Metric            string  `json:"metric"`
	Target            float64 `json:"target"`
	ErrorBudget       float64 `json:"error_budget"`
	CompliancePercent float64 `json:"compliance_percent"`
	Period            string  `json:"period"`
}

type Dashboard struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Description string    `json:"description"`
	TimeRange   string    `json:"time_range"`
	RefreshRate int       `json:"refresh_rate"`
	PanelCount  int       `json:"panel_count"`
	CreatedAt   time.Time `json:"created_at"`
}

type Anomaly struct {
	ID            string    `json:"id"`
	MetricName    string    `json:"metric_name"`
	Severity      string    `json:"severity"`
	Score         float64   `json:"score"`
	ExpectedValue float64   `json:"expected_value"`
	ActualValue   float64   `json:"actual_value"`
	DetectedAt    time.Time `json:"detected_at"`
	Status        string    `json:"status"`
}

func MetricsCmd() *cobra.Command {
	return metricsCmd
}

func init() {

	metricsCmd.AddCommand(metricsListCmd)
	metricsCmd.AddCommand(metricsQueryCmd)
	metricsCmd.AddCommand(metricsAlertsCmd)
	metricsCmd.AddCommand(metricsSLACmd)
	metricsCmd.AddCommand(metricsDashboardCmd)
	metricsCmd.AddCommand(metricsAnomaliesCmd)
	metricsCmd.AddCommand(metricsExportCmd)

	metricsListCmd.Flags().StringP("service", "s", "", "Filter by service name")
	metricsListCmd.Flags().IntP("hours", "h", 1, "Hours of data to retrieve")
	metricsListCmd.Flags().StringP("metric", "m", "", "Specific metric name")
	metricsListCmd.Flags().StringP("format", "f", "table", "Output format: table, json, csv")

	metricsQueryCmd.Flags().StringP("start", "s", "1h", "Start time (e.g., 1h, 24h, 7d)")
	metricsQueryCmd.Flags().StringP("end", "e", "now", "End time")
	metricsQueryCmd.Flags().StringP("step", "t", "1m", "Query resolution step")

	metricsAlertsCmd.AddCommand(alertsListCmd)
	metricsAlertsCmd.AddCommand(alertsCreateCmd)
	metricsAlertsCmd.AddCommand(alertsDeleteCmd)
	metricsAlertsCmd.AddCommand(alertsFiringCmd)

	alertsListCmd.Flags().StringP("severity", "s", "", "Filter by severity: critical, warning, info")
	alertsListCmd.Flags().BoolP("enabled", "e", false, "Show only enabled rules")

	alertsCreateCmd.Flags().StringP("file", "f", "", "Alert rule definition file (JSON/YAML)")
	alertsCreateCmd.Flags().StringP("name", "n", "", "Alert name")
	alertsCreateCmd.Flags().StringP("query", "q", "", "PromQL query")
	alertsCreateCmd.Flags().Float64P("threshold", "t", 0, "Threshold value")
	alertsCreateCmd.Flags().StringP("operator", "o", "gt", "Operator: gt, gte, lt, lte, eq, neq")
	alertsCreateCmd.Flags().StringP("severity", "s", "warning", "Severity: critical, warning, info")

	metricsSLACmd.AddCommand(slaStatusCmd)
	metricsSLACmd.AddCommand(slaListCmd)
	metricsSLACmd.AddCommand(slaCreateCmd)

	slaStatusCmd.Flags().StringP("service", "s", "", "Service name")
	slaStatusCmd.Flags().StringP("period", "p", "monthly", "Period: daily, weekly, monthly")

	slaCreateCmd.Flags().StringP("name", "n", "", "SLA name")
	slaCreateCmd.Flags().StringP("service", "s", "", "Service name")
	slaCreateCmd.Flags().StringP("metric", "m", "", "Metric to track")
	slaCreateCmd.Flags().Float64P("target", "t", 99.9, "Target percentage (e.g., 99.9)")
	slaCreateCmd.Flags().Float64P("budget", "b", 0.1, "Error budget percentage")

	metricsDashboardCmd.AddCommand(dashboardListCmd)
	metricsDashboardCmd.AddCommand(dashboardExportCmd)
	metricsDashboardCmd.AddCommand(dashboardImportCmd)
	metricsDashboardCmd.AddCommand(dashboardCreateCmd)

	dashboardExportCmd.Flags().StringP("output", "o", "", "Output file path")
	dashboardImportCmd.Flags().StringP("file", "f", "", "Dashboard definition file")

	metricsAnomaliesCmd.Flags().StringP("service", "s", "", "Filter by service")
	metricsAnomaliesCmd.Flags().StringP("severity", "v", "", "Filter by severity: critical, high, medium, low")
	metricsAnomaliesCmd.Flags().IntP("hours", "h", 24, "Hours to look back")

	metricsExportCmd.Flags().StringP("service", "s", "", "Service to export")
	metricsExportCmd.Flags().StringP("start", "t", "24h", "Start time")
	metricsExportCmd.Flags().StringP("format", "f", "json", "Export format: json, csv, prometheus")
	metricsExportCmd.Flags().StringP("output", "o", "", "Output file")
}

var metricsListCmd = &cobra.Command{
	Use:   "list",
	Short: "List recent metrics",
	Long:  `List recent metric samples with optional filtering by service, metric name, and time range.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		service, _ := cmd.Flags().GetString("service")
		hours, _ := cmd.Flags().GetInt("hours")
		metric, _ := cmd.Flags().GetString("metric")
		format, _ := cmd.Flags().GetString("format")

		params := fmt.Sprintf("hours=%d", hours)
		if service != "" {
			params += fmt.Sprintf("&service=%s", service)
		}
		if metric != "" {
			params += fmt.Sprintf("&metric=%s", metric)
		}

		url := fmt.Sprintf("%s%s/samples?%s", getAPIBase(), metricsAPIBase, params)
		resp, err := makeRequest("GET", url, nil)
		if err != nil {
			return fmt.Errorf("failed to fetch metrics: %w", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			body, _ := io.ReadAll(resp.Body)
			return fmt.Errorf("API error: %s - %s", resp.Status, string(body))
		}

		var metrics []MetricSample
		if err := json.NewDecoder(resp.Body).Decode(&metrics); err != nil {
			return fmt.Errorf("failed to parse response: %w", err)
		}

		return displayMetrics(metrics, format)
	},
}

var metricsQueryCmd = &cobra.Command{
	Use:   "query <promql>",
	Short: "Execute PromQL query",
	Long: `Execute a PromQL query against the metrics database.

Examples:
  # Average CPU by region
  aeropctl metrics query 'avg(cpu_usage_percent{service="api"}) by (region)'
  
  # Request rate over last hour
  aeropctl metrics query 'rate(http_requests_total[5m])' --start 1h
  
  # 95th percentile latency
  aeropctl metrics query 'histogram_quantile(0.95, http_request_duration_seconds)'`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		query := args[0]
		start, _ := cmd.Flags().GetString("start")
		end, _ := cmd.Flags().GetString("end")
		step, _ := cmd.Flags().GetString("step")

		payload := map[string]string{
			"query": query,
			"start": start,
			"end":   end,
			"step":  step,
		}

		jsonData, _ := json.Marshal(payload)
		url := fmt.Sprintf("%s%s/query", getAPIBase(), metricsAPIBase)
		resp, err := makeRequest("POST", url, jsonData)
		if err != nil {
			return fmt.Errorf("failed to execute query: %w", err)
		}
		defer resp.Body.Close()

		var result map[string]interface{}
		if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
			return fmt.Errorf("failed to parse response: %w", err)
		}

		output, _ := json.MarshalIndent(result, "", "  ")
		fmt.Println(string(output))

		return nil
	},
}

var metricsAlertsCmd = &cobra.Command{
	Use:   "alerts",
	Short: "Manage alert rules and instances",
	Long:  `Manage alert rules, view firing alerts, and alert history.`,
}

var alertsListCmd = &cobra.Command{
	Use:   "list",
	Short: "List alert rules",
	RunE: func(cmd *cobra.Command, args []string) error {
		severity, _ := cmd.Flags().GetString("severity")
		enabledOnly, _ := cmd.Flags().GetBool("enabled")

		params := ""
		if severity != "" {
			params += fmt.Sprintf("severity=%s&", severity)
		}
		if enabledOnly {
			params += "enabled=true&"
		}

		url := fmt.Sprintf("%s%s/alerts?%s", getAPIBase(), metricsAPIBase, params)
		resp, err := makeRequest("GET", url, nil)
		if err != nil {
			return fmt.Errorf("failed to fetch alerts: %w", err)
		}
		defer resp.Body.Close()

		var alerts []AlertRule
		if err := json.NewDecoder(resp.Body).Decode(&alerts); err != nil {
			return fmt.Errorf("failed to parse response: %w", err)
		}

		return displayAlerts(alerts)
	},
}

var alertsCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create new alert rule",
	RunE: func(cmd *cobra.Command, args []string) error {
		file, _ := cmd.Flags().GetString("file")

		var payload []byte
		var err error

		if file != "" {

			payload, err = os.ReadFile(file)
			if err != nil {
				return fmt.Errorf("failed to read file: %w", err)
			}
		} else {

			name, _ := cmd.Flags().GetString("name")
			query, _ := cmd.Flags().GetString("query")
			threshold, _ := cmd.Flags().GetFloat64("threshold")
			operator, _ := cmd.Flags().GetString("operator")
			severity, _ := cmd.Flags().GetString("severity")

			if name == "" || query == "" {
				return fmt.Errorf("--name and --query are required")
			}

			alert := map[string]interface{}{
				"name":      name,
				"query":     query,
				"threshold": threshold,
				"operator":  operator,
				"severity":  severity,
			}
			payload, _ = json.Marshal(alert)
		}

		url := fmt.Sprintf("%s%s/alerts", getAPIBase(), metricsAPIBase)
		resp, err := makeRequest("POST", url, payload)
		if err != nil {
			return fmt.Errorf("failed to create alert: %w", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode == http.StatusCreated {
			fmt.Println("Alert rule created successfully")
			return nil
		}

		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed to create alert: %s", string(body))
	},
}

var alertsDeleteCmd = &cobra.Command{
	Use:   "delete <alert_id>",
	Short: "Delete alert rule",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		alertID := args[0]

		url := fmt.Sprintf("%s%s/alerts/%s", getAPIBase(), metricsAPIBase, alertID)
		resp, err := makeRequest("DELETE", url, nil)
		if err != nil {
			return fmt.Errorf("failed to delete alert: %w", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode == http.StatusOK {
			fmt.Printf("Alert rule %s deleted successfully\n", alertID)
			return nil
		}

		return fmt.Errorf("failed to delete alert: %s", resp.Status)
	},
}

var alertsFiringCmd = &cobra.Command{
	Use:   "firing",
	Short: "List currently firing alerts",
	RunE: func(cmd *cobra.Command, args []string) error {
		url := fmt.Sprintf("%s%s/alerts/firing", getAPIBase(), metricsAPIBase)
		resp, err := makeRequest("GET", url, nil)
		if err != nil {
			return fmt.Errorf("failed to fetch firing alerts: %w", err)
		}
		defer resp.Body.Close()

		var alerts []AlertInstance
		if err := json.NewDecoder(resp.Body).Decode(&alerts); err != nil {
			return fmt.Errorf("failed to parse response: %w", err)
		}

		return displayFiringAlerts(alerts)
	},
}

var metricsSLACmd = &cobra.Command{
	Use:   "sla",
	Short: "Manage SLA definitions and compliance",
	Long:  `View SLA status, compliance tracking, and error budget consumption.`,
}

var slaStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "View SLA compliance status",
	RunE: func(cmd *cobra.Command, args []string) error {
		service, _ := cmd.Flags().GetString("service")
		period, _ := cmd.Flags().GetString("period")

		params := fmt.Sprintf("period=%s", period)
		if service != "" {
			params += fmt.Sprintf("&service=%s", service)
		}

		url := fmt.Sprintf("%s%s/sla/status?%s", getAPIBase(), metricsAPIBase, params)
		resp, err := makeRequest("GET", url, nil)
		if err != nil {
			return fmt.Errorf("failed to fetch SLA status: %w", err)
		}
		defer resp.Body.Close()

		var slas []SLADefinition
		if err := json.NewDecoder(resp.Body).Decode(&slas); err != nil {
			return fmt.Errorf("failed to parse response: %w", err)
		}

		return displaySLAs(slas)
	},
}

var slaListCmd = &cobra.Command{
	Use:   "list",
	Short: "List SLA definitions",
	RunE: func(cmd *cobra.Command, args []string) error {
		url := fmt.Sprintf("%s%s/sla", getAPIBase(), metricsAPIBase)
		resp, err := makeRequest("GET", url, nil)
		if err != nil {
			return fmt.Errorf("failed to fetch SLAs: %w", err)
		}
		defer resp.Body.Close()

		var slas []SLADefinition
		if err := json.NewDecoder(resp.Body).Decode(&slas); err != nil {
			return fmt.Errorf("failed to parse response: %w", err)
		}

		return displaySLAs(slas)
	},
}

var slaCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create new SLA definition",
	RunE: func(cmd *cobra.Command, args []string) error {
		name, _ := cmd.Flags().GetString("name")
		service, _ := cmd.Flags().GetString("service")
		metric, _ := cmd.Flags().GetString("metric")
		target, _ := cmd.Flags().GetFloat64("target")
		budget, _ := cmd.Flags().GetFloat64("budget")

		if name == "" || service == "" || metric == "" {
			return fmt.Errorf("--name, --service, and --metric are required")
		}

		payload := map[string]interface{}{
			"name":         name,
			"service":      service,
			"metric":       metric,
			"target":       target,
			"error_budget": budget,
		}

		jsonData, _ := json.Marshal(payload)
		url := fmt.Sprintf("%s%s/sla", getAPIBase(), metricsAPIBase)
		resp, err := makeRequest("POST", url, jsonData)
		if err != nil {
			return fmt.Errorf("failed to create SLA: %w", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode == http.StatusCreated {
			fmt.Println("SLA definition created successfully")
			return nil
		}

		return fmt.Errorf("failed to create SLA: %s", resp.Status)
	},
}

var metricsDashboardCmd = &cobra.Command{
	Use:   "dashboard",
	Short: "Manage dashboards",
	Long:  `Create, export, import, and manage dashboards.`,
}

var dashboardListCmd = &cobra.Command{
	Use:   "list",
	Short: "List dashboards",
	RunE: func(cmd *cobra.Command, args []string) error {
		url := fmt.Sprintf("%s%s/dashboards", getAPIBase(), metricsAPIBase)
		resp, err := makeRequest("GET", url, nil)
		if err != nil {
			return fmt.Errorf("failed to fetch dashboards: %w", err)
		}
		defer resp.Body.Close()

		var dashboards []Dashboard
		if err := json.NewDecoder(resp.Body).Decode(&dashboards); err != nil {
			return fmt.Errorf("failed to parse response: %w", err)
		}

		return displayDashboards(dashboards)
	},
}

var dashboardExportCmd = &cobra.Command{
	Use:   "export <dashboard_id>",
	Short: "Export dashboard definition",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		dashboardID := args[0]
		output, _ := cmd.Flags().GetString("output")

		url := fmt.Sprintf("%s%s/dashboards/%s/export", getAPIBase(), metricsAPIBase, dashboardID)
		resp, err := makeRequest("GET", url, nil)
		if err != nil {
			return fmt.Errorf("failed to export dashboard: %w", err)
		}
		defer resp.Body.Close()

		data, err := io.ReadAll(resp.Body)
		if err != nil {
			return fmt.Errorf("failed to read response: %w", err)
		}

		if output != "" {
			if err := os.WriteFile(output, data, 0644); err != nil {
				return fmt.Errorf("failed to write file: %w", err)
			}
			fmt.Printf("Dashboard exported to %s\n", output)
		} else {
			fmt.Println(string(data))
		}

		return nil
	},
}

var dashboardImportCmd = &cobra.Command{
	Use:   "import",
	Short: "Import dashboard definition",
	RunE: func(cmd *cobra.Command, args []string) error {
		file, _ := cmd.Flags().GetString("file")
		if file == "" {
			return fmt.Errorf("--file is required")
		}

		data, err := os.ReadFile(file)
		if err != nil {
			return fmt.Errorf("failed to read file: %w", err)
		}

		url := fmt.Sprintf("%s%s/dashboards/import", getAPIBase(), metricsAPIBase)
		resp, err := makeRequest("POST", url, data)
		if err != nil {
			return fmt.Errorf("failed to import dashboard: %w", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode == http.StatusCreated {
			fmt.Println("Dashboard imported successfully")
			return nil
		}

		return fmt.Errorf("failed to import dashboard: %s", resp.Status)
	},
}

var dashboardCreateCmd = &cobra.Command{
	Use:   "create <name>",
	Short: "Create new dashboard",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name := args[0]

		payload := map[string]interface{}{
			"name":         name,
			"description":  "",
			"time_range":   "1h",
			"refresh_rate": 30,
		}

		jsonData, _ := json.Marshal(payload)
		url := fmt.Sprintf("%s%s/dashboards", getAPIBase(), metricsAPIBase)
		resp, err := makeRequest("POST", url, jsonData)
		if err != nil {
			return fmt.Errorf("failed to create dashboard: %w", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode == http.StatusCreated {
			var dashboard Dashboard
			json.NewDecoder(resp.Body).Decode(&dashboard)
			fmt.Printf("Dashboard created: %s (ID: %s)\n", dashboard.Name, dashboard.ID)
			return nil
		}

		return fmt.Errorf("failed to create dashboard: %s", resp.Status)
	},
}

var metricsAnomaliesCmd = &cobra.Command{
	Use:   "anomalies",
	Short: "View detected anomalies",
	RunE: func(cmd *cobra.Command, args []string) error {
		service, _ := cmd.Flags().GetString("service")
		severity, _ := cmd.Flags().GetString("severity")
		hours, _ := cmd.Flags().GetInt("hours")

		params := fmt.Sprintf("hours=%d", hours)
		if service != "" {
			params += fmt.Sprintf("&service=%s", service)
		}
		if severity != "" {
			params += fmt.Sprintf("&severity=%s", severity)
		}

		url := fmt.Sprintf("%s%s/anomalies?%s", getAPIBase(), metricsAPIBase, params)
		resp, err := makeRequest("GET", url, nil)
		if err != nil {
			return fmt.Errorf("failed to fetch anomalies: %w", err)
		}
		defer resp.Body.Close()

		var anomalies []Anomaly
		if err := json.NewDecoder(resp.Body).Decode(&anomalies); err != nil {
			return fmt.Errorf("failed to parse response: %w", err)
		}

		return displayAnomalies(anomalies)
	},
}

var metricsExportCmd = &cobra.Command{
	Use:   "export",
	Short: "Export metrics data",
	RunE: func(cmd *cobra.Command, args []string) error {
		service, _ := cmd.Flags().GetString("service")
		start, _ := cmd.Flags().GetString("start")
		format, _ := cmd.Flags().GetString("format")
		output, _ := cmd.Flags().GetString("output")

		params := fmt.Sprintf("start=%s&format=%s", start, format)
		if service != "" {
			params += fmt.Sprintf("&service=%s", service)
		}

		url := fmt.Sprintf("%s%s/export?%s", getAPIBase(), metricsAPIBase, params)
		resp, err := makeRequest("GET", url, nil)
		if err != nil {
			return fmt.Errorf("failed to export metrics: %w", err)
		}
		defer resp.Body.Close()

		data, err := io.ReadAll(resp.Body)
		if err != nil {
			return fmt.Errorf("failed to read response: %w", err)
		}

		if output != "" {
			if err := os.WriteFile(output, data, 0644); err != nil {
				return fmt.Errorf("failed to write file: %w", err)
			}
			fmt.Printf("Metrics exported to %s\n", output)
		} else {
			fmt.Println(string(data))
		}

		return nil
	},
}

func displayMetrics(metrics []MetricSample, format string) error {
	if len(metrics) == 0 {
		fmt.Println("No metrics found")
		return nil
	}

	switch format {
	case "json":
		data, _ := json.MarshalIndent(metrics, "", "  ")
		fmt.Println(string(data))
	case "csv":
		fmt.Println("timestamp,metric,value,labels")
		for _, m := range metrics {
			labels := formatLabels(m.Labels)
			fmt.Printf("%s,%s,%.2f,\"%s\"\n", m.Timestamp.Format(time.RFC3339), m.MetricName, m.Value, labels)
		}
	default:
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "TIMESTAMP\tMETRIC\tVALUE\tLABELS")
		for _, m := range metrics {
			labels := formatLabels(m.Labels)
			fmt.Fprintf(w, "%s\t%s\t%.2f\t%s\n",
				m.Timestamp.Format("2006-01-02 15:04:05"),
				m.MetricName,
				m.Value,
				labels)
		}
		w.Flush()
	}

	return nil
}

func displayAlerts(alerts []AlertRule) error {
	if len(alerts) == 0 {
		fmt.Println("No alert rules found")
		return nil
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tNAME\tSEVERITY\tSTATE\tQUERY")
	for _, a := range alerts {
		query := truncate(a.Query, 50)
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\n", a.ID[:8], a.Name, a.Severity, a.State, query)
	}
	w.Flush()

	return nil
}

func displayFiringAlerts(alerts []AlertInstance) error {
	if len(alerts) == 0 {
		fmt.Println("No firing alerts")
		return nil
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "RULE\tSTATE\tVALUE\tFIRED AT\tDURATION\tMESSAGE")
	for _, a := range alerts {
		duration := time.Since(a.FiredAt).Round(time.Second)
		message := truncate(a.Message, 40)
		fmt.Fprintf(w, "%s\t%s\t%.2f\t%s\t%s\t%s\n",
			a.RuleName,
			a.State,
			a.Value,
			a.FiredAt.Format("15:04:05"),
			duration,
			message)
	}
	w.Flush()

	return nil
}

func displaySLAs(slas []SLADefinition) error {
	if len(slas) == 0 {
		fmt.Println("No SLA definitions found")
		return nil
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "NAME\tSERVICE\tMETRIC\tTARGET\tCURRENT\tBUDGET\tSTATUS")
	for _, s := range slas {
		status := "✓ OK"
		if s.CompliancePercent < s.Target {
			status = "✗ VIOLATION"
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%.2f%%\t%.2f%%\t%.2f%%\t%s\n",
			s.Name,
			s.Service,
			s.Metric,
			s.Target,
			s.CompliancePercent,
			s.ErrorBudget,
			status)
	}
	w.Flush()

	return nil
}

func displayDashboards(dashboards []Dashboard) error {
	if len(dashboards) == 0 {
		fmt.Println("No dashboards found")
		return nil
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tNAME\tPANELS\tTIME RANGE\tREFRESH\tCREATED")
	for _, d := range dashboards {
		fmt.Fprintf(w, "%s\t%s\t%d\t%s\t%ds\t%s\n",
			d.ID[:8],
			d.Name,
			d.PanelCount,
			d.TimeRange,
			d.RefreshRate,
			d.CreatedAt.Format("2006-01-02"))
	}
	w.Flush()

	return nil
}

func displayAnomalies(anomalies []Anomaly) error {
	if len(anomalies) == 0 {
		fmt.Println("No anomalies detected")
		return nil
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "METRIC\tSEVERITY\tSCORE\tEXPECTED\tACTUAL\tDETECTED\tSTATUS")
	for _, a := range anomalies {
		fmt.Fprintf(w, "%s\t%s\t%.2f\t%.2f\t%.2f\t%s\t%s\n",
			a.MetricName,
			a.Severity,
			a.Score,
			a.ExpectedValue,
			a.ActualValue,
			a.DetectedAt.Format("15:04:05"),
			a.Status)
	}
	w.Flush()

	return nil
}

func formatLabels(labels map[string]string) string {
	if len(labels) == 0 {
		return ""
	}

	parts := make([]string, 0, len(labels))
	for k, v := range labels {
		parts = append(parts, fmt.Sprintf("%s=%s", k, v))
	}
	return strings.Join(parts, ", ")
}

func makeRequest(method, url string, body []byte) (*http.Response, error) {
	var req *http.Request
	var err error

	if body != nil {
		req, err = http.NewRequest(method, url, strings.NewReader(string(body)))
	} else {
		req, err = http.NewRequest(method, url, nil)
	}

	if err != nil {
		return nil, err
	}

	req.Header.Set("Content-Type", "application/json")

	if token := os.Getenv("AEROP_API_TOKEN"); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	client := &http.Client{Timeout: 30 * time.Second}
	return client.Do(req)
}

func getAPIBase() string {
	if base := os.Getenv("AEROP_API_BASE"); base != "" {
		return base
	}
	return "http://localhost:4000"
}
