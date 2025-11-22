export const initTheme = () => {
  console.log('[Theme] Initializing theme system...');

  const stored = localStorage.getItem('phx:theme');
  const systemPrefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  const initial = stored || (systemPrefersDark ? 'dark' : 'light');

  applyTheme(initial);

  window.setTheme = (theme) => {
    console.log(`[Theme] Setting theme to: ${theme}`);
    if (theme === 'system') {
      localStorage.removeItem('phx:theme');
      const systemTheme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
      applyTheme(systemTheme);
    } else {
      localStorage.setItem('phx:theme', theme);
      applyTheme(theme);
    }

    document.dispatchEvent(new CustomEvent('phx:theme-changed', {
      detail: { theme } 
    }));
  };

  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
    if (!localStorage.getItem('phx:theme')) {
      const newTheme = e.matches ? 'dark' : 'light';
      console.log(`[Theme] System theme changed to: ${newTheme}`);
      applyTheme(newTheme);
    }
  });
  console.log(`[Theme] Theme system initialized with theme: ${initial}`);
};

function applyTheme(theme) {
  const root = document.documentElement;
  if (theme === 'dark') {
    root.setAttribute('data-theme', 'dark');
  } else if (theme === 'light') {
    root.setAttribute('data-theme', 'light');
  } else {
    const systemTheme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    root.setAttribute('data-theme', systemTheme);
  }
}

export const getCurrentTheme = () => {
  return document.documentElement.getAttribute('data-theme') || 'light';
};

export const toggleTheme = () => {
  const current = getCurrentTheme();
  const next = current === 'dark' ? 'light' : 'dark';
  window.setTheme(next);
  return next;
};