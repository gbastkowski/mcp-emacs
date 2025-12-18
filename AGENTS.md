# MCP Emacs Project Guidelines

## Project Overview

MCP server that enables AI agents to interact with Emacs.
Uses `emacsclient` for communication.

Repository layout:
- `packages/server`: Node.js MCP server module
- `packages/emacs`: Emacs Lisp package that must be installed separately

## Tech Stack

- TypeScript with @modelcontextprotocol/sdk
- Node.js (ES modules)
- emacsclient for Emacs communication
- STDIO transport

## Architecture Decisions

### Emacs Communication
- Use `emacsclient --eval` for all Emacs interactions
- Timeout set to 5 seconds for safety
- Requires Emacs server mode to be running

### Error Handling
- Catch and wrap emacsclient errors with descriptive messages
- Return "No active selection" for empty regions (not an error)

## Code Style

- Use ES modules (type: "module" in package.json)
- Strict TypeScript configuration
- Prefer explicit types over inference where it improves clarity
- Two-space indentation, LF endings, and final newlines are enforced via `.editorconfig`
- Keep public members at the top of classes, with private helpers grouped below
- Keep short parameter lists on a single line when they fit and avoid trailing commas on the last element/argument
- For simple `switch` branches prefer single-line `case` statements (`case "x": doWork(); break`)
- Git commits should follow the tbaggery guidelines: short imperative subject (~50 chars), wrap additional context at ~72 chars, and keep messages brief unless extra detail is essential.

## Tools & Resources Implementation

Each tool should:
1. Define clear input schema with required fields
2. Use `evalInEmacs()` helper for Elisp evaluation
3. Strip surrounding quotes from Elisp string results
4. Return MCP-compliant response objects with content array

Resources follow the same pattern using the `src/resources` base class. Prefer dedicated resource classes over ad-hoc registrations so metadata, URIs, and read callbacks live together.

## Testing

Manual testing workflow:
1. Start Emacs with server-start
2. Build the MCP server (run `npm run build` inside `packages/server`)
3. Test with MCP client
4. Check emacsclient behavior directly when debugging

## Future Enhancements

Potential additions (not yet implemented):
- More buffer operations (save, close, switch)
- Region manipulation (insert, replace text)
- Navigation commands (goto line, search)
- Emacs Lisp evaluation with variable capture
- File system operations via dired
