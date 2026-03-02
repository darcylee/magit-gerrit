;;; magit-gerrit.el --- Magit plugin for Gerrit Code Review  -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2013-2025 Brian Fransioli
;;
;; Author: Brian Fransioli <assem@terranpro.org>
;; URL: https://github.com/terranpro/magit-gerrit
;; Package-Requires: ((emacs "25.1") (magit "3.3.0") (transient "0.3.0"))
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see http://www.gnu.org/licenses/.

;;; Commentary:
;;
;; Magit plugin to make Gerrit code review easy-to-use from Emacs and
;; without the need for a browser!
;;
;; Currently uses the [deprecated] gerrit ssh interface, which has
;; meant that obtaining the list of reviewers is not possible, only
;; the list of approvals (those who have already verified and/or code
;; reviewed).
;;
;;; To Use:
;;
;; (require 'magit-gerrit)
;; (setq-default magit-gerrit-ssh-creds "myid@gerrithost.org")
;;
;;
;; M-x `magit-status'
;; h R  <= magit-gerrit uses the R prefix, see help
;;
;;; Workflow:
;;
;; 1) *check out branch => changes => (ma)git commit*
;; 2) R P  <= [ger*R*it *P*ush for review]
;; 3) R A  <= [ger*R*it *A*dd reviewer] (by email address)
;; 4) *wait for verification/code reviews* [approvals shown in status]
;; 5) R S  <= [ger*R*it *S*ubmit review]
;;
;;; Other Comments:
;; `magit-gerrit-ssh-creds' is buffer local, so if you work with
;; multiple Gerrit's, you can make this a file or directory local
;; variable for one particular project.
;;
;; If your git remote for gerrit is not the default "origin", then
;; `magit-gerrit-remote' should be adjusted accordingly (e.g. "gerrit")
;;
;; Recommended to auto add reviewers via git hooks (precommit), rather
;; than manually performing 'R A' for every review.
;;
;; `magit-gerrit' will be enabled automatically on `magit-status' if
;; the git remote repo uses the same creds found in
;; `magit-gerrit-ssh-creds'.
;;
;; Ex:  magit-gerrit-ssh-creds == br.fransioli@gerrit.org
;; $ cd ~/elisp; git remote -v => https://github.com/terranpro/magit-gerrit.git
;; ^~~ `magit-gerrit-mode' would *NOT* be enabled here
;;
;; $ cd ~/gerrit/prja; git remote -v => ssh://br.fransioli@gerrit.org/.../prja
;; ^~~ `magit-gerrit-mode' *WOULD* be enabled here
;;
;;; Code:

(require 'magit)
(require 'transient)
(require 'json)

(eval-when-compile
  (require 'cl-lib))

(defvar-local magit-gerrit-ssh-creds nil
  "Credentials used to execute gerrit commands via ssh of the form ID@Server")

(defvar-local magit-gerrit-remote "origin"
  "Default remote name to use for gerrit (e.g. \"origin\", \"gerrit\")")

(defvar-local magit-gerrit-force-enable nil
  "Force enabling `magit-gerrit' for the project.")

(defvar-local magit-gerrit-port 29418
  "The default port to use with the Gerrit host.")

(defcustom magit-gerrit-use-push-url nil
  "If t use push url from 'git remote' for Gerrit connection."
  :group 'magit-gerrit
  :type 'boolean)

(defcustom magit-gerrit-show-review-labels nil
  "If t show Gerrit Review Labels as 1st row."
  :group 'magit-gerrit
  :type 'boolean)

(defconst magit-gerrit-default-review-labels
  (list (list "Code-Review" "CR") (list "Verified" "Ve")))

(defcustom magit-gerrit-review-labels magit-gerrit-default-review-labels
  "List of review labels including possible user defined."
  :group 'magit-gerrit
  :type 'list)

(defcustom magit-gerrit-popup-prefix "R"
  "Key code to open magit-gerrit popup."
  :group 'magit-gerrit
  :type 'key-sequence)

(defcustom magit-gerrit-signed-push-p nil
  "Whether or not to push with the --signed option."
  :group 'magit-gerrit
  :type 'boolean)

(defcustom magit-gerrit-extra-options nil
  "Extra options defined when fetching reviews"
  :group 'magit-gerrit
  :type 'string)

(defcustom magit-gerrit-collapse-patchset-section nil
  "Collapse/hide gerrit section containing patchsets by default.
Collapse/hide the section body containing the list of gerrit
changesets by default when t. This only has an effect when
creating the section for the first time. When the section is
recreated during a refresh, then the visibility of predecessor is
inherited and this setting is ignored. See also the HIDE
parameter of `magit-insert-section'."
  :group 'magit-gerrit
  :type 'boolean)

(defcustom magit-gerrit-ellipsis ".."
  "String ellipsis"
  :group 'magit-gerrit
  :type 'string)

(defun gerrit-command (cmd &rest args)
  (let ((gcmd (concat
               "-x -p "
               (number-to-string magit-gerrit-port)
               " "
               (or magit-gerrit-ssh-creds
                   (error "`magit-gerrit-ssh-creds' must be set!"))
               " "
               "gerrit "
               cmd
               " "
               (mapconcat 'identity args " "))))
    ;; (message (format "Using cmd: %s" gcmd))
    gcmd))

(defun gerrit-query (prj &optional status)
  (gerrit-command "query"
                  "--format=JSON"
                  "--current-patch-set"
                  (concat "project:" prj)
                  (concat magit-gerrit-extra-options)
                  (concat "status:" (or status "open"))))

(defun gerrit-review ())

(defun gerrit-ssh-cmd (cmd &rest args)
  (apply #'call-process
         "ssh" nil nil nil
         (split-string (apply #'gerrit-command cmd args))))

(defun gerrit-review-abandon (prj rev)
  (gerrit-ssh-cmd "review" "--project" prj "--abandon" rev))

(defun gerrit-review-submit (prj rev &optional msg)
  (gerrit-ssh-cmd "review" "--project" prj "--submit"
                  (if msg msg "") rev))

(defun gerrit-code-review (prj rev score &optional msg)
  (gerrit-ssh-cmd "review" "--project" prj "--code-review" score
                  (if msg msg "") rev))

(defun gerrit-review-verify (prj rev score &optional msg)
  (gerrit-ssh-cmd "review" "--project" prj "--verified" score
                  (if msg msg "") rev))

(defun magit-gerrit-select-remote-url-cmd ()
  "Returns git command to be used to resolve remote URL."
  (if magit-gerrit-use-push-url
      (list "remote" "get-url" "--push")
    (list "ls-remote" "--get-url")))

(defun magit-gerrit-get-remote-url ()
  "Returns remote URL."
  (magit-git-string (magit-gerrit-select-remote-url-cmd) magit-gerrit-remote))

(defun magit-gerrit-get-project ()
  (let* ((regx (rx (zero-or-one ?:) (zero-or-more (any digit)) ?/
                   (group (not (any "/")))
                   (group (one-or-more (not (any "."))))))
         (str (or (magit-gerrit-get-remote-url) ""))
         (sstr (car (last (split-string str "//")))))
    (when (string-match regx sstr)
      (concat (match-string 1 sstr)
              (match-string 2 sstr)))))

(defun magit-gerrit-string-real-length (s)
  (if (multibyte-string-p s)
      (let* ((mm (- (string-bytes s) (length s)))
             (n (- (length s) (/ mm 2))))
        (+ mm n))
    (length s)))

(defun magit-gerrit-create-branch-force (branch parent)
  "Switch 'HEAD' to new BRANCH at revision PARENT and update working tree.
Fails if working tree or staging area contain uncommitted changes.
Succeed even if branch already exist
\('git checkout -B BRANCH REVISION')."
  (cond ((run-hook-with-args-until-success
          'magit-create-branch-hook branch parent))
        ((and branch (not (string= branch "")))
         (magit-save-repository-buffers)
         (magit-run-git "checkout" "-B" branch parent))))

(defun magit-gerrit-format-short-timestring (seconds)
  (let* ((years  (/ seconds 32140800))
         (months (/ seconds 2678400))
         (days (/ seconds 86400))
         (hours (/ seconds 3600))
         (minutes (/ seconds 60)))
    (cond
     ((> years 1) (format "%2d %s" years (if (> years 2) "years" "year")))
     ((> months 1) (format "%2d %s" months (if (> months 2) "months" "month")))
     ((> days 1) (format "%2d %s" days (if (> days 2) "days" "day")))
     ((> hours 1) (format "%2d %s" hours (if (> hours 2) "hours" "hour")))
     ((> minutes 1) (format "%2d %s" minutes (if (> minutes 2) "minutes" "minute")))
     (t "just now"))))

(defun magit-gerrit-pretty-print-review-header ()
  (let* ((wid (window-width))
         ;; number
         (numstr (propertize (format "%-13s" "Patchset")))
         ;; ;; patchset num
         ;; (patchsetstr (propertize (format "%-5s" "Patchset")))
         ;; branch info
         (branch (propertize (truncate-string-to-width
                              "Branch"
                              20
                              nil ?\s magit-gerrit-ellipsis)))
         ;; sizeinfo
         (sizeinfo (propertize (truncate-string-to-width
                                (format "     %s" "Delta")
                                15
                                nil ?\s magit-gerrit-ellipsis)))
         ;; owner
         (author (propertize (truncate-string-to-width
                              (format "%s" "Owner")
                              10
                              nil ?\s magit-gerrit-ellipsis)))
         ;; lastupdate
         (lastupdate (propertize (truncate-string-to-width
                                  (format "%s" "Updated")
                                  12
                                  nil ?\s magit-gerrit-ellipsis)))
         ;; approvals
         (approvals-info (magit-gerrit-create-review-labels))

         ;; subject
         (subjstr (propertize
                   (truncate-string-to-width
                    (format "%s" "Subject")
                    (- wid (length (concat numstr author
                                           (cond
                                            ((> wid 128) (concat branch sizeinfo lastupdate approvals-info))
                                            ((> wid 108) (concat sizeinfo lastupdate approvals-info))
                                            ((> wid 94)  (concat sizeinfo approvals-info))
                                            ((> wid 80)  (concat approvals-info))
                                            (t ""))))
                       1)
                    nil ?\s magit-gerrit-ellipsis)))

         (show-str (concat numstr subjstr author
                           (cond
                            ((> wid 128) (concat branch sizeinfo lastupdate approvals-info))
                            ((> wid 108) (concat sizeinfo lastupdate approvals-info))
                            ((> wid 94)  (concat sizeinfo approvals-info))
                            ((> wid 80)  (concat approvals-info))
                            (t "")))))
    (propertize (format "%s\n" show-str) 'font-lock-face 'highlight)))

(defun magit-gerrit-pretty-print-review (num patchsetn subj owner-name br size-i size-d ctime approvals-info &optional draft)
  ;; window-width - two prevents long line arrow from being shown
  (let* ((wid (window-width))
         ;; number
         (numstr (propertize (format "%-8s" num) 'font-lock-face 'magit-hash))
         ;; patchset num
         (patchsetstr (propertize (format "%-5s" (format "[%s]" patchsetn))
                                  'font-lock-face 'magit-hash))
         ;; branch info
         (branch (propertize (truncate-string-to-width
                              br
                              20
                              nil ?\s magit-gerrit-ellipsis)
                             'font-lock-face 'magit-hash))
         ;; sizeinfo
         (sizeinfo (concat (propertize (truncate-string-to-width
                                        (format "%+7s"  (concat "+" (number-to-string size-i)))
                                        7
                                        nil ?\s magit-gerrit-ellipsis)
                                       'font-lock-face 'diff-added)
                           " "
                           (propertize (truncate-string-to-width
                                        (format "-%s" size-d)
                                        7
                                        nil ?\s magit-gerrit-ellipsis)
                                       'font-lock-face 'diff-removed)))
         ;; owner
         (author (propertize (truncate-string-to-width
                              (format "%s" owner-name)
                              10
                              nil ?\s magit-gerrit-ellipsis)
                             'font-lock-face 'magit-log-author))
         ;; lastupdate
         (lastupdate (propertize (truncate-string-to-width
                                  (magit-gerrit-format-short-timestring
                                   (time-to-seconds (time-since ctime)))
                                  12
                                  nil ?\s magit-gerrit-ellipsis)))
         ;; approvals
         ;; (left (- left (* 3 (length magit-gerrit-review-labels))))

         ;; subject
         (subjstr (propertize
                   (truncate-string-to-width
                    subj
                    (- wid (length (concat numstr patchsetstr
                                           (cond
                                            ((> wid 128) (concat branch sizeinfo lastupdate approvals-info))
                                            ((> wid 108) (concat sizeinfo lastupdate approvals-info))
                                            ((> wid 94)  (concat sizeinfo approvals-info))
                                            ((> wid 80)  (concat approvals-info))
                                            (t ""))))
                       (magit-gerrit-string-real-length author)
                       1)
                    nil ?\s magit-gerrit-ellipsis)
                   'font-lock-face
                   (if draft
                       'magit-dimmed
                     'magit-filename)))
         (show-str (concat numstr patchsetstr subjstr author
                           (cond
                            ((> wid 128) (concat branch sizeinfo lastupdate approvals-info))
                            ((> wid 108) (concat sizeinfo lastupdate approvals-info))
                            ((> wid 94)  (concat sizeinfo approvals-info))
                            ((> wid 80)  (concat approvals-info))
                            (t "")))))
    (format "%s\n" show-str)))


(defun magit-gerrit-match-review-labels (score type)
  "Match SCORE to correct TYPE."
  (let ((matchlist nil))
    (dolist (labeltuple magit-gerrit-review-labels matchlist)
      (push (and (string= type (car labeltuple)) score) matchlist))
    (nreverse matchlist)))

(defun magit-gerrit-trans-score (type value-list)
  (if (and value-list (length> value-list 0))
      (let ((min-v (apply 'min value-list))
            (max-v (apply 'max value-list))
            (t-max-v 1)
            (t-min-v -1))
        (if (string= "Code-Review" type)
            (setq t-max-v 2 t-min-v -2))
        (cond
         ((<= min-v t-min-v) (propertize "x" 'font-lock-face 'magit-signature-bad))
         ((>= max-v t-max-v) (propertize "√" 'font-lock-face 'magit-signature-good))
         ((> min-v 0) (propertize (format "+%d" min-v) 'font-lock-face 'magit-signature-good))
         (t (propertize (format "%d" min-v) 'font-lock-face 'magit-signature-bad))))
    " "))

(defun magit-gerrit-wash-approvals-oneline (approvals)
  (let* (type-values)
    (seq-doseq (approval approvals)
      (let ((type (cdr (assq 'type approval)))
            (value (string-to-number (cdr (assq 'value approval)))))
        (push value (alist-get type type-values nil nil #'string-equal))))
    (mapconcat
     (lambda (elem)
       (let* ((long (car elem))
              (short (cadr elem))
              (score (magit-gerrit-trans-score
                      long (cdr (assoc long type-values)))))
         (format "%2s" score)))
     magit-gerrit-review-labels
     " ")))

(defun magit-gerrit-wash-review ()
  (let* ((beg (point))
         (jobj (json-read))
         (end (point))
         (num (cdr-safe (assoc 'number jobj)))
         (subj (cdr-safe (assoc 'subject jobj)))
         (br (cdr-safe (assoc 'branch jobj)))
         (owner (cdr-safe (assoc 'owner jobj)))
         (owner-name (cdr-safe (assoc 'name owner)))
         ;; (owner-email (cdr-safe (assoc 'email owner)))
         (patchsets (cdr-safe (assoc 'currentPatchSet jobj)))
         (patchset-num (cdr-safe (assoc 'number patchsets)))
         (last-update (cdr-safe (assoc 'lastUpdated jobj)))
         (size-insert (cdr-safe (assoc 'sizeInsertions patchsets)))
         (size-delete (cdr-safe (assoc 'sizeDeletions patchsets)))
         ;; compare w/t since when false the value is => :json-false
         (isdraft (eq (cdr-safe (assoc 'isDraft patchsets)) t))
         (approvs (cdr-safe (if (listp patchsets)
                                (assoc 'approvals patchsets)
                              (assoc 'approvals (aref patchsets 0)))))
         (scoreinfo (magit-gerrit-wash-approvals-oneline approvs)))

    (if (and beg end)
        (delete-region beg end))
    (when (and num subj owner-name)
      (magit-insert-section (section subj)
        (insert (propertize
                 (magit-gerrit-pretty-print-review num
                                                   patchset-num
                                                   subj
                                                   owner-name
                                                   br
                                                   size-insert
                                                   size-delete
                                                   last-update
                                                   scoreinfo
                                                   isdraft)
                 'magit-gerrit-jobj
                 jobj))
        (add-text-properties beg (point) (list 'magit-gerrit-jobj jobj)))
      t)))

(defun magit-gerrit-wash-reviews (&rest _args)
  (magit-wash-sequence #'magit-gerrit-wash-review))

(defun magit-gerrit-create-review-labels ()
  "Create review labels heading."
  (let* ((pad "")
         (review-labels pad))
    (dolist (label-tuple magit-gerrit-review-labels review-labels)
      (setq review-labels (concat review-labels (car (cdr label-tuple)) " ")))
    (string-trim-right review-labels)))

(defun magit-gerrit-section (_section title washer &rest args)
  (let ((magit-git-executable "ssh")
        (magit-remote-git-executable "ssh")
        (magit-git-global-arguments nil))
    (magit-insert-section (section title magit-gerrit-collapse-patchset-section)
      (magit-insert-heading title)
      (insert (magit-gerrit-pretty-print-review-header))
      (magit-git-wash washer (split-string (car args)))
      (insert "\n"))))

(defun magit-gerrit-remote-update (&optional _remote)
  nil)

(defun magit-gerrit-review-at-point ()
  (get-text-property (point) 'magit-gerrit-jobj))

(defsubst magit-gerrit-process-wait ()
  (while (and magit-this-process
              (eq (process-status magit-this-process) 'run))
    (sleep-for 0.005)))

(defun magit-gerrit-fetch-patchset ()
  "fetch a Gerrit Review Patchset"
  (let ((jobj (magit-gerrit-review-at-point)))
    (when jobj
      (let ((ref (cdr (assoc 'ref (assoc 'currentPatchSet jobj)))))
        (let* ((_magit-proc (magit-git-fetch magit-gerrit-remote ref)))
          (message (format "Waiting a git fetch from %s to complete..."
                           magit-gerrit-remote))
          (magit-gerrit-process-wait))))))

(defun magit-gerrit-view-patchset-diff ()
  "View the Diff for a Patchset"
  (interactive)
  (let ((jobj (magit-gerrit-review-at-point)))
    (when jobj
      (let ((ref (cdr (assoc 'ref (assoc 'currentPatchSet jobj))))
            (dir default-directory))
        (magit-gerrit-fetch-patchset)
        (message (format "Generating Gerrit Patchset for refs %s dir %s" ref dir))
        (magit-diff-range "FETCH_HEAD~1..FETCH_HEAD")))))

(defun magit-gerrit-download-patchset ()
  "Download a Gerrit Review Patchset"
  (interactive)
  (let ((jobj (magit-gerrit-review-at-point)))
    (when jobj
      (let ((ref (cdr (assoc 'ref (assoc 'currentPatchSet jobj))))
            (dir default-directory)
            (branch (format "review/%s/%s-%s"
                            (cdr (assoc 'username (assoc 'owner jobj)))
                            (cdr (or (assoc 'topic jobj) (assoc 'number jobj)))
                            (cdr-safe (assoc 'number (cdr-safe (assoc 'currentPatchSet jobj)))))))
        (magit-gerrit-fetch-patchset)
        (message (format "Checking out refs %s to %s in %s" ref branch dir))
        (magit-gerrit-create-branch-force branch "FETCH_HEAD")))))

(defun magit-gerrit-cherry-pick-patchset ()
  "Cherry-pick a Gerrit Review Patchset"
  (interactive)
  (let ((jobj (magit-gerrit-review-at-point)))
    (when jobj
      (magit-gerrit-fetch-patchset)
      (magit--cherry-pick '("FETCH_HEAD") nil))))

(defun magit-gerrit-browse-review ()
  "Browse the Gerrit Review with a browser."
  (interactive)
  (let ((jobj (magit-gerrit-review-at-point)))
    (if jobj
        (browse-url (cdr (assoc 'url jobj))))))

(defun magit-gerrit-copy-review (with-commit-message)
  "Copy review url and commit message."
  (let ((jobj (magit-gerrit-review-at-point)))
    (if jobj
        (with-temp-buffer
          (insert
           (concat (if with-commit-message
                       (concat (format "%s: " (cdr-safe (assoc 'number jobj)))
                               (car (split-string (cdr (assoc 'commitMessage jobj)) "\n" t)) " | "))
                   (cdr (assoc 'url jobj))))
          (message "%s" (buffer-string))
          (clipboard-kill-region (point-min) (point-max))))))

(defun magit-gerrit-copy-review-url ()
  "Copy review url only"
  (interactive)
  (magit-gerrit-copy-review nil))

(defun magit-gerrit-copy-review-url-commit-message ()
  "Copy review url with commit message"
  (interactive)
  (magit-gerrit-copy-review t))

(defun magit-insert-gerrit-reviews ()
  (magit-gerrit-section 'gerrit-reviews
                        "Reviews:" 'magit-gerrit-wash-reviews
                        (gerrit-query (magit-gerrit-get-project))))

(defun magit-gerrit-add-reviewer ()
  (interactive)
  "ssh -x -p 29418 user@gerrit gerrit set-reviewers --project toplvlroot/prjname --add email@addr"

  (gerrit-ssh-cmd "set-reviewers"
                  "--project" (magit-gerrit-get-project)
                  "--add" (read-string "Reviewer Name/Email: ")
                  (cdr-safe (assoc 'id (magit-gerrit-review-at-point)))))

(defun magit-gerrit-arguments ()
  (or (transient-args 'magit-gerrit-dispatch)
      (list "")))

(defun magit-gerrit-verify-review (args)
  "Verify a Gerrit Review."
  (interactive (magit-gerrit-arguments))

  (let ((score (completing-read "Score: "
                                '("-2" "-1" "0" "+1" "+2")
                                nil t
                                "+1"))
        (rev (cdr-safe (assoc
                        'revision
                        (cdr-safe (assoc 'currentPatchSet
                                         (magit-gerrit-review-at-point))))))
        (prj (magit-gerrit-get-project)))
    (gerrit-review-verify prj rev score args)
    (magit-refresh)))

(defun magit-gerrit-code-review (args)
  "Perform a Gerrit Code Review"
  (interactive (magit-gerrit-arguments))
  (let ((score (completing-read "Score: "
                                '("-2" "-1" "0" "+1" "+2")
                                nil t
                                "+1"))
        (rev (cdr-safe (assoc
                        'revision
                        (cdr-safe (assoc 'currentPatchSet
                                         (magit-gerrit-review-at-point))))))
        (prj (magit-gerrit-get-project)))
    (gerrit-code-review prj rev score args)
    (magit-refresh)))

(defun magit-gerrit-submit-review (args)
  "Submit a Gerrit Code Review"
  ;; "ssh -x -p 29418 user@gerrit gerrit review REVISION  -- --project PRJ --submit "
  (interactive (magit-gerrit-arguments))
  (let ((prj (magit-gerrit-get-project))
        (rev (cdr-safe (assoc
                        'revision
                        (cdr-safe (assoc 'currentPatchSet
                                         (magit-gerrit-review-at-point)))))))
    (gerrit-review-submit prj rev args)
    (magit-fetch-all-no-prune)
    (magit-refresh)))

(defun magit-gerrit-push-review (status)
  (let* ((branch (or (magit-get-current-branch)
                     (error "Don't push a detached head.  That's gross")))
         (commitid (or (when (eq (oref (magit-current-section) type)
                                 'commit)
                         (oref (magit-current-section) value))
                       (error "Couldn't find a commit at point")))
         (rev (magit-rev-parse (or commitid
                                   (error "Select a commit for review"))))

         (branch-remote (and branch (magit-get "branch" branch "remote"))))

    ;; (message "Args: %s "
    ;;         (concat rev ":" branch-pub))

    (let* ((branch-merge (if (or (null branch-remote)
                                 (string= branch-remote "."))
                             (completing-read
                              "Remote Branch: "
                              (let ((rbs (magit-list-remote-branch-names)))
                                (mapcar
                                 #'(lambda (rb)
                                     (and (string-match (rx bos
                                                            (one-or-more (not (any "/")))
                                                            "/"
                                                            (group (one-or-more any))
                                                            eos)
                                                        rb)
                                          (concat "refs/heads/" (match-string 1 rb))))
                                 rbs)))
                           (and branch (magit-get "branch" branch "merge"))))
           (branch-pub (progn
                         (string-match (rx "refs/heads" (group (one-or-more any)))
                                       branch-merge)
                         (format "refs/%s%s" status (match-string 1 branch-merge)))))

      (when (or (null branch-remote)
                (string= branch-remote "."))
        (setq branch-remote magit-gerrit-remote))

      (magit-run-git-async "push" "-v" (when magit-gerrit-signed-push-p "--signed") branch-remote
                           (concat rev ":" branch-pub)))))

(defun magit-gerrit-create-review ()
  (interactive)
  (magit-gerrit-push-review 'for))

(defun magit-gerrit-create-draft ()
  (interactive)
  (magit-gerrit-push-review 'drafts))

(defun magit-gerrit-publish-draft ()
  (interactive)
  (let ((prj (magit-gerrit-get-project))
        (rev (cdr-safe (assoc
                        'revision
                        (cdr-safe (assoc 'currentPatchSet
                                         (magit-gerrit-review-at-point)))))))
    (gerrit-ssh-cmd "review" "--project" prj "--publish" rev))
  (magit-refresh))

(defun magit-gerrit-delete-draft ()
  (interactive)
  (let ((prj (magit-gerrit-get-project))
        (rev (cdr-safe (assoc
                        'revision
                        (cdr-safe (assoc 'currentPatchSet
                                         (magit-gerrit-review-at-point)))))))
    (gerrit-ssh-cmd "review" "--project" prj "--delete" rev))
  (magit-refresh))

(defun magit-gerrit-abandon-review ()
  (interactive)
  (let ((prj (magit-gerrit-get-project))
        ;; (id (cdr-safe (assoc 'id (magit-gerrit-review-at-point))))
        (rev (cdr-safe (assoc
                        'revision
                        (cdr-safe (assoc 'currentPatchSet
                                         (magit-gerrit-review-at-point)))))))
    ;; (message "Prj: %s Rev: %s Id: %s" prj rev id)
    (gerrit-review-abandon prj rev)
    (magit-refresh)))

(defun magit-gerrit-read-comment (&rest _args)
  (format "\'%s\'"
          (read-from-minibuffer "Message: ")))

(transient-define-argument magit-gerrit-message:--message ()
  :description "Message"
  :class 'transient-option
  :key "-m"
  :argument "--message "
  :reader 'magit-gerrit-read-comment)

(defun magit-gerrit-create-branch (_branch _parent))

;;;###autoload (autoload 'magit-gerrit-dispatch "magit-gerrit" nil t)
(transient-define-prefix magit-gerrit-dispatch ()
  "Popup console for magit gerrit commands."
  ["Arguments"
   ("-m" magit-gerrit-message:--message)]
  [["Actions"
    ("A" "Add Reviewer"                    magit-gerrit-add-reviewer)
    ("B" "Abandon Review"                  magit-gerrit-abandon-review)
    ("k" "Delete Draft"                    magit-gerrit-delete-draft)
    ("p" "Publish Draft Patchset"          magit-gerrit-publish-draft)
    ("P" "Push Commit For Review"          magit-gerrit-create-review)
    ("S" "Submit Review"                   magit-gerrit-submit-review)
    ("W" "Push Commit For Draft Review"    magit-gerrit-create-draft)]
   ["Review"
    ("b" "Browse Review"                   magit-gerrit-browse-review)
    ("C" "Code Review"                     magit-gerrit-code-review)
    ("d" "View Patchset Diff"              magit-gerrit-view-patchset-diff)
    ("D" "Download Patchset"               magit-gerrit-download-patchset)
    ("F" "Cherry-pick Patchset"            magit-gerrit-cherry-pick-patchset)
    ("V" "Verify"                          magit-gerrit-verify-review)]]
  ["Others"
   ("y" "Copy Review URL"                  magit-gerrit-copy-review-url)
   ("Y" "Copy Review URL And Message"      magit-gerrit-copy-review-url-commit-message)])

(defvar magit-gerrit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map magit-gerrit-popup-prefix 'magit-gerrit-dispatch)
    map))

(define-minor-mode magit-gerrit-mode "Gerrit support for Magit"
  :lighter " Gerrit" :require 'magit-topgit :keymap 'magit-gerrit-mode-map
  (or (derived-mode-p 'magit-mode)
      (error "This mode only makes sense with magit"))
  (or magit-gerrit-ssh-creds
      (error "You *must* set `magit-gerrit-ssh-creds' to enable magit-gerrit-mode"))
  (or (magit-gerrit-get-remote-url)
      (error "You *must* set `magit-gerrit-remote' to a valid Gerrit remote"))
  (cond
   (magit-gerrit-mode
    (magit-add-section-hook 'magit-status-sections-hook
                            'magit-insert-gerrit-reviews
                            'magit-insert-stashes t t)
    (add-hook 'magit-create-branch-command-hook
              'magit-gerrit-create-branch nil t)
    ;;(add-hook 'magit-pull-command-hook 'magit-gerrit-pull nil t)
    (add-hook 'magit-remote-update-command-hook
              'magit-gerrit-remote-update nil t)
    (add-hook 'magit-push-command-hook
              'magit-gerrit-push nil t))

   (t
    (remove-hook 'magit-after-insert-stashes-hook
                 'magit-insert-gerrit-reviews t)
    (remove-hook 'magit-create-branch-command-hook
                 'magit-gerrit-create-branch t)
    ;;(remove-hook 'magit-pull-command-hook 'magit-gerrit-pull t)
    (remove-hook 'magit-remote-update-command-hook
                 'magit-gerrit-remote-update t)
    (remove-hook 'magit-push-command-hook
                 'magit-gerrit-push t)))
  (when (called-interactively-p 'any)
    (magit-refresh)))

(defun magit-gerrit-detect-ssh-creds (remote-url)
  "Derive `magit-gerrit-ssh-creds' from REMOTE-URL.
Assumes REMOTE-URL is a Gerrit repo if scheme is SSH and port is the
default Gerrit SSH port."
  (let ((url (url-generic-parse-url remote-url)))
    (when (and (string= "ssh" (url-type url))
               (eq magit-gerrit-port (url-port url)))
      (set (make-local-variable 'magit-gerrit-ssh-creds)
           (format "%s@%s" (url-user url) (url-host url)))
      (message "Detected magit-gerrit-ssh-creds=%s" magit-gerrit-ssh-creds))))

(defun magit-gerrit-check-enable ()
  (defvar magit-gerrit-dispatch-is-added nil)
  (defvar magit-origin-action nil)
  (let ((remote-url (magit-gerrit-get-remote-url)))
    (when (and remote-url
               (or magit-gerrit-force-enable
                   (and (or magit-gerrit-ssh-creds
                            (magit-gerrit-detect-ssh-creds remote-url))
                        (string-match magit-gerrit-ssh-creds remote-url))))
      (magit-gerrit-mode 1))
    (if (not magit-origin-action)
        (setf magit-origin-action
              (lookup-key magit-mode-map magit-gerrit-popup-prefix)))
    (cond
     (magit-gerrit-mode
      ;; update keymap with prefix incase it has changed
      (define-key magit-mode-map magit-gerrit-popup-prefix 'magit-gerrit-dispatch)
      (define-key magit-mode-map [remap magit-visit-thing] 'magit-gerrit-browse-review)

      ;; Attach Magit Gerrit to Magit's default help popup
      (if (not magit-gerrit-dispatch-is-added)
          (transient-append-suffix 'magit-dispatch "z"
            `(,magit-gerrit-popup-prefix "Gerrit" magit-gerrit-dispatch)))
      (setq magit-gerrit-dispatch-is-added t))
     (t
      (define-key magit-mode-map magit-gerrit-popup-prefix magit-origin-action)
      ;; Dettach Magit Gerrit to Magit's default help popup
      (setq magit-gerrit-dispatch-is-added nil)
      (transient-remove-suffix 'magit-dispatch magit-gerrit-popup-prefix)))))

;; Hack in dir-local variables that might be set for magit gerrit
(add-hook 'magit-status-mode-hook #'hack-dir-local-variables-non-file-buffer t)

;;;###autoload
(defun magit-gerrit-auto-enable ()
  "Try to auto enable magit-gerrit in the `magit-status' buffer."
  (add-hook 'magit-status-mode-hook #'magit-gerrit-check-enable t)
  (add-hook 'magit-log-mode-hook #'magit-gerrit-check-enable t))

(provide 'magit-gerrit)

;;; magit-gerrit.el ends here
