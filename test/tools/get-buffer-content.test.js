import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { GetBufferContentTool } from "../../dist/tools/get-buffer-content.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("GetBufferContentTool", () => {
  it("returns parsed buffer content", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-buffer-content": '"Hello from buffer"'
    })
    new GetBufferContentTool(server, emacs)
    const response = server.callTool("get_buffer_content")
    assert.equal(response.content[0].text, "Hello from buffer")
  })
})
