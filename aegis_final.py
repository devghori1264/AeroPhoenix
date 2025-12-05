#!/usr/bin/env python3
"""
AEGIS III: GOD MODE ELIXIR CLEANER
----------------------------------
Architecture: Recursive Descent Lexical Analysis with Context Stacking
Integrity:    Pre-Write Backup + In-Place Inode Preservation
Logic:        Deep Scan & Skip (Touches ONLY files with comments)
VS Code:      Fully Compatible with Local History/Timeline
"""

import os
import sys
import re
import shutil
import hashlib
import tempfile
import argparse
import time
from enum import Enum, auto
from pathlib import Path
from typing import List, Tuple, Optional, Set

# ==============================================================================
# 1. CONFIGURATION & TARGETS
# ==============================================================================

# The script will REFUSE to scan or touch any file not in this list.
ALLOWED_FILES = {
    "apps/orchestrator/config/config.exs",
    "apps/orchestrator/config/prod.exs",
    "apps/orchestrator/config/test.exs",
    "apps/orchestrator/lib/orchestrator/application.ex",
    "apps/orchestrator/lib/orchestrator/cache/cache_warmer.ex",
    "apps/orchestrator/lib/orchestrator/cache/pg_cache.ex",
    "apps/orchestrator/lib/orchestrator/cache/query_cache.ex",
    "apps/orchestrator/lib/orchestrator/cache/replication_buffer.ex",
    "apps/orchestrator/lib/orchestrator/deployments/deployment_controller.ex",
    "apps/orchestrator/lib/orchestrator/flyd_client.ex",
    "apps/orchestrator/lib/orchestrator/latency/geo_router.ex",
    "apps/orchestrator/lib/orchestrator/latency/hedged_request.ex",
    "apps/orchestrator/lib/orchestrator/latency/request_coalescer.ex",
    "apps/orchestrator/lib/orchestrator/live_migration/checkpointer.ex",
    "apps/orchestrator/lib/orchestrator/live_migration/coordinator.ex",
    "apps/orchestrator/lib/orchestrator/live_migration/cutover.ex",
    "apps/orchestrator/lib/orchestrator/live_migration/state_transfer.ex",
    "apps/orchestrator/lib/orchestrator/logs/aggregator.ex",
    "apps/orchestrator/lib/orchestrator/logs/producer.ex",
    "apps/orchestrator/lib/orchestrator/machine.ex",
    "apps/orchestrator/lib/orchestrator/machine/proto_stubs.ex",
    "apps/orchestrator/lib/orchestrator/machine_actor.ex",
    "apps/orchestrator/lib/orchestrator/machine_actor/fsm.ex",
    "apps/orchestrator/lib/orchestrator/machine_actor/storage.ex",
    "apps/orchestrator/lib/orchestrator/machine_actor/supervisor.ex",
    "apps/orchestrator/lib/orchestrator/machine_actor/wal.ex",
    "apps/orchestrator/lib/orchestrator/machine_event.ex",
    "apps/orchestrator/lib/orchestrator/machine_fsm.ex",
    "apps/orchestrator/lib/orchestrator/machine_manager.ex",
    "apps/orchestrator/lib/orchestrator/machines/machine.ex",
    "apps/orchestrator/lib/orchestrator/manager.ex",
    "apps/orchestrator/lib/orchestrator/metrics/collector.ex",
    "apps/orchestrator/lib/orchestrator/migration/cutover_coordinator.ex",
    "apps/orchestrator/lib/orchestrator/migration/dirty_page_tracker.ex",
    "apps/orchestrator/lib/orchestrator/migration/migration_coordinator.ex",
    "apps/orchestrator/lib/orchestrator/migration/migration_stream.ex",
    "apps/orchestrator/lib/orchestrator/migration/progress_tracker.ex",
    "apps/orchestrator/lib/orchestrator/nats_listener.ex",
    "apps/orchestrator/lib/orchestrator/network/anycast_router.ex",
    "apps/orchestrator/lib/orchestrator/network/identity.ex",
    "apps/orchestrator/lib/orchestrator/network/ip_registry.ex",
    "apps/orchestrator/lib/orchestrator/placement/cost_optimizer.ex",
    "apps/orchestrator/lib/orchestrator/placement/executor.ex",
    "apps/orchestrator/lib/orchestrator/placement/latency_optimizer.ex",
    "apps/orchestrator/lib/orchestrator/placement/optimization_service.ex",
    "apps/orchestrator/lib/orchestrator/placement/scheduler.ex",
    "apps/orchestrator/lib/orchestrator/predictive_planner.ex",
    "apps/orchestrator/lib/orchestrator/predictive_simulator.ex",
    "apps/orchestrator/lib/orchestrator/pubsub.ex",
    "apps/orchestrator/lib/orchestrator/quota/quota_enforcer.ex",
    "apps/orchestrator/lib/orchestrator/reconciliation/engine.ex",
    "apps/orchestrator/lib/orchestrator/recovery/drift_detector.ex",
    "apps/orchestrator/lib/orchestrator/recovery/reconciler.ex",
    "apps/orchestrator/lib/orchestrator/recovery/repair_actions.ex",
    "apps/orchestrator/lib/orchestrator/region_registry.ex",
    "apps/orchestrator/lib/orchestrator/replication/crdt_state.ex",
    "apps/orchestrator/lib/orchestrator/replication/gossip_protocol.ex",
    "apps/orchestrator/lib/orchestrator/replication/partition_detector.ex",
    "apps/orchestrator/lib/orchestrator/replication/raft_consensus.ex",
    "apps/orchestrator/lib/orchestrator/replication/state_sync.ex",
    "apps/orchestrator/lib/orchestrator/resource_coordinator.ex",
    "apps/orchestrator/lib/orchestrator/resource_manager.ex",
    "apps/orchestrator/lib/orchestrator/router.ex",
    "apps/orchestrator/lib/orchestrator/scaling/auto_scaler.ex",
    "apps/orchestrator/lib/orchestrator/scaling/metric_definition.ex",
    "apps/orchestrator/lib/orchestrator/scaling/metric_sample.ex",
    "apps/orchestrator/lib/orchestrator/security/capability_manager.ex",
    "apps/orchestrator/lib/orchestrator/security/kill_switch.ex",
    "apps/orchestrator/lib/orchestrator/security/oidc_provider.ex",
    "apps/orchestrator/lib/orchestrator/security/vault.ex",
    "apps/orchestrator/lib/orchestrator/testing/holodeck.ex",
    "apps/orchestrator/lib/orchestrator/testing/starvation_test.ex",
    "apps/orchestrator_web/channels/debug_channel.ex",
    "apps/orchestrator_web/controllers/debug_controller.ex",
    "apps/orchestrator_web/controllers/fsm_controller.ex",
    "apps/orchestrator_web/controllers/machine_controller.ex",
    "apps/orchestrator_web/controllers/placement_controller.ex",
    "apps/orchestrator_web/debug_session.ex",
    "apps/orchestrator/mix.exs",
    "apps/orchestrator/priv/repo/migrations/20241121000001_create_event_store.exs",
    "apps/orchestrator/priv/repo/migrations/20241121000002_create_cost_analytics.exs",
    "apps/orchestrator/priv/repo/migrations/20241121000003_create_performance_metrics.exs",
    "apps/orchestrator/priv/repo/migrations/20241122000001_create_security_compliance.exs",
    "apps/orchestrator/priv/repo/migrations/20241123000001_create_deployments.exs",
    "apps/orchestrator/priv/repo/migrations/20250124000002_create_scaling_tables.exs",
    "apps/orchestrator/test/auto_scaling_test.exs",
    "apps/orchestrator/test/flyd_client_test.exs",
    "apps/orchestrator/test/integration/zombie_resource_test.exs",
    "apps/orchestrator/test/live_migration_test.exs",
    "apps/orchestrator/test/machine_fsm_test.exs",
    "apps/orchestrator/test/manager_test.exs",
    "apps/orchestrator/test/orchestrator/cache/pg_cache_test.exs",
    "apps/orchestrator/test/orchestrator/latency/geo_router_test.exs",
    "apps/orchestrator/test/orchestrator/latency/hedged_request_test.exs",
    "apps/orchestrator/test/orchestrator/latency/request_coalescer_test.exs",
    "apps/orchestrator/test/orchestrator/logs/aggregator_test.exs",
    "apps/orchestrator/test/orchestrator/logs/producer_test.exs",
    "apps/orchestrator/test/orchestrator/machine_actor_test.exs",
    "apps/orchestrator/test/orchestrator/machine_fsm_advanced_test.exs",
    "apps/orchestrator/test/orchestrator/metrics/collector_test.exs",
    "apps/orchestrator/test/orchestrator/metrics/latency_tracker_test.exs",
    "apps/orchestrator/test/orchestrator/migration/cutover_test.exs",
    "apps/orchestrator/test/orchestrator/migration/dirty_page_test.exs",
    "apps/orchestrator/test/orchestrator/migration/migration_coordinator_test.exs",
    "apps/orchestrator/test/orchestrator/migration/migration_stream_test.exs",
    "apps/orchestrator/test/orchestrator/migration/state_transfer_test.exs",
    "apps/orchestrator/test/orchestrator/network/network_identity_test.exs",
    "apps/orchestrator/test/orchestrator/quota/quota_enforcer_test.exs",
    "apps/orchestrator/test/orchestrator/quota/token_bucket_test.exs",
    "apps/orchestrator/test/orchestrator/recovery/drift_detector_test.exs",
    "apps/orchestrator/test/orchestrator/recovery/reconciler_test.exs",
    "apps/orchestrator/test/orchestrator/recovery/zombie_scenarios_test.exs",
    "apps/orchestrator/test/orchestrator/replication/crdt_state_test.exs",
    "apps/orchestrator/test/orchestrator/replication/gossip_protocol_test.exs",
    "apps/orchestrator/test/orchestrator/replication/partition_detector_test.exs",
    "apps/orchestrator/test/orchestrator/resource_scenarios_test.exs",
    "apps/orchestrator/test/orchestrator/security/capability_manager_test.exs",
    "apps/orchestrator/test/orchestrator/security/kill_switch_test.exs",
    "apps/orchestrator/test/orchestrator/security/oidc_provider_test.exs",
    "apps/orchestrator/test/orchestrator/security/vault_test.exs",
    "apps/orchestrator/test/orchestrator/testing/holodeck_test.exs",
    "apps/orchestrator/test/orchestrator/testing/starvation_test_test.exs",
    "apps/orchestrator/test/placement_executor_test.exs",
    "apps/orchestrator/test/placement_scheduler_test.exs",
    "apps/orchestrator/test/replication_test.exs",
    "apps/orchestrator/test/support/data_case.ex",
    "apps/orchestrator/test/test_helper.exs",
    "apps/phoenix_ui/config/prod.exs"
}

BACKUP_EXTENSION = ".aegis.bak"

# ==============================================================================
# 2. LEXICAL ANALYSIS ENGINE (THE BRAIN)
# ==============================================================================

class Context(Enum):
    ROOT_CODE = auto()
    DOUBLE_QUOTE_STRING = auto()  # "..."
    SINGLE_QUOTE_STRING = auto()  # '...'
    HEREDOC_DOUBLE = auto()       # """..."""
    HEREDOC_SINGLE = auto()       # '''...'''
    SIGIL_BODY = auto()           # ~x(...)

class Lexer:
    def __init__(self, source):
        self.src = source
        self.len = len(source)
        self.i = 0
        self.output = []
        self.stack = [(Context.ROOT_CODE, None, None)]
        self.last_char_was_newline = True
        self.line_has_code = False
        self.current_line_whitespace_buffer = []

    def current_context(self):
        return self.stack[-1][0]

    def push_context(self, ctx, terminator=None, delimiter=None):
        self.stack.append((ctx, terminator, delimiter))

    def pop_context(self):
        if len(self.stack) > 1:
            self.stack.pop()

    def peek(self, offset=1):
        if self.i + offset < self.len:
            return self.src[self.i + offset]
        return None

    def match_ahead(self, string):
        if self.i + len(string) <= self.len:
            return self.src[self.i : self.i + len(string)] == string
        return False

    def flush_whitespace(self):
        self.output.extend(self.current_line_whitespace_buffer)
        self.current_line_whitespace_buffer = []

    def process(self):
        while self.i < self.len:
            char = self.src[self.i]
            ctx = self.current_context()

            # =========================
            # CONTEXT: ROOT CODE
            # =========================
            if ctx == Context.ROOT_CODE:
                
                # --- CASE 1: Character Literals (?#) ---
                if char == '?':
                    self.flush_whitespace()
                    self.line_has_code = True
                    self.output.append(char)
                    self.i += 1
                    if self.i < self.len:
                        if self.src[self.i] == '\\':
                            self.output.append(self.src[self.i])
                            self.i += 1
                        if self.i < self.len:
                            self.output.append(self.src[self.i])
                            self.i += 1
                    continue

                # --- CASE 2: Comments (#) ---
                elif char == '#':
                    if not self.line_has_code:
                        # Full Line Comment: Remove comment AND newline
                        self.current_line_whitespace_buffer = [] 
                        while self.i < self.len and self.src[self.i] != '\n':
                            self.i += 1
                        if self.i < self.len and self.src[self.i] == '\n':
                            self.i += 1
                            self.last_char_was_newline = True
                            self.line_has_code = False
                    else:
                        # Inline Comment: Remove comment, KEEP newline
                        self.flush_whitespace()
                        while self.i < self.len and self.src[self.i] != '\n':
                            self.i += 1
                    continue

                # --- CASE 3: Heredocs ---
                elif self.match_ahead('"""'):
                    self.flush_whitespace()
                    self.line_has_code = True
                    self.push_context(Context.HEREDOC_DOUBLE, '"""')
                    self.output.append('"""')
                    self.i += 3
                    continue
                elif self.match_ahead("'''"):
                    self.flush_whitespace()
                    self.line_has_code = True
                    self.push_context(Context.HEREDOC_SINGLE, "'''")
                    self.output.append("'''")
                    self.i += 3
                    continue

                # --- CASE 4: Strings ---
                elif char == '"':
                    self.flush_whitespace()
                    self.line_has_code = True
                    self.push_context(Context.DOUBLE_QUOTE_STRING, '"')
                    self.output.append('"')
                    self.i += 1
                    continue
                elif char == "'":
                    self.flush_whitespace()
                    self.line_has_code = True
                    self.push_context(Context.SINGLE_QUOTE_STRING, "'")
                    self.output.append("'")
                    self.i += 1
                    continue

                # --- CASE 5: Sigils ---
                elif char == '~':
                    self.flush_whitespace()
                    self.line_has_code = True
                    self.handle_sigil_entry()
                    continue

                # --- CASE 6: Whitespace ---
                elif char in ' \t':
                    if self.last_char_was_newline:
                        self.current_line_whitespace_buffer.append(char)
                    else:
                        self.output.append(char)
                    self.i += 1
                    continue
                
                elif char == '\n':
                    self.flush_whitespace()
                    self.output.append(char)
                    self.last_char_was_newline = True
                    self.line_has_code = False
                    self.i += 1
                    continue

                # --- CASE 7: Interpolation Closing ---
                elif char == '}' and len(self.stack) > 1:
                    self.flush_whitespace()
                    self.line_has_code = True
                    self.pop_context()
                    self.output.append('}')
                    self.i += 1
                    continue

                # --- CASE 8: Standard Code ---
                else:
                    self.flush_whitespace()
                    self.last_char_was_newline = False
                    self.line_has_code = True
                    self.output.append(char)
                    self.i += 1

            # =========================
            # CONTEXT: STRINGS & HEREDOCS
            # =========================
            elif ctx in [Context.DOUBLE_QUOTE_STRING, Context.HEREDOC_DOUBLE, 
                         Context.SINGLE_QUOTE_STRING, Context.HEREDOC_SINGLE]:
                terminator = self.stack[-1][1]

                if char == '#' and self.peek() == '{' and ctx in [Context.DOUBLE_QUOTE_STRING, Context.HEREDOC_DOUBLE]:
                    self.push_context(Context.ROOT_CODE)
                    self.output.append("#{")
                    self.i += 2
                    continue
                
                if char == '\\':
                    self.output.append(char)
                    self.i += 1
                    if self.i < self.len:
                        self.output.append(self.src[self.i])
                        self.i += 1
                    continue

                if self.match_ahead(terminator):
                    self.output.append(terminator)
                    self.i += len(terminator)
                    self.pop_context()
                    continue
                
                self.output.append(char)
                self.i += 1

            # =========================
            # CONTEXT: SIGIL BODY
            # =========================
            elif ctx == Context.SIGIL_BODY:
                delimiter = self.stack[-1][2]

                if char == '#' and self.peek() == '{':
                    self.push_context(Context.ROOT_CODE)
                    self.output.append("#{")
                    self.i += 2
                    continue

                if char == delimiter['close']:
                    delimiter['count'] -= 1
                    if delimiter['count'] == 0:
                        self.output.append(char)
                        self.i += 1
                        self.pop_context()
                        continue
                elif char == delimiter['open'] and delimiter['open'] != delimiter['close']:
                    delimiter['count'] += 1

                self.output.append(char)
                self.i += 1

        self.flush_whitespace()
        return "".join(self.output)

    def handle_sigil_entry(self):
        self.output.append('~')
        self.i += 1
        while self.i < self.len and self.src[self.i].isalpha():
            self.output.append(self.src[self.i])
            self.i += 1
        if self.i >= self.len: return
        start_char = self.src[self.i]
        self.output.append(start_char)
        self.i += 1
        close_char = start_char
        if start_char == '(': close_char = ')'
        elif start_char == '[': close_char = ']'
        elif start_char == '{': close_char = '}'
        elif start_char == '<': close_char = '>'
        self.push_context(Context.SIGIL_BODY, delimiter={'open': start_char, 'close': close_char, 'count': 1})

# ==============================================================================
# 3. SAFETY & TRANSACTION ENGINE (TIMELINE AWARE)
# ==============================================================================

class TransactionEngine:
    @staticmethod
    def get_checksum(filepath: Path) -> str:
        sha256_hash = hashlib.sha256()
        try:
            with open(filepath, "rb") as f:
                for byte_block in iter(lambda: f.read(4096), b""):
                    sha256_hash.update(byte_block)
            return sha256_hash.hexdigest()
        except FileNotFoundError:
            return "MISSING"

    @staticmethod
    def count_structural_tokens(text: str) -> dict:
        tokens = ["defmodule", "def", "do", "end", "case", "cond", "if"]
        counts = {}
        for t in tokens:
            matches = re.findall(r'\b' + re.escape(t) + r'\b', text)
            counts[t] = len(matches)
        return counts

    @staticmethod
    def verify_integrity(original_text: str, cleaned_text: str, filepath: str) -> bool:
        if len(cleaned_text) < len(original_text) * 0.4:
            print(f"    [CRITICAL] File size reduced by > 60% for {filepath}. Aborting.")
            return False
        return True

    @staticmethod
    def inplace_surgical_write(filepath: Path, content: str) -> bool:
        """
        WRITES IN PLACE (Preserves Inode for VS Code Timeline).
        Safety Mechanism:
        1. Create Backup first.
        2. Verify Backup.
        3. Truncate and Overwrite original file.
        4. Flush and Sync.
        """
        try:
            # 1. Create Backup (Crucial step for In-Place writing)
            backup_path = filepath.with_suffix(filepath.suffix + BACKUP_EXTENSION)
            
            # Remove old backup if exists to ensure freshness
            if backup_path.exists():
                os.remove(backup_path)
                
            shutil.copy2(filepath, backup_path)
            
            # 2. Verify Backup Hash
            if TransactionEngine.get_checksum(filepath) != TransactionEngine.get_checksum(backup_path):
                 print(f"    [BACKUP ERROR] Backup corrupted for {filepath}. Aborting write.")
                 return False

            # 3. IN-PLACE WRITE (Truncate and Overwrite)
            # We use 'w' mode on the same path. This preserves the Inode on most filesystems.
            # This triggers the "File Modified" event in VS Code, rather than "File Created".
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(content)
                f.flush()
                os.fsync(f.fileno()) # Ensure data hits the physical disk
            
            # 4. Touch the file time to guarantee watchers wake up
            current_time = time.time()
            os.utime(filepath, (current_time, current_time))

            return True

        except Exception as e:
            print(f"    [WRITE ERROR] {e}")
            # If we crashed mid-write, we try to restore immediately
            if backup_path.exists():
                print(f"    [AUTO-RECOVERY] Restoring {filepath} from backup...")
                shutil.copy2(backup_path, filepath)
            return False

# ==============================================================================
# 4. MAIN CONTROLLER
# ==============================================================================

def main():
    parser = argparse.ArgumentParser(description="Aegis III: God Mode Elixir Cleaner")
    parser.add_argument("--force", action="store_true", help="Actually modify files (Default: Dry Run)")
    parser.add_argument("--restore", action="store_true", help="Restore from backups")
    args = parser.parse_args()

    root_dir = Path(os.getcwd())
    
    # --- RESTORE MODE ---
    if args.restore:
        print("\n🔄 INITIATING SYSTEM RESTORE...")
        restored = 0
        for root, dirs, files in os.walk(root_dir):
            for file in files:
                if file.endswith(BACKUP_EXTENSION):
                    backup_path = Path(root) / file
                    original_path = backup_path.parent / backup_path.stem 
                    try:
                        shutil.copy2(backup_path, original_path)
                        os.remove(backup_path)
                        print(f"    [RESTORED] {original_path}")
                        restored += 1
                    except Exception as e:
                        print(f"    [FAILED] {original_path}: {e}")
        print(f"✅ System Restore Complete. {restored} files recovered.\n")
        return

    # --- CLEAN MODE ---
    print("\n⚔️  AEGIS III: GOD MODE ENGAGED (TIMELINE COMPATIBLE + DEEP SCAN)")
    print(f"    Target Files: {len(ALLOWED_FILES)}")
    print(f"    Operation: {'WRITING TO DISK' if args.force else 'DRY RUN (Simulation)'}")
    print("=" * 60)

    stats = {'processed': 0, 'modified': 0, 'errors': 0, 'skipped': 0, 'clean': 0}

    for relative_path_str in ALLOWED_FILES:
        file_path = root_dir / relative_path_str
        
        if not file_path.exists():
            continue

        try:
            stats['processed'] += 1
            
            # 1. READ FILE
            original_content = file_path.read_text(encoding='utf-8')
            
            # 2. LEXICAL ANALYSIS (Deep Scan)
            lexer = Lexer(original_content)
            cleaned_content = lexer.process()

            # 3. DEEP SCAN CHECK
            # If no comments were found, original == cleaned.
            if original_content == cleaned_content:
                print(f"    ✨ [CLEAN] Skipping {relative_path_str} (No comments found)")
                stats['clean'] += 1
                continue
            
            # 4. INTEGRITY CHECK
            if not TransactionEngine.verify_integrity(original_content, cleaned_content, str(file_path)):
                stats['errors'] += 1
                continue

            print(f"    🧹 [DIRTY] Found comments in {relative_path_str}")
            
            # 5. ACTION
            if args.force:
                # Use the new In-Place Surgical Write
                success = TransactionEngine.inplace_surgical_write(file_path, cleaned_content)
                if success:
                    print(f"       💾 [SAVED] Comments removed from {relative_path_str}")
                    stats['modified'] += 1
                else:
                    stats['errors'] += 1
            else:
                stats['modified'] += 1 # Counting as potential modification

        except Exception as e:
            print(f"    ❌ [EXCEPTION] {file_path}: {e}")
            stats['errors'] += 1

    print("=" * 60)
    print("MISSION REPORT:")
    print(f"    Processed: {stats['processed']}")
    print(f"    Clean (Skipped): {stats['clean']}")
    print(f"    Dirty (Targeted):  {stats['modified']}")
    print(f"    Errors:    {stats['errors']}")
    
    if not args.force and stats['modified'] > 0:
        print("\n⚠️  Simulation complete. No files were touched.")
        print("    Run with --force to execute.")

if __name__ == "__main__":
    main()