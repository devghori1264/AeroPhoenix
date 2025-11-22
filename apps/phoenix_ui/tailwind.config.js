/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './apps/phoenix_ui/lib/**/*.{ex,heex,eex}',
    './apps/phoenix_ui/assets/js/**/*.js',
    './apps/phoenix_ui/assets/css/**/*.css'
  ],
  darkMode: ['class', '[data-theme="dark"]'],
  theme: {
    extend: {
      colors: {
        primary: {
          300: '#C4B5FD',
          400: '#A78BFA',
          500: '#8B5CF6',
          600: '#7C3AED',
          700: '#6D28D9'
        },
        brand: {
          50: '#eef7ff',
          500: '#0077ff',
          700: '#0055cc'
        },
        cyan: {
          500: '#06B6D4',
          600: '#0891B2'
        },
        emerald: {
          500: '#10B981',
          600: '#059669'
        },
        amber: {
          500: '#F59E0B',
          600: '#D97706'
        },
        rose: {
          500: '#FB7185',
          600: '#F43F5E'
        },
        sky: {
          500: '#0EA5E9',
          600: '#0284C7'
        },
        indigo: {
          500: '#6366F1',
          600: '#4F46E5'
        },
        teal: {
          500: '#14B8A6',
          600: '#0D9488'
        },
        violet: {
          500: '#8B5CF6',
          600: '#7C3AED'
        }
      },
      boxShadow: {
        'soft': '0 6px 18px rgba(12, 14, 20, 0.08)',
        'floating': '0 10px 30px rgba(12, 14, 20, 0.12)',
        'glow-primary': '0 0 20px rgba(124, 58, 237, 0.4)',
        'glow-success': '0 0 20px rgba(16, 185, 129, 0.4)',
        'glow-error': '0 0 20px rgba(251, 113, 133, 0.4)'
      },
      borderRadius: {
        'xl': '0.75rem',
        '2xl': '1rem'
      },
      animation: {
        'pulse-dot': 'pulse-dot 2s cubic-bezier(0.4, 0, 0.6, 1) infinite',
        'skeleton': 'skeleton-loading 1.5s ease-in-out infinite'
      },
      keyframes: {
        'pulse-dot': {
          '0%, 100%': { opacity: '1' },
          '50%': { opacity: '0.5' }
        },
        'skeleton-loading': {
          '0%': { backgroundPosition: '200% 0' },
          '100%': { backgroundPosition: '-200% 0' }
        }
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', '-apple-system', 'BlinkMacSystemFont', 'Segoe UI', 'Roboto', 'sans-serif'],
        mono: ['ui-monospace', 'SFMono-Regular', 'Menlo', 'Monaco', 'Consolas', 'Liberation Mono', 'Courier New', 'monospace']
      }
    }
  },
  plugins: []
};
