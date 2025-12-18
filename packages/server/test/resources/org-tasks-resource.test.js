import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"
import { OrgTasksResource } from "../../dist/resources/org-tasks-resource.js"

describe("OrgTasksResource", () => {
  it("returns org tasks text", async () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-org-tasks": '"Task list"'
    })
    new OrgTasksResource(server, emacs)
    const result = await server.readResource("org-tasks")
    assert.equal(result.contents[0].text, "Task list")
  })
})
