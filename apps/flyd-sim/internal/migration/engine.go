package migration

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/devghori1264/aerophoenix/flyd-sim/internal/models"
	"github.com/devghori1264/aerophoenix/flyd-sim/internal/storage"
	pb "github.com/devghori1264/aerophoenix/flyd-sim/proto"
	"github.com/google/uuid"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	migrationCounter = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "flyd_migrations_total",
		Help: "Total number of migrations by result",
	}, []string{"result"})

	migrationDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "flyd_migration_duration_seconds",
		Help:    "Migration duration in seconds",
		Buckets: prometheus.ExponentialBuckets(1, 2, 10),
	}, []string{"strategy"})

	migrationPhaseGauge = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "flyd_migration_current_phase",
		Help: "Current phase of active migrations",
	}, []string{"migration_id", "phase"})

	bytesTransferredCounter = promauto.NewCounter(prometheus.CounterOpts{
		Name: "flyd_migration_bytes_transferred_total",
		Help: "Total bytes transferred during migrations",
	})
)

type Engine struct {
	store            storage.Store
	activeMigrations sync.Map
	phaseExecutors   map[pb.MigrationPhase]PhaseExecutor
	mu               sync.RWMutex
	metrics          *MigrationMetrics

	maxConcurrentMigrations int
	defaultTimeout          time.Duration
}

func NewEngine(store storage.Store) *Engine {
	e := &Engine{
		store:                   store,
		phaseExecutors:          make(map[pb.MigrationPhase]PhaseExecutor),
		maxConcurrentMigrations: 10,
		defaultTimeout:          30 * time.Minute,
		metrics: &MigrationMetrics{
			ByStrategy:      make(map[pb.MigrationStrategy]int64),
			ByPhaseFailures: make(map[pb.MigrationPhase]int64),
		},
	}

	e.registerPhaseExecutors()

	return e
}

func (e *Engine) registerPhaseExecutors() {
	e.phaseExecutors[pb.MigrationPhase_PHASE_VALIDATING] = e.executeValidation
	e.phaseExecutors[pb.MigrationPhase_PHASE_PREPARING_SOURCE] = e.executePrepareSource
	e.phaseExecutors[pb.MigrationPhase_PHASE_CREATING_TARGET] = e.executeCreateTarget
	e.phaseExecutors[pb.MigrationPhase_PHASE_TRANSFERRING_STATE] = e.executeTransferState
	e.phaseExecutors[pb.MigrationPhase_PHASE_VERIFYING_STATE] = e.executeVerifyState
	e.phaseExecutors[pb.MigrationPhase_PHASE_NETWORK_CUTOVER] = e.executeNetworkCutover
	e.phaseExecutors[pb.MigrationPhase_PHASE_CLEANUP] = e.executeCleanup
}

func (e *Engine) StartMigration(
	ctx context.Context,
	machineID string,
	targetRegion string,
	strategy pb.MigrationStrategy,
	options *pb.MigrationOptions,
) (*Migration, error) {

	sourceMachine, err := e.store.GetMachine(ctx, machineID)
	if err != nil {
		return nil, fmt.Errorf("failed to load source machine: %w", err)
	}

	if err := e.validateMigrationRequest(sourceMachine, targetRegion, strategy); err != nil {
		return nil, err
	}

	if options == nil {
		options = &pb.MigrationOptions{
			TimeoutSeconds: int64(e.defaultTimeout.Seconds()),
			PreserveIp:     true,
		}
	}

	timeout := time.Duration(options.TimeoutSeconds) * time.Second
	migrationCtx, cancel := context.WithTimeout(ctx, timeout)

	migration := &Migration{
		ID:            MigrationID(uuid.NewString()),
		MachineID:     machineID,
		SourceRegion:  sourceMachine.Region,
		TargetRegion:  targetRegion,
		Strategy:      strategy,
		Options:       options,
		State:         pb.MigrationState_STATE_PENDING,
		CurrentPhase:  pb.MigrationPhase_PHASE_VALIDATING,
		Steps:         make([]StepExecution, 0),
		StartedAt:     time.Now().UTC(),
		ctx:           migrationCtx,
		cancel:        cancel,
		progressChan:  make(chan ProgressUpdate, 100),
		sourceMachine: sourceMachine,
		checkpoints:   make(map[pb.MigrationPhase]*Checkpoint),
	}

	e.activeMigrations.Store(migration.ID, migration)

	go e.executeMigration(migration)

	return migration, nil
}

func (e *Engine) executeMigration(m *Migration) {
	startTime := time.Now()

	defer func() {
		duration := time.Since(startTime)
		migrationDuration.WithLabelValues(m.Strategy.String()).Observe(duration.Seconds())

		close(m.progressChan)
		m.cancel()

		time.AfterFunc(5*time.Minute, func() {
			e.activeMigrations.Delete(m.ID)
		})
	}()

	phases := e.getPhasesForStrategy(m.Strategy)

	m.setState(pb.MigrationState_STATE_IN_PROGRESS)

	for _, phase := range phases {

		select {
		case <-m.ctx.Done():
			e.handleMigrationFailure(m, phase, fmt.Errorf("migration cancelled: %w", m.ctx.Err()))
			return
		default:
		}

		if e.isCriticalPhase(phase) {
			if err := e.createCheckpoint(m, phase); err != nil {
				e.handleMigrationFailure(m, phase, fmt.Errorf("checkpoint failed: %w", err))
				return
			}
		}

		m.setPhase(phase)
		migrationPhaseGauge.WithLabelValues(string(m.ID), phase.String()).Set(1)

		executor, exists := e.phaseExecutors[phase]
		if !exists {
			e.handleMigrationFailure(m, phase, fmt.Errorf("no executor for phase %s", phase))
			return
		}

		step := m.startStep(phase.String(), phase)

		if err := executor(m.ctx, m); err != nil {
			step.fail(err)
			e.handleMigrationFailure(m, phase, err)
			return
		}

		step.complete()
		migrationPhaseGauge.WithLabelValues(string(m.ID), phase.String()).Set(0)
	}

	e.completeMigration(m)
}

func (e *Engine) getPhasesForStrategy(strategy pb.MigrationStrategy) []pb.MigrationPhase {
	switch strategy {
	case pb.MigrationStrategy_STOP_AND_MOVE:
		return []pb.MigrationPhase{
			pb.MigrationPhase_PHASE_VALIDATING,
			pb.MigrationPhase_PHASE_PREPARING_SOURCE,
			pb.MigrationPhase_PHASE_CREATING_TARGET,
			pb.MigrationPhase_PHASE_TRANSFERRING_STATE,
			pb.MigrationPhase_PHASE_VERIFYING_STATE,
			pb.MigrationPhase_PHASE_NETWORK_CUTOVER,
			pb.MigrationPhase_PHASE_CLEANUP,
		}
	case pb.MigrationStrategy_CLONE_AND_REDIRECT:
		return []pb.MigrationPhase{
			pb.MigrationPhase_PHASE_VALIDATING,
			pb.MigrationPhase_PHASE_CREATING_TARGET,
			pb.MigrationPhase_PHASE_TRANSFERRING_STATE,
			pb.MigrationPhase_PHASE_VERIFYING_STATE,
			pb.MigrationPhase_PHASE_NETWORK_CUTOVER,
			pb.MigrationPhase_PHASE_CLEANUP,
		}
	default:
		return []pb.MigrationPhase{pb.MigrationPhase_PHASE_VALIDATING}
	}
}

func (e *Engine) isCriticalPhase(phase pb.MigrationPhase) bool {
	critical := map[pb.MigrationPhase]bool{
		pb.MigrationPhase_PHASE_PREPARING_SOURCE: true,
		pb.MigrationPhase_PHASE_NETWORK_CUTOVER:  true,
	}
	return critical[phase]
}

func (e *Engine) validateMigrationRequest(
	source *models.Machine,
	targetRegion string,
	strategy pb.MigrationStrategy,
) error {
	if source.Region == targetRegion {
		return &ValidationError{
			Field:   "target_region",
			Message: "target region must differ from source region",
		}
	}

	if source.Status == "terminated" {
		return &ValidationError{
			Field:   "machine_status",
			Message: "cannot migrate terminated machine",
		}
	}

	var alreadyMigrating bool
	e.activeMigrations.Range(func(key, value interface{}) bool {
		m := value.(*Migration)
		if m.MachineID == source.ID && m.State == pb.MigrationState_STATE_IN_PROGRESS {
			alreadyMigrating = true
			return false
		}
		return true
	})

	if alreadyMigrating {
		return &ValidationError{
			Field:   "machine_id",
			Message: "machine is already being migrated",
		}
	}

	return nil
}

func (e *Engine) createCheckpoint(m *Migration, phase pb.MigrationPhase) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	checkpoint := &Checkpoint{
		Phase:     phase,
		Timestamp: time.Now().UTC(),

		MachineState: &models.Machine{
			ID:        m.sourceMachine.ID,
			Name:      m.sourceMachine.Name,
			Region:    m.sourceMachine.Region,
			Status:    m.sourceMachine.Status,
			Version:   m.sourceMachine.Version,
			CreatedAt: m.sourceMachine.CreatedAt,
			UpdatedAt: m.sourceMachine.UpdatedAt,
			Metadata:  m.sourceMachine.Metadata,
		},
		Reversible: true,
	}

	m.checkpoints[phase] = checkpoint
	return nil
}

func (e *Engine) handleMigrationFailure(m *Migration, failedPhase pb.MigrationPhase, err error) {
	m.mu.Lock()
	m.Error = err
	m.State = pb.MigrationState_STATE_FAILED
	m.CurrentPhase = pb.MigrationPhase_PHASE_FAILED
	completedAt := time.Now().UTC()
	m.CompletedAt = &completedAt
	m.mu.Unlock()

	migrationCounter.WithLabelValues("failed").Inc()
	e.mu.Lock()
	e.metrics.FailedMigrations++
	e.metrics.ByPhaseFailures[failedPhase]++
	e.mu.Unlock()

	m.publishProgress(ProgressUpdate{
		MigrationID:     m.ID,
		Phase:           pb.MigrationPhase_PHASE_FAILED,
		ProgressPercent: 0,
		Message:         fmt.Sprintf("Migration failed at %s: %v", failedPhase, err),
		Timestamp:       time.Now().UTC(),
	})

	if e.shouldRollback(m, failedPhase) {
		if rollbackErr := e.executeRollback(m, failedPhase); rollbackErr != nil {

			m.publishProgress(ProgressUpdate{
				MigrationID: m.ID,
				Phase:       pb.MigrationPhase_PHASE_ROLLING_BACK,
				Message:     fmt.Sprintf("Rollback failed: %v", rollbackErr),
				Timestamp:   time.Now().UTC(),
			})
		} else {
			m.mu.Lock()
			m.State = pb.MigrationState_STATE_ROLLED_BACK
			m.mu.Unlock()
			migrationCounter.WithLabelValues("rolled_back").Inc()
			e.mu.Lock()
			e.metrics.RolledBackMigrations++
			e.mu.Unlock()
		}
	}
}

func (e *Engine) shouldRollback(m *Migration, failedPhase pb.MigrationPhase) bool {

	if failedPhase == pb.MigrationPhase_PHASE_CLEANUP ||
		failedPhase == pb.MigrationPhase_PHASE_COMPLETED {
		return false
	}

	m.mu.RLock()
	defer m.mu.RUnlock()

	for phase, checkpoint := range m.checkpoints {
		if phase <= failedPhase && checkpoint.Reversible {
			return true
		}
	}

	return false
}

func (e *Engine) executeRollback(m *Migration, fromPhase pb.MigrationPhase) error {
	m.setPhase(pb.MigrationPhase_PHASE_ROLLING_BACK)

	var latestCheckpoint *Checkpoint
	var latestPhase pb.MigrationPhase

	m.mu.RLock()
	for phase, cp := range m.checkpoints {
		if phase < fromPhase && cp.Reversible {
			if latestCheckpoint == nil || phase > latestPhase {
				latestCheckpoint = cp
				latestPhase = phase
			}
		}
	}
	m.mu.RUnlock()

	if latestCheckpoint == nil {
		return fmt.Errorf("no reversible checkpoint found")
	}

	if err := e.store.SaveMachine(m.ctx, latestCheckpoint.MachineState); err != nil {
		return fmt.Errorf("failed to restore machine state: %w", err)
	}

	if m.targetMachine != nil {

		_ = e.store.SaveMachine(m.ctx, &models.Machine{
			ID:     m.targetMachine.ID,
			Status: "terminated",
		})
	}

	return nil
}

func (e *Engine) completeMigration(m *Migration) {
	m.mu.Lock()
	m.State = pb.MigrationState_STATE_COMPLETED
	m.CurrentPhase = pb.MigrationPhase_PHASE_COMPLETED
	completedAt := time.Now().UTC()
	m.CompletedAt = &completedAt
	m.mu.Unlock()

	migrationCounter.WithLabelValues("success").Inc()
	bytesTransferredCounter.Add(float64(m.BytesTransferred))

	e.mu.Lock()
	e.metrics.SuccessfulMigrations++
	e.metrics.TotalBytesTransferred += m.BytesTransferred
	e.metrics.ByStrategy[m.Strategy]++
	e.mu.Unlock()

	m.publishProgress(ProgressUpdate{
		MigrationID:      m.ID,
		Phase:            pb.MigrationPhase_PHASE_COMPLETED,
		ProgressPercent:  100,
		Message:          "Migration completed successfully",
		BytesTransferred: m.BytesTransferred,
		Timestamp:        time.Now().UTC(),
	})
}

func (e *Engine) GetMigrationStatus(migrationID MigrationID) (*pb.MigrationStatusResponse, error) {
	value, ok := e.activeMigrations.Load(migrationID)
	if !ok {
		return nil, fmt.Errorf("migration %s not found", migrationID)
	}

	m := value.(*Migration)
	m.mu.RLock()
	defer m.mu.RUnlock()

	steps := make([]*pb.MigrationStepStatus, len(m.Steps))
	for i, step := range m.Steps {
		steps[i] = &pb.MigrationStepStatus{
			StepName:   step.Name,
			Completed:  step.CompletedAt != nil,
			DurationMs: step.Duration.Milliseconds(),
			Error:      formatError(step.Error),
		}
	}

	var errorMsg string
	if m.Error != nil {
		errorMsg = m.Error.Error()
	}

	var completedAtUnix int64
	if m.CompletedAt != nil {
		completedAtUnix = m.CompletedAt.Unix()
	}

	return &pb.MigrationStatusResponse{
		MigrationId:      string(m.ID),
		Phase:            m.CurrentPhase,
		State:            m.State,
		SourceRegion:     m.SourceRegion,
		TargetRegion:     m.TargetRegion,
		BytesTransferred: m.BytesTransferred,
		TotalBytes:       m.TotalBytes,
		Steps:            steps,
		ErrorMessage:     errorMsg,
		StartedAt:        m.StartedAt.Unix(),
		CompletedAt:      completedAtUnix,
	}, nil
}

func (e *Engine) StreamProgress(migrationID MigrationID) (<-chan ProgressUpdate, error) {
	value, ok := e.activeMigrations.Load(migrationID)
	if !ok {
		return nil, fmt.Errorf("migration %s not found", migrationID)
	}

	m := value.(*Migration)
	return m.progressChan, nil
}

func (m *Migration) setState(state pb.MigrationState) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.State = state
}

func (m *Migration) setPhase(phase pb.MigrationPhase) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.CurrentPhase = phase
}

func (m *Migration) startStep(name string, phase pb.MigrationPhase) *StepExecution {
	step := StepExecution{
		Name:      name,
		Phase:     phase,
		StartedAt: time.Now().UTC(),
		Metadata:  make(map[string]interface{}),
	}

	m.mu.Lock()
	m.Steps = append(m.Steps, step)
	stepIndex := len(m.Steps) - 1
	m.mu.Unlock()

	return &m.Steps[stepIndex]
}

func (step *StepExecution) complete() {
	now := time.Now().UTC()
	step.CompletedAt = &now
	step.Duration = now.Sub(step.StartedAt)
}

func (step *StepExecution) fail(err error) {
	now := time.Now().UTC()
	step.CompletedAt = &now
	step.Duration = now.Sub(step.StartedAt)
	step.Error = err
}

func (m *Migration) publishProgress(update ProgressUpdate) {
	select {
	case m.progressChan <- update:
	default:

	}
}

func formatError(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
