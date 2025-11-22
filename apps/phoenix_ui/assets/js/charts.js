import { Chart, registerables } from 'chart.js';

Chart.register(...registerables);

function getThemeColors() {
  const isDark = document.documentElement.getAttribute('data-theme') === 'dark';

  return {
    primary: getComputedStyle(document.documentElement).getPropertyValue('--c-primary-600').trim() || '#7C3AED',
    success: getComputedStyle(document.documentElement).getPropertyValue('--c-emerald-500').trim() || '#10B981',
    warning: getComputedStyle(document.documentElement).getPropertyValue('--c-amber-500').trim() || '#F59E0B',
    error: getComputedStyle(document.documentElement).getPropertyValue('--c-rose-500').trim() || '#FB7185',
    info: getComputedStyle(document.documentElement).getPropertyValue('--c-sky-500').trim() || '#0EA5E9',
    text: getComputedStyle(document.documentElement).getPropertyValue('--text').trim() || (isDark ? '#E6EEF8' : '#0F172A'),
    textSecondary: getComputedStyle(document.documentElement).getPropertyValue('--text-secondary').trim() || (isDark ? '#CBD5E1' : '#475569'),
    border: getComputedStyle(document.documentElement).getPropertyValue('--border').trim() || (isDark ? '#334155' : '#E2E8F0'),
    grid: isDark ? 'rgba(255, 255, 255, 0.1)' : 'rgba(0, 0, 0, 0.1)'
  };
}

function getDefaultOptions(type = 'line') {
  const colors = getThemeColors();

  const baseOptions = {
    responsive: true,
    maintainAspectRatio: false,
    plugins: {
      legend: {
        labels: {
          color: colors.text,
          font: {
            family: 'Inter, sans-serif',
            size: 12
          }
        }
      },
      tooltip: {
        backgroundColor: colors.surface || 'rgba(0, 0, 0, 0.8)',
        titleColor: colors.text,
        bodyColor: colors.textSecondary,
        borderColor: colors.border,
        borderWidth: 1,
        cornerRadius: 8,
        padding: 12,
        titleFont: {
          family: 'Inter, sans-serif',
          size: 13,
          weight: 600
        },
        bodyFont: {
          family: 'Inter, sans-serif',
          size: 12
        }
      }
    },
    scales: {}
  };

  if (['line', 'bar', 'scatter'].includes(type)) {
    baseOptions.scales = {
      x: {
        ticks: {
          color: colors.textSecondary,
          font: {
            size: 11
          }
        },
        grid: {
          color: colors.grid
        }
      },
      y: {
        ticks: {
          color: colors.textSecondary,
          font: {
            size: 11
          }
        },
        grid: {
          color: colors.grid
        }
      }
    };
  }

  return baseOptions;
}

export function createLineChart(canvas, data, options = {}) {
  const colors = getThemeColors();
  const mergedOptions = {
    ...getDefaultOptions('line'),
    ...options
  };

  if (data.datasets) {
    data.datasets = data.datasets.map((dataset, idx) => ({
      borderColor: colors.primary,
      backgroundColor: `${colors.primary}33`,
      borderWidth: 2,
      tension: 0.4,
      fill: true,
      pointRadius: 3,
      pointHoverRadius: 5,
      ...dataset
    }));
  }

  return new Chart(canvas, {
    type: 'line',
    data,
    options: mergedOptions
  });
}

export function createBarChart(canvas, data, options = {}) {
  const colors = getThemeColors();
  const mergedOptions = {
    ...getDefaultOptions('bar'),
    ...options
  };

  if (data.datasets) {
    data.datasets = data.datasets.map((dataset, idx) => ({
      backgroundColor: colors.primary,
      borderColor: colors.primary,
      borderWidth: 1,
      borderRadius: 4,
      ...dataset
    }));
  }

  return new Chart(canvas, {
    type: 'bar',
    data,
    options: mergedOptions
  });
}

export function createDoughnutChart(canvas, data, options = {}) {
  const colors = getThemeColors();
  const defaultColors = [
    colors.primary,
    colors.success,
    colors.warning,
    colors.info,
    colors.error
  ];

  const mergedOptions = {
    ...getDefaultOptions('doughnut'),
    ...options
  };

  if (data.datasets) {
    data.datasets = data.datasets.map((dataset, idx) => ({
      backgroundColor: defaultColors,
      borderColor: colors.surface || '#fff',
      borderWidth: 2,
      ...dataset
    }));
  }

  return new Chart(canvas, {
    type: 'doughnut',
    data,
    options: mergedOptions
  });
}

export function createSparkline(canvas, data, color = null) {
  const colors = getThemeColors();
  const lineColor = color || colors.primary;

  const chartData = {
    labels: data.labels || Array.from({length: data.values.length}, (_, i) => i),
    datasets: [{
      data: data.values,
      borderColor: lineColor,
      backgroundColor: `${lineColor}22`,
      borderWidth: 2,
      tension: 0.4,
      fill: true,
      pointRadius: 0,
      pointHoverRadius: 3
    }]
  };

  return new Chart(canvas, {
    type: 'line',
    data: chartData,
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: {
          display: false
        },
        tooltip: {
          enabled: true,
          mode: 'index',
          intersect: false
        }
      },
      scales: {
        x: {
          display: false
        },
        y: {
          display: false
        }
      },
      interaction: {
        intersect: false,
        mode: 'index'
      }
    }
  });
}

export function updateChartData(chart, newData) {
  if (!chart) return;

  chart.data = newData;
  chart.update('none');
}

export function destroyChart(chart) {
  if (chart) {
    chart.destroy();
  }
}

let chartInstances = new Set();

export function registerChart(chart) {
  chartInstances.add(chart);
}

export function unregisterChart(chart) {
  chartInstances.delete(chart);
}

document.addEventListener('phx:theme-changed', () => {
  console.log('[Charts] Theme changed, updating all charts...');
  chartInstances.forEach(chart => {
    if (chart && !chart.isDestroyed) {
      chart.update('none');
    }
  });
});

export default {
  createLineChart,
  createBarChart,
  createDoughnutChart,
  createSparkline,
  updateChartData,
  destroyChart,
  registerChart,
  unregisterChart
};
