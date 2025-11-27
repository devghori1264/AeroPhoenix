export const ThemeSystemHook = {
  mounted() {
    console.log('[ThemeSystem] Mounted');

    this.currentTheme = localStorage.getItem('aerophoenix-theme') || 'dark';
    this.customThemes = JSON.parse(localStorage.getItem('aerophoenix-custom-themes') || '[]');

    this.initializeTheme();
    this.initializeThemeToggle();
    this.initializeThemeBuilder();
    this.setupAccessibility();
  },

  initializeTheme() {
    document.documentElement.setAttribute('data-theme', this.currentTheme);
    this.applyTheme(this.currentTheme);
  },

  initializeThemeToggle() {
    const toggle = this.el.querySelector('#theme-toggle');
    if (!toggle) return;

    toggle.addEventListener('click', () => {
      this.currentTheme = this.currentTheme === 'dark' ? 'light' : 'dark';
      this.switchTheme(this.currentTheme);
    });

    this.updateToggleState(toggle);
  },

  switchTheme(theme) {
    document.documentElement.classList.add('theme-transitioning');

    setTimeout(() => {
      document.documentElement.setAttribute('data-theme', theme);
      this.applyTheme(theme);
      localStorage.setItem('aerophoenix-theme', theme);

      setTimeout(() => {
        document.documentElement.classList.remove('theme-transitioning');
      }, 300);
    }, 50);

    this.pushEvent('theme_changed', { theme });
  },

  applyTheme(theme) {
    const themes = {
      dark: {
        '--bg-primary': '#0f172a',
        '--bg-secondary': '#1e293b',
        '--text-primary': '#f3f4f6',
        '--text-secondary': '#cbd5e1',
        '--accent': '#8b5cf6',
        '--accent-hover': '#a78bfa'
      },
      light: {
        '--bg-primary': '#ffffff',
        '--bg-secondary': '#f8fafc',
        '--text-primary': '#1e293b',
        '--text-secondary': '#475569',
        '--accent': '#8b5cf6',
        '--accent-hover': '#7c3aed'
      }
    };

    const colors = themes[theme] || themes.dark;
    Object.entries(colors).forEach(([key, value]) => {
      document.documentElement.style.setProperty(key, value);
    });
  },

  initializeThemeBuilder() {
    const builder = this.el.querySelector('#theme-builder');
    if (!builder) return;

    const colorInputs = builder.querySelectorAll('input[type="color"]');
    colorInputs.forEach(input => {
      input.addEventListener('change', () => {
        this.updatePreview();
      });
    });

    const saveBtn = builder.querySelector('#save-theme-btn');
    if (saveBtn) {
      saveBtn.addEventListener('click', () => {
        this.saveCustomTheme();
      });
    }
  },

  updatePreview() {
    const preview = this.el.querySelector('#theme-preview');
    if (!preview) return;

    const builder = this.el.querySelector('#theme-builder');
    const colors = {};

    builder.querySelectorAll('input[type="color"]').forEach(input => {
      colors[input.dataset.var] = input.value;
    });

    Object.entries(colors).forEach(([key, value]) => {
      preview.style.setProperty(key, value);
    });
  },

  saveCustomTheme() {
    const builder = this.el.querySelector('#theme-builder');
    const nameInput = builder.querySelector('#theme-name');

    const theme = {
      name: nameInput.value || 'Custom Theme',
      id: `custom-${Date.now()}`,
      colors: {}
    };

    builder.querySelectorAll('input[type="color"]').forEach(input => {
      theme.colors[input.dataset.var] = input.value;
    });

    this.customThemes.push(theme);
    localStorage.setItem('aerophoenix-custom-themes', JSON.stringify(this.customThemes));

    this.showToast('success', `Theme "${theme.name}" saved successfully`);
    this.renderThemeList();
  },

  renderThemeList() {
    const list = this.el.querySelector('#custom-themes-list');
    if (!list) return;

    list.innerHTML = '';

    this.customThemes.forEach(theme => {
      const item = document.createElement('div');
      item.className = 'theme-item';
      item.innerHTML = `
        <span class="theme-name">${theme.name}</span>
        <div class="theme-actions">
          <button class="btn-apply" data-theme-id="${theme.id}">Apply</button>
          <button class="btn-delete" data-theme-id="${theme.id}">Delete</button>
        </div>
      `;

      item.querySelector('.btn-apply').addEventListener('click', () => {
        this.applyCustomTheme(theme);
      });

      item.querySelector('.btn-delete').addEventListener('click', () => {
        this.deleteCustomTheme(theme.id);
      });

      list.appendChild(item);
    });
  },

  applyCustomTheme(theme) {
    Object.entries(theme.colors).forEach(([key, value]) => {
      document.documentElement.style.setProperty(key, value);
    });

    this.showToast('success', `Applied theme: ${theme.name}`);
  },

  deleteCustomTheme(id) {
    this.customThemes = this.customThemes.filter(t => t.id !== id);
    localStorage.setItem('aerophoenix-custom-themes', JSON.stringify(this.customThemes));
    this.renderThemeList();
    this.showToast('success', 'Theme deleted');
  },

  setupAccessibility() {
    if (window.matchMedia) {
      const darkModeQuery = window.matchMedia('(prefers-color-scheme: dark)');

      if (!localStorage.getItem('aerophoenix-theme')) {
        this.currentTheme = darkModeQuery.matches ? 'dark' : 'light';
        this.applyTheme(this.currentTheme);
      }

      darkModeQuery.addEventListener('change', (e) => {
        if (!localStorage.getItem('aerophoenix-theme')) {
          this.switchTheme(e.matches ? 'dark' : 'light');
        }
      });
    }

    document.addEventListener('keydown', (e) => {
      if (e.key === 'Tab') {
        document.body.classList.add('keyboard-navigation');
      }
    });

    document.addEventListener('mousedown', () => {
      document.body.classList.remove('keyboard-navigation');
    });
  },

  updateToggleState(toggle) {
    if (this.currentTheme === 'dark') {
      toggle.innerHTML = '🌙';
      toggle.setAttribute('aria-label', 'Switch to light mode');
    } else {
      toggle.innerHTML = '☀️';
      toggle.setAttribute('aria-label', 'Switch to dark mode');
    }
  },

  showToast(type, message) {
    this.pushEvent('toast', { type, message });
  },

  destroyed() {
    console.log('[ThemeSystem] Destroyed');
  }
};

export default ThemeSystemHook;
