import { readFileSync } from "node:fs";
import yaml from "js-yaml";

// EffectFn1 path -> Json (the parsed value IS an argonaut Json at runtime).
export const readYamlImpl = (path) => yaml.load(readFileSync(path, "utf8"));
export const readJsonImpl = (path) => JSON.parse(readFileSync(path, "utf8"));

// Effect (Array String): the args after the binary name.
export const argv = () => process.argv.slice(2);
