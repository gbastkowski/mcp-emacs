import { describe, it, beforeEach, afterEach } from "node:test"
import assert from "node:assert/strict"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { spawnSync } from "node:child_process"
import { EmacsClient } from "../dist/emacs-client.js"
import { GetSelectionTool } from "../dist/tools/get-selection.js"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const originalPath = process.env.PATH ?? ""
const binDir = path.join(__dirname, "bin")
const COMPLEX_BUFFER = `Hello from "buffer"\\path
Next line with tab	and bell`
const hasRealEmacs = spawnSync("emacsclient", ["--eval", "t"], { stdio: "ignore" }).status === 0
const describeReal = hasRealEmacs ? describe : describe.skip

describe(
  "EmacsClient integration",
  { concurrency: false },
  () => {
    let logDir
    let logFile

    const readLog = () => {
      const raw = readFileSync(logFile, "utf8")
      return raw
        .split("\n")
        .map((line) => line.trim())
        .filter(Boolean)
    }

    beforeEach(() => {
      logDir = mkdtempSync(path.join(tmpdir(), "mcp-emacs-test-"))
      logFile = path.join(logDir, "emacsclient.log")
      writeFileSync(logFile, "", "utf8")
      process.env.PATH = `${binDir}${path.delimiter}${originalPath}`
      process.env.MCP_TEST_LOG = logFile
    })

    afterEach(() => {
      process.env.PATH = originalPath
      delete process.env.MCP_TEST_LOG
      if (logDir) {
        rmSync(logDir, { recursive: true, force: true })
      }
    })

    it("loads helper only once per client instance", () => {
      const client = new EmacsClient(1000)

      assert.equal(
        client.parseElispString(client.callElispFunction("mcp-emacs-get-buffer-content")),
        COMPLEX_BUFFER
      )

      assert.equal(
        client.parseElispString(client.callElispFunction("mcp-emacs-get-buffer-content")),
        COMPLEX_BUFFER
      )

      const entries = readLog()

      assert.equal(entries.filter((line) => line.includes("load-file")).length, 1)

      const contentCalls = entries.filter((line) => line.startsWith("(mcp-emacs-get-buffer-content"))
      assert.equal(contentCalls.length, 2)
    })

    it("returns user-friendly text when selection is inactive", () => {
      const client = new EmacsClient(1000)
      const fakeServer = { registerTool() {} }

      assert.equal(
        new GetSelectionTool(fakeServer, client).handle(undefined, undefined, undefined).content[0].text,
        "No active selection"
      )
    })

    it("escapes complex file paths when opening files", () => {
      const client = new EmacsClient(1000)
      const weirdPath = '/tmp/weird "quote" path\\segment' + "\nnext"
      client.callElispFunction("mcp-emacs-open-file", [weirdPath])
      const entries = readLog()
      const last = entries[entries.length - 1]
      assert.ok(last.startsWith("(mcp-emacs-open-file"))
      assert.ok(
        last.includes("\\\"quote\\\""),
        "expected embedded quotes to be escaped"
      )
      assert.ok(last.includes("\\\\segment"), "expected backslash escaped")
      assert.ok(last.includes("\\nnext"), "expected newline escaped")
    })

    it("returns diagnostics from Emacs", () => {
      assert.equal(
        new EmacsClient(1000).callElispStringFunction("mcp-emacs-diagnose"),
        "Diagnostics stub"
      )
      assert.ok(readLog().some((line) => line.startsWith("(mcp-emacs-diagnose")))
    })
  }
)

describeReal(
  "EmacsClient real Emacs roundtrip",
  () => {
    it("formats strings correctly for Emacs", () => {
      const client = new EmacsClient(3000)
      const weird = 'real test "quotes" here \\ newline' + "\nmore"
      const rawResult = client.callElispFunction("format", ["%s", weird])
      const stripped = client.parseElispString(rawResult)
      assert.equal(stripped, weird)
    })
  }
)
