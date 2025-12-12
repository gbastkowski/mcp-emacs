import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { GotoLineTool } from "../../dist/tools/goto-line.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("GotoLineTool", () => {
  it("jumps to a specific line and column", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-goto-location": '"Moved to line 10, column 5"'
    })

    new GotoLineTool(server, emacs)

    const response = server.callTool("goto_line", {
      line: 10,
      column: 5
    })

    assert.equal(response.content[0].text, "Moved to line 10, column 5")
    assert.deepEqual(emacs.calls[0], {
      name: "mcp-emacs-goto-location",
      args: [10, 5, null]
    })
  })

  it("prefers function names when provided", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-goto-location": '"Moved to function foo"'
    })

    new GotoLineTool(server, emacs)

    const response = server.callTool("goto_line", {
      functionName: "foo"
    })

    assert.equal(response.content[0].text, "Moved to function foo")
    assert.deepEqual(emacs.calls[0], {
      name: "mcp-emacs-goto-location",
      args: [null, null, "foo"]
    })
  })

  it("requires either a line or function name", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs()

    new GotoLineTool(server, emacs)

    assert.throws(() => {
      server.callTool("goto_line", {})
    }, /Provide either line or functionName/)
    assert.equal(emacs.calls.length, 0)
  })
})
