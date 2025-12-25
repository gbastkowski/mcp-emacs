#!/usr/bin/env node
import { createRequire                } from "node:module"
import { fileURLToPath, pathToFileURL } from "node:url"
import path from "node:path"
import { existsSync } from "node:fs"
import { spawnSync  } from "node:child_process"

const require   = createRequire(import.meta.url)
const rootDir   = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const distEntry = path.join(rootDir, "dist", "index.js")

if (!existsSync(distEntry)) {
  const result = spawnSync("npm", ["run", "build"], { cwd: rootDir, encoding: "utf-8" })
  if (result.stdout)        { process.stderr.write(result.stdout) }
  if (result.stderr)        { process.stderr.write(result.stderr) }
  if (result.status !== 0)  { process.exit(result.status ?? 1) }
}

await import(pathToFileURL(distEntry).href)
