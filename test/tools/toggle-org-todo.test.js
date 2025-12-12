import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { ToggleOrgTodoTool } from "../../dist/tools/toggle-org-todo.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("ToggleOrgTodoTool", () => {
  it("sets an explicit TODO state", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-toggle-org-todo": '"Set TODO state to DONE"'
    })

    new ToggleOrgTodoTool(server, emacs)
    const response = server.callTool("toggle_org_todo", { state: "DONE" })

    assert.equal(response.content[0].text, "Set TODO state to DONE")
    assert.deepEqual(emacs.calls[0], {
      name: "mcp-emacs-toggle-org-todo",
      args: ["DONE"],
    })
  })

  it("toggles when no state is provided", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-toggle-org-todo": '"Advanced TODO state"'
    })

    new ToggleOrgTodoTool(server, emacs)
    const response = server.callTool("toggle_org_todo", {})

    assert.equal(response.content[0].text, "Advanced TODO state")
    assert.deepEqual(emacs.calls[0], {
      name: "mcp-emacs-toggle-org-todo",
      args: [null],
    })
  })
})
