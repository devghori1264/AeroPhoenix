import * as d3 from 'd3';
import Chart from 'chart.js/auto';

export const ScalingVisualizerHook = {
  mounted() {
    console.log('[ScalingVisualizer] Mounted');
    
    this.initializePredictiveChart();
    this.initializeEventsTimeline();
    this.setupEventHandlers();
  },
  
  initializePredictiveChart() {
    const canvas = this.el.querySelector('#predictive-chart');
    if (!canvas) return;
    
    const ctx = canvas.getContext('2d');
    this.chart = new Chart(ctx, {
      type: 'line',
      data: {
        labels: [],
        datasets: [
          {
            label: 'Current Capacity',
            data: [],
            borderColor: '#8b5cf6',
            backgroundColor: 'rgba(139, 92, 246, 0.1)',
            fill: true,
            borderWidth: 2
          },
          {
            label: 'Predicted Load',
            data: [],
            borderColor: '#ec4899',
            borderDash: [5, 5],
            fill: false,
            borderWidth: 2
          },
          {
            label: 'Scaling Threshold',
            data: [],
            borderColor: '#fbbf24',
            borderDash: [10, 5],
            fill: false,
            borderWidth: 1
          }
        ]
      },
      options: {
        responsive: true,
        animation: { duration: 750, easing: 'easeInOutQuart' },
        scales: {
          y: { beginAtZero: true }
        }
      }
    });
  },
  
  initializeEventsTimeline() {
    const container = this.el.querySelector('#scaling-events');
    if (!container) return;
    
    this.eventsContainer = container;
  },
  
  setupEventHandlers() {
    this.handleEvent('scaling_event', (data) => {
      this.addScalingEvent(data);
    });
    
    this.handleEvent('capacity_update', (data) => {
      this.updateCapacity(data);
    });
  },
  
  addScalingEvent(event) {
    if (!this.eventsContainer) return;
    
    const el = document.createElement('div');
    el.className = `scaling-event event-${event.type}`;
    el.innerHTML = `
      <div class="event-icon">${event.type === 'scale_up' ? '📈' : '📉'}</div>
      <div class="event-content">
        <strong>${event.type === 'scale_up' ? 'Scaled Up' : 'Scaled Down'}</strong>
        <span>${event.instances} instances</span>
        <span class="event-time">${new Date(event.timestamp).toLocaleTimeString()}</span>
      </div>
    `;
    
    this.eventsContainer.prepend(el);
  },
  
  updateCapacity(data) {
    if (!this.chart) return;
    
    this.chart.data.labels.push(new Date(data.timestamp).toLocaleTimeString());
    this.chart.data.datasets[0].data.push(data.current);
    this.chart.data.datasets[1].data.push(data.predicted);
    this.chart.data.datasets[2].data.push(data.threshold);
    
    if (this.chart.data.labels.length > 50) {
      this.chart.data.labels.shift();
      this.chart.data.datasets.forEach(ds => ds.data.shift());
    }
    
    this.chart.update('active');
  },
  
  destroyed() {
    if (this.chart) this.chart.destroy();
  }
};

export default ScalingVisualizerHook;
