// Checks every bench data file `lune run benchdata check` wrote to .cache/bench-data against the
// published JSON Schema, so a reader of the files can rely on it

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import process from "node:process";

import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const DATA_DIR = ".cache/bench-data";
const SCHEMA_PATH = "benchmarks/schema.json";

function listJson(dir) {
	return readdirSync(dir).flatMap((name) => {
		const path = join(dir, name);
		if (statSync(path).isDirectory()) {
			return listJson(path);
		}
		return name.endsWith(".json") ? [path] : [];
	});
}

// strictRequired would refuse the "one of these fields" rule in notMeasured
const ajv = new Ajv2020({ allErrors: true, strict: true, strictRequired: false });
addFormats(ajv);
const validate = ajv.compile(JSON.parse(readFileSync(SCHEMA_PATH, "utf8")));

let failed = 0;
const files = listJson(DATA_DIR).filter((path) => !path.includes("schema"));
for (const path of files) {
	if (!validate(JSON.parse(readFileSync(path, "utf8")))) {
		failed += 1;
		process.stdout.write(`${relative(DATA_DIR, path)}:\n`);
		for (const error of validate.errors.slice(0, 10)) {
			process.stdout.write(`  ${error.instancePath || "/"} ${error.message}\n`);
		}
	}
}
process.stdout.write(
	`${files.length - failed} of ${files.length} bench data files match the schema\n`,
);
if (failed > 0 || files.length === 0) {
	process.exitCode = 1;
}
