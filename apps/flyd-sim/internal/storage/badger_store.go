package storage

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"

	"github.com/devghori1264/aerophoenix/flyd-sim/internal/models"
	badger "github.com/dgraph-io/badger/v4"
)

var (
	ErrNotFound = errors.New("not found")
)

// Store interface (kept minimal, allows swapping implementations).
type Store interface {
	SaveMachine(ctx context.Context, m *models.Machine) error
	GetMachine(ctx context.Context, id string) (*models.Machine, error)
	Close() error
}

// BadgerStore implements Store with Badger DB.
type BadgerStore struct {
	db *badger.DB
}

func NewBadgerStore(path string) (Store, error) {
	opts := badger.DefaultOptions(filepath.Clean(path))
	opts.Logger = nil                         // disable badger logs for test clarity
	opts = opts.WithValueLogFileSize(1 << 20) // smaller value log for local dev
	db, err := badger.Open(opts)
	if err != nil {
		return nil, err
	}
	return &BadgerStore{db: db}, nil
}

func (s *BadgerStore) Close() error {
	return s.db.Close()
}

func machineKey(id string) []byte {
	return []byte("machine:" + id)
}

func (s *BadgerStore) SaveMachine(ctx context.Context, m *models.Machine) error {
	return s.db.Update(func(txn *badger.Txn) error {
		data, err := json.Marshal(m)
		if err != nil {
			return err
		}
		return txn.Set(machineKey(m.ID), data)
	})
}

func (s *BadgerStore) GetMachine(ctx context.Context, id string) (*models.Machine, error) {
	var out models.Machine
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(machineKey(id))
		if err != nil {
			if err == badger.ErrKeyNotFound {
				return ErrNotFound
			}
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &out)
		})
	})
	if err != nil {
		return nil, err
	}
	return &out, nil
}
