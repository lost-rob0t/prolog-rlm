(in-package #:prolog-rlm)

(defstruct connection
  process
  input
  output
  root
  (next-id 0 :type integer))

(defstruct (prolog-term (:constructor raw-term (text)))
  (text "" :type string))

(defstruct (prolog-var (:constructor %make-prolog-var (name)))
  (name "" :type string))

(defstruct (prolog-dict (:constructor %make-prolog-dict (tag pairs)))
  tag
  pairs)

(defun var (name)
  (let ((text (string name)))
    (unless (and (> (length text) 0)
                 (or (upper-case-p (char text 0))
                     (char= #\_ (char text 0)))
                 (every (lambda (ch)
                          (or (alphanumericp ch)
                              (char= ch #\_)))
                        text))
      (error "Invalid Prolog variable name: ~S" name))
    (%make-prolog-var text)))

(defun pdict (&rest key-values)
  (apply #'tagged-dict "json" key-values))

(defun tagged-dict (tag &rest key-values)
  (unless (evenp (length key-values))
    (error "Dictionary requires alternating key/value arguments."))
  (%make-prolog-dict
   tag
   (loop for (key value) on key-values by #'cddr
         collect (cons key value))))

(defun pcompound (functor &rest arguments)
  (raw-term
   (format nil "~A(~{~A~^,~})"
           (%encode-atom functor)
           (mapcar #'%encode-prolog arguments))))

(defun %default-root ()
  (uiop:pathname-parent-directory-pathname
   (asdf:system-source-directory "prolog-rlm-cl")))

(defun start-rlm (&key (root (%default-root)) (swipl "swipl"))
  (let* ((root-path (uiop:ensure-directory-pathname root))
         (bridge (merge-pathnames
                  "prolog/adaptors/rlm_common_lisp_bridge.pl"
                  root-path)))
    (unless (probe-file bridge)
      (error "prolog-rlm Common Lisp bridge not found: ~A" bridge))
    (let* ((process
             (uiop:launch-program
              (list swipl
                    "-q"
                    "-s" (namestring bridge)
                    "-g" "rlm_common_lisp_bridge:bridge_main"
                    "-t" "halt")
              :input :stream
              :output :stream
              :error-output *error-output*
              :wait nil))
           (connection
             (make-connection
              :process process
              :input (uiop:process-info-input process)
              :output (uiop:process-info-output process)
              :root root-path)))
      (handler-case
          (let ((hello (%request connection "HELLO" "rlm" "-")))
            (unless (response-ok-p hello)
              (error "prolog-rlm bridge HELLO failed: ~S" hello))
            connection)
        (error (condition)
          (ignore-errors (uiop:terminate-process process))
          (error condition))))))

(defun stop-rlm (connection)
  (when (and connection
             (connection-process connection))
    (ignore-errors (%request connection "SHUTDOWN" "rlm" "-"))
    (ignore-errors (finish-output (connection-input connection)))
    (ignore-errors
      (when (uiop:process-alive-p (connection-process connection))
        (uiop:terminate-process (connection-process connection)))))
  t)

(defmacro with-rlm ((name &rest start-options) &body body)
  `(let ((,name (start-rlm ,@start-options)))
     (unwind-protect
          (progn ,@body)
       (stop-rlm ,name))))

(defun response-ok-p (response)
  (eq (getf response :status) :ok))

(defun module-exports (connection module)
  (let ((reply (%request connection "EXPORTS" (%module-name module) "-")))
    (unless (response-ok-p reply)
      (error "Cannot inspect RLM module ~A: ~S" module reply))
    (getf reply :exports)))

(defun call-rlm (connection predicate &optional arguments)
  (call-prolog connection "rlm" predicate arguments))

(defun call-prolog (connection module predicate &optional arguments)
  (let* ((module-name (%module-name module))
         (predicate-name (%predicate-name predicate))
         (encoded-arguments (mapcar #'%encode-prolog arguments))
         (goal (if encoded-arguments
                   (format nil "~A(~{~A~^,~})"
                           (%encode-atom predicate-name)
                           encoded-arguments)
                   (%encode-atom predicate-name)))
         (reply (%request connection
                          "CALL"
                          module-name
                          (%uhex-encode goal))))
    (when (eq (getf reply :status) :error)
      (error "Prolog call failed: ~S" reply))
    reply))

(defun binding-term (response name)
  (let* ((wanted (string name))
         (row (find wanted
                    (getf response :bindings)
                    :key (lambda (entry) (getf entry :name))
                    :test #'string=)))
    (when row
      (raw-term (getf row :term)))))

(defun %request (connection operation module payload)
  (unless (uiop:process-alive-p (connection-process connection))
    (error "prolog-rlm bridge process is not alive."))
  (let ((id (incf (connection-next-id connection))))
    (format (connection-input connection)
            "~D~C~A~C~A~C~A~%"
            id #\Tab operation #\Tab module #\Tab payload)
    (finish-output (connection-input connection))
    (let ((line (read-line (connection-output connection) nil nil)))
      (unless line
        (error "prolog-rlm bridge closed without replying."))
      (let ((*read-eval* nil))
        (multiple-value-bind (reply position)
            (read-from-string line)
          (declare (ignore position))
          (unless (and (listp reply)
                       (eql id (getf reply :id)))
            (error "Mismatched prolog-rlm bridge reply: ~S" reply))
          reply)))))

(defun %uhex-encode (text)
  (if (zerop (length text))
      "-"
      (with-output-to-string (out)
        (loop for character across text
              for code = (char-code character)
              do (format out "~6,'0X" code)))))

(defun %module-name (module)
  (let ((text (string-downcase (string module))))
    (unless (and (> (length text) 0)
                 (alpha-char-p (char text 0))
                 (every (lambda (ch)
                          (or (alphanumericp ch)
                              (char= ch #\_)))
                        text))
      (error "Invalid Prolog module name: ~S" module))
    text))

(defun %predicate-name (predicate)
  (let ((text (string-downcase (string predicate))))
    (unless (> (length text) 0)
      (error "Invalid Prolog predicate name: ~S" predicate))
    text))

(defun %encode-prolog (value)
  (typecase value
    (prolog-term (prolog-term-text value))
    (prolog-var (prolog-var-name value))
    (prolog-dict (%encode-dict value))
    (string (%encode-string value))
    (integer (write-to-string value :base 10 :radix nil))
    (float (%encode-float value))
    (ratio (format nil "(~A/~A)" (numerator value) (denominator value)))
    (null "[]")
    (cons
     (unless (list-length value)
       (error "Improper or circular lists cannot be encoded as Prolog lists."))
     (format nil "[~{~A~^,~}]" (mapcar #'%encode-prolog value)))
    (vector
     (format nil "[~{~A~^,~}]"
             (map 'list #'%encode-prolog value)))
    (symbol
     (if (eq value t)
         "true"
         (%encode-atom value)))
    (t
     (error "Cannot encode ~S as a closed Prolog term." value))))

(defun %encode-dict (dictionary)
  (format nil "~A{~{~A~^,~}}"
          (%encode-atom (prolog-dict-tag dictionary))
          (mapcar
           (lambda (pair)
             (format nil "~A:~A"
                     (%encode-atom (car pair))
                     (%encode-prolog (cdr pair))))
           (prolog-dict-pairs dictionary))))

(defun %encode-atom (value)
  (let ((text (string-downcase (string value))))
    (with-output-to-string (out)
      (write-char #\' out)
      (loop for ch across text do
        (case ch
          (#\\ (write-string "\\\\" out))
          (#\' (write-string "\\'" out))
          (#\Newline (write-string "\\n" out))
          (#\Return (write-string "\\r" out))
          (#\Tab (write-string "\\t" out))
          (otherwise (write-char ch out))))
      (write-char #\' out))))

(defun %encode-string (text)
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for ch across text do
      (case ch
        (#\\ (write-string "\\\\" out))
        (#\" (write-string "\\"" out))
        (#\Newline (write-string "\\n" out))
        (#\Return (write-string "\\r" out))
        (#\Tab (write-string "\\t" out))
        (otherwise (write-char ch out))))
    (write-char #\" out)))

(defun %encode-float (value)
  (let ((text (write-to-string value)))
    (string-right-trim
     '(#\Space #\Tab)
     (substitute #\e #\d
                 (substitute #\e #\D text)))))
