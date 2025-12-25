import type { McpServer   } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"

export type ResourceReadResult = {
  contents: Array<{ uri: string; mimeType: string; text: string }>
}

export abstract class EmacsResource {
  abstract readonly name: string
  abstract readonly uri: string
  abstract readonly description: string
  abstract readonly mimeType: string

  protected readonly emacs: EmacsClient

  protected constructor(emacs: EmacsClient) {
    this.emacs = emacs
  }

  abstract read(): Promise<ResourceReadResult> | ResourceReadResult

  register(server: McpServer): void {
    server.registerResource(
      this.name,
      this.uri,
      {
        description: this.description,
        mimeType: this.mimeType
      },
      () => this.read()
    )
  }
}
