(in-package #:cl-irregsexp)

(deftype integer-match-index ()
  `(integer 0 ,(floor most-positive-fixnum 3)))

(defmacro fail ()
  (error "fail called out of a with-fail"))

(defvar *target* "")
(defvar *pos* 0)
(declaim (type integer-match-index *pos*))

(defmacro def-target ()
  `(progn
     ,@(loop for type in *specialized-types*
	     for func = (specialized-func-symbol 'target type)
	     collect
	     `(progn
		(declaim (ftype (function () ,type) ,func))
		(defun-speedy ,func ()
		  (declare (optimize speed (safety 0)))
		  (declare (type ,type *target*))
		  *target*)))))
(def-target)

(eval-when (:compile-toplevel :load-toplevel)
  (pushnew 'target *type-specific-match-functions*))

(defmacro with-fail (body &body fail-actions)
  (assert fail-actions)
  `(flet ((fail () ,@fail-actions (error "Fail must not return: ~A (in ~A)" ',fail-actions ',body)))
     ,body))

(defmacro with-match-block (&body body)
  (with-unique-names (match-block restart)
    `(block ,match-block
       (tagbody 
	  ,restart
	  (return-from ,match-block
	    (macrolet ((match-block-restart ()
			 `(locally (declare (optimize speed (safety 0)))
			    (go ,',restart)))
		       (return-from-match-block (&optional value)
			 (once-only (value)
			   `(locally (declare (optimize speed (safety 0)))
			      (return-from  ,',match-block ,value)))))
	      (locally ,@body)))))))

(with-define-specialized-match-functions
  (defmacro force-to-target-sequence (v)
    `(force ,v))

  (defun-speedy len-available ()
    (- (length (target)) *pos*))

  (defmacro check-len-available (len)
    (once-only (len)
      `(locally
	   (declare (type integer-match-index ,len *pos*))
	 (declare (optimize speed (safety 0)))
	 (when (> (the integer-match-index (+ *pos* ,len)) (the integer-match-index (length (target))))
	   (fail))
	 (values))))
 
  (defmacro peek (&optional (len '(len-available)))
    (once-only (len)
      `(locally    
	   (declare (type integer-match-index ,len *pos*))
	 (check-len-available ,len)
	 (subseq (target) *pos* (+ *pos* ,len)))))

  (defmacro eat (&optional (len 1))
    (once-only (len)
      `(locally
	   (declare (type integer-match-index ,len))
	 (prog1
	     (peek ,len)
	   (eat-unchecked ,len)))))

  (defun-speedy eat-unchecked (&optional (len 1))
    (declare (optimize speed (safety 0)))
    (declare (type integer-match-index len *pos*))
    (incf *pos* len)
    (values))

  (defun-speedy elt-target (i)
    (declare (optimize speed (safety 0)))
    (declare (type integer-match-index i))
    (elt (target) i))

  (defun-speedy peek-one-unchecked (&optional (i 0))
    (declare (optimize speed (safety 0)))
    (declare (type integer-match-index i *pos*))
    (elt-target (+ *pos* i)))

  (defmacro peek-one (&optional (i 0))
    (once-only (i)
    `(progn
       (check-len-available (1+ ,i))
       (peek-one-unchecked ,i))))

  (defun-speedy force-to-target-element-type (c)
    (let ((s (force-to-target-sequence c)))
      (assert (= 1 (length s)))
      (elt s 0)))

  (defmacro dynamic-literal (v)
    `(let ((value (force-to-target-sequence ,v)))
       (check-len-available (length value))
       (loop for i of-type integer-match-index below (length value)
	     unless (eql (peek-one-unchecked i) (elt value i))
	     do (fail))
       (eat-unchecked (length value))
       (values))))

(defun-consistent to-int (val)
  (etypecase val
    (fixnum val)
    (character (char-code val))))

(defmacro with-match-env ((type target) &body body)
  (check-type type symbol)
  `(with-specialized-match-functions (,type)
     (let ((*target* (force-to-target-sequence ,target)))
       (declare (type ,type *target*))
       (declare (optimize speed))
       ,(output-code (simplify-seq body)))))


(defmacro with-match ( (target &key (on-failure '(error 'match-failed))) &body body)
  (with-unique-names (bv s)
    (once-only (target)
      `(flet ((fail ()
		,on-failure
		(error "top-level fail returned")))
	 (flet ((,bv () ;; use separate flets so poor SBCL does not struggle so much with large matches
		  (with-match-env (simple-byte-vector ,target)
		    ,@body))
		(,s ()
		  (with-match-env (simple-string ,target)
		    ,@body)))
	 (declare (inline ,bv ,s))
	 (let ((*pos* 0))
	   (declare (type integer-match-index *pos*))
	   (etypecase ,target
	     (byte-vector (,bv))
	     (string (,s)))))))))
