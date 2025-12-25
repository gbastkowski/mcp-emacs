import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"
import { DiagnoseEmacsTool } from "./diagnose-emacs.js"
import { DescribeFlycheckInfoTool } from "./describe-flycheck.js"
import { GetBufferContentTool } from "./get-buffer-content.js"
import { GetBufferFilenameTool } from "./get-buffer-filename.js"
import { GetEnvVarsTool } from "./get-env-vars.js"
import { GetErrorContextTool } from "./get-error-context.js"
import { GetSelectionTool } from "./get-selection.js"
import { OpenFileTool } from "./open-file.js"
import { EditFileRegionTool } from "./edit-file-region.js"
import { InsertAtPointTool } from "./insert-at-point.js"
import { GotoLineTool } from "./goto-line.js"
import { ToggleOrgTodoTool } from "./toggle-org-todo.js"
import { EvalTool } from "./eval.js"

export function registerTools(server: McpServer, emacs: EmacsClient): void {
  const tools = [
    GetBufferContentTool,
    GetBufferFilenameTool,
    GetSelectionTool,
    OpenFileTool,
    EditFileRegionTool,
    InsertAtPointTool,
    GotoLineTool,
    ToggleOrgTodoTool,
    DescribeFlycheckInfoTool,
    GetErrorContextTool,
    GetEnvVarsTool,
    EvalTool,
    DiagnoseEmacsTool
  ]

  for (const ToolCtor of tools) { new ToolCtor(emacs).register(server) }
}
