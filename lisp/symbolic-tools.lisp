(in-package #:prolog-rlm)

(defun make-tool-schema (&key name description capability arguments result
                              (effect :read)
                              (time-limit 1.0d0)
                              (max-output-bytes 65536))
  (unless name
    (error "A symbolic tool schema requires :NAME."))
  (unless description
    (error "A symbolic tool schema requires :DESCRIPTION."))
  (unless arguments
    (error "A symbolic tool schema requires :ARGUMENTS."))
  (unless result
    (error "A symbolic tool schema requires :RESULT."))
  (tagged-dict
   "tool_schema"
   :name name
   :description description
   :capability (or capability (pcompound "tool" name))
   :effect effect
   :arguments arguments
   :result result
   :limits (pdict :time_limit time-limit
                  :max_output_bytes max-output-bytes)))

(defun create-tool-registry (connection)
  (let* ((reply
           (call-prolog connection
                        "rlm_tool"
                        "tool_registry_create"
                        (list (var "Registry"))))
         (registry (binding-term reply "Registry")))
    (unless (and (response-ok-p reply) registry)
      (error "Could not create RLM tool registry: ~S" reply))
    registry))

(defun destroy-tool-registry (connection registry)
  (call-prolog connection
               "rlm_tool"
               "tool_registry_destroy"
               (list registry)))

(defun register-symbolic-tool (connection registry schema program
                                &key (options nil))
  (let* ((reply
           (call-prolog connection
                        "rlm_symbolic_tool"
                        "symbolic_tool_register"
                        (list registry
                              schema
                              program
                              options
                              (var "Outcome"))))
         (outcome (binding-term reply "Outcome")))
    (unless (and (response-ok-p reply) outcome)
      (error "Could not register symbolic RLM tool: ~S" reply))
    outcome))

(defun invoke-tool (connection registry capabilities name arguments
                     &key (options nil))
  (let* ((reply
           (call-prolog connection
                        "rlm_tool"
                        "tool_invoke"
                        (list registry
                              capabilities
                              name
                              arguments
                              options
                              (var "Outcome")
                              (var "Trace"))))
         (outcome (binding-term reply "Outcome"))
         (trace (binding-term reply "Trace")))
    (values outcome trace reply)))

(defun sym-field (key)
  (pcompound "field" key))

(defun sym-path (&rest keys)
  (pcompound "path" keys))

(defun sym-const (value)
  (pcompound "const" value))

(defun sym-and (&rest conditions)
  (pcompound "and" conditions))

(defun sym-or (&rest conditions)
  (pcompound "or" conditions))

(defun sym-not (condition)
  (pcompound "not" condition))

(defun sym= (left right)
  (pcompound "eq" left right))

(defun sym/= (left right)
  (pcompound "neq" left right))

(defun sym< (left right)
  (pcompound "lt" left right))

(defun sym<= (left right)
  (pcompound "lte" left right))

(defun sym> (left right)
  (pcompound "gt" left right))

(defun sym>= (left right)
  (pcompound "gte" left right))

(defun sym-in (value choices)
  (pcompound "in" value choices))

(defun sym-present (value)
  (pcompound "present" value))

(defun sym-add (left right)
  (pcompound "add" left right))

(defun sym-sub (left right)
  (pcompound "sub" left right))

(defun sym-mul (left right)
  (pcompound "mul" left right))

(defun sym-div (left right)
  (pcompound "div" left right))

(defun sym-min (left right)
  (pcompound "min" left right))

(defun sym-max (left right)
  (pcompound "max" left right))

(defun sym-expr (expression)
  (pcompound "expr" expression))

(defun sym-rule (condition result-template)
  (pcompound "rule" condition result-template))

(defun sym-program (rules default-template)
  (pcompound "symbolic_program" rules default-template))
