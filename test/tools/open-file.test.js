import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { OpenFileTool } from "../../dist/tools/open-file.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("OpenFileTool", () => {
  it("opens files via emacsclient", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-open-file": '"Opened"'
    })
    const tool = new OpenFileTool(emacs)
    tool.register(server)
    const path = "/tmp/weird path"
    const response = server.callTool("open_file", { path })
    assert.equal(response.content[0].text, `Opened file: ${path}`)
    assert.deepEqual(emacs.calls[0], { name: "mcp-emacs-open-file", args: [path] })
  })
})
