;;; mcp-emacs-tutor.el --- Guided intro to mcp-emacs in a side window -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.12.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A `vimtutor'-style introduction to mcp-emacs for a human meeting the
;; Emacs-side UX for the first time (issue #106).  The project had grown
;; past the README's quickstart, and the shortest path to "what is this
;; and how do I try it" was a guided read rather than more reference
;; material.
;;
;; The tutor is documentation with a thin container.  `mcp-emacs-tutor'
;; opens a read-only Org buffer in a side window -- the whole point is to
;; read the steps *beside* your work, not to replace it -- with one
;; top-level headline per step, covering the headline flow: start the
;; server, point a client at it, run an agent client in Emacs, and watch
;; an edit come back as a diff you approve.
;;
;; There is deliberately no state machine and no keybinding to advance:
;; a step is a section, scrolling is the interaction, and nothing here
;; touches the network.  The lesson text lives in this file as a string
;; so it is versionable and diffable like the specs it teaches.

;;; Code:

(require 'org)

(defconst mcp-emacs-tutor-buffer-name "*mcp-emacs-tutor*"
  "Name of the buffer the guided introduction is rendered into.")

(defconst mcp-emacs-tutor--lesson
  "* mcp-emacs in ten minutes

mcp-emacs turns Emacs into a live workspace for AI coding agents.  The
agent and you work the same buffers, the same diagnostics, the same Org
plan -- and every edit it makes is one you can see and approve.

This is a short guided tour: nine steps, about ten minutes.  Read a
step, try it, scroll to the next.  Nothing here needs a special key and
nothing is sent anywhere until you start the server yourself.

* Step 1: Start the MCP server

The server runs inside this Emacs session -- there is no separate
process -- and speaks MCP over HTTP.  Start it on demand with:

  M-x mcp-emacs-server-start

To have it up whenever Emacs starts, use the idempotent entry point
instead; calling it twice is safe:

  (add-hook 'emacs-startup-hook #'mcp-emacs-server-ensure)

* Step 2: Confirm it is listening

The server listens on http://localhost:8765/mcp.  The port is
customisable (`mcp-emacs-server-port').  Check the state at any time:

  M-x mcp-emacs-server-running-p

and stop it when you are done for the day:

  M-x mcp-emacs-server-stop

* Step 3: Attach a client

Any MCP client can attach -- Claude Code, opencode, or one you wrote.
Point it at http://localhost:8765/mcp as an HTTP MCP server.  From then
on its tool calls land in *this* session: the buffers you are editing,
not a copy of them.

* Step 4: Run an agent client inside Emacs

You do not have to leave Emacs to talk to the agent.  Open a
conversation in a normal buffer:

  M-x claude-client-open

The conversation is a buffer like any other -- terminal-free, with the
agent's replies rendered as text.  For the full Claude Code TUI inside a
window, use `M-x mcp-emacs-run'; the opencode client has its own
`opencode-client-*' commands.

* Step 5: The agent works on your live buffers

Ask the agent about the code in front of you, and it reads the real
thing: buffers, the active selection, xref, tree-sitter, diagnostics,
the project, your Org files.  There is no copy-paste round trip -- the
buffer the agent edits is the buffer you are looking at.

* Step 6: See an edit gated by a diff

An edit that changes your files comes back as a proposal, not a fait
accompli.  The agent calls the `apply_diff' tool, mcp-emacs opens an
ediff of the change, and nothing is written until you approve it.  Reject
it and the file is untouched.  This is the heart of the project: you see
every edit before it lands.

* Step 7: Gate native edits too

`apply_diff' works with any client.  To gate Claude Code's *native* Edit
and Write operations the same way, turn on the IDE integration; those
edits then route through the same diff review instead of going straight
to disk.  See docs/clients.md, section on native edit diff review.

* Step 8: Share an Org task list

The `org_task_*' tools let the agent read and tick items on the same Org
task list you use, and the `/mcp-emacs:emacs-loop' command ties the loop
together.  This is what it looks like when the agent is a colleague in
your Org file rather than a chat window beside it.

* Step 9: Where to go next

The README's entry-point list is the map; docs/tools.md covers the tool
surface, docs/clients.md the clients you just met, and docs/orgspec.md
the Org-native spec workflow.  Nothing to install for this tour -- the
important part is already done: the server is running and the agent is
working in your session."
  "The guided introduction, as Org text, one top-level headline per step.
Kept as a string in this file -- rather than a separate .org -- so the
lesson is versionable and diffable alongside the code it teaches.")

(defun mcp-emacs-tutor--buffer ()
  "Create or refresh the tutor buffer and return it.
The buffer holds read-only Org text.  The fixed `mcp-emacs-tutor-buffer-name'
means a second call returns the same buffer instead of opening a duplicate."
  (with-current-buffer (get-buffer-create mcp-emacs-tutor-buffer-name)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert mcp-emacs-tutor--lesson)
      (goto-char (point-min)))
    (let ((org-inhibit-startup t))
      (org-mode))
    (setq buffer-read-only t)
    (current-buffer)))

;;;###autoload
(defun mcp-emacs-tutor ()
  "Open the guided mcp-emacs introduction in a read-only side window.
The text is a short sequence of Org steps, each a headline; read it top
to bottom and follow along in your own session.  Advancing is scrolling
-- there is no lesson player and nothing is sent over the network."
  (interactive)
  (display-buffer (mcp-emacs-tutor--buffer)
                  '((display-buffer-reuse-window
                     display-buffer-in-side-window)
                    (side . right)
                    (slot . 0))))

(provide 'mcp-emacs-tutor)
;;; mcp-emacs-tutor.el ends here
