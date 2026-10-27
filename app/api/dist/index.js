// Bundle généré par : bun build ./index.ts --outdir ./dist --target node --minify
// Source : app/api/index.ts + src/app.ts + src/utils/redis.ts + src/utils/postgres.ts
"use strict";

import Fastify from "fastify";
import os from "os";
import postgresPlugin from "@fastify/postgres";
import Redis from "ioredis";

// ── utils/redis.ts ────────────────────────────────────────────────────────────
function buildRedis() {
  const redis = new Redis({
    host: process.env.REDIS_HOST,
    port: Number(process.env.REDIS_PORT),
    password: process.env.REDIS_PASSWORD,
    connectTimeout: 500,
    maxRetriesPerRequest: 1,
    enableOfflineQueue: false,
    retryStrategy: (n) => Math.min(n * 200, 2000),
  });
  redis.on("error", () => {});
  const isReady = () => redis.status === "ready";
  return { redis, isReady };
}

// ── src/app.ts ────────────────────────────────────────────────────────────────
function buildFastify(config) {
  const fastify = Fastify({ logger: true });
  const redisClient = buildRedis();

  fastify.register(postgresPlugin, {
    connectionString:
      config?.databaseUrl ||
      `postgresql://${process.env.PG_USER}:${process.env.PG_PASSWORD}@${process.env.PG_HOST}:${process.env.PG_PORT}/${process.env.PG_DB}`,
    connectionTimeoutMillis: 1500,
  });

  // GET /resultat?matricule=XXXX
  fastify.get("/resultat", async (request, reply) => {
    const { matricule } = request.query;
    if (!matricule) {
      return reply.status(400).send({ message: "Le paramètre 'matricule' est requis" });
    }
    const cle = `${process.env.CACHE_PREFIX}:${matricule}`;
    const utile = redisClient.isReady() && matricule.length <= 64;
    if (utile) {
      try {
        const hit = await redisClient.redis.get(cle);
        if (hit) return reply.header("X-Cache", "HIT").type("application/json").send(hit);
      } catch { /* cache indisponible : repli sur la base */ }
    }
    try {
      const result = await fastify.pg.query(
        "SELECT * FROM resultat WHERE matricule_candidat = $1",
        [matricule]
      );
      if (result.rowCount === 0) {
        return reply.status(404).send({ message: "Aucun résultat trouvé pour le matricule fourni" });
      }
      const corps = JSON.stringify(result.rows);
      if (utile) redisClient.redis.set(cle, corps, "EX", Number(process.env.CACHE_TTL)).catch(() => {});
      return reply.header("X-Cache", "MISS").type("application/json").send(corps);
    } catch (err) {
      fastify.log.error(err);
      return reply.status(500).send({ message: "Erreur interne du serveur" });
    }
  });

  // GET /sante — sonde HAProxy
  fastify.get("/sante", async (request, reply) => {
    try {
      await fastify.pg.query("SELECT 1");
      return reply.status(200).send();
    } catch (err) {
      fastify.log.error(err);
      return reply.status(503).send();
    }
  });

  // GET /info — renvoie le nom d'hôte (pour vérifier la répartition de charge)
  fastify.get("/info", async () => {
    return os.hostname();
  });

  return fastify;
}

// ── index.ts (point d'entrée) ─────────────────────────────────────────────────
const app = buildFastify();
const port = Number(process.env.PORT) || 3000;
const host = process.env.HOST || "0.0.0.0";

app
  .listen({ port, host })
  .then(() => {
    console.log(`Server listening on http://${host}:${port}`);
  })
  .catch((err) => {
    app.log.error(err);
    process.exit(1);
  });
