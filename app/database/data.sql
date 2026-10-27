WITH candidats AS (
    SELECT
        n,
        ((n * 37) % 2001)::numeric / 100 AS moyenne
    FROM generate_series(1, 50000) AS serie(n)
)
INSERT INTO resultats (matricule, nom, serie, moyenne, admis)
SELECT
    CASE WHEN n = 1 THEN '146066W' ELSE 'GEN-' || lpad((n - 1)::text, 5, '0') END,
    'Candidat ' || n,
    chr(65 + ((n - 1) % 5)),
    moyenne,
    moyenne >= 10
FROM candidats
ON CONFLICT (matricule) DO NOTHING;
