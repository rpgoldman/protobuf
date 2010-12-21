
;;;;    protobuf.asd


;; Copyright 2010, Google Inc. All rights reserved.

;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions are
;; met:

;;     * Redistributions of source code must retain the above copyright
;; notice, this list of conditions and the following disclaimer.
;;     * Redistributions in binary form must reproduce the above
;; copyright notice, this list of conditions and the following disclaimer
;; in the documentation and/or other materials provided with the
;; distribution.
;;     * Neither the name of Google Inc. nor the names of its
;; contributors may be used to endorse or promote products derived from
;; this software without specific prior written permission.

;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;; "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;; LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;; A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;; OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;; SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
;; LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
;; DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
;; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
;; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
;; OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


(cl:in-package #:asdf)

;; Pathname of Google's protocol buffer compiler.  You must replace this
;; pathname with the appropriate one for your system.

(defvar *protoc* #p"/local/software/package/google-protobuf/bin/protoc"
  "Pathname of Google's protocol buffer compiler.")
(export '*protoc*)

;; Pathname of the Lisp protocol buffer compiler backend.  You must replace
;; this pathname with the appropriate one for your system.

(defvar *protoc-gen-lisp* #p"/local/software/package/protoc-gen-lisp/bin/protoc-gen-lisp"
  "Pathname of the Lisp protocol buffer compiler backend, protoc-gen-lisp.")
(export '*protoc-gen-lisp*)

(defvar *protoc-relative-path* nil
  "Proto file arguments to the protobuf compiler are relative paths?")
(export '*protoc-relative-path*)


(defclass protobuf-source-file (cl-source-file)
  ((relative-proto-pathname
    :initarg :proto-pathname
    :initform nil
    :reader proto-pathname
    :documentation "Relative pathname that specifies the location of a .proto file.")
   (search-path
    :initform ()
    :initarg :proto-search-path
    :reader search-path
    :documentation "List containing directories where the protocol buffer
compiler should search for imported protobuf files.  Non-absolute pathnames
are treated as relative to the directory containing the DEFSYSTEM form in
which they appear."))
  (:documentation "A protocol buffer definition file."))

(export '(protobuf-source-file proto-pathname search-path))


(in-package #:common-lisp-user)

(defpackage #:protobuf-system
  (:documentation "System definitions for protocol buffer code.")
  (:use #:common-lisp #:asdf))

(in-package #:protobuf-system)


(defclass proto-to-lisp (operation)
  ()
  (:documentation "An ASDF operation that compiles a .proto file containing
protocol buffer definitions into a Lisp source file."))

(defmethod component-depends-on ((operation compile-op) (component protobuf-source-file))
  "Compiling a protocol buffer file depends on generating Lisp source code
for the protobuf, but also on loading package definitions and in-line
function definitions that the machine-generated protobuf Lisp code uses."
  `((proto-to-lisp ,(component-name component))
    ,@(call-next-method)))

(defmethod component-depends-on ((operation load-op) (component protobuf-source-file))
  "Loading a protocol buffer file depends on generating Lisp source code
for the protobuf, but also on loading package definitions and in-line
function definitions that the machine-generated protobuf Lisp code uses."
  `((proto-to-lisp ,(component-name component))
    ,@(call-next-method)))

(defun proto-input (protobuf-source-file)
  "Return the pathname of the protocol buffer definition file that must be
translated into Lisp source code for this PROTO-FILE component."
  (if (proto-pathname protobuf-source-file)
      ;; Path of the protobuf file was specified with :PROTO-PATHNAME.
      (merge-pathnames
       (make-pathname :type "proto")
       (merge-pathnames (pathname (proto-pathname protobuf-source-file))
                        (component-pathname (component-parent protobuf-source-file))))
      ;; No :PROTO-PATHNAME was specified, so the path of the protobuf
      ;; defaults to that of the Lisp file, but with a ".proto" suffix.
      (let ((lisp-pathname (component-pathname protobuf-source-file)))
        (merge-pathnames (make-pathname :type "proto") lisp-pathname))))

(defmethod input-files ((operation proto-to-lisp) (component protobuf-source-file))
  (list *protoc* *protoc-gen-lisp* (proto-input component)))

(defmethod output-files ((operation proto-to-lisp) (component protobuf-source-file))
  "Arrange for the Lisp output file of PROTO-TO-LISP operations to be stored
where fasl files are located."
  (values (list (component-pathname component))
          nil))                     ; allow around methods to translate

(defun resolve-relative-pathname (path parent-path)
  "When PATH doesn't have an absolute directory component, treat it as
relative to PARENT-PATH."
  (let* ((pathname (pathname path))
         (directory (pathname-directory pathname)))
    (if (and (list directory) (eq (car directory) :absolute))
        pathname
        (let ((resolved-path (merge-pathnames pathname parent-path)))
          (make-pathname :directory (pathname-directory resolved-path)
                         :name nil
                         :type nil
                         :defaults resolved-path)))))

(defun resolve-search-path (protobuf-source-file)
  (let ((search-path (search-path protobuf-source-file)))
    (let ((parent-path (component-pathname (component-parent protobuf-source-file))))
      (mapcar (lambda (path)
                (resolve-relative-pathname path parent-path))
              search-path))))

;; XXXX: This before method would not be needed if PROTO-TO-LISP were a
;; subclass of COMPILE-OP.  Should we make that change?

(defmethod perform :before ((operation proto-to-lisp) (component protobuf-source-file))
  (map nil #'ensure-directories-exist (output-files operation component)))

(defmethod perform ((operation proto-to-lisp) (component protobuf-source-file))
  (let* ((source-file (proto-input component))
         (source-file-argument (if *protoc-relative-path*
                                   (file-namestring source-file)
                                   (namestring source-file)))
         ;; Around methods on output-file may globally redirect output
         ;; products, so we must call that method instead of executing
         ;; (component-pathname component).
         (output-file (first (output-files operation component)))
         (search-path (cons (directory-namestring source-file) (resolve-search-path component)))
         (status (run-shell-command "~A --plugin=~A --proto_path=~{~A~^:~} --lisp_out=~A ~A"
                                    (namestring *protoc*)
                                    (namestring *protoc-gen-lisp*)
                                    search-path
                                    (directory-namestring output-file)
                                    source-file-argument)))
    (unless (zerop status)
      (error 'compile-failed :component component :operation operation))))

(defmethod asdf::component-self-dependencies :around ((op load-op) (c protobuf-source-file))
  "Remove PROTO-TO-LISP operations from self dependencies.  Otherwise, the
Lisp output files of PROTO-TO-LISP are considered to be input files for
LOAD-OP, which means ASDF loads both the .lisp file and the .fasl file."
  (remove-if (lambda (x)
               (eq (car x) 'proto-to-lisp))
             (call-next-method)))

;; The following code was copied from asdf.lisp and modified slightly to set
;; SOURCE-FILE to a pathname in the directory where fasl files are stored.
;; The PERFORM method defined in asdf.lisp for instances of CL-SOURCE-FILE
;; computes SOURCE-FILE by calling COMPONENT-PATHNAME instead of by calling
;; the INPUT-FILES generic function.  I think this is a misfeature of ASDF.

(defmethod perform ((operation compile-op) (c protobuf-source-file))
  (let ((source-file (make-pathname :name (pathname-name (component-pathname c))
                                    :type "lisp"
                                    :defaults (first (output-files operation c))))
        (output-file (first (output-files operation c)))
        (*compile-file-warnings-behaviour* (operation-on-warnings operation))
        (*compile-file-failure-behaviour* (operation-on-failure operation)))
    (multiple-value-bind (output warnings-p failure-p)
        (apply #'compile-file* source-file :output-file output-file
               (asdf::compile-op-flags operation))
      (when warnings-p
        (case (operation-on-warnings operation)
          (:warn (warn
                  "~@<COMPILE-FILE warned while performing ~A on ~A.~@:>"
                  operation c))
          (:error (error 'compile-warned :component c :operation operation))
          (:ignore nil)))
      (when failure-p
        (case (operation-on-failure operation)
          (:warn (warn
                  "~@<COMPILE-FILE failed while performing ~A on ~A.~@:>"
                  operation c))
          (:error (error 'compile-failed :component c :operation operation))
          (:ignore nil)))
      (unless output
        (error 'compile-error :component c :operation operation)))))


;;; Protocol buffer support code.


(defsystem protobuf
  :name "Protocol Buffer"
  :description "Protocol buffer code"
  :long-description "A Common Lisp implementation of Google's protocol
buffer support libraries."
  :version "0.5"
  :author "Robert Brown"
  :licence "See file COPYING and the copyright messages in individual files."
  ;; After loading the system, announce its availability.
  :perform (load-op :after (operation component)
             (pushnew :protobuf cl:*features*)
             (provide 'protobuf))
  :depends-on (#-(or allegro clisp sbcl) :trivial-utf-8)
  :components
  ((:static-file "COPYING")
   (:static-file "README")
   (:static-file "TODO")
   (:cl-source-file "package")
   #-(or abcl allegro cmu sbcl)
   (:module "sysdep"
    :pathname ""           ; this module's files are not in a subdirectory
    :depends-on ("package")
    :components ((:cl-source-file "portable-float")))
   (:cl-source-file "optimize" :depends-on ("package"))
   (:cl-source-file "base" :depends-on ("package" "optimize"))
   (:cl-source-file "varint"  :depends-on ("package" "optimize" "base"))
   (:cl-source-file "protocol-buffer" :depends-on ("package"))
   ;; The varint dependency is needed because some varint functions are
   ;; declared in line, and so must be loaded before wire-format is compiled.
   (:cl-source-file "wire-format"
    :depends-on ("package" "base" "optimize" "varint"
                 #-(or abcl allegro cmu sbcl) "sysdep"))))
