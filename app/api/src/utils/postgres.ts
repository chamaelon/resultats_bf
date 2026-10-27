interface CheckEnvResult {
  isValid: boolean;
  missingVars: string[];
}

export function checkEnv(): CheckEnvResult { 
  const missingVars: string[] = [];
  if (!process.env.PG_USER) {
    missingVars.push("PG_USER");
  }
  if (!process.env.PG_PASSWORD) {
    missingVars.push("PG_PASSWORD");
  }
  if (!process.env.PG_PORT) {
    missingVars.push("PG_PORT");
  }
  if (!process.env.PG_DB) {
    missingVars.push("PG_DB");
  }

  return { isValid: missingVars.length === 0, missingVars };
}