-- ════════════════════════════════════════════════════════════════════════════
-- init-db.sql — Esquema y datos semilla del laboratorio
--
-- PostgreSQL ejecuta automáticamente este script la primera vez que se crea el
-- volumen de datos (docker-entrypoint-initdb.d).
--
-- Las dos tablas sostienen el flujo trazado:
--   orders    → la consulta service-a
--   inventory → la consulta service-b
--
-- NOTA SOBRE LA COPIA EN services/common/
--
-- Este archivo existe dos veces a proposito:
--
--   scripts/init-db.sql         lo monta docker-compose en el contenedor de
--                               PostgreSQL (docker-entrypoint-initdb.d)
--   services/common/init-db.sql viaja DENTRO de la imagen de los servicios y
--                               lo ejecuta AlmacenPostgres al arrancar
--
-- La segunda copia es la que hace que el despliegue funcione contra bases
-- gestionadas (RDS, Cloud SQL), que no tienen el mecanismo de inicializacion
-- del contenedor oficial. Si se cambia una, hay que copiarla a la otra:
--   cp scripts/init-db.sql services/common/init-db.sql
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS orders (
    id          VARCHAR(16) PRIMARY KEY,
    product     VARCHAR(64)    NOT NULL,
    quantity    INTEGER        NOT NULL CHECK (quantity > 0),
    status      VARCHAR(32)    NOT NULL DEFAULT 'pending',
    unit_price  NUMERIC(10, 2) NOT NULL,
    created_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS inventory (
    product     VARCHAR(64) PRIMARY KEY,
    available   INTEGER     NOT NULL DEFAULT 0 CHECK (available >= 0),
    reserved    INTEGER     NOT NULL DEFAULT 0,
    warehouse   VARCHAR(32) NOT NULL DEFAULT 'WH-CENTRAL',
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índice sobre product: service-a filtra pedidos por producto en los reportes.
CREATE INDEX IF NOT EXISTS idx_orders_product ON orders (product);

-- ── Datos semilla ───────────────────────────────────────────────────────────
-- Los productos cubren a propósito los tres niveles de stock que evalúa
-- service-b (healthy / low / out_of_stock) para que el dashboard muestre
-- variedad de resultados de negocio sin tener que mutar datos.
INSERT INTO inventory (product, available, reserved, warehouse) VALUES
    ('laptop-pro',    250,  12, 'WH-CENTRAL'),
    ('mouse-wireless', 980,  40, 'WH-CENTRAL'),
    ('keyboard-mech',  120,   8, 'WH-NORTE'),
    ('monitor-27',      45,   5, 'WH-NORTE'),
    ('webcam-hd',        7,   2, 'WH-SUR'),      -- stock bajo
    ('dock-usbc',        3,   1, 'WH-SUR'),      -- stock bajo
    ('headset-anc',      0,   0, 'WH-CENTRAL'),  -- sin stock
    ('ssd-1tb',        400,  25, 'WH-CENTRAL')
ON CONFLICT (product) DO NOTHING;

-- 40 pedidos distribuidos entre los productos anteriores.
INSERT INTO orders (id, product, quantity, status, unit_price)
SELECT
    'ORD-' || LPAD(gs::TEXT, 4, '0'),
    (ARRAY['laptop-pro','mouse-wireless','keyboard-mech','monitor-27',
           'webcam-hd','dock-usbc','headset-anc','ssd-1tb'])[1 + (gs % 8)],
    1 + (gs % 5),
    (ARRAY['pending','confirmed','shipped','delivered'])[1 + (gs % 4)],
    ROUND((50 + (gs * 37) % 1500)::NUMERIC, 2)
FROM generate_series(1, 40) AS gs
ON CONFLICT (id) DO NOTHING;

-- ── Verificación ────────────────────────────────────────────────────────────
DO $$
DECLARE
    n_orders    INTEGER;
    n_inventory INTEGER;
BEGIN
    SELECT COUNT(*) INTO n_orders    FROM orders;
    SELECT COUNT(*) INTO n_inventory FROM inventory;
    RAISE NOTICE 'Semilla cargada: % pedidos, % productos', n_orders, n_inventory;
END $$;
