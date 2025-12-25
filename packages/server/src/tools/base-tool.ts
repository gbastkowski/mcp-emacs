import type { McpServer   } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"

type ToolMetadata = Record<string, unknown>
type ElispArg     = string | number | boolean | null

export abstract class EmacsTool {
  public abstract readonly name: string
  public abstract readonly metadata: ToolMetadata
  protected readonly emacs: EmacsClient

  protected constructor(emacs: EmacsClient) {
    this.emacs = emacs
  }

  public register(server: McpServer): void {
    server.registerTool(
      this.name,
      this.metadata as never,
      ((args: unknown, extra: unknown, context: unknown) => this.handle(args, extra, context)) as never
    )
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  protected abstract handle(args: unknown, extra: unknown, context: unknown): Promise<any> | any

  protected callTextFunction(functionName: string, args: ElispArg[] = []): string {
    const raw = this.emacs.callElispFunction(functionName, args)
    return this.emacs.parseElispString(raw)
  }
}
