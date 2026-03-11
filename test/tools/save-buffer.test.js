import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { SaveBufferTool } from "../../dist/tools/save-buffer.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("SaveBufferTool", () => {
  it("saves the current buffer", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-save-buffer": '"Saved buffer: *scratch*"'
    })
    const tool = new SaveBufferTool(emacs)
    tool.register(server)
    const response = server.callTool("save_buffer")
    assert.equal(response.content[0].text, "Saved buffer: *scratch*")
  })
})
