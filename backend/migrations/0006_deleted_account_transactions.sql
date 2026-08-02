CREATE TABLE retained_credit_transactions (
  transaction_id TEXT PRIMARY KEY,
  revoked_at TEXT,
  retained_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
