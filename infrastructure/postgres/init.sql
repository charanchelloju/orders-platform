-- Initializes per-service schemas in one Postgres instance.
-- Each service uses its own schema for isolation while sharing a DB.

CREATE SCHEMA IF NOT EXISTS orders;
CREATE SCHEMA IF NOT EXISTS payments;
CREATE SCHEMA IF NOT EXISTS inventory;

-- Service-specific users with schema-scoped privileges.
-- For demo only — real prod would use Vault/Secrets Manager.
CREATE USER order_service     WITH PASSWORD 'order_pw';
CREATE USER payment_service   WITH PASSWORD 'payment_pw';
CREATE USER inventory_service WITH PASSWORD 'inventory_pw';

GRANT ALL PRIVILEGES ON SCHEMA orders     TO order_service;
GRANT ALL PRIVILEGES ON SCHEMA payments   TO payment_service;
GRANT ALL PRIVILEGES ON SCHEMA inventory  TO inventory_service;

ALTER ROLE order_service     SET search_path TO orders;
ALTER ROLE payment_service   SET search_path TO payments;
ALTER ROLE inventory_service SET search_path TO inventory;
