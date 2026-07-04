// buranbrew-consumer drains sensor and control telemetry from Redis Streams
// into TimescaleDB using the "archiver" consumer group.
//
// Consumer policy:
// - Pending entries are replayed before following new entries.
// - Messages are acknowledged only after a successful insert.
// - Database conflict handling makes replays idempotent.
// - Malformed messages are logged and dropped.
//
// Configuration:
//   REDIS_ADDR overrides the full Redis endpoint; otherwise REDIS_PORT is used
//   with 127.0.0.1 and defaults to 6379.
//   PG_DSN overrides the full PostgreSQL connection string; otherwise
//   POSTGRES_PORT is used with the local buranbrew database and defaults to 5433.

package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/redis/go-redis/v9"
)

const (
	group         = "archiver"
	sensorStream  = "telemetry:sensor"
	controlStream = "telemetry:control"
	blockFor      = 5 * time.Second
)

// Environment helper
func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// Redis field helper
func field(v map[string]interface{}, k string) string {
	s, _ := v[k].(string)
	return s
}

// Timestamp selection
func ts(id string, v map[string]interface{}) time.Time {
	// try producer timestamp
	if ms, err := strconv.ParseInt(field(v, "ts_ms"), 10, 64); err == nil {
		return time.UnixMilli(ms)
	}
	// try redis entry ID
	if i := strings.IndexByte(id, '-'); i > 0 {
		if ms, err := strconv.ParseInt(id[:i], 10, 64); err == nil {
			return time.UnixMilli(ms)
		}
	}
	// fallback: current time
	return time.Now()
}

type archiver struct {
	db  *sql.DB
	rdb *redis.Client
}

// Writes one entry to the right table.
// Malformed entry returns nil (then ack it away).
// DB failure returns error (then leave event pending, retry later).
// ON CONFLICT (event_id, ts) DO NOTHING prevents duplicate row
func (a *archiver) insert(ctx context.Context, stream, id string, v map[string]interface{}) error {
	switch stream {
	case sensorStream:
		value, err := strconv.ParseFloat(field(v, "value"), 64)
		if err != nil {
			log.Printf("drop %s %s: bad value %q", stream, id, field(v, "value"))
			return nil
		}
		node, _ := strconv.Atoi(field(v, "node"))
		_, err = a.db.ExecContext(ctx,
			`INSERT INTO sensor_data (ts, node_id, metric, value, event_id)
			 VALUES ($1,$2,$3,$4,$5) ON CONFLICT (event_id, ts) DO NOTHING`,
			ts(id, v), node, field(v, "metric"), value, id)
		return err
	case controlStream:
		if field(v, "action") == "" {
			log.Printf("drop %s %s: no action", stream, id)
			return nil
		}
		var diff sql.NullInt64
		if d, err := strconv.ParseInt(field(v, "diff_centi"), 10, 64); err == nil {
			diff = sql.NullInt64{Int64: d, Valid: true}
		}
		detail, _ := json.Marshal(v)
		_, err := a.db.ExecContext(ctx,
			`INSERT INTO control_events (ts, action, diff_centi, detail, event_id)
			 VALUES ($1,$2,$3,$4,$5) ON CONFLICT (event_id, ts) DO NOTHING`,
			ts(id, v), field(v, "action"), diff, detail, id)
		return err
	}
	return nil
}

// One step performs one redis read batch and archives its messages.
// return:
//   the number of successfully inserted and ack messages
//   the first redis or database error encountered
func (a *archiver) step(ctx context.Context, consumer, cursor string) (int, error) {
	res, err := a.rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
		Group:    group,
		Consumer: consumer,
		Streams:  []string{sensorStream, controlStream, cursor, cursor},
		Count:    100,
		Block:    blockFor, // ignored by Redis for the "0" (history) cursor
	}).Result()
	if err == redis.Nil {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	n := 0
	for _, s := range res {
		for _, m := range s.Messages {
			if err := a.insert(ctx, s.Stream, m.ID, m.Values); err != nil {
				return n, err
			}
			if err := a.rdb.XAck(ctx, s.Stream, group, m.ID).Err(); err != nil {
				return n, err
			}
			n++
		}
	}
	return n, nil
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("consumer ")
	// graceful shutdown context
	ctx, stop := signal.NotifyContext(
		context.Background(),
		syscall.SIGINT,
		syscall.SIGTERM,
	)
	defer stop()

	redisAddr := env("REDIS_ADDR", "127.0.0.1:"+env("REDIS_PORT", "6379"))
	pgPort := env("POSTGRES_PORT", "5433")
	pgDSN := env("PG_DSN", "postgres://buranbrew@127.0.0.1:"+pgPort+"/buranbrew?sslmode=disable")

	a := &archiver{
		rdb: redis.NewClient(&redis.Options{
			Addr: redisAddr,
		}),
	}
	db, err := sql.Open("pgx", pgDSN)
	if err != nil {
		log.Fatalf("pg open: %v", err)
	}
	// The consumer is sequential and handles a low telemetry rate, so 2 is enough
	db.SetMaxOpenConns(2)
	a.db = db

	for _, s := range []string{
		sensorStream,
		controlStream,
	} {
		if err := a.rdb.XGroupCreateMkStream(
			ctx,
			s,
			group,
			"0",
		).Err(); err != nil &&
			!strings.Contains(err.Error(), "BUSYGROUP") {
			log.Fatalf("xgroup create %s: %v", s, err)
		}
	}

	consumer, _ := os.Hostname()
	if consumer == "" {
		consumer = "archiver-1"
	}
	log.Printf("draining %s + %s (group %q, consumer %q)",
		sensorStream, controlStream, group, consumer)

	cursor := "0" // start by replaying the pending entries
	for ctx.Err() == nil {
		n, err := a.step(ctx, consumer, cursor)
		switch {
		case err != nil:
			// Back off, then replay pending entries
			log.Printf("step: %v (retry in 5s)", err)
			sleep(ctx, 5*time.Second)
			cursor = "0" // re-drain on recovery
		case n == 0 && cursor == "0":
			// Pending entries drained; follow new entries (live)
			cursor = ">"
		case n > 0:
			// Report progress
			log.Printf("archived %d (%s)",
				n, map[bool]string{true: "pending", false: "live"}[cursor == "0"],
			)
		}
	}
	log.Print("shutting down")
}

func sleep(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}
