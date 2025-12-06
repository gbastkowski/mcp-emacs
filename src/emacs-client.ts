import { execFileSync } from "child_process"
import { readFileSync } from "fs"
import { join, dirname } from "path"
import { fileURLToPath } from "url"

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

export class EmacsClient {
  private timeout: number
  private elispDir: string

  constructor(timeout: number = 5000) {
    this.timeout = timeout
    this.elispDir = join(__dirname, "..", "elisp")
  }

  private loadElisp(filename: string): string {
    return readFileSync(join(this.elispDir, filename), "utf-8").trim()
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

  private evalElispFile(filename: string, substitutions?: Record<string, string>): string {
    let elisp = this.loadElisp(filename)
    if (substitutions) {
      for (const [key, value] of Object.entries(substitutions)) {
        elisp = elisp.replace(key, value)
      }
    }
    return this.evalInEmacs(elisp)
  }

  private stripQuotes(str: string): string {
    return str.slice(1, -1)
  }

  getBufferContent(): string {
    const content = this.evalElispFile("get-buffer-content.el")
    return this.stripQuotes(content)
  }

  getSelection(): string | null {
    const selection = this.evalElispFile("get-selection.el")
    if (selection === "nil") return null
    return this.stripQuotes(selection)
  }

  openFile(path: string): void {
    this.evalElispFile("open-file.el", { "%PATH%": path })
  }

  getBufferFilename(): string | null {
    const filename = this.evalElispFile("get-buffer-filename.el")
    if (filename === "nil") return null
    return this.stripQuotes(filename)
  }

  getFlycheckInfo(): string {
    const result = this.evalElispFile("get-flycheck-info.el")
    return this.stripQuotes(result)
  }

  getErrorContext(): string {
    const result = this.evalElispFile("get-error-context.el")
    return this.stripQuotes(result)
  }

  getOrgTasks(): string {
    const result = this.evalElispFile("get-org-tasks.el")
    return this.stripQuotes(result)
  }

  getEnvVars(): string {
    const result = this.evalElispFile("get-env-vars.el")
    return this.stripQuotes(result)
  }
}
