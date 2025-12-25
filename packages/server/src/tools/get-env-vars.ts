import type { EmacsClient } from "../emacs-client.js"
import { EmacsTool } from "./base-tool.js"

export class GetEnvVarsTool extends EmacsTool {
  public readonly name = "get_env_vars"
  public readonly metadata = {
    description: "List the environment variables currently visible to Emacs"
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  protected handle(_args: unknown, _extra: unknown, _context: unknown) {
    const vars = this.callTextFunction("mcp-emacs-get-env-vars")
    return { content: [ { type: "text", text: vars } ] }
  }
}
