import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"

export type ResourceReadResult = {
  contents: Array<{ uri: string; mimeType: string; text: string }>
}

type ResourceConfig = {
  name: string
  uri: string
  description: string
  mimeType: string
}

export abstract class EmacsResource {
  private readonly config: ResourceConfig

  constructor(
    protected readonly server: McpServer,
    protected readonly emacs: EmacsClient,
    config: ResourceConfig
  ) {
    this.config = config
    this.register()
  }

  protected abstract read(): Promise<ResourceReadResult> | ResourceReadResult

  private register(): void {
    this.server.registerResource(
      this.config.name,
      this.config.uri,
      {
        description: this.config.description,
        mimeType: this.config.mimeType
      },
      () => this.read()
    )
  }
}
