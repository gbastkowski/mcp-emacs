import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { GetCurrentClockedTaskTool } from "../../dist/tools/get-current-clocked-task.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("GetCurrentClockedTaskTool", () => {
  it("reports when no task is currently clocked in", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-current-clocked-task": "nil"
    })
    const tool = new GetCurrentClockedTaskTool(emacs)
    tool.register(server)
    const response = server.callTool("get_current_clocked_task")
    assert.equal(response.content[0].text, "No task is currently clocked in")
    assert.deepEqual(emacs.calls, [ { name: "mcp-emacs-get-current-clocked-task", args: [] } ])
  })

  it("returns the current clocked task text", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-current-clocked-task": '"Review release notes"'
    })
    const tool = new GetCurrentClockedTaskTool(emacs)
    tool.register(server)
    const response = server.callTool("get_current_clocked_task")
    assert.equal(response.content[0].text, "Review release notes")
    assert.deepEqual(emacs.calls, [ { name: "mcp-emacs-get-current-clocked-task", args: [] } ])
  })
})
