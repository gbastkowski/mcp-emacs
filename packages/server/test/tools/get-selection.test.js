import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { GetSelectionTool } from "../../dist/tools/get-selection.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("GetSelectionTool", () => {
  it("reports when no selection is active", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-selection": "nil"
    })
    const tool = new GetSelectionTool(emacs)
    tool.register(server)
    const response = server.callTool("get_selection")
    assert.equal(response.content[0].text, "No active selection")
  })

  it("returns current selection text", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-selection": '"Highlighted text"'
    })
    const tool = new GetSelectionTool(emacs)
    tool.register(server)
    const response = server.callTool("get_selection")
    assert.equal(response.content[0].text, "Highlighted text")
  })
})
