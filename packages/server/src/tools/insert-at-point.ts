import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"
import { z } from "zod"
import { EmacsTool } from "./base-tool.js"

const insertSchema = z.object({
  text: z.string().describe("Text to insert at the current point"),
  replaceSelection: z
    .boolean()
    .default(false)
    .describe("Replace the active selection if one exists"),
})

type InsertArgs = z.infer<typeof insertSchema>

export class InsertAtPointTool extends EmacsTool {
  constructor(server: McpServer, emacs: EmacsClient) {
    super(server, emacs, {
      name: "insert_at_point",
      metadata: {
        description: "Insert text at point or replace the current selection in Emacs",
        inputSchema: insertSchema,
      },
    })
  }

  protected handle(args: unknown, _extra: unknown, _context: unknown) {
    const parsed: InsertArgs = insertSchema.parse(args)
    const result = this.callTextFunction("mcp-emacs-insert-at-point", [
      parsed.text,
      parsed.replaceSelection,
    ])

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
