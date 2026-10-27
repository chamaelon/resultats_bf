import { afterAll, beforeAll, afterEach, describe, expect, test, mock } from "bun:test";
import { buildFastify } from "../../src/app";
import { MockDatabase } from "../../src/utils/mock";
import os from "os";

describe("Test d'intégration pour l'application", () => {
	const app = buildFastify();
	const mockDb = new MockDatabase();

	beforeAll(async () => {
		await app.ready();
		// `app.pg` n'existe qu'une fois le plugin @fastify/postgres chargé,
		// donc l'override doit se faire après app.ready(), pas avant.
		app.pg.query = mock(mockDb.query) as unknown as typeof app.pg.query;
	});

	afterEach(() => {
		mockDb.resetData();
		mockDb.makeAvailable();
	});

	afterAll(async () => {
		await app.close();
	});

	test("GET /sante — base disponible", async () => {
		mockDb.makeAvailable();
		const response = await app.inject({ method: "GET", url: "/sante" });
		expect(response.statusCode).toBe(200);
	});

	test("GET /sante — base indisponible", async () => {
		mockDb.makeUnavailable();
		const response = await app.inject({ method: "GET", url: "/sante" });
		expect(response.statusCode).toBe(503);
	});

	test("GET /info", async () => {
		const response = await app.inject({ method: "GET", url: "/info" });
		expect(response.statusCode).toBe(200);
		expect(response.body).toBe(os.hostname());
	});

	test("GET /resultat sans matricule", async () => {
		const response = await app.inject({ method: "GET", url: "/resultat" });
		expect(response.statusCode).toBe(400);
	});

	test("GET /resultat avec un matricule valide", async () => {
		const matricule = "123456";
		const resultat = { matricule, nom: "Candidat Test", serie: "A", moyenne: 17.5, admis: true };
		mockDb.addData("resultats", [resultat]);
		const response = await app.inject({
			method: "GET",
			url: `/resultat?matricule=${matricule}`,
		});
		expect(response.statusCode).toBe(200);
		expect(response.json<Array<typeof resultat>>()).toEqual([resultat]);
	});

	test("GET /resultat avec un matricule inconnu", async () => {
		const response = await app.inject({
			method: "GET",
			url: "/resultat?matricule=inconnu",
		});
		expect(response.statusCode).toBe(404);
	});
});