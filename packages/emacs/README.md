# mcp-emacs (Emacs package)

Helper utilities that expose the Emacs-side commands expected by the `mcp-emacs-server` Node MCP server.

## Installation

1. Clone this repository or fetch the `packages/emacs` directory somewhere on your disk.
2. Add the `packages/emacs/lisp` directory to your `load-path` and require the package:

```elisp
(add-to-list 'load-path "/path/to/mcp-emacs/packages/emacs/lisp")
(require 'mcp-emacs)
```

You can also make the package available through `straight.el` or `use-package` by pointing them at this directory.

## Provided features

The package defines the `mcp-emacs-*` functions invoked by the MCP server tools (diagnostics, buffer helpers, editing helpers, etc.). It is safe to load in any Emacs with server mode enabled.
