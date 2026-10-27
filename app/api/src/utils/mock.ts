<<<<<<< Updated upstream
=======
export interface MockQueryResult<T = any> {
	rows: T[];
	rowCount: number;
}

/**
 * Simule un client PostgreSQL pour les tests : magasin de données en mémoire
 * + réponses au format `pg` ({ rows, rowCount }) attendu par app.ts.
 */
export class MockDatabase {
	private data: Record<string, any[]> = {};
	private isAvailable = true;

	makeUnavailable() {
		this.isAvailable = false;
	}

	makeAvailable() {
		this.isAvailable = true;
	}

	addData(table: string, rows: any[]) {
		this.data[table] = rows;
	}

	getData(table: string): any[] {
		if (!this.isAvailable) {
			throw new Error("Database is unavailable");
		}
		return this.data[table] || [];
	}

	resetData() {
		this.data = {};
	}

	isDatabaseAvailable(): boolean {
		return this.isAvailable;
	}

	removeData(table: string) {
		delete this.data[table];
	}

	/**
	 * Simule `pg.Pool.query`.
	 * Déclarée en propriété fléchée (et non en méthode classique) pour que
	 * `this` reste lié à l'instance même quand la fonction est extraite
	 * (ex. `mock(mockDb.query)` puis assignée à `app.pg.query`) — avec une
	 * méthode normale, `this.data` serait `undefined` dans ce cas.
	 */
	query = (sql: string, params: any[] = []): Promise<MockQueryResult> => {
		if (!this.isAvailable) {
			return Promise.reject(new Error("Database is unavailable"));
		}

		const tableMatch = sql.match(/from\s+(\w+)/i);
		const table = tableMatch?.[1];
		if (!table) {
			// Requête sans table (ex: health check "SELECT 1")
			return Promise.resolve({ rows: [{ "?column?": 1 }], rowCount: 1 });
		}

		const rows = this.getData(table);
		const filtered = params.length
			? rows.filter((row) => (row.matricule ?? row.matricule_candidat) === params[0])
			: rows;

		return Promise.resolve({ rows: filtered, rowCount: filtered.length });
	};
}
>>>>>>> Stashed changes
