import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { SwitchBufferTool } from "../../dist/tools/switch-buffer.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("SwitchBufferTool", () => {
  it("switches to the named buffer", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-switch-buffer": '"Switched to buffer: *scratch*"'
    })
    const tool = new SwitchBufferTool(emacs)
    tool.register(server)
    const response = server.callTool("switch_buffer", { name: "*scratch*" })
    assert.equal(response.content[0].text, "Switched to buffer: *scratch*")
    assert.deepEqual(emacs.calls[0], {
      name: "mcp-emacs-switch-buffer",
      args: ["*scratch*"]
    })
  })
})
