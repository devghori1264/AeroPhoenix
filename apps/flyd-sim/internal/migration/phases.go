package migration

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/rand"
	"time"

	"github.com/devghori1264/aerophoenix/flyd-sim/internal/models"
	pb "github.com/devghori1264/aerophoenix/flyd-sim/proto"
	"github.com/google/uuid"
)

func (e *Engine) executeValidation(ctx context.Context, m *Migration) error {
	m.publishProgress(ProgressUpdate{
		MigrationID:     m.ID,
		Phase:           pb.MigrationPhase_PHASE_VALIDATING,
		ProgressPercent: 5,
		Message:         "Validating migration prerequisites",
		Timestamp:       time.Now().UTC(),
	})

	sourceMachine, err := e.store.GetMachine(ctx, m.MachineID)
	if err != nil {
		return fmt.Errorf("source machine validation failed: %w", err)
	}

	m.mu.Lock()
	m.sourceMachine = sourceMachine
	m.mu.Unlock()

	validStates := map[string]bool{
		"pending": true,
		"running": true,
		"stopped": true,
	}

	if !validStates[sourceMachine.Status] {
		return fmt.Errorf("machine status %s is not migratable", sourceMachine.Status)
	}

	estimatedBytes := int64(1024 * 1024 * 100)
	if diskSizeStr, ok := sourceMachine.Metadata["disk_size_mb"]; ok {

		var diskSize int64
		fmt.Sscanf(diskSizeStr, "%d", &diskSize)
		if diskSize > 0 {
			estimatedBytes = diskSize * 1024 * 1024
		}
	}

	m.mu.Lock()
	m.TotalBytes = estimatedBytes
	m.mu.Unlock()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(time.Duration(50+rand.Intn(150)) * time.Millisecond):
	}

	m.publishProgress(ProgressUpdate{
		MigrationID:     m.ID,
		Phase:           pb.MigrationPhase_PHASE_VALIDATING,
		ProgressPercent: 10,
		Message:         fmt.Sprintf("Validation complete. Ready to migrate %s from %s to %s", m.MachineID, m.SourceRegion, m.TargetRegion),
		Timestamp:       time.Now().UTC(),
	})

	return nil
}

func (e *Engine) executePrepareSource(ctx context.Context, m *Migration) error {
	m.publishProgress(ProgressUpdate{
		MigrationID:     m.ID,
		Phase:           pb.MigrationPhase_PHASE_PREPARING_SOURCE,
		ProgressPercent: 15,
		Message:         "Preparing source machine",
		Timestamp:       time.Now().UTC(),
	})

	if m.Strategy == pb.MigrationStrategy_STOP_AND_MOVE {
		m.mu.RLock()
		sourceMachine := m.sourceMachine
		m.mu.RUnlock()

		sourceMachine.Status = "stopping"
		sourceMachine.UpdatedAt = time.Now().UTC()
		sourceMachine.Version++

		if err := e.store.SaveMachine(ctx, sourceMachine); err != nil {
			return fmt.Errorf("failed to update source machine status: %w", err)
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(100+rand.Intn(400)) * time.Millisecond):
		}

		sourceMachine.Status = "stopped"
		sourceMachine.UpdatedAt = time.Now().UTC()
		sourceMachine.Version++

		if err := e.store.SaveMachine(ctx, sourceMachine); err != nil {
			return fmt.Errorf("failed to stop source machine: %w", err)
		}

		m.mu.Lock()
		m.sourceMachine = sourceMachine
		m.mu.Unlock()
	}

	if err := e.createStateSnapshot(ctx, m); err != nil {
		return fmt.Errorf("failed to create state snapshot: %w", err)
	}

	m.publishProgress(ProgressUpdate{
		MigrationID:     m.ID,
		Phase:           pb.MigrationPhase_PHASE_PREPARING_SOURCE,
		ProgressPercent: 25,
		Message:         "Source machine prepared successfully",
		Timestamp:       time.Now().UTC(),
	})

	return nil
}

func (e *Engine) executeCreateTarget(ctx context.Context, m *Migration) error {
	m.publishProgress(ProgressUpdate{
		MigrationID:     m.ID,
		Phase:           pb.MigrationPhase_PHASE_CREATING_TARGET,
		ProgressPercent: 30,
		Message:         fmt.Sprintf("Creating target machine in %s", m.TargetRegion),
		Timestamp:       time.Now().UTC(),
	})

	m.mu.RLock()
	sourceMachine := m.sourceMachine
	m.mu.RUnlock()

	targetMachine := &models.Machine{
		ID:        uuid.NewString(),
		Name:      sourceMachine.Name,
		Region:    m.TargetRegion,
		Status:    "provisioning",
		Version:   1,
		CreatedAt: time.Now().UTC(),
		UpdatedAt: time.Now().UTC(),
		Metadata:  make(map[string]string),
	}

	for k, v := range sourceMachine.Metadata {
		targetMachine.Metadata[k] = v
	}

	targetMachine.Metadata["migration_id"] = string(m.ID)
	targetMachine.Metadata["migration_source_id"] = sourceMachine.ID
	targetMachine.Metadata["migration_source_region"] = sourceMachine.Region
	targetMachine.Metadata["migration_timestamp"] = time.Now().UTC().Format(time.RFC3339)

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(time.Duration(200+rand.Intn(600)) * time.Millisecond):
	}

	if err := e.store.SaveMachine(ctx, targetMachine); err != nil {
		return fmt.Errorf("failed to create target machine: %w", err)
	}

	m.mu.Lock()
	m.targetMachine = targetMachine
	m.mu.Unlock()

	m.publishProgress(ProgressUpdate{
		MigrationID:     m.ID,
		Phase:           pb.MigrationPhase_PHASE_CREATING_TARGET,
		ProgressPercent: 40,
		Message:         fmt.Sprintf("Target machine %s created in %s", targetMachine.ID, m.TargetRegion),
		Timestamp:       time.Now().UTC(),
	})

	return nil
}

func (e *Engine) executeTransferState(ctx context.Context, m *Migration) error {
	m.publishProgress(ProgressUpdate{
		MigrationID:     m.ID,
		Phase:           pb.MigrationPhase_PHASE_TRANSFERRING_STATE,
		ProgressPercent: 45,
		Message:         "Beginning state transfer",
		Timestamp:       time.Now().UTC(),
	})

	totalBytes := m.TotalBytes
	chunkSize := int64(1024 * 1024 * 10)
	var transferred int64

	for transferred < totalBytes {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		toTransfer := chunkSize
		if transferred+chunkSize > totalBytes {
			toTransfer = totalBytes - transferred
		}

		transferTime := e.calculateTransferTime(m.SourceRegion, m.TargetRegion, toTransfer)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(transferTime):
		}

		transferred += toTransfer
		m.mu.Lock()
		m.BytesTransferred = transferred
		m.mu.Unlock()

		progressPercent := int32(45 + (float64(transferred)/float64(totalBytes))*30)
		m.publishProgress(ProgressUpdate{
			MigrationID:      m.ID,
			Phase:            pb.MigrationPhase_PHASE_TRANSFERRING_STATE,
			ProgressPercent:  progressPercent,
			Message:          fmt.Sprintf("Transferred %d/%d bytes (%.1f%%)", transferred, totalBytes, float64(transferred)/float64(totalBytes)*100),
			BytesTransferred: transferred,
			Timestamp:        time.Now().UTC(),
		})
	}

	m.publishProgress(ProgressUpdate{
		MigrationID:      m.ID,
		Phase:            pb.MigrationPhase_PHASE_TRANSFERRING_STATE,
		ProgressPercent:  75,
		Message:          "State transfer complete",
		BytesTransferred: transferred,
		Timestamp:        time.Now().UTC(),
	})

	return nil
}

func (e *Engine) executeVerifyState(ctx context.Context, m *Migration) error {
	m.publishProgress(ProgressUpdate{
		MigrationID:     m.ID,
		Phase:           pb.MigrationPhase_PHASE_VERIFYING_STATE,
		ProgressPercent: 80,
		Message:         "Verifying state integrity",
		Timestamp:       time.Now().UTC(),
	})

	if m.Options != nil && m.Options.SkipStateVerification {
		m.publishProgress(ProgressUpdate{
			MigrationID:     m.ID,
			Phase:           pb.MigrationPhase_PHASE_VERIFYING_STATE,
			ProgressPercent: 85,
			Message:         "State verification skipped (skip_state_verification=true)",
			Timestamp:       time.Now().UTC(),
		})
		return nil
	}

	sourceChecksum, err := e.computeStateChecksum(m.sourceMachine)
	if err != nil {
		return fmt.Errorf("failed to compute source checksum: %w", err)
	}

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(time.Duration(100+rand.Intn(300)) * time.Millisecond):
	}

	targetChecksum, err := e.computeStateChecksum(m.targetMachine)
	if err != nil {
		return fmt.Errorf("failed to compute target checksum: %w", err)
	}

	if sourceChecksum != targetChecksum {
		return fmt.Errorf("state verification failed: checksum mismatch (source=%s, target=%s)", sourceChecksum, targetChecksum)
	}

	m.publishProgress(ProgressUpdate{
		MigrationID:     m.ID,
		Phase:           pb.MigrationPhase_PHASE_VERIFYING_STATE,
		ProgressPercent: 85,
		Message:         fmt.Sprintf("State verified successfully (checksum=%s)", sourceChecksum[:16]),
		Timestamp:       time.Now().UTC(),
	})

	return nil
}

func (e *Engine) executeNetworkCutover(ctx context.Context, m *Migration) error {
	m.publishProgress(ProgressUpdate{
		MigrationID:     m.ID,
		Phase:           pb.MigrationPhase_PHASE_NETWORK_CUTOVER,
		ProgressPercent: 90,
		Message:         "Initiating network cutover",
		Timestamp:       time.Now().UTC(),
	})

	m.mu.RLock()
	targetMachine := m.targetMachine
	m.mu.RUnlock()

	targetMachine.Status = "running"
	targetMachine.UpdatedAt = time.Now().UTC()
	targetMachine.Version++

	if err := e.store.SaveMachine(ctx, targetMachine); err != nil {
		return fmt.Errorf("failed to start target machine: %w", err)
	}

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(time.Duration(50+rand.Intn(150)) * time.Millisecond):
	}

	m.mu.Lock()
	m.targetMachine = targetMachine
	m.mu.Unlock()

	m.publishProgress(ProgressUpdate{
		MigrationID:     m.ID,
		Phase:           pb.MigrationPhase_PHASE_NETWORK_CUTOVER,
		ProgressPercent: 95,
		Message:         "Network cutover complete - traffic now routing to target",
		Timestamp:       time.Now().UTC(),
	})

	return nil
}

func (e *Engine) executeCleanup(ctx context.Context, m *Migration) error {
	m.publishProgress(ProgressUpdate{
		MigrationID:     m.ID,
		Phase:           pb.MigrationPhase_PHASE_CLEANUP,
		ProgressPercent: 97,
		Message:         "Cleaning up source machine",
		Timestamp:       time.Now().UTC(),
	})

	m.mu.RLock()
	sourceMachine := m.sourceMachine
	m.mu.RUnlock()

	sourceMachine.Status = "terminated"
	sourceMachine.UpdatedAt = time.Now().UTC()
	sourceMachine.Version++

	if sourceMachine.Metadata == nil {
		sourceMachine.Metadata = make(map[string]string)
	}
	sourceMachine.Metadata["terminated_by_migration"] = string(m.ID)
	sourceMachine.Metadata["migrated_to_region"] = m.TargetRegion
	sourceMachine.Metadata["migrated_to_machine_id"] = m.targetMachine.ID
	sourceMachine.Metadata["termination_timestamp"] = time.Now().UTC().Format(time.RFC3339)

	if err := e.store.SaveMachine(ctx, sourceMachine); err != nil {

		m.publishProgress(ProgressUpdate{
			MigrationID: m.ID,
			Phase:       pb.MigrationPhase_PHASE_CLEANUP,
			Message:     fmt.Sprintf("Warning: failed to terminate source machine: %v", err),
			Timestamp:   time.Now().UTC(),
		})
	}

	if m.Options != nil && m.Options.PreserveIp {

		updatedMachine := &models.Machine{
			ID:        m.MachineID,
			Name:      m.targetMachine.Name,
			Region:    m.TargetRegion,
			Status:    m.targetMachine.Status,
			Version:   m.targetMachine.Version,
			CreatedAt: m.sourceMachine.CreatedAt,
			UpdatedAt: time.Now().UTC(),
			Metadata:  m.targetMachine.Metadata,
		}

		if err := e.store.SaveMachine(ctx, updatedMachine); err != nil {
			return fmt.Errorf("failed to update machine record: %w", err)
		}
	}

	m.publishProgress(ProgressUpdate{
		MigrationID:     m.ID,
		Phase:           pb.MigrationPhase_PHASE_CLEANUP,
		ProgressPercent: 99,
		Message:         "Cleanup complete",
		Timestamp:       time.Now().UTC(),
	})

	return nil
}

func (e *Engine) createStateSnapshot(ctx context.Context, m *Migration) error {
	m.mu.RLock()
	sourceMachine := m.sourceMachine
	m.mu.RUnlock()

	snapshotMetadata := map[string]interface{}{
		"machine_id":   sourceMachine.ID,
		"region":       sourceMachine.Region,
		"status":       sourceMachine.Status,
		"version":      sourceMachine.Version,
		"created_at":   sourceMachine.CreatedAt,
		"snapshot_at":  time.Now().UTC(),
		"migration_id": m.ID,
	}

	if sourceMachine.Metadata == nil {
		sourceMachine.Metadata = make(map[string]string)
	}
	snapshotJSON, _ := json.Marshal(snapshotMetadata)
	sourceMachine.Metadata["migration_snapshot"] = string(snapshotJSON)

	return e.store.SaveMachine(ctx, sourceMachine)
}

func (e *Engine) calculateTransferTime(sourceRegion, targetRegion string, bytes int64) time.Duration {

	regionLatency := map[string]map[string]int{
		"us-east": {
			"us-east":      10,
			"us-west":      60,
			"eu-west":      90,
			"ap-south":     180,
			"ap-northeast": 200,
		},
		"eu-west": {
			"us-east":      90,
			"us-west":      150,
			"eu-west":      10,
			"ap-south":     120,
			"ap-northeast": 200,
		},
		"ap-south": {
			"us-east":      180,
			"us-west":      150,
			"eu-west":      120,
			"ap-south":     10,
			"ap-northeast": 80,
		},
	}

	baseLatency := 50
	if latencies, ok := regionLatency[sourceRegion]; ok {
		if latency, ok := latencies[targetRegion]; ok {
			baseLatency = latency
		}
	}

	bandwidth := int64(100 * 1024 * 1024)
	transferTimeMs := baseLatency + int((bytes*1000)/bandwidth)

	jitter := rand.Intn(transferTimeMs / 10)
	return time.Duration(transferTimeMs+jitter) * time.Millisecond
}

func (e *Engine) computeStateChecksum(machine *models.Machine) (string, error) {

	stateData := fmt.Sprintf("%s:%s:%s:%d:%v",
		machine.ID,
		machine.Name,
		machine.Region,
		machine.Version,
		machine.Metadata,
	)

	hash := sha256.Sum256([]byte(stateData))
	return hex.EncodeToString(hash[:]), nil
}
