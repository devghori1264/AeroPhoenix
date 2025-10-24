package natsclient

import (
	"context"
	"fmt"
	"time"

	"github.com/nats-io/nats.go"
)

type Publisher struct {
	nc  *nats.Conn
	url string
}

func NewPublisher(url string) (*Publisher, error) {
	opts := []nats.Option{
		nats.Name("aerophoenix-flyd-sim"),
		nats.MaxReconnects(-1),
		nats.ReconnectWait(2 * time.Second),
		nats.DisconnectErrHandler(func(nc *nats.Conn, err error) {
			fmt.Printf("nats disconnected: %v\n", err)
		}),
		nats.ReconnectHandler(func(nc *nats.Conn) {
			fmt.Printf("nats reconnected to %s\n", nc.ConnectedUrl())
		}),
	}
	nc, err := nats.Connect(url, opts...)
	if err != nil {
		return nil, err
	}
	return &Publisher{nc: nc, url: url}, nil
}

func (p *Publisher) Publish(ctx context.Context, subject string, payload []byte) error {
	if p.nc == nil || p.nc.IsClosed() {
		return fmt.Errorf("nats not connected")
	}
	return p.nc.Publish(subject, payload)
}

func (p *Publisher) Close() {
	if p.nc != nil {
		p.nc.Drain()
		p.nc.Close()
	}
}
