import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { GetErrorContextTool } from "../../dist/tools/get-error-context.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("GetErrorContextTool", () => {
  it("returns error context", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-error-context": '"Warnings buffer"'
    })
    const tool = new GetErrorContextTool(emacs)
    tool.register(server)
    const response = server.callTool("get_error_context")
    assert.equal(response.content[0].text, "Warnings buffer")
    assert.equal(emacs.calls[0].name, "mcp-emacs-get-error-context")
  })
})
