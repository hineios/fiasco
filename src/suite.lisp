;;; -*- mode: Lisp; -*-
;;;
;;; Copyright (c) 2006 by the authors.
;;;
;;; See LICENCE for details.

(in-package :fiasco)

(defun find-suite-for-package (package)
  (gethash package *package-bound-suites*))

(defun make-suite (name &rest args &key &allow-other-keys)
  (apply #'make-instance 'test :name name args))

(defmacro defsuite (name-or-name-with-args &optional args)
  (destructuring-bind (name &rest deftest-args)
      (ensure-list name-or-name-with-args)
    (let ((bind-to-package (getf deftest-args :bind-to-package)))
      (setq bind-to-package
            (if (eq t bind-to-package)
                *package*
                (find-package bind-to-package)))
      (remf deftest-args :bind-to-package)
      (with-unique-names (test)
        `(progn
           (deftest (,name ,@deftest-args) ,args
             (let* ((,test (find-test ',name)))
               (loop
                 :for subtest :being :the :hash-values
                   :of (children-of ,test)
                 :when (and (auto-call? subtest)
                            (or (zerop (length
                                        (lambda-list-of subtest)))
                                (member (first
                                         (lambda-list-of subtest))
                                        '(&rest &key &optional))))
                   :do (funcall (name-of subtest))))
             (values))
           (let ((suite (find-test ',name)))
             ,(when bind-to-package
                `(setf (gethash ,bind-to-package *package-bound-suites*) suite))
             (values suite)))))))

(setf *root-suite* (make-suite 'root-suite :documentation "Root Suite" :in nil))
(setf *suite* *root-suite*)


;;; define-test-package and friends
(defpackage :fiasco-suites
  (:use)
  (:documentation "~
Namespace for Fiasco suites defined via DEFINE-TEST-PACKAGE."))

(defsuite (fiasco-suites::all-tests :in root-suite))

(defun all-tests ()
  "Run all currently defined tests."
  (run-tests 'fiasco-suites::all-tests))

(defmacro define-test-package (name-or-name-with-args &body package-options)
  "Defines a new package and binds to it a new test suite.

The binding between package and suite means that tests defined while
inside this package are automatically added to the associated
suite. Inside the new package, the function RUN-PACKAGE-TESTS is the
preferred way to execute the suite. To run the tests from outside, use
RUN-TESTS.

NAME-OR-NAME-WITH-ARGS names the package and suite to create. It is
either a single symbol NAME, or a list (NAME :IN PARENT-SUITE) where
PARENT-SUITE designated the Fiasco suite previously created with
DEFSUITE that should parent the newly created suite.

Package NAME is defined via normal `defpackage', and in addition to
processing PACKAGE-OPTIONS, automatically USES the :FIASCO and :CL
packages."
  (destructuring-bind (name &key (in 'fiasco-suites::all-tests))
      (alexandria:ensure-list name-or-name-with-args)
    (unless (find-package name)
      (make-package name :use nil))
    (let ((suite-sym (intern (string name) :fiasco-suites)))
      `(progn
	 (defpackage ,name
	   ,@(append `((:use :fiasco :cl))
		     package-options))
	 (defsuite (,suite-sym :bind-to-package ,name
			       :in ,in))))))

(defvar *pretty-log-stream* nil)
(defvar *pretty-log-verbose-p* nil)

(defun run-tests (testable &key
                             (describe-failures t)
                             verbose
                             (stream *standard-output*)
                             interactive)
  "Execute tests designated by TESTABLE.

Returns two values:

1. A boolean indicating whether all tests were successful, and
2. A list of objects containing test results for each executed suite.

TESTABLE can be a test or suite designator as accepted by
FIND-TEST, or a package designator for a package associated with a
test suite, or a list composed of any combination of the above.

With optional INTERACTIVE, run tests interactively, i.e. break on
errors and unexpected assertion failures.

With optional DESCRIBE-FAILURES, T by default, describe failures to
optional STREAM, which defaults to *STANDARD-OUTPUT*.

With optional VERBOSE print more information about each test run, like
its docstring."
  (loop for thing in (alexandria:ensure-list testable)
        ;; `suite' is used though it needn't be a test suite, might be
        ;; just a single TESTABLE.
        ;;
        for suite = (etypecase thing
                      (testable thing)
                      (package (find-suite-for-package thing))
                      (symbol (or (find-test thing :otherwise nil)
                                  (find-suite-for-package
                                   (find-package thing)))))
        for result = (progn
                       (assert suite
                               nil
                               "Can't find anything testable designated by ~a"
                               thing)
                       (run-suite-tests suite
                                        :verbose verbose
                                        :stream stream
                                        :interactive interactive)
                       *last-test-result*)
        collect result into results
        do (unless (or interactive
                       (not describe-failures)
                       (zerop (length (failures-of result))))
             (describe-failed-tests :result result :stream stream))

        finally
           (return (values (every #'zerop
                                  (mapcar #'length
                                          (mapcar #'failures-of results)))
                           results))))

(defun run-package-tests (&key (package *package* package-supplied-p)
                               (packages (list *package*) packages-supplied-p)
                               (describe-failures t)
                               verbose
                               (stream *standard-output*)
                               interactive)
  "Execute test suite(s) associated with PACKAGE or PACKAGES.

PACKAGE defaults to the current package. Don't supply both both
PACKAGE and PACKAGES.

See RUN-TESTS for the meaning of the remaining keyword arguments."
  (assert (not (and packages-supplied-p package-supplied-p))
          nil
          "Supply either :PACKAGE or :PACKAGES, not both")
  (run-tests (if packages-supplied-p
                 packages
                 package)
             :describe-failures describe-failures
             :verbose verbose
             :stream stream
             :interactive interactive))

(defun run-suite-tests (suite-designator &key verbose (stream t) interactive)
  (let ((*debug-on-unexpected-error* interactive)
        (*debug-on-assertion-failure* interactive)
        (*print-test-run-progress* nil)
        (*pretty-log-stream*
          (make-instance 'column-counting-output-stream  :understream stream))
        (*pretty-log-verbose-p* verbose)
        (*run-test-function* #'pretty-run-test)
        (*context* nil))
    (funcall (etypecase suite-designator
               (symbol suite-designator)
               (test (name-of suite-designator))))
    (terpri stream)
    (values)))

(defvar *within-non-suite-test* nil
  "True within the scope of a non-suite test. Used to suppress printing test
  status for recursive test calls.")

(defun pretty-run-test (test function)
  ;; HACK: until printing of recursive tests is implemented nicely we avoid
  ;; reporting non-toplevel tests altogether.
  (when *within-non-suite-test*
    (return-from pretty-run-test (run-test-body-in-handlers test function)))
  (labels
      ((depth-of (context)
         (let ((depth 0))
           (loop while (setf context (parent-context-of context))
                 do (incf depth))
           depth))
       (pp (format-control &rest format-args)
         ;; format magic courtesy of Robert Smith (github #24)
         (format *pretty-log-stream* "~&~v@{~C~:*~}"
                 (* (depth-of *context*) 2) #\Space)
         (apply #'format *pretty-log-stream* format-control format-args))
       (suite-p ()
         (not (zerop (hash-table-count (children-of test))))))
    (if (suite-p)
        (pp "~A (Suite)" (name-of test))
        (pp "~A" (name-of test)))
    (let* ((*error-output* *pretty-log-stream*)
           (*standard-output* *pretty-log-stream*)
           (*within-non-suite-test* (not (suite-p)))
           (retval-v-list (multiple-value-list
                           (run-test-body-in-handlers test function)))
           (failures (failures-of *context*))
           (skipped (skipped-p *context*)))
      (unless (suite-p)
        (format *pretty-log-stream* "~v@{~C~:*~}"
                (max 1 (- *test-progress-print-right-margin*
                          (output-column *pretty-log-stream*)
                          (length "[FAIL]")))
                #\.)
        (format *pretty-log-stream* "[~A]~%"
                (cond
                  (skipped  "SKIP")
                  (failures "FAIL")
                  (t        " OK ")))
        (when (and *pretty-log-verbose-p* (not skipped))
          (pp "    (~A)"
              (or (documentation (name-of test) 'function)
                  "no docstring for this test"))
          (pp "    (~A assertions, ~A failed, ~A errors, ~A expected)~%"
              (length (assertions-of *context*))
              (count-if (alexandria:rcurry #'typep 'failed-assertion) failures)
              (count-if (alexandria:rcurry #'typep 'unexpected-error) failures)
              (count-if 'expected-p failures))))
      (values-list retval-v-list))))

(defun indented-format (level stream format-control &rest format-arguments)
  (let ((line-prefix (make-string level :initial-element #\Space)))
    (let ((output (format nil "~?~%" format-control format-arguments)))
      (with-input-from-string (s output)
        (loop for line = (read-line s nil nil) until (null line)
              do (format stream "~A~A~%" line-prefix line))))))

(defun describe-failed-tests (&key (result *last-test-result* result-provided-p)
                                   (stream t))
  "Prints out a report for RESULT in STREAM.

RESULT defaults to `*last-test-result*' and STREAM defaults to t"
  (check-type result (or null context))
  ;; Check if there was a last run.
  (when (null result)
    (unless result-provided-p
      (format stream "~&~%No tests have been run yet.~%"))
    (return-from describe-failed-tests))

  ;; Guaranteed that RESULT is an object of type CONTEXT.
  (let* ((failures (failures-of result))
         (nfailures (length failures)))
    (cond ((zerop nfailures)
           (format stream "~&~%Test run had no failures.~%"))
          (t
           (format stream "~&~%Test run had ~D failure~:P:~%" nfailures)
           (loop for failure in failures
                 for test-num from 1
                 do (format stream "~%  Failure ~A: ~A when running ~S~%"
                            test-num
                            (type-of failure)
                            (name-of (test-of (context-of failure))))
                    (indented-format 4 stream "~a" (describe-object failure nil)))))))


;; Local Variables:
;; coding: utf-8-unix
;; End:
