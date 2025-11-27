import { Terminal } from 'xterm';
import { FitAddon } from 'xterm-addon-fit';
import { WebLinksAddon } from 'xterm-addon-web-links';
import 'xterm/css/xterm.css';

export const XTerminal = {
  mounted() {
    this.term = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: 'Menlo, Monaco, "Courier New", monospace',
      theme: {
        background: '#1a1b26',
        foreground: '#a9b1d6',
        cursor: '#c0caf5',
        black: '#32344a',
        red: '#f7768e',
        green: '#9ece6a',
        yellow: '#e0af68',
        blue: '#7aa2f7',
        magenta: '#ad8ee6',
        cyan: '#449dab',
        white: '#787c99',
        brightBlack: '#444b6a',
        brightRed: '#ff7a93',
        brightGreen: '#b9f27c',
        brightYellow: '#ff9e64',
        brightBlue: '#7da6ff',
        brightMagenta: '#bb9af7',
        brightCyan: '#0db9d7',
        brightWhite: '#acb0d0'
      },
      allowProposedApi: true
    });

    this.fitAddon = new FitAddon();
    this.term.loadAddon(this.fitAddon);
    this.term.loadAddon(new WebLinksAddon());
    this.term.open(this.el);
    this.fitAddon.fit();
    this.sendResize();

    this.term.onData((data) => {
      this.pushEvent("terminal_input", { data: data });
    });

    this.term.onResize(({ rows, cols }) => {
      this.pushEvent("terminal_resize", { rows, cols });
    });

    this.resizeObserver = new ResizeObserver(() => {
      clearTimeout(this.resizeTimeout);
      this.resizeTimeout = setTimeout(() => {
        this.fitAddon.fit();
        this.sendResize();
      }, 100);
    });

    this.resizeObserver.observe(this.el);

    this.term.writeln('\x1b[1;32m╔════════════════════════════════════════╗\x1b[0m');
    this.term.writeln('\x1b[1;32m║  AeroPhoenix Live Debugger Terminal   ║\x1b[0m');
    this.term.writeln('\x1b[1;32m╚════════════════════════════════════════╝\x1b[0m');
    this.term.writeln('');
    this.term.writeln('Connecting to PTY session...');
    this.term.writeln('');
  },

  updated() {
  },

  destroyed() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
    }
    if (this.resizeTimeout) {
      clearTimeout(this.resizeTimeout);
    }
    if (this.term) {
      this.term.dispose();
    }
  },

  sendResize() {
    if (this.term) {
      this.pushEvent("terminal_resize", {
        rows: this.term.rows,
        cols: this.term.cols
      });
    }
  },

  handleEvent(event, payload) {
    if (event === 'terminal_data' && this.term) {
      this.term.write(payload.data);
    }
  }
};