import Chart from 'chart.js/auto';


export const MetricsDashboardHook = {
  mounted() {
    console.log('[MetricsDashboard] Mounted');
    
    this.canvas = this.el.querySelector('canvas');
    if (!this.canvas) return;
    
    this.machineId = this.el.dataset.machineId;
    this.chartType = this.el.dataset.chartType || 'timeseries';
    
    this.data = {
      labels: [],
      datasets: []
    };
    
    this.stats = {
      p50: [],
      p95: [],
      p99: [],
      mean: [],
      max: []
    };
    
    this.thresholds = {
      cpu: { warning: 70, critical: 90 },
      latency: { warning: 100, critical: 500 },
      memory: { warning: 80, critical: 95 }
    };
    
    this.initializeChart();
    this.setupEventHandlers();
    this.startAnimations();
  },
  
  initializeChart() {
    const ctx = this.canvas.getContext('2d');
    
    if (this.chartType === 'timeseries') {
      this.createTimeSeriesChart(ctx);
    } else if (this.chartType === 'percentile') {
      this.createPercentileChart(ctx);
    } else if (this.chartType === 'comparative') {
      this.createComparativeChart(ctx);
    } else {
      this.createTimeSeriesChart(ctx);
    }
  },
  
  createTimeSeriesChart(ctx) {
    this.chart = new Chart(ctx, {
      type: 'line',
      data: {
        labels: this.data.labels,
        datasets: [
          {
            label: 'CPU Usage (%)',
            data: [],
            borderColor: 'rgba(139, 92, 246, 1)',
            backgroundColor: this.createGradient(ctx, 'rgba(139, 92, 246, 0.3)', 'rgba(139, 92, 246, 0)'),
            fill: true,
            tension: 0.4,
            borderWidth: 3,
            pointRadius: 0,
            pointHoverRadius: 6,
            pointHoverBackgroundColor: '#8b5cf6',
            pointHoverBorderColor: '#fff',
            pointHoverBorderWidth: 2,
            yAxisID: 'cpu'
          },
          {
            label: 'Latency (ms)',
            data: [],
            borderColor: 'rgba(236, 72, 153, 1)',
            backgroundColor: this.createGradient(ctx, 'rgba(236, 72, 153, 0.3)', 'rgba(236, 72, 153, 0)'),
            fill: true,
            tension: 0.4,
            borderWidth: 3,
            pointRadius: 0,
            pointHoverRadius: 6,
            pointHoverBackgroundColor: '#ec4899',
            pointHoverBorderColor: '#fff',
            pointHoverBorderWidth: 2,
            yAxisID: 'latency'
          },
          {
            label: 'Memory (%)',
            data: [],
            borderColor: 'rgba(6, 182, 212, 1)',
            backgroundColor: this.createGradient(ctx, 'rgba(6, 182, 212, 0.3)', 'rgba(6, 182, 212, 0)'),
            fill: true,
            tension: 0.4,
            borderWidth: 3,
            pointRadius: 0,
            pointHoverRadius: 6,
            pointHoverBackgroundColor: '#06b6d4',
            pointHoverBorderColor: '#fff',
            pointHoverBorderWidth: 2,
            yAxisID: 'memory'
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: {
          duration: 750,
          easing: 'easeInOutQuart',
          onProgress: (animation) => {
            this.animateGlow(animation.currentStep / animation.numSteps);
          }
        },
        interaction: {
          mode: 'index',
          intersect: false
        },
        scales: {
          x: {
            type: 'time',
            time: {
              unit: 'minute',
              displayFormats: {
                minute: 'HH:mm'
              }
            },
            grid: {
              color: 'rgba(71, 85, 105, 0.2)',
              drawBorder: false
            },
            ticks: {
              color: '#94a3b8',
              font: {
                family: "'Courier New', monospace",
                size: 11
              }
            }
          },
          cpu: {
            type: 'linear',
            position: 'left',
            min: 0,
            max: 100,
            grid: {
              color: 'rgba(139, 92, 246, 0.1)',
              drawBorder: false
            },
            ticks: {
              color: '#8b5cf6',
              font: {
                family: "'Courier New', monospace",
                size: 11
              },
              callback: (value) => `${value}%`
            }
          },
          latency: {
            type: 'linear',
            position: 'right',
            min: 0,
            grid: {
              display: false
            },
            ticks: {
              color: '#ec4899',
              font: {
                family: "'Courier New', monospace",
                size: 11
              },
              callback: (value) => `${value}ms`
            }
          },
          memory: {
            type: 'linear',
            position: 'right',
            min: 0,
            max: 100,
            grid: {
              display: false
            },
            ticks: {
              color: '#06b6d4',
              font: {
                family: "'Courier New', monospace",
                size: 11
              },
              callback: (value) => `${value}%`
            }
          }
        },
        plugins: {
          legend: {
            display: true,
            position: 'top',
            labels: {
              color: '#f3f4f6',
              font: {
                family: 'Inter, sans-serif',
                size: 12,
                weight: '600'
              },
              padding: 16,
              usePointStyle: true,
              pointStyle: 'circle'
            }
          },
          tooltip: {
            enabled: true,
            mode: 'index',
            intersect: false,
            backgroundColor: 'rgba(15, 23, 42, 0.95)',
            titleColor: '#f3f4f6',
            bodyColor: '#cbd5e1',
            borderColor: 'rgba(139, 92, 246, 0.5)',
            borderWidth: 2,
            padding: 12,
            displayColors: true,
            callbacks: {
              title: (items) => {
                return new Date(items[0].parsed.x).toLocaleString();
              },
              label: (context) => {
                const label = context.dataset.label || '';
                const value = context.parsed.y.toFixed(2);
                const threshold = this.getThreshold(label, value);
                return `${label}: ${value}${threshold}`;
              }
            }
          },
          zoom: {
            pan: {
              enabled: true,
              mode: 'x',
              modifierKey: 'shift'
            },
            zoom: {
              wheel: {
                enabled: true,
                speed: 0.1
              },
              pinch: {
                enabled: true
              },
              mode: 'x'
            },
            limits: {
              x: { min: 'original', max: 'original' }
            }
          }
        }
      }
    });
    
    this.addThresholdLines();
  },
  
  createPercentileChart(ctx) {
    this.chart = new Chart(ctx, {
      type: 'line',
      data: {
        labels: this.data.labels,
        datasets: [
          {
            label: 'p99',
            data: this.stats.p99,
            borderColor: 'rgba(239, 68, 68, 0.8)',
            borderWidth: 2,
            borderDash: [5, 5],
            fill: false,
            tension: 0.4,
            pointRadius: 0
          },
          {
            label: 'p95',
            data: this.stats.p95,
            borderColor: 'rgba(251, 191, 36, 0.8)',
            borderWidth: 2,
            borderDash: [3, 3],
            fill: '-1',
            backgroundColor: 'rgba(251, 191, 36, 0.1)',
            tension: 0.4,
            pointRadius: 0
          },
          {
            label: 'p50 (Median)',
            data: this.stats.p50,
            borderColor: 'rgba(16, 185, 129, 1)',
            borderWidth: 3,
            fill: '-1',
            backgroundColor: 'rgba(16, 185, 129, 0.15)',
            tension: 0.4,
            pointRadius: 0
          },
          {
            label: 'Mean',
            data: this.stats.mean,
            borderColor: 'rgba(139, 92, 246, 1)',
            borderWidth: 2,
            fill: false,
            tension: 0.4,
            pointRadius: 0
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: {
          duration: 1000,
          easing: 'easeInOutCubic'
        },
        scales: {
          x: {
            type: 'time',
            grid: {
              color: 'rgba(71, 85, 105, 0.2)'
            },
            ticks: {
              color: '#94a3b8'
            }
          },
          y: {
            beginAtZero: true,
            grid: {
              color: 'rgba(71, 85, 105, 0.2)'
            },
            ticks: {
              color: '#94a3b8'
            }
          }
        },
        plugins: {
          legend: {
            display: true,
            position: 'top',
            labels: {
              color: '#f3f4f6',
              usePointStyle: true
            }
          },
          tooltip: {
            mode: 'index',
            intersect: false,
            backgroundColor: 'rgba(15, 23, 42, 0.95)',
            titleColor: '#f3f4f6',
            bodyColor: '#cbd5e1',
            borderColor: 'rgba(139, 92, 246, 0.5)',
            borderWidth: 2
          }
        }
      }
    });
  },
  
  createComparativeChart(ctx) {
    this.chart = new Chart(ctx, {
      type: 'bar',
      data: {
        labels: ['Current', 'Previous Hour', '24h Ago', 'Weekly Avg'],
        datasets: [
          {
            label: 'CPU Usage',
            data: [0, 0, 0, 0],
            backgroundColor: 'rgba(139, 92, 246, 0.8)',
            borderColor: 'rgba(139, 92, 246, 1)',
            borderWidth: 2,
            borderRadius: 8
          },
          {
            label: 'Latency',
            data: [0, 0, 0, 0],
            backgroundColor: 'rgba(236, 72, 153, 0.8)',
            borderColor: 'rgba(236, 72, 153, 1)',
            borderWidth: 2,
            borderRadius: 8
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: {
          duration: 1500,
          easing: 'easeInOutElastic',
          delay: (context) => {
            return context.dataIndex * 150;
          }
        },
        scales: {
          y: {
            beginAtZero: true,
            grid: {
              color: 'rgba(71, 85, 105, 0.2)'
            },
            ticks: {
              color: '#94a3b8'
            }
          },
          x: {
            grid: {
              display: false
            },
            ticks: {
              color: '#94a3b8',
              font: {
                weight: '600'
              }
            }
          }
        },
        plugins: {
          legend: {
            display: true,
            position: 'top',
            labels: {
              color: '#f3f4f6',
              padding: 16
            }
          },
          tooltip: {
            backgroundColor: 'rgba(15, 23, 42, 0.95)',
            titleColor: '#f3f4f6',
            bodyColor: '#cbd5e1',
            borderColor: 'rgba(139, 92, 246, 0.5)',
            borderWidth: 2,
            padding: 12
          }
        }
      }
    });
  },
  
  addThresholdLines() {
    if (!this.chart || this.chartType !== 'timeseries') return;
    
    const cpuWarningPlugin = {
      id: 'cpuWarningLine',
      afterDatasetsDraw: (chart) => {
        const ctx = chart.ctx;
        const yScale = chart.scales.cpu;
        const xScale = chart.scales.x;
        
        ctx.save();
        ctx.strokeStyle = 'rgba(251, 191, 36, 0.6)';
        ctx.lineWidth = 2;
        ctx.setLineDash([10, 5]);
        
        const warningY = yScale.getPixelForValue(this.thresholds.cpu.warning);
        ctx.beginPath();
        ctx.moveTo(xScale.left, warningY);
        ctx.lineTo(xScale.right, warningY);
        ctx.stroke();
        
        ctx.strokeStyle = 'rgba(239, 68, 68, 0.6)';
        const criticalY = yScale.getPixelForValue(this.thresholds.cpu.critical);
        ctx.beginPath();
        ctx.moveTo(xScale.left, criticalY);
        ctx.lineTo(xScale.right, criticalY);
        ctx.stroke();
        
        ctx.restore();
      }
    };
    
    Chart.register(cpuWarningPlugin);
  },
  
  createGradient(ctx, color1, color2) {
    const gradient = ctx.createLinearGradient(0, 0, 0, 400);
    gradient.addColorStop(0, color1);
    gradient.addColorStop(1, color2);
    return gradient;
  },
  
  animateGlow(progress) {
    if (!this.canvas) return;
    
    const intensity = Math.sin(progress * Math.PI) * 0.3 + 0.2;
    this.canvas.style.filter = `drop-shadow(0 0 ${intensity * 20}px rgba(139, 92, 246, ${intensity}))`;
  },
  
  getThreshold(label, value) {
    let threshold = null;
    
    if (label.includes('CPU')) {
      threshold = this.thresholds.cpu;
    } else if (label.includes('Latency')) {
      threshold = this.thresholds.latency;
    } else if (label.includes('Memory')) {
      threshold = this.thresholds.memory;
    }
    
    if (!threshold) return '';
    
    if (value >= threshold.critical) {
      return ' 🔴 CRITICAL';
    } else if (value >= threshold.warning) {
      return ' ⚠️ WARNING';
    }
    return ' ✓';
  },
  
  setupEventHandlers() {
    this.handleEvent('metrics_update', (data) => {
      this.updateChart(data);
    });
    
    this.handleEvent('metrics_batch', (data) => {
      this.updateBatch(data);
    });
    
    this.handleEvent('reset_zoom', () => {
      if (this.chart && this.chart.resetZoom) {
        this.chart.resetZoom();
      }
    });
    
    const resetBtn = this.el.querySelector('.reset-zoom-btn');
    if (resetBtn) {
      resetBtn.addEventListener('click', () => {
        if (this.chart && this.chart.resetZoom) {
          this.chart.resetZoom('active');
        }
      });
    }
  },
  
  updateChart(data) {
    if (!this.chart) return;
    
    const timestamp = new Date(data.timestamp || Date.now());
    
    this.data.labels.push(timestamp);
    this.chart.data.datasets[0].data.push(data.cpu || 0);
    this.chart.data.datasets[1].data.push(data.latency || 0);
    this.chart.data.datasets[2].data.push(data.memory || 0);
    
    if (this.data.labels.length > 100) {
      this.data.labels.shift();
      this.chart.data.datasets.forEach(dataset => dataset.data.shift());
    }
    
    this.updatePercentileStats(data);
    
    this.checkThresholds(data);
    
    this.chart.update('active');
  },
  
  updateBatch(batch) {
    if (!this.chart || !batch.points) return;
    
    batch.points.forEach(point => {
      const timestamp = new Date(point.timestamp);
      this.data.labels.push(timestamp);
      this.chart.data.datasets[0].data.push(point.cpu || 0);
      this.chart.data.datasets[1].data.push(point.latency || 0);
      this.chart.data.datasets[2].data.push(point.memory || 0);
    });
    
    this.chart.update('none');
  },
  
  updatePercentileStats(data) {
    const values = [data.cpu, data.latency, data.memory].filter(v => v != null);
    
    if (values.length === 0) return;
    
    const sorted = values.slice().sort((a, b) => a - b);
    const p50 = sorted[Math.floor(sorted.length * 0.5)];
    const p95 = sorted[Math.floor(sorted.length * 0.95)];
    const p99 = sorted[Math.floor(sorted.length * 0.99)];
    const mean = sorted.reduce((a, b) => a + b, 0) / sorted.length;
    
    this.stats.p50.push(p50);
    this.stats.p95.push(p95);
    this.stats.p99.push(p99);
    this.stats.mean.push(mean);
    
    if (this.stats.p50.length > 100) {
      this.stats.p50.shift();
      this.stats.p95.shift();
      this.stats.p99.shift();
      this.stats.mean.shift();
    }
  },
  
  checkThresholds(data) {
    const alerts = [];
    
    if (data.cpu >= this.thresholds.cpu.critical) {
      alerts.push({ type: 'critical', metric: 'CPU', value: data.cpu });
    } else if (data.cpu >= this.thresholds.cpu.warning) {
      alerts.push({ type: 'warning', metric: 'CPU', value: data.cpu });
    }
    
    if (data.latency >= this.thresholds.latency.critical) {
      alerts.push({ type: 'critical', metric: 'Latency', value: data.latency });
    } else if (data.latency >= this.thresholds.latency.warning) {
      alerts.push({ type: 'warning', metric: 'Latency', value: data.latency });
    }
    
    if (alerts.length > 0) {
      this.pushEvent('threshold_alert', { alerts });
      this.showAlertAnimation(alerts);
    }
  },
  
  showAlertAnimation(alerts) {
    const container = this.el.querySelector('.alert-container');
    if (!container) return;
    
    alerts.forEach((alert, index) => {
      const el = document.createElement('div');
      el.className = `alert-badge alert-${alert.type}`;
      el.style.animationDelay = `${index * 100}ms`;
      el.textContent = `${alert.metric}: ${alert.value.toFixed(1)}`;
      
      container.appendChild(el);
      
      setTimeout(() => {
        el.classList.add('fade-out');
        setTimeout(() => el.remove(), 500);
      }, 3000);
    });
  },
  
  startAnimations() {
    setInterval(() => {
      if (this.chart && this.chart.data.datasets[0].data.length > 0) {
        const lastValue = this.chart.data.datasets[0].data.slice(-1)[0];
        if (lastValue > this.thresholds.cpu.warning) {
          this.el.classList.add('pulse-warning');
          setTimeout(() => this.el.classList.remove('pulse-warning'), 1000);
        }
      }
    }, 5000);
  },
  
  destroyed() {
    console.log('[MetricsDashboard] Destroyed');
    if (this.chart) {
      this.chart.destroy();
    }
  }
};

export default MetricsDashboardHook;
