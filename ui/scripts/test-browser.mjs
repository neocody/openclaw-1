import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const cwd = fileURLToPath(new URL("..", import.meta.url));
const config = "vitest.config.ts";
// Fresh Vite/Chromium processes prevent cross-file module-mock fetch failures.
// Vitest discovers the files so the browser config remains the source of truth.
const discovery = spawnSync(
  "pnpm",
  ["exec", "vitest", "list", "--config", config, "--filesOnly", "--json"],
  { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] },
);
if (discovery.error || discovery.status !== 0) {
  console.error(discovery.error ?? "Browser test discovery failed");
  process.exit(1);
}
const files = JSON.parse(discovery.stdout);
if (!Array.isArray(files) || files.length === 0) {
  throw new Error("No browser test files found");
}
for (const { file, projectName } of files) {
  if (typeof file !== "string" || typeof projectName !== "string") {
    throw new Error("Invalid browser test discovery result");
  }
  console.log(`Browser test file: ${file}`);
  const result = spawnSync(
    "pnpm",
    ["exec", "vitest", "run", "--config", config, "--project", projectName, file],
    { cwd, stdio: "inherit" },
  );
  if (result.error || result.status !== 0) {
    console.error(result.error ?? `Browser test failed: ${file}`);
    process.exit(result.status || 1);
  }
}
console.log(`Complete browser suite: ${files.length} files passed`);
