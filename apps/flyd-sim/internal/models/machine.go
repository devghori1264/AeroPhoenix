package models

import "time"

type Machine struct {
	ID        string            `json:"id"`
	Name      string            `json:"name"`
	Region    string            `json:"region"`
	Status    string            `json:"status"`
	Version   int64             `json:"version"`
	CreatedAt time.Time         `json:"created_at"`
	UpdatedAt time.Time         `json:"updated_at"`
	Metadata  map[string]string `json:"metadata,omitempty"`
}
