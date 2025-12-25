import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { EditFileRegionTool } from "../../dist/tools/edit-file-region.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("EditFileRegionTool", () => {
  it("sends edits to Emacs with the expected arguments", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-edit-file-region": '"Edited /tmp/test at 1:1-1:1"'
    })

    const tool = new EditFileRegionTool(emacs)
    tool.register(server)

    const response = server.callTool("edit_file_region", {
      path: "/tmp/test",
      start: { line: 1, column: 1 },
      end: { line: 1, column: 1 },
      text: "hello",
      save: true,
    })

    assert.equal(response.content[0].text, "Edited /tmp/test at 1:1-1:1")
    assert.deepEqual(emacs.calls[0], {
      name: "mcp-emacs-edit-file-region",
      args: ["/tmp/test", 1, 1, 1, 1, "hello", true]
    })
  })

  it("throws when the end comes before the start", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-edit-file-region": '"no-op"'
    })

    const tool = new EditFileRegionTool(emacs)
    tool.register(server)

    assert.throws(() => {
      server.callTool("edit_file_region", {
        path: "/tmp/test",
        start: { line: 3, column: 5 },
        end: { line: 2, column: 1 },
        text: "broken",
      })
    }, /Start line must be before or equal to end line/)
    assert.equal(emacs.calls.length, 0)
  })
})
