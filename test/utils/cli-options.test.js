import { describe, it }         from "node:test"
import assert                   from "node:assert/strict"
import { parseCliOptions }      from "../../dist/utils/cli-options.js"

describe("parseCliOptions", () => {
  it("returns empty options when no args provided", () => {
    assert.deepEqual(parseCliOptions([]), {})
  })

  it("parses --emacsclient-executable VALUE form", () => {
    const result = parseCliOptions(["--emacsclient-executable", "/tmp/emacsclient"])
    assert.equal(result.emacsclientExecutable, "/tmp/emacsclient")
  })

  it("parses --emacsclient-executable=VALUE form", () => {
    const result = parseCliOptions(["--emacsclient-executable=/opt/bin/emacsclient"])
    assert.equal(result.emacsclientExecutable, "/opt/bin/emacsclient")
  })

  it("throws when flag is missing value", () => {
    assert.throws(() => parseCliOptions(["--emacsclient-executable"]), /requires a value/)
  })
})
