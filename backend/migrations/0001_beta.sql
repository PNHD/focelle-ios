CREATE TABLE app_config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT INTO app_config (key, value) VALUES
  ('beta_started_at', CURRENT_TIMESTAMP),
  ('beta_force', 'auto'),
  ('beta_duration_days', '60'),
  ('beta_max_activations', '500');

CREATE TABLE beta_devices (
  device_hash TEXT PRIMARY KEY,
  ai_successes INTEGER NOT NULL DEFAULT 0 CHECK (ai_successes BETWEEN 0 AND 3),
  first_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  activated_at TEXT
);

CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_hash TEXT NOT NULL,
  name TEXT NOT NULL,
  occurred_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX events_occurred_at ON events (occurred_at);
