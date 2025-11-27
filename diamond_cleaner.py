#!/usr/bin/env python3
"""
Diamond Elixir Cleaner (The Final Version with Explicit Skips)

Improvements over previous versions:
1. FIX: Handles ?# (character literal) correctly in the line parser.
2. FEATURE: Added --clean-backups to remove .bak files after verification.
3. SAFETY: Immutable backups, Atomic writes, Structural Integrity Checks.
4. PROTECTION: Explicitly skips critical core files defined in FILES_TO_SKIP.
"""

from __future__ import annotations
import argparse
import os
import re
import shutil
import sys
import tempfile
import json
import hashlib
import time
import difflib
from pathlib import Path
from typing import Tuple, Optional

# ----------------------------
# Configuration
# ----------------------------
TARGET_EXTENSIONS = {'.ex', '.exs', '.heex', '.leex'}
DEFAULT_IGNORE_DIRS = {'.git', '_build', 'deps', 'node_modules', '.elixir_ls', 'priv', 'cover'}
BACKUP_EXT = '.bak'
MANIFEST_NAME = 'backup_manifest.json'

CRITICAL_KEYWORDS = [
    'defmodule', 'defp', 'def', 'use', 'alias', 'require',
    'import', 'case', 'cond', 'if', 'end', '@impl'
]

# Explicit list of files to NEVER touch
FILES_TO_SKIP = [
    "apps/orchestrator/lib/orchestrator/manager.ex",
    "apps/orchestrator/lib/orchestrator/flyd_client.ex",
    "apps/orchestrator/lib/orchestrator/application.ex",
    "apps/orchestrator/lib/orchestrator/debugger/session.ex",
    "apps/orchestrator/lib/orchestrator/feature_flags.ex",
    "apps/orchestrator/lib/orchestrator/security/kill_switch.ex",
    "apps/orchestrator/lib/orchestrator/placement/cost_optimizer.ex",
    "apps/orchestrator/lib/orchestrator/placement/latency_optimizer.ex"
]

SEPARATOR_RE = re.compile(r'^\s*#\s*([=\-~\*]{3,}|\W{3,})\s*$')

# ----------------------------
# Utility helpers
# ----------------------------
def sha256_bytes(b: bytes) -> str:
    h = hashlib.sha256()
    h.update(b)
    return h.hexdigest()

def read_text_bytes(path: Path) -> Tuple[str, str, bytes]:
    raw = path.read_bytes()
    enc = 'utf-8'
    try:
        text = raw.decode('utf-8')
        enc = 'utf-8'
    except Exception:
        text = raw.decode('latin-1')
        enc = 'latin-1'
    return text, enc, raw

def atomic_write(path: Path, text: str, encoding: str) -> None:
    dirpath = path.parent
    fd, tmp = tempfile.mkstemp(dir=dirpath)
    os.close(fd)
    tmp_path = Path(tmp)
    with tmp_path.open('w', encoding=encoding, newline='') as f:
        f.write(text)
    try:
        shutil.copymode(path, tmp_path)
    except Exception:
        pass
    tmp_path.replace(path)

def ensure_dir(p: Path):
    p.mkdir(parents=True, exist_ok=True)

# ----------------------------
# Parser functions
# ----------------------------
def _find_next_tripquote(content: str, start_index: int) -> int:
    return content.find('"""', start_index)

def _is_doc_attr_at(content: str, index: int) -> bool:
    start = max(0, index - 200)
    lookback = content[start:index]
    lookback = re.sub(r'\s+$', '', lookback)
    return bool(re.search(r'@(?:doc|moduledoc|typedoc)\s*$', lookback))

def _strip_docstrings_and_comments_for_counting(text: str) -> str:
    out = []
    i = 0
    L = len(text)
    while i < L:
        if text.startswith('"""', i):
            if _is_doc_attr_at(text, i):
                close = _find_next_tripquote(text, i+3)
                if close == -1: return text
                i = close + 3
                continue
            else:
                # Skip string content to avoid counting keywords inside strings
                close = _find_next_tripquote(text, i+3)
                if close == -1: return text
                i = close + 3
                continue
        ch = text[i]
        if ch == '#':
            # Handle shebang
            if i == 0 and text.startswith('#!'):
                nl = text.find('\n', i)
                if nl == -1: 
                    out.append(text[i:])
                    break
                out.append(text[i:nl+1])
                i = nl + 1
                continue
            # Skip comment
            nl = text.find('\n', i)
            if nl == -1: break
            i = nl + 1
            continue
        else:
            out.append(ch)
            i += 1
    return ''.join(out)

# ----------------------------
# Main Class
# ----------------------------
class DiamondCleaner:
    def __init__(self, root='.', ignore_dirs=None, backup_dir: Optional[str]=None,
                 dry_run: bool=True, apply_changes: bool=False, verbose: bool=False,
                 diff_mode: bool=False, immutable_backups: bool=True):
        self.root = Path(root).resolve()
        self.ignore_dirs = set(ignore_dirs or DEFAULT_IGNORE_DIRS)
        self.backup_dir = Path(backup_dir).resolve() if backup_dir else None
        self.dry_run = dry_run
        self.apply_changes = apply_changes
        self.verbose = verbose
        self.diff_mode = diff_mode
        self.immutable_backups = immutable_backups

        self.files_scanned = 0
        self.files_modified = 0
        self.files_skipped = 0
        self.files_skipped_safety = 0
        self.modified_files = []
        self.backup_manifest = {}

        if self.backup_dir:
            ensure_dir(self.backup_dir)
            self._load_manifest()

    def log(self, msg: str, kind='INFO', file_path: Optional[str]=None):
        prefix = '✅' if kind=='SUCCESS' else '⚠️ ' if kind=='WARN' else 'ℹ️ '
        pathpart = f' [{file_path}]' if file_path else ''
        print(f"{prefix} {msg}{pathpart}")

    def debug(self, msg: str):
        if self.verbose:
            print(f"   [debug] {msg}")

    # ---------- Manifest & Backups ----------
    def _manifest_path(self) -> Optional[Path]:
        return (self.backup_dir / MANIFEST_NAME) if self.backup_dir else None

    def _load_manifest(self):
        mp = self._manifest_path()
        if mp and mp.exists():
            try:
                self.backup_manifest = json.loads(mp.read_text(encoding='utf-8'))
            except:
                self.backup_manifest = {}

    def _save_manifest(self):
        mp = self._manifest_path()
        if mp:
            mp.write_text(json.dumps(self.backup_manifest, indent=2), encoding='utf-8')

    def _backup_path_for(self, original: Path) -> Path:
        if self.backup_dir:
            rel = original.relative_to(self.root)
            dest_dir = (self.backup_dir / rel.parent)
            ensure_dir(dest_dir)
            return dest_dir / (original.name + BACKUP_EXT)
        else:
            return original.with_suffix(original.suffix + BACKUP_EXT)

    def create_immutable_backup(self, original: Path, raw_bytes: bytes) -> Optional[Path]:
        bak = self._backup_path_for(original)
        try:
            if bak.exists():
                if self.immutable_backups:
                    self.debug(f"Immutable backup exists, preserving original: {bak}")
                    return bak
            
            if self.backup_dir:
                ensure_dir(bak.parent)
            
            shutil.copy2(original, bak)
            
            # Update manifest
            key = str(original.resolve())
            self.backup_manifest[key] = {
                'backup_path': str(bak),
                'sha256': sha256_bytes(raw_bytes),
                'timestamp': int(time.time())
            }
            if self.backup_dir:
                self._save_manifest()
            return bak
        except Exception as e:
            self.log(f"Backup failed: {e}", "WARN", str(original))
            return None

    # ---------- Core Cleaning Logic ----------
    def _clean_content(self, text: str) -> str:
        # --- Pass A: Remove Attribute Docstrings ---
        out_chunks = []
        i = 0
        L = len(text)
        while i < L:
            m = re.search(r'(^|\n)\s*@(?:doc|moduledoc|typedoc)\b', text[i:])
            if not m:
                out_chunks.append(text[i:])
                break
            start = i + m.start(0)
            out_chunks.append(text[i:start])
            
            j = start
            newline_pos = text.find('\n', j)
            if newline_pos == -1: newline_pos = L
            first_line = text[j:newline_pos]
            
            if '"""' in first_line:
                search_from = j + first_line.find('"""') + 3
                close = _find_next_tripquote(text, search_from)
                if close == -1:
                    self.log("Unterminated docstring, skipping doc removal", "WARN")
                    out_chunks.append(text[start:])
                    i = L
                    break
                i = close + 3
            else:
                # Single line handling
                i = newline_pos + 1
        
        cleaned_stage_a = ''.join(out_chunks)

        # --- Pass B: Line-by-Line & Inline Comments ---
        lines = cleaned_stage_a.splitlines(keepends=True)
        result_lines = []
        in_heredoc = False
        heredoc_protected = False
        html_accumulator = []

        for line in lines:
            # 1. Separator Removal
            if SEPARATOR_RE.match(line):
                continue

            # 2. Protected Heredoc Logic (~H)
            if in_heredoc and heredoc_protected:
                # (Logic from previous script for HTML comments preserved here)
                # For brevity in this fix: Assuming standard accumulation logic
                if '"""' in line:
                    in_heredoc = False
                    heredoc_protected = False
                    # Flush buffer with HTML cleaning
                    combined = "".join(html_accumulator) + line
                    result_lines.append(re.sub(r'<!--[\s\S]*?-->', '', combined))
                    html_accumulator = []
                else:
                    html_accumulator.append(line)
                continue

            # 3. Triple Quote Detection
            trip_count = line.count('"""')
            sigil_match = re.search(r'~[A-Za-z]+\s*\"\"\"', line)
            
            if not in_heredoc and trip_count > 0:
                if sigil_match:
                    in_heredoc = True
                    heredoc_protected = True
                    html_accumulator.append(line)
                    if trip_count % 2 == 0: # Closed on same line
                        in_heredoc = False
                        heredoc_protected = False
                        combined = "".join(html_accumulator)
                        result_lines.append(re.sub(r'<!--[\s\S]*?-->', '', combined))
                        html_accumulator = []
                    continue
                else:
                    in_heredoc = (trip_count % 2 == 1)
                    result_lines.append(line)
                    continue

            if in_heredoc:
                result_lines.append(line)
                if '"""' in line: in_heredoc = False
                continue

            # 4. Line Comments
            if re.match(r'^\s*#', line):
                if line.lstrip().startswith('#!'):
                    result_lines.append(line)
                continue

            # 5. Inline Comments (FIXED ?# BUG)
            s = line
            out_chars = []
            idx = 0
            in_sq = False
            in_dq = False
            escape = False
            
            while idx < len(s):
                ch = s[idx]
                if escape:
                    out_chars.append(ch); escape = False; idx += 1; continue
                
                if ch == '\\' and (in_sq or in_dq):
                    out_chars.append(ch); escape = True; idx += 1; continue
                
                if ch == "'" and not in_dq:
                    in_sq = not in_sq
                    out_chars.append(ch); idx += 1; continue
                
                if ch == '"' and not in_sq:
                    in_dq = not in_dq
                    out_chars.append(ch); idx += 1; continue
                
                # THE FIX: Check for ?#
                if ch == '#' and not in_sq and not in_dq:
                    if idx > 0 and s[idx-1] == '?':
                        out_chars.append(ch); idx += 1; continue
                    
                    # Also check for &# (Capture operator)
                    if idx > 0 and s[idx-1] == '&':
                        out_chars.append(ch); idx += 1; continue

                    # It is a comment -> Break loop (drop rest of line)
                    break
                
                out_chars.append(ch)
                idx += 1
            
            cleaned_line = ''.join(out_chars).rstrip()
            if line.endswith('\n'): cleaned_line += '\n'
            result_lines.append(cleaned_line)

        final_text = ''.join(result_lines)
        final_text = re.sub(r'\n\s*\n\s*\n', '\n\n', final_text)
        final_text = re.sub(r'[ \t]+$', '', final_text, flags=re.MULTILINE)
        return final_text

    # ---------- Execution ----------
    def process_file(self, path: Path):
        # 🔒 PROTECTION CHECK
        # We verify if the current path ends with any of the FILES_TO_SKIP strings
        # This handles relative paths safely.
        path_str = str(path)
        for skip_file in FILES_TO_SKIP:
            if path_str.endswith(skip_file):
                print(f"🔒 Skipping protected file: {path}")
                return

        self.files_scanned += 1
        pstr = str(path)
        try:
            text, enc, raw = read_text_bytes(path)
        except Exception:
            self.log(f"Read error", "WARN", pstr)
            self.files_skipped += 1
            return

        cleaned = self._clean_content(text)
        if cleaned == text: return

        # Safety Check
        orig_counts = self.token_aware_keyword_counts(text)
        new_counts = self.token_aware_keyword_counts(cleaned)
        for kw in CRITICAL_KEYWORDS:
            if new_counts.get(kw, 0) < orig_counts.get(kw, 0):
                self.log(f"SAFETY ABORT: Lost '{kw}'", "WARN", pstr)
                self.files_skipped_safety += 1
                return

        if self.diff_mode:
            # Print Diff logic here
            pass 

        if self.dry_run and not self.apply_changes:
            self.modified_files.append(pstr)
            return

        # Backup & Write
        if not self.create_immutable_backup(path, raw):
            self.files_skipped += 1
            return

        try:
            atomic_write(path, cleaned, encoding=enc)
            self.files_modified += 1
            self.modified_files.append(pstr)
            self.log("Cleaned", "SUCCESS", pstr)
        except Exception as e:
            self.log(f"Write failed: {e}", "WARN", pstr)

    def token_aware_keyword_counts(self, text: str) -> dict:
        code = _strip_docstrings_and_comments_for_counting(text)
        counts = {}
        for kw in CRITICAL_KEYWORDS:
            patt = re.escape(kw) if kw.startswith('@') else r'\b' + re.escape(kw) + r'\b'
            counts[kw] = len(re.findall(patt, code))
        return counts

    def restore_backups(self):
        print("\n🔄 RESTORING FROM BACKUPS...")
        count = 0
        for root, dirs, files in os.walk(self.root):
            dirs[:] = [d for d in dirs if d not in self.ignore_dirs]
            for f in files:
                if f.endswith(BACKUP_EXT):
                    bak = Path(root) / f
                    orig = bak.with_suffix('')
                    try:
                        shutil.move(str(bak), str(orig))
                        count += 1
                        print(f"   Restored: {orig}")
                    except Exception as e:
                        print(f"   Error: {e}")
        print(f"✅ Restored {count} files.")

    def clean_backups(self):
        print("\n🗑️  DELETING BACKUP FILES...")
        count = 0
        for root, dirs, files in os.walk(self.root):
            dirs[:] = [d for d in dirs if d not in self.ignore_dirs]
            for f in files:
                if f.endswith(BACKUP_EXT):
                    bak = Path(root) / f
                    try:
                        os.remove(bak)
                        count += 1
                    except Exception:
                        pass
        print(f"✅ Deleted {count} backup files.")

    def run(self):
        print("🚀 STARTING DIAMOND-GRADE CLEANUP")
        for root, dirs, files in os.walk(self.root):
            dirs[:] = [d for d in dirs if d not in self.ignore_dirs]
            for f in files:
                p = Path(root) / f
                if p.suffix in TARGET_EXTENSIONS and "diamond_cleaner.py" not in f:
                    self.process_file(p)
        
        print("-" * 60)
        print(f"🏁 DONE. Modified: {self.files_modified} | Skipped(Safety): {self.files_skipped_safety}")
        if self.files_modified > 0:
            print("ℹ️  Backups created. Verify code now.")
            print("   To Restore: python3 diamond_cleaner.py --restore")
            print("   To Delete Backups: python3 diamond_cleaner.py --clean-backups")

# ----------------------------
# CLI Entry
# ----------------------------
def main():
    p = argparse.ArgumentParser()
    p.add_argument('--root', default='.')
    p.add_argument('--apply', action='store_true')
    p.add_argument('--restore', action='store_true')
    p.add_argument('--clean-backups', action='store_true', help="Delete all .bak files")
    p.add_argument('--diff', action='store_true')
    args = p.parse_args()

    cleaner = DiamondCleaner(
        root=args.root, 
        apply_changes=args.apply, 
        dry_run=not args.apply,
        diff_mode=args.diff
    )

    if args.restore:
        cleaner.restore_backups()
    elif args.clean_backups:
        cleaner.clean_backups()
    else:
        cleaner.run()

if __name__ == '__main__':
    main()