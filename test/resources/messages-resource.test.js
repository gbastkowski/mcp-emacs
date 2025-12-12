import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"
import { MessagesResource } from "../../dist/resources/messages-resource.js"

describe("MessagesResource", () => {
  it("returns Messages buffer text", async () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-buffer-text": (args) => `"Messages:${args[0]}"`
    })
    new MessagesResource(server, emacs)
    const result = await server.readResource("messages-buffer")
    assert.equal(result.contents[0].text, "Messages:*Messages*")
  })
})
