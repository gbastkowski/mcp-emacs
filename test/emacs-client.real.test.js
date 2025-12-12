import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { EmacsClient } from "../dist/emacs-client.js"

const hasRealEmacs =
  spawnSync("emacsclient", ["--eval", "t"], { stdio: "ignore" }).status === 0
const describeReal = hasRealEmacs ? describe : describe.skip

describeReal("EmacsClient real Emacs roundtrip", () => {
  it("formats strings correctly for Emacs", () => {
    const client = new EmacsClient(3000)
    const weird = 'real test "quotes" here \\ newline' + "\nmore"
    const rawResult = client.callElispFunction("format", ["%s", weird])
    const stripped = client.parseElispString(rawResult)
    assert.equal(stripped, weird)
  })
})
