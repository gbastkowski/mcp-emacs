;;; init.el --- Init file for the isolated test Emacs -*- lexical-binding: t; -*-

;; Loaded by bin/test-emacs.sh with `--init-directory' pointing at this
;; directory, so this is the whole configuration of the test instance -- no
;; Doom, no user config, no personal packages.  Two reasons it exists rather
;; than running the suites in the working Emacs:
;;
;;   - Every fixture that pops a window, an ediff or a *claude-client* buffer
;;     used to land in the middle of whatever was being worked on.
;;   - Anything that wedges or kills the instance (a runaway process filter, a
;;     ws handler error, a hard crash) took the working session with it.
;;
;; Isolation is by state, not just by process: the MCP HTTP port, the
;; emacsclient socket and the IDE lockfile directory are what a second Emacs
;; would otherwise fight the working one over.  `mcp-emacs-ide' already picks a
;; random WebSocket port, so that one needs no offset.
;;
;; It lives in test/init/ rather than test/ itself because Emacs warns when
;; `user-emacs-directory' also sits on `load-path', and test/ has to be on
;; `load-path' for the suites.

;;; Code:

(require 'package)

;; `user-emacs-directory' is set by the script's `--init-directory', which
;; points at .test-emacs/home/ rather than at this file's own directory.  It
;; has to: `native-comp-eln-load-path' is derived from it at startup, before
;; any init file runs, so an init directory inside the tracked tree gets an
;; eln-cache/ dropped into the repo whatever this file does afterwards.  All
;; instance state therefore lands under the git-ignored .test-emacs/.

;; Deps come from a package dir the script prepares under .test-emacs/, so a
;; run never mutates ~/.emacs.d and only refreshes MELPA when something is
;; actually missing.
(setq package-user-dir
      (or (getenv "MCP_EMACS_TEST_PACKAGE_DIR")
          (expand-file-name "package" user-emacs-directory)))
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)

;; MCP_EMACS_TEST_REPO is always set by the script; the fallback is for a
;; hand-rolled `emacs --init-directory test/init' invocation.
(let ((repo (or (getenv "MCP_EMACS_TEST_REPO")
                (expand-file-name "../.." (file-name-directory load-file-name)))))
  (add-to-list 'load-path (expand-file-name "elisp" repo))
  (add-to-list 'load-path (expand-file-name "test" repo)))

;; Offset from the working instance's 8765 so both can listen at once.  Set
;; before the server module is loaded, hence the bare defvar.
(defvar mcp-emacs-server-port)
(setq mcp-emacs-server-port
      (string-to-number (or (getenv "MCP_EMACS_TEST_PORT") "8775")))

;; Keep IDE lockfiles out of ~/.claude/ide, or a stale test lockfile can be
;; picked up by a real Claude launched from the working Emacs.
(defvar mcp-emacs-ide-lockfile-directory)
(setq mcp-emacs-ide-lockfile-directory
      (expand-file-name "ide/" user-emacs-directory))

(setq inhibit-startup-screen t
      make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      ;; A prompt in a headless daemon is a hang, not a question.
      confirm-kill-processes nil
      ;; Suites assert on buffer text; an indentation surprise inherited from
      ;; a personal default would be noise.
      indent-tabs-mode nil)

;; Batch only: in a daemon or GUI this would drop into a debugger on every
;; error a fixture deliberately provokes.
(when noninteractive
  (setq debug-on-error t))

;;; init.el ends here
