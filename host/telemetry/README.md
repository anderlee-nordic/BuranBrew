# Cellarman Operations Guide

Cellarman is the collective name referring to the telemetry stack which consists of Redis, 
the Go consumer, TimescaleDB, and Grafana.

Complete the host bring-up steps in the
[Host Bring-up & Commissioning Guide](../README.md) before using this guide.

[TOC]

## 1. Start Cellarman

### One-time setup

#### Create the `buran` user
```bash
sudo useradd -rm -d /home/buran -s /bin/bash buran
```

#### Grant `buran` read access to the code tree (via ACL)
```bash
sudo apt update && sudo apt install -y acl
sudo setfacl -m u:buran:x /root                         # traverse /root only
sudo setfacl -R -m u:buran:rX /root/buranbrew/host      # read + traverse the tree
sudo setfacl -R -d -m u:buran:rX /root/buranbrew/host   # DEFAULT ACL: survives redeploys
```

#### Create buran's data directory
```bash
sudo install -d -o buran -g buran /home/buran/telemetry
```

### Regular workflow

Run the telemetry stack as the unprivileged `buran` user:

```bash
sudo -u buran bash -lc \
  'cd /root/buranbrew/host && \
   TELEMETRY_DATA=/home/buran/telemetry \
   nix run .#cellarman'
```

Open Grafana in browser:

```text
http://<PI_ADDRESS>:3000
```

Use the value of `GRAFANA_PORT` from `host.env` when it is not `3000`. 

## 2. Start a fermentation batch

The dashboard associates telemetry with a batch by timestamp. Sensor and control
rows are not modified or tagged with a batch ID; readings between `started_at`
and `ended_at` belong to that batch.

Connect to TimescaleDB:

```bash
psql \
  -h 127.0.0.1 \
  -p "${POSTGRES_PORT:-5433}" \
  -U buranbrew \
  -d buranbrew
```

### First real batch only

The schema creates `Batch #0` as a dashboard placeholder. Remove it before the
first real brew:

```sql
DELETE FROM batches
WHERE batch_id = 0
  AND name = 'Batch #0';
```

### Confirm that no batch is active

Keep only one active batch at a time:

```sql
SELECT batch_id, name, style, vessel, started_at
FROM batches
WHERE ended_at IS NULL
ORDER BY started_at DESC;
```

End an existing active batch before starting another one.

### Create the batch

Insert a row with `ended_at` left as `NULL`:

```sql
INSERT INTO batches (
    name,
    style,
    vessel,
    started_at,
    og,
    target_fg,
    notes
)
VALUES (
    'Batch #1 — Summer Saison',
    'Saison',
    'fermenter-1',
    now(),
    1.052,
    1.004,
    'Pitched Belle Saison at 22 C'
);
```

Use the actual time fermentation monitoring begins. The **Current batch** card
updates on the next dashboard refresh.

When OG is not yet available, omit it during insertion and add it later:

```sql
UPDATE batches
SET og = 1.052
WHERE ended_at IS NULL;
```

## 3. Start the fermentation controller

Run the control model as `root`, because it uses the Matter controller storage:

```bash
cd /root/buranbrew/host
nix run .
```

Start Cellarman beforehand so the first control cycle is recorded. The
model publishes one set of readings and one control decision per minute.
Telemetry failure does not stop the control loop, but data produced while Redis is
unavailable may not be recorded.

Do not run `cellarman-simulate` during a real fermentation. The simulator and the
model write to the same telemetry streams and would mix synthetic and real data.

## 4. Monitor the fermentation

Use the **Cellarman** dashboard for routine checks:

- **Internal**: beer or Tilt temperature.
- **Ambient**: chamber or room temperature.
- **Gravity**: Tilt specific gravity.
- **Control**: current `HEAT`, `IDLE`, or `COOL` decision.
- **Current batch**: active batch metadata and age.
- **Alerts**: includes sensor freshness, control freshness, temperature safety, gravity
  jumps, and controller effectiveness.

Real sensor data normally arrives once per minute. A single missing gravity point
can occur when the Tilt beacon is not received; short gaps do not require batch
changes or re-commissioning.

### Alert meanings

| Dashboard status | Meaning | Operator action |
|---|---|---|
| `Sensors: stale` | One or more sensor series has no new database row for over 3 minutes. | Check whether the model is running and whether Matter reads are still succeeding. |
| `Control: stale` | No new controller decision for over 3 minutes. | Check the model process before changing the fermentation setup. |
| `Temperature safety: warning` | A fresh internal reading is below 5 °C or above 30 °C. | Check the beer and fermentor immediately, then verify the sensor reading. |
| `SG jump: warning` | Two recent gravity readings differ by more than 0.005. | Treat the latest reading as suspect until later samples confirm it. |
| `Effectiveness: warning` | Heating or cooling has remained active for more than 2 hours without reaching `IDLE`. | Check the plug, heater or cooler, chamber, and temperature trend. |

Grafana evaluates rules once per minute. The **staleness** and **temperature safety** alerts must
remain abnormal for additional 2 minutes before they enter the firing state.

## 5. Update batch information

List recent batches:

```sql
SELECT
    batch_id,
    name,
    style,
    vessel,
    started_at,
    ended_at,
    og,
    target_fg
FROM batches
ORDER BY started_at DESC;
```

Correct metadata by targeting the batch ID:

```sql
UPDATE batches
SET style = 'Hazy IPA'
WHERE batch_id = 1;
```

Append an operational note without losing existing notes:

```sql
UPDATE batches
SET notes = concat_ws(
    ' | ',
    nullif(notes, ''),
    'Day 3: dry hop added'
)
WHERE ended_at IS NULL;
```

Use notes for events that help interpret the graphs, such as pitching, dry
hopping, temperature changes, cold crashing, transfers, or sensor relocation.

## 6. End the batch

End the active batch when fermentation monitoring for that vessel is complete:

```sql
UPDATE batches
SET ended_at = now(),
    notes = concat_ws(
        ' | ',
        nullif(notes, ''),
        'Final SG 1.006; transferred to keg'
    )
WHERE ended_at IS NULL;
```

Confirm that no batch remains active:

```sql
SELECT batch_id, name, started_at, ended_at
FROM batches
ORDER BY started_at DESC
LIMIT 5;
```

After a batch is ended, its historical telemetry remains associated with it by
the stored time range. The dashboard continues to show the most recent batch
until another active batch is created.

## 7. Stop the processes

Stop the model with `Ctrl-C` in its terminal.

In the Process Compose interface, use `F10` or `Ctrl-C` to stop the Cellarman
stack cleanly. The PostgreSQL history under `/home/buran/telemetry/pg` is retained
for the next run.

## 8. Reset Cellarman data

All writable Cellarman state is stored below `TELEMETRY_DATA`, normally
`/home/buran/telemetry`. Stop the control model and Cellarman before removing
runtime directories.

> These operations are destructive. Do **not** remove
> `~/buranbrew/chip-storage`, as it contains the Matter fabric credentials and is
> unrelated to telemetry.

### Remove an incorrect batch definition

Deleting a batch does not delete sensor or control history, because batch
membership is calculated from timestamps at query time:

```sql
DELETE FROM batches
WHERE batch_id = 1;
```

To clear only archived telemetry while keeping the database, schema, Grafana,
and batch definitions:

```sql
TRUNCATE sensor_data, control_events;
```

To clear telemetry and all batch definitions:

```sql
TRUNCATE sensor_data, control_events, batches RESTART IDENTITY;
```

The schema recreates the `Batch #0` placeholder the next time `pg-schema.sh`
runs while `batches` is empty.

### Reset the Redis buffer

This discards queued or pending events that have not yet reached TimescaleDB:

```bash
sudo rm -rf /home/buran/telemetry/redis
```

Redis recreates the directory, streams, and `archiver` consumer group on the
next Cellarman start. Only do this after the consumer has caught up, unless the
queued data may be discarded.

### Reset TimescaleDB

This removes the complete PostgreSQL cluster, including all telemetry, batches,
and database configuration:

```bash
sudo rm -rf /home/buran/telemetry/pg
```

On the next Cellarman start, `pg-init.sh` creates a new cluster and
`pg-schema.sh` recreates the database and tables.

### Reset Grafana

This removes Grafana's local database, users, preferences, plugins, and generated
provisioning:

```bash
sudo rm -rf /home/buran/telemetry/grafana
```

The packaged datasource, dashboard, and alert provisioning are regenerated on
the next start.

### Reset the complete telemetry stack

To return Cellarman to a first-run state:

```bash
sudo rm -rf \
  /home/buran/telemetry/redis \
  /home/buran/telemetry/pg \
  /home/buran/telemetry/grafana
```

Then start Cellarman normally. The directories and service state are recreated
under the `buran` user.

## 9. Optional pre-brew validation

Use synthetic data only when the real model is stopped:

```bash
cd /root/buranbrew/host
nix run .#cellarman-simulate -- live 2
```

Run the fast, rollback-only alert checks with:

```bash
nix run .#cellarman-simulate -- alert-test all
```

These SQL tests do not permanently change historical telemetry. Stop the live
simulator before starting the real controller.
