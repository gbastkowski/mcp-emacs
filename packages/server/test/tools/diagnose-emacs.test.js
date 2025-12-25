import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { DiagnoseEmacsTool } from "../../dist/tools/diagnose-emacs.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("DiagnoseEmacsTool", () => {
  it("returns diagnostic report", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-diagnose": '"Diagnostics"'
    })
    const tool = new DiagnoseEmacsTool(emacs)
    tool.register(server)
    const response = server.callTool("diagnose_emacs")
    assert.equal(response.content[0].text, "Diagnostics")
    assert.equal(emacs.calls[0].name, "mcp-emacs-diagnose")
  })
})
