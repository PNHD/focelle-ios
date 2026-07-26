INSERT INTO app_config (key, value) VALUES ('referral_enabled', 'off');

CREATE TABLE referral_codes (
  code TEXT PRIMARY KEY,
  account_id INTEGER NOT NULL UNIQUE REFERENCES accounts(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE referral_claims (
  referred_account_id INTEGER PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  referrer_account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  code TEXT NOT NULL REFERENCES referral_codes(code),
  claimed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  qualified_transaction_id TEXT UNIQUE,
  benefit_ends_at_ms INTEGER,
  reversed_at TEXT
);

CREATE INDEX referral_claims_referrer ON referral_claims (referrer_account_id);
