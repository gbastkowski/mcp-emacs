import { execFileSync } from "child_process"
import { join, dirname } from "path"
import { fileURLToPath } from "url"

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

export class EmacsClient {
  private timeout: number
  private elispDir: string
  private initFile: string
  private initialized: boolean

  constructor(timeout: number = 5000) {
    this.timeout = timeout
    this.elispDir = join(__dirname, "..", "elisp")
    this.initFile = join(this.elispDir, "mcp-init.el")
    this.initialized = false
  }

  private evalInEmacs(elisp: string): string {
    try {
      const result = execFileSync(
        "emacsclient",
        ["--eval", elisp],
        {
          encoding: "utf-8",
          timeout: this.timeout,
        }
      )
      return result.trim()
    } catch (error) {
      throw new Error(`Failed to communicate with Emacs: ${error}`)
    }
  }

  private ensureInitialized(): void {
    if (this.initialized) return
    const escapedPath = this.escapeElispString(this.initFile)
    const loadCommand = `(progn (unless (featurep 'mcp-emacs) (load-file "${escapedPath}")) 'mcp-emacs-ready)`
    this.evalInEmacs(loadCommand)
    this.initialized = true
  }

  private escapeElispString(value: string): string {
    return value
      .replace(/\\/g, "\\\\")
      .replace(/"/g, '\\"')
      .replace(/\n/g, "\\n")
      .replace(/\r/g, "\\r")
      .replace(/\t/g, "\\t")
  }

  private formatElispArg(value: string | number | boolean | null): string {
    if (typeof value === "string") {
      return `"${this.escapeElispString(value)}"`
    }
    if (typeof value === "number") {
      return value.toString()
    }
    if (typeof value === "boolean") {
      return value ? "t" : "nil"
    }
    if (value === null) {
      return "nil"
    }
    throw new Error("Unsupported elisp argument type")
  }

  private callElispFunction(
    functionName: string,
    args: Array<string | number | boolean | null> = []
  ): string {
    this.ensureInitialized()
    const formattedArgs = args.map((arg) => this.formatElispArg(arg)).join(" ")
    const form = `(${functionName}${formattedArgs ? " " + formattedArgs : ""})`
    return this.evalInEmacs(form)
  }

  private stripQuotes(str: string): string {
    return str.slice(1, -1)
  }

  getBufferContent(): string {
    const content = this.callElispFunction("mcp-emacs-get-buffer-content")
    return this.stripQuotes(content)
  }

  getSelection(): string | null {
    const selection = this.callElispFunction("mcp-emacs-get-selection")
    if (selection === "nil") return null
    return this.stripQuotes(selection)
  }

  openFile(path: string): void {
    this.callElispFunction("mcp-emacs-open-file", [path])
  }

  getBufferFilename(): string | null {
    const filename = this.callElispFunction("mcp-emacs-get-buffer-filename")
    if (filename === "nil") return null
    return this.stripQuotes(filename)
  }

  getFlycheckInfo(): string {
    const result = this.callElispFunction("mcp-emacs-get-flycheck-info")
    return this.stripQuotes(result)
  }

  getErrorContext(): string {
    const result = this.callElispFunction("mcp-emacs-get-error-context")
    return this.stripQuotes(result)
  }

  getOrgTasks(): string {
    const result = this.callElispFunction("mcp-emacs-get-org-tasks")
    return this.stripQuotes(result)
  }

  getEnvVars(): string {
    const result = this.callElispFunction("mcp-emacs-get-env-vars")
    return this.stripQuotes(result)
  }
}
