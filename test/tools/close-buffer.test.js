import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { CloseBufferTool } from "../../dist/tools/close-buffer.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("CloseBufferTool", () => {
  it("closes the current buffer", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-close-buffer": '"Closed buffer: *scratch*"'
    })
    const tool = new CloseBufferTool(emacs)
    tool.register(server)
    const response = server.callTool("close_buffer", { save: true })
    assert.equal(response.content[0].text, "Closed buffer: *scratch*")
    assert.deepEqual(emacs.calls[0], {
      name: "mcp-emacs-close-buffer",
      args: [true]
    })
  })
})
