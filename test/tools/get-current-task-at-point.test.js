import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { GetCurrentTaskAtPointTool } from "../../dist/tools/get-current-task-at-point.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("GetCurrentTaskAtPointTool", () => {
  it("reports when there is no current task at point", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-current-task-at-point": "nil"
    })
    const tool = new GetCurrentTaskAtPointTool(emacs)
    tool.register(server)
    const response = server.callTool("get_current_task_at_point")
    assert.equal(response.content[0].text, "No current task at point")
    assert.deepEqual(emacs.calls, [ { name: "mcp-emacs-get-current-task-at-point", args: [] } ])
  })

  it("returns the current task at point", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-current-task-at-point": '"Fix display-line-numbers-width"'
    })
    const tool = new GetCurrentTaskAtPointTool(emacs)
    tool.register(server)
    const response = server.callTool("get_current_task_at_point")
    assert.equal(response.content[0].text, "Fix display-line-numbers-width")
    assert.deepEqual(emacs.calls, [ { name: "mcp-emacs-get-current-task-at-point", args: [] } ])
  })
})
