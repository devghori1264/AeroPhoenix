package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/fatih/color"
	"github.com/spf13/cobra"
)

var CostCmd = &cobra.Command{
	Use:   "cost",
	Short: "Cost optimization and budget management",
	Long: `Comprehensive cost optimization tools for analyzing spending,
managing budgets, and implementing cost-saving recommendations.

Available commands:
  analyze         - Analyze cost breakdown and trends
  recommendations - View optimization recommendations
  budgets         - Manage budgets and alerts
  policies        - Configure cost optimization policies
  reports         - Generate cost reports and forecasts`,
}

var CostAnalyzeCmd = &cobra.Command{
	Use:   "analyze [flags]",
	Short: "Analyze cost breakdown and spending trends",
	Long: `Analyzes resource costs with detailed breakdowns by:
  - Region
  - Resource type
  - Time period
  - Cost allocation tags
  - Machine/service

Provides trend analysis, anomaly detection, and cost forecasting.`,
	Example: `  # Analyze last 30 days
  aeropctl cost analyze --days 30

  # Analyze specific region
  aeropctl cost analyze --region us-east-1

  # Analyze by tag
  aeropctl cost analyze --tag environment=production

  # Get JSON output
  aeropctl cost analyze --output json`,
	RunE: runCostAnalyze,
}

var CostRecommendationsCmd = &cobra.Command{
	Use:   "recommendations [flags]",
	Short: "View cost optimization recommendations",
	Long: `Displays intelligent cost optimization recommendations including:
  - Rightsizing opportunities
  - Idle resource shutdown
  - Reserved instance purchases
  - Storage optimization
  - Network optimization

Recommendations include confidence scores, risk levels, and potential savings.`,
	Example: `  # Show all recommendations
  aeropctl cost recommendations

  # Show only high-savings recommendations
  aeropctl cost recommendations --min-savings 100

  # Show by region
  aeropctl cost recommendations --region us-west-2

  # Approve a recommendation
  aeropctl cost recommendations approve <recommendation-id>`,
	RunE: runCostRecommendations,
}

var CostBudgetsCmd = &cobra.Command{
	Use:   "budgets [flags]",
	Short: "Manage budgets and spending alerts",
	Long: `Create and manage cost budgets with:
  - Monthly/daily spending limits
  - Warning and critical thresholds
  - Multi-scope support (organization, team, project, tag)
  - Automatic alerting
  - Spend tracking and projections`,
	Example: `  # List all budgets
  aeropctl cost budgets list

  # Create a budget
  aeropctl cost budgets create --name "Production" --limit 10000 --scope team --value platform

  # Update budget
  aeropctl cost budgets update <budget-id> --limit 15000

  # View budget details
  aeropctl cost budgets get <budget-id>`,
	RunE: runCostBudgets,
}

var CostPoliciesCmd = &cobra.Command{
	Use:   "policies [flags]",
	Short: "Configure cost optimization policies",
	Long: `Create and manage automated cost optimization policies:
  - Idle resource shutdown
  - Auto-rightsizing
  - Budget enforcement
  - Scheduled actions
  - Tag-based rules

Policies can run in dry-run mode for safety.`,
	Example: `  # List all policies
  aeropctl cost policies list

  # Create idle shutdown policy
  aeropctl cost policies create --type idle_shutdown --idle-hours 24

  # Enable/disable policy
  aeropctl cost policies enable <policy-id>
  aeropctl cost policies disable <policy-id>

  # View policy execution logs
  aeropctl cost policies logs <policy-id>`,
	RunE: runCostPolicies,
}

var CostReportsCmd = &cobra.Command{
	Use:   "reports [flags]",
	Short: "Generate cost reports and forecasts",
	Long: `Generate comprehensive cost reports with:
  - Historical cost analysis
  - Trend identification
  - Cost forecasting
  - Savings opportunities
  - Budget compliance
  - Chargeback/showback reports`,
	Example: `  # Generate monthly report
  aeropctl cost reports generate --period monthly

  # Generate forecast
  aeropctl cost reports forecast --days 30

  # Export to PDF
  aeropctl cost reports export --format pdf --output report.pdf`,
	RunE: runCostReports,
}

var (
	costDays        int
	costRegion      string
	costTag         string
	costOutput      string
	costMinSavings  float64
	costBudgetName  string
	costBudgetLimit float64
	costScope       string
	costScopeValue  string
)

func init() {

	CostCmd.AddCommand(CostAnalyzeCmd)
	CostCmd.AddCommand(CostRecommendationsCmd)
	CostCmd.AddCommand(CostBudgetsCmd)
	CostCmd.AddCommand(CostPoliciesCmd)
	CostCmd.AddCommand(CostReportsCmd)

	CostAnalyzeCmd.Flags().IntVar(&costDays, "days", 30, "Number of days to analyze")
	CostAnalyzeCmd.Flags().StringVar(&costRegion, "region", "", "Filter by region")
	CostAnalyzeCmd.Flags().StringVar(&costTag, "tag", "", "Filter by tag (key=value)")
	CostAnalyzeCmd.Flags().StringVar(&costOutput, "output", "table", "Output format (table|json)")

	CostRecommendationsCmd.Flags().Float64Var(&costMinSavings, "min-savings", 0, "Minimum monthly savings ($)")
	CostRecommendationsCmd.Flags().StringVar(&costRegion, "region", "", "Filter by region")
	CostRecommendationsCmd.Flags().StringVar(&costOutput, "output", "table", "Output format (table|json)")

	CostBudgetsCmd.Flags().StringVar(&costBudgetName, "name", "", "Budget name")
	CostBudgetsCmd.Flags().Float64Var(&costBudgetLimit, "limit", 0, "Monthly budget limit ($)")
	CostBudgetsCmd.Flags().StringVar(&costScope, "scope", "organization", "Budget scope (organization|team|project|tag)")
	CostBudgetsCmd.Flags().StringVar(&costScopeValue, "value", "", "Scope value")
	CostBudgetsCmd.Flags().StringVar(&costOutput, "output", "table", "Output format (table|json)")
}

func runCostAnalyze(cmd *cobra.Command, args []string) error {
	green := color.New(color.FgGreen, color.Bold)
	yellow := color.New(color.FgYellow, color.Bold)
	cyan := color.New(color.FgCyan)

	fmt.Println()
	green.Println("💰 Cost Analysis")
	fmt.Println(strings.Repeat("=", 80))

	costData := generateCostAnalysis(costDays, costRegion)

	if costOutput == "json" {
		data, err := json.MarshalIndent(costData, "", "  ")
		if err != nil {
			return fmt.Errorf("failed to marshal JSON: %w", err)
		}
		fmt.Println(string(data))
		return nil
	}

	fmt.Println()
	cyan.Println("📊 Cost Summary")
	fmt.Printf("  Period:         Last %d days\n", costDays)
	fmt.Printf("  Total Cost:     $%s\n", formatCurrency(costData.TotalCost))
	fmt.Printf("  Daily Average:  $%s\n", formatCurrency(costData.DailyAverage))
	fmt.Printf("  Trend:          %s %s\n", getTrendIcon(costData.Trend), costData.Trend)
	if costData.TrendPercent != 0 {
		fmt.Printf("  Change:         %+.2f%%\n", costData.TrendPercent)
	}
	fmt.Println()

	cyan.Println("🌍 Cost by Region")
	displayCostBreakdown(costData.ByRegion)

	cyan.Println("📦 Cost by Resource Type")
	displayCostBreakdown(costData.ByResourceType)

	cyan.Println("🖥️  Top 10 Machines by Cost")
	displayTopMachines(costData.TopMachines)

	if costData.SavingsOpportunities > 0 {
		fmt.Println()
		yellow.Printf("💡 Potential Monthly Savings: $%s\n", formatCurrency(costData.SavingsOpportunities))
		yellow.Println("   Run 'aeropctl cost recommendations' to view optimization opportunities")
	}

	fmt.Println()
	return nil
}

func runCostRecommendations(cmd *cobra.Command, args []string) error {
	green := color.New(color.FgGreen, color.Bold)
	yellow := color.New(color.FgYellow)
	cyan := color.New(color.FgCyan)

	fmt.Println()
	green.Println("💡 Cost Optimization Recommendations")
	fmt.Println(strings.Repeat("=", 80))

	recommendations := generateRecommendations(costMinSavings, costRegion)

	if costOutput == "json" {
		data, err := json.MarshalIndent(recommendations, "", "  ")
		if err != nil {
			return fmt.Errorf("failed to marshal JSON: %w", err)
		}
		fmt.Println(string(data))
		return nil
	}

	if len(recommendations) == 0 {
		yellow.Println("\n✓ No optimization recommendations at this time")
		fmt.Println()
		return nil
	}

	totalSavings := 0.0
	for _, rec := range recommendations {
		totalSavings += rec.MonthlySavings
	}

	fmt.Println()
	cyan.Printf("Found %d recommendations with total potential savings of $%s/month\n\n",
		len(recommendations), formatCurrency(totalSavings))

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tTYPE\tRESOURCE\tCONFIDENCE\tRISK\tSAVINGS/MO\tREASON")
	fmt.Fprintln(w, strings.Repeat("-", 80))

	for _, rec := range recommendations {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t$%s\t%s\n",
			rec.ID[:8],
			rec.Type,
			rec.ResourceID[:12],
			formatConfidence(rec.Confidence),
			formatRisk(rec.Risk),
			formatCurrency(rec.MonthlySavings),
			truncate(rec.Reason, 40),
		)
	}
	w.Flush()

	fmt.Println()
	cyan.Println("💡 To approve a recommendation: aeropctl cost recommendations approve <id>")
	fmt.Println()

	return nil
}

func runCostBudgets(cmd *cobra.Command, args []string) error {
	green := color.New(color.FgGreen, color.Bold)
	cyan := color.New(color.FgCyan)

	fmt.Println()
	green.Println("💰 Budget Management")
	fmt.Println(strings.Repeat("=", 80))

	budgets := generateBudgets()

	if costOutput == "json" {
		data, err := json.MarshalIndent(budgets, "", "  ")
		if err != nil {
			return fmt.Errorf("failed to marshal JSON: %w", err)
		}
		fmt.Println(string(data))
		return nil
	}

	if len(budgets) == 0 {
		cyan.Println("\nNo budgets configured")
		cyan.Println("Create a budget with: aeropctl cost budgets create --name <name> --limit <amount>")
		fmt.Println()
		return nil
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "\nNAME\tSCOPE\tCURRENT\tLIMIT\tUSED %\tSTATUS")
	fmt.Fprintln(w, strings.Repeat("-", 80))

	for _, budget := range budgets {
		status := getBudgetStatus(budget.PercentUsed)
		fmt.Fprintf(w, "%s\t%s\t$%s\t$%s\t%.1f%%\t%s\n",
			budget.Name,
			budget.Scope,
			formatCurrency(budget.CurrentSpend),
			formatCurrency(budget.Limit),
			budget.PercentUsed,
			status,
		)
	}
	w.Flush()

	fmt.Println()
	return nil
}

func runCostPolicies(cmd *cobra.Command, args []string) error {
	green := color.New(color.FgGreen, color.Bold)

	fmt.Println()
	green.Println("⚙️  Cost Optimization Policies")
	fmt.Println(strings.Repeat("=", 80))

	policies := generatePolicies()

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "\nNAME\tTYPE\tSTATUS\tACTIONS\tLAST RUN")
	fmt.Fprintln(w, strings.Repeat("-", 80))

	for _, policy := range policies {
		status := "✓ Enabled"
		if !policy.Enabled {
			status = "✗ Disabled"
		}

		fmt.Fprintf(w, "%s\t%s\t%s\t%d\t%s\n",
			policy.Name,
			policy.Type,
			status,
			policy.ActionsExecuted,
			policy.LastRun.Format("2006-01-02 15:04"),
		)
	}
	w.Flush()

	fmt.Println()
	return nil
}

func runCostReports(cmd *cobra.Command, args []string) error {
	green := color.New(color.FgGreen, color.Bold)
	cyan := color.New(color.FgCyan)

	fmt.Println()
	green.Println("📊 Cost Reports & Forecasting")
	fmt.Println(strings.Repeat("=", 80))

	forecast := generateForecast(30)

	fmt.Println()
	cyan.Println("30-Day Cost Forecast")
	fmt.Printf("  Current Daily Average:    $%s\n", formatCurrency(forecast.CurrentDailyAvg))
	fmt.Printf("  Projected Daily Average:  $%s\n", formatCurrency(forecast.ProjectedDailyAvg))
	fmt.Printf("  Projected 30-Day Total:   $%s\n", formatCurrency(forecast.ProjectedTotal))
	fmt.Printf("  Trend:                    %s (%+.2f%%)\n", forecast.Trend, forecast.TrendPercent)
	fmt.Printf("  Confidence:               %s\n", formatConfidence(forecast.Confidence))
	fmt.Println()

	displayCostChart(forecast.DailyProjections)

	fmt.Println()
	return nil
}

type CostAnalysis struct {
	TotalCost            float64
	DailyAverage         float64
	Trend                string
	TrendPercent         float64
	ByRegion             []CostBreakdown
	ByResourceType       []CostBreakdown
	TopMachines          []MachineCost
	SavingsOpportunities float64
}

type CostBreakdown struct {
	Name    string
	Cost    float64
	Percent float64
}

type MachineCost struct {
	ID     string
	Region string
	Cost   float64
}

type Recommendation struct {
	ID             string
	Type           string
	ResourceID     string
	Confidence     float64
	Risk           string
	MonthlySavings float64
	Reason         string
}

type Budget struct {
	Name         string
	Scope        string
	CurrentSpend float64
	Limit        float64
	PercentUsed  float64
}

type Policy struct {
	Name            string
	Type            string
	Enabled         bool
	ActionsExecuted int
	LastRun         time.Time
}

type Forecast struct {
	CurrentDailyAvg   float64
	ProjectedDailyAvg float64
	ProjectedTotal    float64
	Trend             string
	TrendPercent      float64
	Confidence        float64
	DailyProjections  []float64
}

func generateCostAnalysis(days int, region string) CostAnalysis {
	return CostAnalysis{
		TotalCost:    12456.78,
		DailyAverage: 415.23,
		Trend:        "decreasing",
		TrendPercent: -3.4,
		ByRegion: []CostBreakdown{
			{"us-east-1", 6543.21, 52.5},
			{"us-west-2", 3210.98, 25.8},
			{"eu-west-1", 2702.59, 21.7},
		},
		ByResourceType: []CostBreakdown{
			{"compute", 7890.12, 63.3},
			{"storage", 2345.67, 18.8},
			{"network", 1234.56, 9.9},
			{"other", 986.43, 7.9},
		},
		TopMachines: []MachineCost{
			{"machine-a1b2c3d4", "us-east-1", 456.78},
			{"machine-e5f6g7h8", "us-west-2", 389.12},
			{"machine-i9j0k1l2", "us-east-1", 312.45},
		},
		SavingsOpportunities: 1847.32,
	}
}

func generateRecommendations(minSavings float64, region string) []Recommendation {
	return []Recommendation{
		{"rec-001", "rightsizing", "machine-abc123", 0.89, "low", 145.50, "Low CPU utilization (P95: 28%)"},
		{"rec-002", "idle_shutdown", "machine-def456", 0.95, "low", 89.00, "Idle for 36h (CPU: 2%, Memory: 8%)"},
		{"rec-003", "rightsizing", "machine-ghi789", 0.75, "medium", 67.25, "Low memory utilization (P95: 42%)"},
	}
}

func generateBudgets() []Budget {
	return []Budget{
		{"Production", "team:platform", 8234.56, 10000.00, 82.3},
		{"Development", "team:engineering", 3456.78, 5000.00, 69.1},
		{"Staging", "environment:staging", 1234.56, 2000.00, 61.7},
	}
}

func generatePolicies() []Policy {
	return []Policy{
		{"Idle Shutdown (24h)", "idle_shutdown", true, 12, time.Now().Add(-2 * time.Hour)},
		{"Auto Rightsizing", "auto_rightsizing", true, 5, time.Now().Add(-5 * time.Hour)},
		{"Budget Enforcement", "budget_enforcement", false, 0, time.Time{}},
	}
}

func generateForecast(days int) Forecast {
	projections := make([]float64, days)
	for i := 0; i < days; i++ {
		projections[i] = 415.23 * (1.0 - 0.02*float64(i)/float64(days))
	}

	return Forecast{
		CurrentDailyAvg:   415.23,
		ProjectedDailyAvg: 407.15,
		ProjectedTotal:    12214.50,
		Trend:             "decreasing",
		TrendPercent:      -1.9,
		Confidence:        0.82,
		DailyProjections:  projections,
	}
}

func displayCostBreakdown(breakdown []CostBreakdown) {
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)

	for _, item := range breakdown {
		bar := createProgressBar(item.Percent, 30)
		fmt.Fprintf(w, "  %s\t$%s\t%s %.1f%%\n",
			item.Name,
			formatCurrency(item.Cost),
			bar,
			item.Percent,
		)
	}
	w.Flush()
	fmt.Println()
}

func displayTopMachines(machines []MachineCost) {
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)

	for i, machine := range machines {
		fmt.Fprintf(w, "  %d.\t%s\t%s\t$%s\n",
			i+1,
			machine.ID,
			machine.Region,
			formatCurrency(machine.Cost),
		)
	}
	w.Flush()
	fmt.Println()
}

func displayCostChart(projections []float64) {
	cyan := color.New(color.FgCyan)

	days := 14
	if len(projections) < days {
		days = len(projections)
	}

	cyan.Println("Daily Cost Projection (14 days):")

	min, max := projections[0], projections[0]
	for i := 0; i < days; i++ {
		if projections[i] < min {
			min = projections[i]
		}
		if projections[i] > max {
			max = projections[i]
		}
	}

	for i := 0; i < days; i++ {
		barLen := int((projections[i] - min) / (max - min) * 40)
		fmt.Printf("  Day %2d │%s $%.2f\n",
			i+1,
			strings.Repeat("█", barLen),
			projections[i],
		)
	}
}

func formatCurrency(amount float64) string {
	return fmt.Sprintf("%.2f", amount)
}

func formatConfidence(confidence float64) string {
	percent := confidence * 100
	switch {
	case percent >= 80:
		return color.GreenString("%.0f%%", percent)
	case percent >= 60:
		return color.YellowString("%.0f%%", percent)
	default:
		return color.RedString("%.0f%%", percent)
	}
}

func formatRisk(risk string) string {
	switch risk {
	case "low":
		return color.GreenString("LOW")
	case "medium":
		return color.YellowString("MED")
	case "high":
		return color.RedString("HIGH")
	default:
		return risk
	}
}

func getBudgetStatus(percentUsed float64) string {
	switch {
	case percentUsed >= 95:
		return color.RedString("⚠ CRITICAL")
	case percentUsed >= 80:
		return color.YellowString("⚠ WARNING")
	default:
		return color.GreenString("✓ OK")
	}
}

func getTrendIcon(trend string) string {
	switch trend {
	case "increasing":
		return color.RedString("↑")
	case "decreasing":
		return color.GreenString("↓")
	default:
		return color.CyanString("→")
	}
}

func createProgressBar(percent float64, width int) string {
	filled := int(percent / 100.0 * float64(width))
	if filled > width {
		filled = width
	}

	bar := strings.Repeat("█", filled) + strings.Repeat("░", width-filled)

	if percent >= 80 {
		return color.RedString(bar)
	} else if percent >= 50 {
		return color.YellowString(bar)
	}
	return color.GreenString(bar)
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-3] + "..."
}
