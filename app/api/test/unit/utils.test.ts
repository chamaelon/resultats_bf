import { beforeEach, describe, expect, test } from "bun:test";
import { MockDatabase } from "../../src/utils/mock";

describe("Test unitaire pour MockDatabase", () => {
	const mockDb = new MockDatabase();

	beforeEach(() => {
		mockDb.resetData();
		mockDb.makeAvailable();
	});

	test("Devrait retourner un tableau vide si aucune donnée n'est présente", async () => {
		const result = await mockDb.query(
			"SELECT * FROM resultats WHERE matricule = $1",
			["12345"]
		);
		expect(result).toEqual({ rows: [], rowCount: 0 });
	});

	test("Devrait retourner la ligne correspondant au matricule fourni", async () => {
		mockDb.addData("resultats", [{ matricule: "12345", moyenne: 17 }]);
		const result = await mockDb.query(
			"SELECT * FROM resultats WHERE matricule = $1",
			["12345"]
		);
		expect(result.rowCount).toBe(1);
		expect(result.rows[0].moyenne).toBe(17);
	});

	test("Devrait rejeter la requête si la base est indisponible", async () => {
		mockDb.makeUnavailable();
		await expect(mockDb.query("SELECT 1")).rejects.toThrow("Database is unavailable");
	});
});