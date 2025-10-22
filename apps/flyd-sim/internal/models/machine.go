package models

import "time"

// Machine is the core domain object representing a compute instance or node.
// Shared between the server and storage layers.
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
