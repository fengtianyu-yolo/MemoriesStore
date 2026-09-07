-- +migrate Up
ALTER TABLE media ADD COLUMN story TEXT NOT NULL DEFAULT '';
ALTER TABLE media ADD COLUMN title TEXT NOT NULL DEFAULT '';
ALTER TABLE media ADD COLUMN place_name TEXT NOT NULL DEFAULT '';

-- +migrate Down
-- SQLite cannot DROP COLUMN portably in older versions; leave no-op for down.
