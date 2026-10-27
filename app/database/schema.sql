CREATE TABLE IF NOT EXISTS resultats (
    matricule VARCHAR(50) PRIMARY KEY,
    nom VARCHAR(100) NOT NULL,
    serie VARCHAR(50) NOT NULL,
    moyenne NUMERIC(5, 2) NOT NULL CHECK (moyenne >= 0 AND moyenne <= 20),
    admis BOOLEAN NOT NULL
);