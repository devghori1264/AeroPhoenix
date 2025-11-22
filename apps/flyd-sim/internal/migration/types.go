package migration

import (
	"context"
	"sync"
	"time"

	"github.com/devghori1264/aerophoenix/flyd-sim/internal/models"
	pb "github.com/devghori1264/aerophoenix/flyd-sim/proto"
)

type MigrationID string

type Migration struct {
	ID               MigrationID
	MachineID        string
	SourceRegion     string
	TargetRegion     string
	Strategy         pb.MigrationStrategy
	Options          *pb.MigrationOptions
	State            pb.MigrationState
	CurrentPhase     pb.MigrationPhase
	Steps            []StepExecution
	BytesTransferred int64
	TotalBytes       int64
	StartedAt        time.Time
	CompletedAt      *time.Time
	Error            error

	ctx          context.Context
	cancel       context.CancelFunc
	progressChan chan ProgressUpdate
	mu           sync.RWMutex

	sourceMachine *models.Machine
	targetMachine *models.Machine

	checkpoints map[pb.MigrationPhase]*Checkpoint
}

type StepExecution struct {
	Name        string
	Phase       pb.MigrationPhase
	StartedAt   time.Time
	CompletedAt *time.Time
	Duration    time.Duration
	Error       error
	Metadata    map[string]interface{}
}

type Checkpoint struct {
	Phase        pb.MigrationPhase
	Timestamp    time.Time
	MachineState *models.Machine
	NetworkState *NetworkSnapshot
	StorageState *StorageSnapshot
	Reversible   bool
}

type NetworkSnapshot struct {
	AnycastIP     string
	PrivateIP     string
	DNSRecords    []DNSRecord
	RoutingTable  map[string]string
	FirewallRules []FirewallRule
}

type DNSRecord struct {
	Name  string
	Type  string
	Value string
	TTL   int
}

type FirewallRule struct {
	Direction string
	Protocol  string
	Port      int
	Source    string
	Action    string
}

type StorageSnapshot struct {
	VolumeID   string
	SizeBytes  int64
	Checksum   string
	SnapshotID string
	MountPoint string
	Filesystem string
}

type ProgressUpdate struct {
	MigrationID      MigrationID
	Phase            pb.MigrationPhase
	ProgressPercent  int32
	Message          string
	BytesTransferred int64
	Timestamp        time.Time
}

type MigrationResult struct {
	Success          bool
	MigrationID      MigrationID
	FinalPhase       pb.MigrationPhase
	Duration         time.Duration
	BytesTransferred int64
	TargetMachineID  string
	Error            error
	RollbackExecuted bool
}

type MigrationMetrics struct {
	TotalMigrations       int64
	SuccessfulMigrations  int64
	FailedMigrations      int64
	RolledBackMigrations  int64
	AverageDuration       time.Duration
	TotalBytesTransferred int64
	ByStrategy            map[pb.MigrationStrategy]int64
	ByPhaseFailures       map[pb.MigrationPhase]int64
}

type ValidationError struct {
	Field   string
	Message string
}

func (e *ValidationError) Error() string {
	return e.Field + ": " + e.Message
}

type PhaseExecutor func(ctx context.Context, m *Migration) error
