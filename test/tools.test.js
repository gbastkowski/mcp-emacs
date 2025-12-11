import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { GetBufferContentTool } from "../dist/tools/get-buffer-content.js"
import { GetBufferFilenameTool } from "../dist/tools/get-buffer-filename.js"
import { GetSelectionTool } from "../dist/tools/get-selection.js"
import { OpenFileTool } from "../dist/tools/open-file.js"
import { DescribeFlycheckInfoTool } from "../dist/tools/describe-flycheck.js"
import { GetErrorContextTool } from "../dist/tools/get-error-context.js"
import { GetEnvVarsTool } from "../dist/tools/get-env-vars.js"
import { DiagnoseEmacsTool } from "../dist/tools/diagnose-emacs.js"

function createFakeServer() {
  const tools = new Map()
  return {
    registerTool(name, _metadata, handler) {
      tools.set(name, handler)
    },
    callTool(name, args) {
      if (!tools.has(name)) {
        throw new Error(`Tool ${name} is not registered`)
      }
      return tools.get(name)(args, undefined, undefined)
    },
  }
}

function createStubEmacs(responses = {}) {
  const calls = []
  return {
    calls,
    callElispFunction(name, args = []) {
      calls.push({ name, args })
      const response = responses[name]
      if (response === undefined) {
        throw new Error(`No stubbed response for ${name}`)
      }
      if (typeof response === "function") {
        return response(args)
      }
      return response
    },
    parseElispString(str) {
      if (str.startsWith('"') && str.endsWith('"')) {
        return str.slice(1, -1)
      }
      return str
    },
  }
}

describe("Tool classes", () => {
  it("returns parsed buffer content", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-buffer-content": '"Hello from buffer"',
    })
    new GetBufferContentTool(server, emacs)
    const response = server.callTool("get_buffer_content")
    assert.equal(response.content[0].text, "Hello from buffer")
  })

  it("reports when buffer has no filename", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-buffer-filename": "nil",
    })
    new GetBufferFilenameTool(server, emacs)
    const response = server.callTool("get_buffer_filename")
    assert.equal(response.content[0].text, "Current buffer is not visiting a file")
  })

  it("returns filename when present", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-buffer-filename": '"/tmp/sample.txt"',
    })
    new GetBufferFilenameTool(server, emacs)
    const response = server.callTool("get_buffer_filename")
    assert.equal(response.content[0].text, "/tmp/sample.txt")
  })

  it("reports when no selection is active", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-selection": "nil",
    })
    new GetSelectionTool(server, emacs)
    const response = server.callTool("get_selection")
    assert.equal(response.content[0].text, "No active selection")
  })

  it("returns current selection text", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-get-selection": '"Highlighted text"',
    })
    new GetSelectionTool(server, emacs)
    const response = server.callTool("get_selection")
    assert.equal(response.content[0].text, "Highlighted text")
  })

  it("opens files via emacsclient", () => {
    const server = createFakeServer()
    const emacs = createStubEmacs({
      "mcp-emacs-open-file": '"Opened"',
    })
    new OpenFileTool(server, emacs)
    const path = "/tmp/weird path"
    const response = server.callTool("open_file", { path })
    assert.equal(response.content[0].text, `Opened file: ${path}`)
    assert.deepEqual(emacs.calls[0], {
      name: "mcp-emacs-open-file",
      args: [path],
    })
  })

  const simpleTools = [
    {
      ToolCtor: DescribeFlycheckInfoTool,
      name: "describe_flycheck_info_at_point",
      fn: "mcp-emacs-get-flycheck-info",
      sample: "Flycheck info",
    },
    {
      ToolCtor: GetErrorContextTool,
      name: "get_error_context",
      fn: "mcp-emacs-get-error-context",
      sample: "Warnings buffer",
    },
    {
      ToolCtor: GetEnvVarsTool,
      name: "get_env_vars",
      fn: "mcp-emacs-get-env-vars",
      sample: "FOO=bar",
    },
    {
      ToolCtor: DiagnoseEmacsTool,
      name: "diagnose_emacs",
      fn: "mcp-emacs-diagnose",
      sample: "Diagnostics",
    },
  ]

  for (const { ToolCtor, name, fn, sample } of simpleTools) {
    it(`${name} returns text from ${fn}`, () => {
      const server = createFakeServer()
      const emacs = createStubEmacs({ [fn]: `"${sample}"` })
      new ToolCtor(server, emacs)
      const response = server.callTool(name)
      assert.equal(response.content[0].text, sample)
      assert.equal(emacs.calls[0].name, fn)
    })
  }
})
