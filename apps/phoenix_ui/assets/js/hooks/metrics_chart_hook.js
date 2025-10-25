import Chart from "chart.js/auto";

const MetricsChartHook = {
    mounted() {
        this.canvas = this.el;
        this.machineId = this.canvas.dataset.machineId;
        this.series = { labels: [], cpu: [], latency: [] };

        this.chart = new Chart(this.canvas.getContext("2d"), {
            type: "line",
            data: {
                labels: this.series.labels,
                datasets: [
                    {
                        label: "CPU (%)",
                        data: this.series.cpu,
                        borderColor: "#60A5FA",
                        backgroundColor: "rgba(96,165,250,0.08)",
                        yAxisID: "cpu",
                        tension: 0.3
                    },
                    {
                        label: "Latency (ms)",
                        data: this.series.latency,
                        borderColor: "#F59E0B",
                        backgroundColor: "rgba(245,158,11,0.06)",
                        yAxisID: "latency",
                        tension: 0.3
                    }
                ]
            },
            options: {
                animation: { duration: 0 },
                interaction: { intersect: false },
                scales: {
                    cpu: { type: "linear", position: "left", beginAtZero: true, ticks: { max: 100 } },
                    latency: { type: "linear", position: "right", beginAtZero: true }
                },
                plugins: { legend: { display: true } },
                responsive: true,
                maintainAspectRatio: false
            }
        });
    const eventName = `metrics:update:${this.machineId}`;
    this.handleEvent(eventName, ({ sample }) => this.pushSample(sample));
    },

    pushSample(sample) {
        const label = new Date(sample.ts).toLocaleTimeString();
        this.series.labels.push(label);
        this.series.cpu.push(Number(sample.cpu || 0));
        this.series.latency.push(Number(sample.latency || 0));

        if (this.series.labels.length > 120) {
            this.series.labels.shift();
            this.series.cpu.shift();
            this.series.latency.shift();
        }
        this.chart.update("none");
    }
};

export default MetricsChartHook;