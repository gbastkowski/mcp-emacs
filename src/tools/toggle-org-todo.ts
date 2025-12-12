import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"
import { z } from "zod"
import { EmacsTool } from "./base-tool.js"

const toggleSchema = z.object({
  state: z.string().min(1).describe("Explicit TODO keyword to set").optional()
})

type ToggleArgs = z.infer<typeof toggleSchema>

export class ToggleOrgTodoTool extends EmacsTool {
  constructor(server: McpServer, emacs: EmacsClient) {
    super(server, emacs, {
      name: "toggle_org_todo",
      metadata: {
        description: "Toggle or set the TODO keyword at point in the current org heading",
        inputSchema: toggleSchema,
      },
    })
  }

  protected handle(args: unknown, _extra: unknown, _context: unknown) {
    const parsed: ToggleArgs = toggleSchema.parse(args ?? {})
    const result = this.callTextFunction("mcp-emacs-toggle-org-todo", [parsed.state ?? null])
    return {
      content: [
        {
          type: "text",
          text: result,
        },
      ],
    }
  }
}
