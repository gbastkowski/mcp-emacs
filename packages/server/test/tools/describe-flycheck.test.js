import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { DescribeFlycheckInfoTool } from "../../dist/tools/describe-flycheck.js"
import { createFakeServer, createStubEmacs } from "../support/tool-fixtures.js"

describe("DescribeFlycheckInfoTool", () => {
  it("returns flycheck info", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-flycheck-info": '"Flycheck info"'
    })
    new DescribeFlycheckInfoTool(server, emacs)
    const response = server.callTool("describe_flycheck_info_at_point")
    assert.equal(response.content[0].text, "Flycheck info")
    assert.equal(emacs.calls[0].name, "mcp-emacs-get-flycheck-info")
  })
})
