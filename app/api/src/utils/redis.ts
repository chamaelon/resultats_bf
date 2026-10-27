import Redis from "ioredis";

interface CheckEnvResult {
	isValid: boolean;
	missingVars: string[];
}

function checkEnv(): CheckEnvResult {
	const missingVars: string[] = [];
	if (!process.env.REDIS_PORT) {
		missingVars.push("REDIS_PORT");
	}
	if (!process.env.CACHE_TTL) {
		missingVars.push("CACHE_TTL");
	}
	if (!process.env.CACHE_PREFIX) {
		missingVars.push("CACHE_PREFIX");
	}
	if (!process.env.REDIS_PASSWORD) {
		missingVars.push("REDIS_PASSWORD");
	}

	return { isValid: missingVars.length === 0, missingVars };
}

interface BuildRedisResult {
	redis: Redis;
	isReady: () => boolean;
}

export function buildRedis(): BuildRedisResult {
	const redis = new Redis({
		host: process.env.REDIS_HOST,
		port: Number(process.env.REDIS_PORT),
		password: process.env.REDIS_PASSWORD,
		connectTimeout: 500,
		maxRetriesPerRequest: 1,
		enableOfflineQueue: false, // Redis en panne : on ne fait pas la queue, on lit la base
		retryStrategy: (n) => Math.min(n * 200, 2000),
	});

	redis.on("error", () => {}); // pas d'exception non gérée
	const isReady = () => redis.status === "ready";
	return { redis, isReady };
}
