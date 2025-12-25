import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"
import { WarningsResource } from "../../dist/resources/warnings-resource.js"

describe("WarningsResource", () => {
  it("returns Warnings buffer text", async () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-buffer-text": (args) => `"Warnings:${args[0]}"`
    })
    const resource = new WarningsResource(emacs)
    resource.register(server)
    const result = await server.readResource("warnings-buffer")
    assert.equal(result.contents[0].text, "Warnings:*Warnings*")
  })
})
