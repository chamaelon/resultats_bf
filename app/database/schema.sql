-- Active: 1790616213824@@127.0.0.1@5432@postgres
-- Schema pour la table "resultat"
-- SGBD: PostgreSQL 18

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Postgres n'autorise pas enum(...) inline dans une définition de colonne :
-- il faut créer un type ENUM à part. Le bloc DO évite une erreur si le
-- script est rejoué et que le type existe déjà.
DO $$ BEGIN
    CREATE TYPE decision_concours AS ENUM ('ADMIS', 'AJOURNE', 'LISTE D''ATTENTE');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS resultat (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    intitule_concours VARCHAR(200) NOT NULL,
    matricule_candidat VARCHAR(50) NOT NULL,
    score DECIMAL(10, 3) NOT NULL,
    decision decision_concours NOT NULL
);

-- Index utile car matricule_candidat est le seul critère de recherche de l'API
CREATE INDEX IF NOT EXISTS idx_resultat_matricule ON resultat (matricule_candidat);