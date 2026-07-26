INSERT INTO app_config (key, value) VALUES ('accounts_enabled', 'off');

CREATE TABLE accounts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  apple_subject_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE account_sessions (
  token_hash TEXT PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  expires_at_ms INTEGER NOT NULL
);

CREATE INDEX account_sessions_account ON account_sessions (account_id);

CREATE TABLE account_devices (
  device_hash TEXT PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE account_credit_operations (
  idempotency_key TEXT PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  amount INTEGER NOT NULL,
  reason TEXT NOT NULL CHECK (reason IN ('purchase', 'spend', 'referral', 'revocation')),
  status TEXT NOT NULL CHECK (status IN ('reserved', 'consumed', 'refunded')),
  transaction_id TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX account_credit_purchase
  ON account_credit_operations (transaction_id)
  WHERE transaction_id IS NOT NULL AND reason = 'purchase';

ALTER TABLE credit_operations ADD COLUMN source TEXT NOT NULL DEFAULT 'daily'
  CHECK (source IN ('daily', 'purchased'));
