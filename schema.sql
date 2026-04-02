-- =============================================================================
-- GPLAN — Schéma Supabase
-- Base de données centralisée fournisseurs plantes/arbres
-- =============================================================================

-- Extensions requises
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

-- =============================================================================
-- Table : suppliers (fournisseurs)
-- =============================================================================

CREATE TABLE suppliers (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  source_type TEXT NOT NULL CHECK (source_type IN ('email', 'api', 'both')),
  email_domain TEXT,                                  -- Domaine email (ex: labotte.be)
  api_key TEXT,
  contact_name TEXT,
  notes TEXT,
  last_updated_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  -- Config API polling (pour les fournisseurs accessibles via API)
  api_url TEXT,                                      -- URL de l'API fournisseur
  api_method TEXT DEFAULT 'GET',                     -- GET ou POST
  api_headers JSONB DEFAULT '{}',                    -- Headers custom (JSON)
  api_body JSONB,                                    -- Body pour les POST
  api_auth_type TEXT CHECK (api_auth_type IN ('none', 'api_key_header', 'api_key_query', 'bearer', 'basic')),
  api_auth_value TEXT,                               -- Clé/token d'authentification
  api_enabled BOOLEAN DEFAULT false,                 -- Activer le polling automatique
  api_schedule TEXT DEFAULT 'daily',                   -- Fréquence : daily, hourly, etc.
  -- Localisation
  address TEXT,                                        -- Adresse complète du fournisseur
  latitude DOUBLE PRECISION,                           -- Coordonnées GPS (calculées depuis l'adresse)
  longitude DOUBLE PRECISION
);

CREATE UNIQUE INDEX idx_suppliers_email ON suppliers(email_domain) WHERE email_domain IS NOT NULL;
CREATE UNIQUE INDEX idx_suppliers_api_key ON suppliers(api_key) WHERE api_key IS NOT NULL;

-- =============================================================================
-- Table : plants (catalogue unifié)
-- =============================================================================

CREATE TABLE plants (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  supplier_id UUID NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE,
  plant_name TEXT NOT NULL,
  plant_name_normalized TEXT NOT NULL,
  botanical_name TEXT,
  category TEXT,
  size TEXT,
  price NUMERIC(10,2),
  currency TEXT DEFAULT 'EUR',
  availability INTEGER,
  quality TEXT,
  unit TEXT DEFAULT 'pièce',
  extra_data JSONB DEFAULT '{}',
  imported_at TIMESTAMPTZ DEFAULT NOW(),
  batch_id TEXT
);

CREATE INDEX idx_plants_supplier ON plants(supplier_id);
CREATE INDEX idx_plants_name_normalized ON plants(plant_name_normalized);
CREATE INDEX idx_plants_name_trgm ON plants USING gin(plant_name_normalized gin_trgm_ops);
CREATE INDEX idx_plants_botanical ON plants(botanical_name) WHERE botanical_name IS NOT NULL;
CREATE INDEX idx_plants_batch ON plants(batch_id);

-- =============================================================================
-- Fonction : normalisation des noms de plantes
-- =============================================================================

CREATE OR REPLACE FUNCTION normalize_plant_name(name TEXT)
RETURNS TEXT AS $$
  SELECT lower(unaccent(trim(name)));
$$ LANGUAGE sql IMMUTABLE;

-- =============================================================================
-- Fonction : recherche de plantes (fuzzy + cross-fournisseurs)
-- =============================================================================

CREATE OR REPLACE FUNCTION search_plants(query TEXT)
RETURNS TABLE (
  plant_name TEXT,
  botanical_name TEXT,
  supplier_name TEXT,
  size TEXT,
  price NUMERIC,
  currency TEXT,
  availability INTEGER,
  quality TEXT,
  unit TEXT,
  extra_data JSONB,
  supplier_id UUID
) AS $$
  SELECT
    p.plant_name,
    p.botanical_name,
    s.name AS supplier_name,
    p.size,
    p.price,
    p.currency,
    p.availability,
    p.quality,
    p.unit,
    p.extra_data,
    p.supplier_id
  FROM plants p
  JOIN suppliers s ON s.id = p.supplier_id
  WHERE p.plant_name_normalized ILIKE '%' || normalize_plant_name(query) || '%'
     OR p.botanical_name ILIKE '%' || query || '%'
  ORDER BY similarity(p.plant_name_normalized, normalize_plant_name(query)) DESC;
$$ LANGUAGE sql;

-- =============================================================================
-- RLS : accès restreint au service_role uniquement
-- =============================================================================

ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE plants ENABLE ROW LEVEL SECURITY;

-- Policy pour service_role (accès complet via n8n)
CREATE POLICY "Service role full access on suppliers"
  ON suppliers FOR ALL
  USING (auth.role() = 'service_role');

CREATE POLICY "Service role full access on plants"
  ON plants FOR ALL
  USING (auth.role() = 'service_role');

-- Policy lecture pour anon (pour la recherche future côté client)
CREATE POLICY "Anon read access on suppliers"
  ON suppliers FOR SELECT
  USING (true);

CREATE POLICY "Anon read access on plants"
  ON plants FOR SELECT
  USING (true);

-- =============================================================================
-- Table : supplier_column_mappings (cache mapping colonnes Excel par fournisseur)
-- =============================================================================

CREATE TABLE supplier_column_mappings (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  supplier_id UUID NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE,
  header_hash TEXT NOT NULL,           -- Hash des headers pour détecter changement de format
  mapping JSONB NOT NULL,              -- Le mapping colonnes → champs plants
  sample_headers TEXT[],               -- Headers originaux pour debug
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(supplier_id)
);

-- RLS
ALTER TABLE supplier_column_mappings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role full access on supplier_column_mappings"
  ON supplier_column_mappings FOR ALL
  USING (auth.role() = 'service_role');
