INSERT INTO app_config (key, value) VALUES
  ('store_sandbox_enabled', 'off'),
  ('store_production_enabled', 'off');

CREATE TABLE store_transactions (
  transaction_id TEXT PRIMARY KEY,
  original_transaction_id TEXT NOT NULL,
  device_hash TEXT,
  product_id TEXT NOT NULL,
  environment TEXT NOT NULL,
  expires_at_ms INTEGER NOT NULL,
  revoked_at_ms INTEGER,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX store_transactions_entitlement
  ON store_transactions (device_hash, expires_at_ms, revoked_at_ms);

CREATE INDEX store_transactions_original
  ON store_transactions (original_transaction_id);

CREATE TABLE store_notifications (
  notification_uuid TEXT PRIMARY KEY,
  received_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
