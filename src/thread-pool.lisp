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

(defgeneric callable-call (call))

(defclass callable ()
  ((handler-func :accessor callable-handler-func :initarg :handler-func)))

(defmethod callable-call ((callable callable))
  (funcall (callable-handler-func callable)))

(defgeneric start-pool (thread-pool)
  (:documentation "Starts serving jobs"))
(defgeneric stop-pool (thread-pool)
  (:documentation "Stops serving jobs"))
(defgeneric add-to-pool (thread-pool functions)
  (:documentation "Add a function or a list of function to the thread pool"))
(defgeneric wait-pool-empty (thread-pool &key timeout)
  (:documentation "Wait until all submitted jobs are finished."))

(defclass thread ()
  ((thread :initarg :thread :accessor thread)
   (running-p :initform nil :accessor running-p)
   (job :initform nil :accessor job)
   (lock :initarg :lock :reader lock)
   (condition :initarg :condition :reader th-condition)))

(defclass thread-pool ()
  ((jobs :accessor jobs :initform (make-instance 'arnesi:queue))
   (pool-size :reader pool-size :initarg :pool-size)
   (threads :accessor threads :initform ())
   (pool-lock :accessor pool-lock :initform (bt:make-lock))
   (pool-condition :accessor pool-condition :initform (bt:make-condition-variable))
   (empty-condition :accessor empty-condition :initform (bt:make-condition-variable))
   (running-p :accessor running-p :initform nil)
   (main-thread :accessor main-thread :initform nil))
  (:default-initargs :pool-size 1))

(defmethod (setf pool-size) (size (thread-pool thread-pool))
  (unless (running-p thread-pool)
    (setf (slot-value thread-pool 'pool-size) size)))

(defun make-thread-pool (&optional (pool-size 1))
  (make-instance 'thread-pool :pool-size pool-size))

(defun make-pool-thread (thread-pool)
  (let ((thread (make-instance 'thread
                               :lock (bt:make-lock)
                               :condition (bt:make-condition-variable))))
    (setf (thread thread)
          (bt:make-thread
           (lambda ()
             (loop while (bt:with-lock-held ((pool-lock thread-pool))
                           (running-p thread-pool))
                do (bt:with-lock-held ((lock thread))
                     (bt:condition-wait (th-condition thread) (lock thread))
                     (with-accessors ((pool-lock pool-lock)
                                      (pool-condition pool-condition))
                         thread-pool

                       (let ((func (job thread)))
                         (when func
                           (setf (job thread) nil)
                           (if (typep func 'callable)
                               (callable-call func)
                               (funcall func))
                           (bt:with-lock-held (pool-lock)
                             (bt:condition-notify pool-condition))))))))
           :name "THREAD-POOL:WORKER-THREAD"))
    thread))

(defun make-main-thread (thread-pool)
  (with-accessors ((pool-condition pool-condition)
                   (empty-condition empty-condition)
                   (threads threads)
                   (running-p running-p)
                   (pool-lock pool-lock)
                   (jobs jobs))
      thread-pool
    (bt:make-thread
     (lambda ()
       (bt:with-lock-held (pool-lock)
         (loop
            while running-p
            do (bt:condition-wait pool-condition pool-lock)
               (if (> (arnesi:queue-count jobs) 0)
                   (loop
                      for thr in threads
                      when (bt:acquire-lock (lock thr) nil)
                      do (let ((job (arnesi:dequeue jobs)))
                           (when job
                             (setf (job thr) job)
                             (bt:condition-notify (th-condition thr))))
                        (bt:release-lock (lock thr)))
                   (bt:condition-notify empty-condition)))))
     :name "THREAD-POOL:MAIN-THREAD")))

(defmethod start-pool ((thread-pool thread-pool))
  (with-accessors ((main-thread main-thread)
                   (threads threads)
                   (pool-size pool-size)
                   (running-p running-p))
      thread-pool
    (unless running-p
      (setf running-p t
            main-thread (make-main-thread thread-pool)
            threads (loop for i from 0 below pool-size
                       collect (make-pool-thread thread-pool))))))

(defmethod stop-pool ((thread-pool thread-pool))
  #.(format nil "STOP-POOL begins the process of stopping a~@
                 thread pool. It shuts down the main dispatch~@
                 thread, and then progressively shuts down the~@
                 worker threads. If there are workers in the~@
                 middle of running a job, this will wait for~@
                 those threads to finish their jobs before~@
                 shutting them down.")
  (with-accessors ((threads threads)
                   (pool-size pool-size)
                   (running-p running-p)
                   (pool-lock pool-lock)
                   (pool-condition pool-condition)
                   (main-thread main-thread))
      thread-pool
    (setf running-p nil)
    (bt:with-lock-held (pool-lock)
      (bt:condition-notify pool-condition))
    (loop for thr in threads
          do (bt:with-lock-held ((lock thr))
               (bt:condition-notify (th-condition thr))))))

(defmethod add-to-pool ((thread-pool thread-pool) functions)
  #.(format nil "ADD-TO-POOL adds one or more jobs to a~@
                 thread pool's queue. These jobs are~@
                 dispatched to worker threads in the~@
                 order that they are submitted, as worker~@
                 threads become available.")
  (with-accessors ((jobs jobs)
           (pool-lock pool-lock)
           (pool-condition pool-condition))
      thread-pool

    (bt:with-lock-held (pool-lock)
      (if (listp functions)
          (dolist (func functions)
            (arnesi:enqueue jobs func))
          (arnesi:enqueue jobs functions))
      (bt:condition-notify pool-condition))))

(defmacro with-thread-pool ((pool-name &key (pool-size 1) (wait-pool-empty t)) &rest body)
  #.(format nil "WITH-THREAD-POOL creates and starts a thread pool,~@
                 ensuring that it is properly shut down with STOP-POOL~@
                 when the form returns.~@
                 ~@
                 By default, the macro waits until all submitted jobs~@
                 finish with WAIT-POOL-EMPTY before the form will return.~@
                 If WAIT-POOL-EMPTY is nil, the macro will call STOP-POOL~@
                 immediately after the body is executed.~@
                 See STOP-POOL for a description of its behavior, as it may~@
                 not stop the pool immediately.")
  `(let ((,pool-name (make-thread-pool ,pool-size)))
     (start-pool ,pool-name)
     (unwind-protect
          (progn
            ,@body
            (when ,wait-pool-empty
              (wait-pool-empty ,pool-name)))
       (stop-pool ,pool-name))))

(defmethod wait-pool-empty (thread-pool &key timeout)
  #.(format nil "WAIT-POOL-EMPTY blocks until all jobs submitted to a~@
                 thread pool have finished, or until TIMEOUT, if~@
                 specified.")
  (with-accessors ((pool-lock pool-lock))
      thread-pool
    (bt:with-lock-held (pool-lock)
      (bt:condition-wait (empty-condition thread-pool) pool-lock :timeout timeout))))
