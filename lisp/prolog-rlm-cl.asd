(asdf:defsystem "prolog-rlm-cl"
  :description "Common Lisp client and symbolic tool harness for prolog-rlm"
  :version "0.1.0"
  :author "lost-rob0t"
  :license "See repository"
  :depends-on ("uiop")
  :serial t
  :components ((:file "package")
               (:file "bridge")
               (:file "symbolic-tools")))
