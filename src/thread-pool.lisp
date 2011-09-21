;;; -*- lisp -*-
;;; $Header: thread-pool.lisp $

;;; Copyright (c) 2011, Andrea Chiumenti.  All rights reserved.

;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:

;;;   * Redistributions of source code must retain the above copyright
;;;     notice, this list of conditions and the following disclaimer.

;;;   * Redistributions in binary form must reproduce the above
;;;     copyright notice, this list of conditions and the following
;;;     disclaimer in the documentation and/or other materials
;;;     provided with the distribution.

;;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR 'AS IS' AND ANY EXPRESSED
;;; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
;;; DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
;;; GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
;;; WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

(in-package :thread-pool)

(defgeneric start-pool (thread-pool)
  (:documentation "Starts serving jobs"))
(defgeneric stop-pool (thread-pool)
  (:documentation "Stops serving jobs"))
(defgeneric add-to-pool (thread-pool functions)
  (:documentation "Add a function or a list of function to the thread pool"))

(defclass thread-pool ()
  ((jobs :accessor jobs :initform (make-instance 'arnesi:queue))
   (pool-size :reader pool-size :initarg :pool-size)
   (threads :accessor threads :initform ())
   (pool-condition-vars :accessor pool-condition-vars :initform ())
   (pool-lock :accessor pool-lock :initform (bordeaux-threads:make-lock))
   (pool-condition :accessor pool-condition :initform (bordeaux-threads:make-condition-variable))
   (running-p :accessor running-p :initform nil)
   (main-thread :accessor main-thread :initform nil))
  (:default-initargs :pool-size 1))

(defmethod (setf pool-size) (size (thread-pool thread-pool))
  (unless (running-p thread-pool)
    (setf (slot-value thread-pool 'pool-size) size)))

(defun make-thread-pool (&optional (pool-size 1))
  (make-instance 'thread-pool :pool-size pool-size))

(defmethod start-pool ((thread-pool thread-pool))
  (with-accessors ((pool-condition pool-condition)		   
		   (main-thread main-thread)
		   (threads threads)
		   (pool-size pool-size)
		   (running-p running-p)
		   (pool-lock pool-lock)
		   (pool-condition-vars pool-condition-vars)
		   (jobs jobs))
      thread-pool
    (unless running-p
      (setf running-p t
	    main-thread (let ((lock (bordeaux-threads:make-lock)))
			  (bordeaux-threads:make-thread 
			   (lambda ()
			     (bordeaux-threads:with-lock-held (lock)
			       (loop
				  while (running-p thread-pool)
				  do (progn (bordeaux-threads:condition-wait pool-condition lock)
					    (with-accessors ((threads threads)
							     (pool-condition-vars pool-condition-vars)
							     (jobs jobs))
						thread-pool
					      (when jobs					      
						(loop for thr in threads
						   for thr-cond in pool-condition-vars
						   when thr
						   return (bordeaux-threads:condition-notify thr-cond)))))))))
			  (bordeaux-threads:condition-notify pool-condition))
	    pool-condition-vars (loop for i from 1 to pool-size
				   collect (bordeaux-threads:make-condition-variable))
	    threads (loop for i from 1 to pool-size
		       collect (let* ((ix (- i 1))
				      (lock (bordeaux-threads:make-lock))
				      (condition (nth ix pool-condition-vars))) 
				 (bordeaux-threads:make-thread 
				  (lambda ()
				    (bordeaux-threads:with-lock-held (lock)
				      (loop 
					 while running-p
					 do (progn (bordeaux-threads:condition-wait condition lock)
						   (with-accessors ((pool-lock pool-lock)
								    (threads threads)
								    (jbos jobs)
								    (pool-condition pool-condition))
						       thread-pool
						     
						     (let ((th (bordeaux-threads:current-thread))
							   (func nil))
						       (bordeaux-threads:with-lock-held (pool-lock)
							 (setf (nth ix threads) nil
							       func (arnesi:dequeue jobs)))						       
						       (when func 
							 (funcall func))
						       (bordeaux-threads:with-lock-held (pool-lock)
							 (setf (nth ix threads) th))
						       (bordeaux-threads:condition-notify pool-condition))))))
				    (bordeaux-threads:condition-notify condition)))))))))

(defmethod stop-pool ((thread-pool thread-pool))
  (with-accessors ((threads threads)
		   (pool-size pool-size)
		   (running-p running-p)
		   (pool-lock pool-lock)
		   (pool-condition-vars pool-condition-vars)
		   (main-thread main-thread))
      thread-pool
    (setf running-p nil)
    (bordeaux-threads:with-lock-held (pool-lock)
      (setf main-thread nil
	    threads nil
	    pool-condition-vars nil))))

(defmethod add-to-pool ((thread-pool thread-pool) functions)
  (with-accessors ((jobs jobs)
		   (pool-lock pool-lock)
		   (pool-condition pool-condition))
      thread-pool
    (bordeaux-threads:with-lock-held (pool-lock)
      (if (listp functions)
	  (dolist (func functions)
	    (arnesi:enqueue jobs func)) 
	  (arnesi:enqueue jobs functions)))
    (bordeaux-threads:condition-notify pool-condition)))