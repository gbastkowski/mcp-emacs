import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { GetEnvVarsTool } from "../../dist/tools/get-env-vars.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("GetEnvVarsTool", () => {
  it("returns environment variables", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-env-vars": '"FOO=bar"'
    })
    const tool = new GetEnvVarsTool(emacs)
    tool.register(server)
    const response = server.callTool("get_env_vars")
    assert.equal(response.content[0].text, "FOO=bar")
    assert.equal(emacs.calls[0].name, "mcp-emacs-get-env-vars")
  })
})
