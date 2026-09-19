(require :asdf)

(defparameter *test-root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))

(asdf:load-asd (merge-pathnames "lisp/prolog-rlm-cl.asd" *test-root*))
(asdf:load-system "prolog-rlm-cl")

(defun check (condition control &rest arguments)
  (unless condition
    (apply #'error control arguments)))

(prolog-rlm:with-rlm (rlm :root *test-root*)
  (let ((exports (prolog-rlm:module-exports rlm "rlm")))
    (dolist (expected '("rlm_version/1"
                        "rlm_completion/4"
                        "rlm_future_await/2"
                        "rlm_authority/2"
                        "conversation_turn/4"
                        "recursion_execute/4"
                        "artifact_put/7"
                        "agent_spawn/5"
                        "graph_run/4"
                        "symbolic_tool_register/5"
                        "cli_run/2"))
      (check (member expected exports :test #'string=)
             "Root RLM export ~A is not visible from Common Lisp."
             expected)))

  (let ((ready (prolog-rlm:call-rlm rlm "rlm_ready")))
    (check (prolog-rlm:response-ok-p ready)
           "rlm_ready/0 failed through the Common Lisp bridge: ~S"
           ready))

  (let ((compiler-ready
          (prolog-rlm:call-prolog
           rlm
           "rlm_prompt_compiler"
           "rlm_prompt_compiler_ready")))
    (check (prolog-rlm:response-ok-p compiler-ready)
           "Prompt compiler public module is not usable from Common Lisp: ~S"
           compiler-ready))

  (let ((blocked nil))
    (handler-case
        (prolog-rlm:call-prolog rlm "lists" "member" nil)
      (error () (setf blocked t)))
    (check blocked
           "Bridge unexpectedly allowed a non-RLM module."))

  (let* ((version-reply
           (prolog-rlm:call-rlm
            rlm
            "rlm_version"
            (list (prolog-rlm:var "Version"))))
         (version
           (prolog-rlm:binding-term version-reply "Version")))
    (check (and (prolog-rlm:response-ok-p version-reply)
                version
                (search "0.1.0"
                        (prolog-rlm:prolog-term-text version)))
           "RLM version query failed from Common Lisp: ~S"
           version-reply))

  (let ((registry (prolog-rlm:create-tool-registry rlm)))
    (unwind-protect
         (let* ((arguments
                  (prolog-rlm:pdict
                   :type :object
                   :required (list :segment)
                   :additional_properties :false
                   :properties
                   (prolog-rlm:pdict
                    :segment (prolog-rlm:pdict :type :string))))
                (result
                  (prolog-rlm:pdict
                   :type :object
                   :required (list :discount)
                   :additional_properties :false
                   :properties
                   (prolog-rlm:pdict
                    :discount (prolog-rlm:pdict :type :number))))
                (schema
                  (prolog-rlm:make-tool-schema
                   :name :education_discount
                   :description "pure symbolic education discount"
                   :arguments arguments
                   :result result))
                (program
                  (prolog-rlm:sym-program
                   (list
                    (prolog-rlm:sym-rule
                     (prolog-rlm:sym=
                      (prolog-rlm:sym-field :segment)
                      (prolog-rlm:sym-const "edu"))
                     (prolog-rlm:pdict :discount 0.30d0)))
                   (prolog-rlm:pdict :discount 0.0d0)))
                (registration
                  (prolog-rlm:register-symbolic-tool
                   rlm registry schema program)))
           (check (search "ok("
                          (prolog-rlm:prolog-term-text registration))
                  "Symbolic tool did not register: ~A"
                  (prolog-rlm:prolog-term-text registration))
           (multiple-value-bind (outcome trace reply)
               (prolog-rlm:invoke-tool
                rlm
                registry
                (list (prolog-rlm:pcompound "tool" :education_discount))
                :education_discount
                (prolog-rlm:pdict :segment "edu"))
             (declare (ignore trace))
             (check (prolog-rlm:response-ok-p reply)
                    "Tool invocation transport failed: ~S"
                    reply)
             (check (and outcome
                         (search "discount"
                                 (prolog-rlm:prolog-term-text outcome)
                                 :test #'char-equal)
                         (search "0.3"
                                 (prolog-rlm:prolog-term-text outcome)))
                    "Symbolic tool did not produce the expected result: ~A"
                    (and outcome
                         (prolog-rlm:prolog-term-text outcome)))))
      (prolog-rlm:destroy-tool-registry rlm registry))))

(format t "COMMON_LISP_ADAPTER_OK~%")
