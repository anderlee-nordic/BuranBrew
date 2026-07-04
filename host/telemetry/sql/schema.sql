-- BuranBrew telemetry schema. Idempotent
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Sensor data (ambient / internal temperature in C, gravity as SG e.g. 1.012).
-- event_id is the Redis stream entry ID (conflict will be handled)
CREATE TABLE IF NOT EXISTS sensor_data (
    ts       timestamptz      NOT NULL,
    node_id  integer          NOT NULL DEFAULT 0,
    metric   text             NOT NULL,      -- 'ambient' | 'internal' | 'gravity'
    value    double precision NOT NULL,
    event_id text             NOT NULL,
    UNIQUE (event_id, ts)                    -- unique key must include the partition column
);
SELECT create_hypertable('sensor_data', 'ts', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS sensor_data_metric_ts ON sensor_data (metric, ts DESC);

-- Control events: every decision the model made (HEAT / IDLE / COOL).
-- detail keeps the raw emitted fields (jsonb) for post-mortem.
CREATE TABLE IF NOT EXISTS control_events (
    ts         timestamptz NOT NULL,
    action     text        NOT NULL,         -- 'HEAT' | 'IDLE' | 'COOL'
    diff_centi integer,
    detail     jsonb,
    event_id   text        NOT NULL,
    UNIQUE (event_id, ts)
);
SELECT create_hypertable('control_events', 'ts', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS control_events_ts ON control_events (ts DESC);

-- Brewing batches define named fermentation periods and metadata.
-- Telemetry is associated with a batch by matching timestamps between started_at and ended_at
-- Sensor rows are not modified or batch-tagged.
CREATE TABLE IF NOT EXISTS batches (
    batch_id   serial PRIMARY KEY,
    name       text        NOT NULL,
    style      text,                          -- beer type, e.g. 'Blabla IPA'
    vessel     text,
    started_at timestamptz NOT NULL,
    ended_at   timestamptz,                   -- NULL = active
    og         numeric(5,3),                  -- original gravity, e.g. 1.060
    target_fg  numeric(5,3),                  -- target final gravity, e.g. 1.012
    notes      text
);
-- Add columns if upgrading an older batches table (idempotent).
ALTER TABLE batches ADD COLUMN IF NOT EXISTS style     text;
ALTER TABLE batches ADD COLUMN IF NOT EXISTS og        numeric(5,3);
ALTER TABLE batches ADD COLUMN IF NOT EXISTS target_fg numeric(5,3);

-- Default demo row, to be changed during real operation
INSERT INTO batches (batch_id, name, style, vessel, started_at, og, target_fg, notes)
SELECT 0, 'Batch #0', 'Blabla IPA', 'fermenter-1', now(), 1.060, 1.012, 'placeholder brew'
WHERE NOT EXISTS (SELECT 1 FROM batches);
