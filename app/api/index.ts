import buildFastify from "./src/app";

const app = buildFastify();
const port = Number(process.env.PORT) || 3000;
const host = process.env.HOST || '0.0.0.0';

app
	.listen({ port,host })
	.then(() => {
		console.log(`Server listening on http://${host}:${port}`);
	})
	.catch((err) => {
		app.log.error(err);
		process.exit(1);
	});