import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { EvalTool } from "../../dist/tools/eval.js"
import { createFakeServer } from "../support/tool-fixtures.js"

describe("EvalTool", () => {
  it("evaluates inside the current buffer", () => {
    const calls = []
    const emacs = {
      evalInEmacs(expression) {
        calls.push(expression)
        return '"ok"'
      },
      parseElispString(value) {
        if (value.startsWith('"') && value.endsWith('"')) return value.slice(1, -1)
        return value
      }
    }

    const server = createFakeServer()
    const tool = new EvalTool(emacs)
    tool.register(server)

    const response = server.callTool("eval", {
      expression: "(revert-buffer nil t)"
    })

    assert.equal(response.content[0].text, "ok")
    assert.equal(
      calls[0],
      "(with-current-buffer (mcp-emacs--current-buffer) (progn (revert-buffer nil t)))"
    )
  })
})
