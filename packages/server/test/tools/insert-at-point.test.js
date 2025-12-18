import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { InsertAtPointTool } from "../../dist/tools/insert-at-point.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("InsertAtPointTool", () => {
  it("replaces the selection when requested", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-insert-at-point": '"Replaced selection"'
    })

    new InsertAtPointTool(server, emacs)

    const response = server.callTool("insert_at_point", {
      text: "updated",
      replaceSelection: true
    })

    assert.equal(response.content[0].text, "Replaced selection")
    assert.deepEqual(emacs.calls[0], {
      name: "mcp-emacs-insert-at-point",
      args: ["updated", true]
    })
  })

  it("defaults to inserting when replaceSelection is omitted", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-insert-at-point": '"Inserted text"'
    })

    new InsertAtPointTool(server, emacs)

    const response = server.callTool("insert_at_point", {
      text: "hello"
    })

    assert.equal(response.content[0].text, "Inserted text")
    assert.deepEqual(emacs.calls[0], {
      name: "mcp-emacs-insert-at-point",
      args: ["hello", false]
    })
  })
})
