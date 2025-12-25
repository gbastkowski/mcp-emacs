import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { GetBufferFilenameTool } from "../../dist/tools/get-buffer-filename.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("GetBufferFilenameTool", () => {
  it("reports when buffer has no filename", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-buffer-filename": "nil"
    })
    const tool = new GetBufferFilenameTool(emacs)
    tool.register(server)
    const response = server.callTool("get_buffer_filename")
    assert.equal(response.content[0].text, "Current buffer is not visiting a file")
  })

  it("returns filename when present", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-buffer-filename": '"/tmp/sample.txt"'
    })
    const tool = new GetBufferFilenameTool(emacs)
    tool.register(server)
    const response = server.callTool("get_buffer_filename")
    assert.equal(response.content[0].text, "/tmp/sample.txt")
  })
})
