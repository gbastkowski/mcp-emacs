import type { EmacsClient } from "../utils/emacs-client.js"
import { EmacsTool } from "./base-tool.js"

export class GetCurrentTaskAtPointTool extends EmacsTool {
  readonly name = "get_current_task_at_point"
  readonly metadata = {
    description: "Get the current Org task at point"
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  handle(_args: unknown, _extra: unknown, _context: unknown) {
    const raw = this.emacs.callElispFunction("mcp-emacs-get-current-task-at-point")
    if (raw === "nil") { return { content: [ { type: "text", text: "No current task at point" } ] } }

    const task = this.emacs.parseElispString(raw)
    return { content: [ { type: "text", text: task } ] }
  }
}
