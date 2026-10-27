<<<<<<< Updated upstream
=======
import Fastify, { type FastifyInstance } from "fastify";
import os from "os";
import postgresPlugin from "@fastify/postgres";
import { buildRedis } from "./utils/redis";

interface AppConfig {
	databaseUrl?: string;
}

interface ResultatQuery {
	matricule?: string;
}

export function buildFastify(config?: AppConfig): FastifyInstance {
	const fastify = Fastify({ logger: true });
	const redis = buildRedis();

	fastify.register(postgresPlugin, {
		connectionString: config?.databaseUrl || `postgresql://${process.env.PG_USER}:${process.env.PG_PASSWORD}@${process.env.PG_HOST}:${process.env.PG_PORT}/${process.env.PG_DB}`,
		connectionTimeoutMillis: 1500, // Timeout de connexion en millisecondes
	});

	// fastify.pg.connect()

	fastify.get<{ Querystring: ResultatQuery }>("/resultat", async (request, reply) => {
		const { matricule } = request.query;

		if (!matricule) {
			return reply.status(400).send({ message: "Le paramètre 'matricule' est requis" });
		}

		const cle = `${process.env.CACHE_PREFIX}:${matricule}`;
		const utile = redis.isReady() && matricule.length <= 64;

		if (utile) {
			try {
				const hit = await redis.redis!.get(cle);
				if (hit) return reply.header("X-Cache", "HIT").type("application/json").send(hit);
			} catch {
				/* cache indisponible : repli sur la base */
			}
		}

		try {
			// Renvoie les champs définis par le schéma métier resultats.
			const result = await fastify.pg.query("SELECT * FROM resultats WHERE matricule = $1", [matricule]);

			if (result.rowCount === 0) {
				return reply.status(404).send({ message: "Aucun résultat trouvé pour le matricule fourni" });
			}
			const corps = JSON.stringify(result.rows);
			if (utile) redis.redis!.set(cle, corps, "EX", Number(process.env.CACHE_TTL)).catch(() => {});
			return reply.header("X-Cache", "MISS").type("application/json").send(corps);
			// return reply.status(200).send(result.rows);
		} catch (err) {
			fastify.log.error(err);
			return reply.status(500).send({ message: "Erreur interne du serveur" });
		}
	});

	fastify.get("/sante", async (request, reply) => {
		try {
			await fastify.pg.query("SELECT 1");
			return reply.status(200).send();
		} catch (err) {
			fastify.log.error(err);
			return reply.status(503).send();
		}
	});

	fastify.get("/info", async () => {
		return os.hostname();
	});

	return fastify;
}

export default buildFastify;
>>>>>>> Stashed changes
