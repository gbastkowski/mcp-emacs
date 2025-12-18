# mcp-emacs (Emacs package)

Helper utilities that expose the Emacs-side commands expected by the `mcp-emacs-server` Node MCP server.

## Installation

1. Clone this repository or fetch the `packages/emacs` directory somewhere on your disk.
2. Choose an install method:
   - **Manual load-path**

     ```elisp
     (add-to-list 'load-path "/path/to/mcp-emacs/packages/emacs/lisp")
     (require 'mcp-emacs)
     ```

   - **Package manager**: e.g. `straight.el` / `use-package`

     ```elisp
     (use-package mcp-emacs
       :straight (mcp-emacs :type git :host github :repo "gbastkowski/mcp-emacs" :files ("packages/emacs/lisp/*.el"))
       :config (server-start))
     ```

   - **package-install-file**: run `M-x package-install-file` and select `packages/emacs/mcp-emacs-pkg.el`

Whichever path you pick, make sure `(require 'mcp-emacs)` happens before the Node server tries to talk to Emacs.

## Provided features

The package defines the `mcp-emacs-*` functions invoked by the MCP server tools (diagnostics, buffer helpers, editing helpers, etc.). It is safe to load in any Emacs with server mode enabled.
