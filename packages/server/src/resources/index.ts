import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"
import { MessagesResource } from "./messages-resource.js"
import { WarningsResource } from "./warnings-resource.js"
import { OrgTasksResource } from "./org-tasks-resource.js"

export function registerResources(server: McpServer, emacs: EmacsClient): void {

  for (const ResourceCtor of [
    OrgTasksResource,
    MessagesResource,
    WarningsResource
  ]) { new ResourceCtor(emacs).register(server) }

}
