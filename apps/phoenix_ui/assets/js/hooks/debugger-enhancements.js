import * as d3 from 'd3';

export const DebuggerEnhancementsHook = {
  mounted() {
    console.log('[DebuggerEnhancements] Mounted');
    
    this.commandHistory = [];
    this.historyIndex = -1;
    this.filters = {
      level: 'all',
      search: '',
      regex: null
    };
    
    this.initializeCommandHistory();
    this.initializeProcessTree();
    this.initializeLogFilter();
    this.setupKeyboardShortcuts();
    this.handleEvent('update_process_tree', (data) => this.updateProcessTree(data));
    this.handleEvent('add_command', (data) => this.addToHistory(data.command));
  },
  
  initializeCommandHistory() {
    this.historyContainer = this.el.querySelector('#command-history');
    if (!this.historyContainer) return;
    
    this.searchInput = this.el.querySelector('#history-search');
    this.historyList = this.el.querySelector('#history-list');
    
    if (this.searchInput) {
      this.searchInput.addEventListener('input', (e) => {
        this.filterHistory(e.target.value);
      });
    }
  },
  
  addToHistory(command) {
    if (!command || command.trim() === '') return;
    
    const timestamp = new Date().toISOString();
    this.commandHistory.unshift({
      command: command.trim(),
      timestamp,
      id: `cmd-${Date.now()}-${Math.random()}`
    });
    if (this.commandHistory.length > 100) {
      this.commandHistory = this.commandHistory.slice(0, 100);
    }
    
    this.renderHistory();
  },
  
  filterHistory(query) {
    if (!query || query.trim() === '') {
      this.renderHistory();
      return;
    }
    const filtered = this.commandHistory.filter(item => {
      return this.fuzzyMatch(item.command.toLowerCase(), query.toLowerCase());
    });
    
    this.renderHistory(filtered);
  },
  
  fuzzyMatch(str, pattern) {
    let patternIdx = 0;
    let strIdx = 0;
    
    while (strIdx < str.length && patternIdx < pattern.length) {
      if (str[strIdx] === pattern[patternIdx]) {
        patternIdx++;
      }
      strIdx++;
    }
    
    return patternIdx === pattern.length;
  },
  
  renderHistory(items = this.commandHistory) {
    if (!this.historyList) return;
    
    this.historyList.innerHTML = '';
    
    items.forEach((item, index) => {
      const el = document.createElement('div');
      el.className = 'history-item';
      el.style.animationDelay = `${index * 30}ms`;
      
      const time = new Date(item.timestamp).toLocaleTimeString();
      
      el.innerHTML = `
        <div class="history-item-header">
          <span class="history-time">${time}</span>
          <button class="history-copy-btn" data-command="${item.command}">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"></path>
            </svg>
          </button>
        </div>
        <code class="history-command">${this.highlightCommand(item.command)}</code>
      `;
      const copyBtn = el.querySelector('.history-copy-btn');
      copyBtn.addEventListener('click', () => {
        this.copyToClipboard(item.command);
        this.showCopyFeedback(copyBtn);
      });
      el.addEventListener('click', (e) => {
        if (e.target !== copyBtn && !copyBtn.contains(e.target)) {
          this.pushEvent('run_command', { command: item.command });
        }
      });
      
      this.historyList.appendChild(el);
    });
  },
  
  highlightCommand(command) {
    return command
      .replace(/^(ls|cd|pwd|cat|grep|find|ps|top|tail|head|echo|mkdir|rm|cp|mv)\b/g, 
        '<span class="cmd-keyword">$1</span>')
      .replace(/(-[a-zA-Z]+)/g, '<span class="cmd-flag">$1</span>')
      .replace(/('.*?'|".*?")/g, '<span class="cmd-string">$1</span>')
      .replace(/(\d+)/g, '<span class="cmd-number">$1</span>');
  },
  
  copyToClipboard(text) {
    navigator.clipboard.writeText(text).catch(err => {
      console.error('Failed to copy:', err);
    });
  },
  
  showCopyFeedback(button) {
    const original = button.innerHTML;
    button.innerHTML = `
      <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"></path>
      </svg>
    `;
    button.classList.add('copied');
    
    setTimeout(() => {
      button.innerHTML = original;
      button.classList.remove('copied');
    }, 1500);
  },
  
  initializeProcessTree() {
    this.treeContainer = this.el.querySelector('#process-tree');
    if (!this.treeContainer) return;
    
    this.treeWidth = this.treeContainer.clientWidth;
    this.treeHeight = 400;
    this.treeSvg = d3.select(this.treeContainer)
      .append('svg')
      .attr('width', this.treeWidth)
      .attr('height', this.treeHeight)
      .attr('class', 'process-tree-svg');
    
    this.treeGroup = this.treeSvg.append('g')
      .attr('transform', 'translate(40, 20)');
    const zoom = d3.zoom()
      .scaleExtent([0.5, 2])
      .on('zoom', (event) => {
        this.treeGroup.attr('transform', event.transform);
      });
    
    this.treeSvg.call(zoom);
    this.updateProcessTree({ processes: [] });
  },
  
  updateProcessTree(data) {
    if (!this.treeGroup || !data.processes) return;
    const root = this.buildProcessTree(data.processes);
    const treeLayout = d3.tree()
      .size([this.treeHeight - 40, this.treeWidth - 80]);
    
    const treeData = treeLayout(d3.hierarchy(root));
    const links = this.treeGroup.selectAll('.process-link')
      .data(treeData.links(), d => `${d.source.data.pid}-${d.target.data.pid}`);
    
    links.exit()
      .transition()
      .duration(300)
      .attr('opacity', 0)
      .remove();
    
    const linksEnter = links.enter()
      .append('path')
      .attr('class', 'process-link')
      .attr('opacity', 0)
      .attr('d', d3.linkHorizontal()
        .x(d => d.y)
        .y(d => d.x));
    
    linksEnter.merge(links)
      .transition()
      .duration(500)
      .attr('opacity', 1)
      .attr('d', d3.linkHorizontal()
        .x(d => d.y)
        .y(d => d.x));
    const nodes = this.treeGroup.selectAll('.process-node')
      .data(treeData.descendants(), d => d.data.pid);
    
    nodes.exit()
      .transition()
      .duration(300)
      .attr('opacity', 0)
      .remove();
    
    const nodesEnter = nodes.enter()
      .append('g')
      .attr('class', 'process-node')
      .attr('transform', d => `translate(${d.y}, ${d.x})`)
      .attr('opacity', 0);
    nodesEnter.append('circle')
      .attr('r', 8)
      .attr('class', d => `process-circle ${this.getProcessStatus(d.data)}`);
    nodesEnter.append('text')
      .attr('dy', -15)
      .attr('class', 'process-label')
      .text(d => d.data.name || d.data.pid);
    nodesEnter.append('text')
      .attr('dy', 25)
      .attr('class', 'process-pid')
      .text(d => `PID: ${d.data.pid}`);
    nodesEnter.append('text')
      .attr('dy', 38)
      .attr('class', 'process-stats')
      .text(d => `CPU: ${d.data.cpu || 0}% | MEM: ${d.data.memory || 0}MB`);
    nodesEnter.append('title')
      .text(d => `${d.data.name}\nPID: ${d.data.pid}\nCPU: ${d.data.cpu || 0}%\nMemory: ${d.data.memory || 0}MB`);
    nodesEnter.merge(nodes)
      .transition()
      .duration(500)
      .attr('transform', d => `translate(${d.y}, ${d.x})`)
      .attr('opacity', 1);
    nodesEnter.on('click', (event, d) => {
      this.showProcessDetails(d.data);
    });
  },
  
  buildProcessTree(processes) {
    if (!processes || processes.length === 0) {
      return {
        pid: 0,
        name: 'No processes',
        children: []
      };
    }
    const processMap = new Map();
    processes.forEach(p => processMap.set(p.pid, { ...p, children: [] }));
    
    let root = null;
    processMap.forEach(process => {
      if (process.ppid && processMap.has(process.ppid)) {
        processMap.get(process.ppid).children.push(process);
      } else {
        root = process;
      }
    });
    
    return root || { pid: 0, name: 'System', children: Array.from(processMap.values()) };
  },
  
  getProcessStatus(process) {
    if (process.cpu > 80) return 'status-critical';
    if (process.cpu > 50) return 'status-warning';
    if (process.memory > 500) return 'status-warning';
    return 'status-normal';
  },
  
  showProcessDetails(process) {
    this.pushEvent('show_process_details', { pid: process.pid });
  },
  
  initializeLogFilter() {
    this.filterContainer = this.el.querySelector('#log-filter');
    if (!this.filterContainer) return;
    const levelButtons = this.filterContainer.querySelectorAll('.level-filter-btn');
    levelButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        levelButtons.forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        this.filters.level = btn.dataset.level;
        this.applyFilters();
      });
    });
    
    const searchInput = this.filterContainer.querySelector('#log-search');
    if (searchInput) {
      searchInput.addEventListener('input', (e) => {
        this.filters.search = e.target.value;
        this.applyFilters();
      });
    }
    
    const regexToggle = this.filterContainer.querySelector('#regex-toggle');
    if (regexToggle) {
      regexToggle.addEventListener('change', (e) => {
        if (e.target.checked && this.filters.search) {
          try {
            this.filters.regex = new RegExp(this.filters.search, 'i');
          } catch (err) {
            this.filters.regex = null;
            console.error('Invalid regex:', err);
          }
        } else {
          this.filters.regex = null;
        }
        this.applyFilters();
      });
    }
  },
  
  applyFilters() {
    this.pushEvent('apply_log_filters', {
      level: this.filters.level,
      search: this.filters.search,
      regex: this.filters.regex ? this.filters.regex.source : null
    });
    
    const filterIndicator = this.el.querySelector('#filter-indicator');
    if (filterIndicator) {
      filterIndicator.classList.add('pulse');
      setTimeout(() => filterIndicator.classList.remove('pulse'), 500);
    }
  },
  
  setupKeyboardShortcuts() {
    document.addEventListener('keydown', (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === 'k') {
        e.preventDefault();
        const search = this.el.querySelector('#history-search') || this.el.querySelector('#log-search');
        if (search) search.focus();
      }
      
      if ((e.ctrlKey || e.metaKey) && e.key === 'l') {
        e.preventDefault();
        this.clearFilters();
      }
      
      if (e.key === 'ArrowUp' && document.activeElement.tagName === 'INPUT') {
        e.preventDefault();
        this.navigateHistory('up');
      }
      if (e.key === 'ArrowDown' && document.activeElement.tagName === 'INPUT') {
        e.preventDefault();
        this.navigateHistory('down');
      }
    });
  },
  
  navigateHistory(direction) {
    if (this.commandHistory.length === 0) return;
    
    if (direction === 'up') {
      this.historyIndex = Math.min(this.historyIndex + 1, this.commandHistory.length - 1);
    } else {
      this.historyIndex = Math.max(this.historyIndex - 1, -1);
    }
    
    const command = this.historyIndex >= 0 
      ? this.commandHistory[this.historyIndex].command 
      : '';
    
    this.pushEvent('fill_command', { command });
  },
  
  clearFilters() {
    this.filters = {
      level: 'all',
      search: '',
      regex: null
    };
    
    const searchInputs = this.el.querySelectorAll('input[type="search"], input[type="text"]');
    searchInputs.forEach(input => input.value = '');
    
    const levelButtons = this.el.querySelectorAll('.level-filter-btn');
    levelButtons.forEach(btn => {
      if (btn.dataset.level === 'all') {
        btn.classList.add('active');
      } else {
        btn.classList.remove('active');
      }
    });
    
    this.applyFilters();
  },
  
  destroyed() {
    console.log('[DebuggerEnhancements] Destroyed');
    if (this.treeSvg) {
      this.treeSvg.remove();
    }
  }
};

export default DebuggerEnhancementsHook;
