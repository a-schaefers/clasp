(in-package "MP")

(defun cas-expander (symbol)
  (core:get-sysprop symbol 'cas-method))
(defun (setf cas-expander) (expander symbol)
  (core:put-sysprop symbol 'cas-method expander))

(defmacro cas (place old new &environment env)
  "(CAS place old new)
Atomically store NEW in PLACE if OLD matches the current value of PLACE.
Matching is as if by EQ, except for fixnums and floats, which is as if by EQL.
Returns the previous value of PLACE; if it's EQL to OLD the swap happened.

Only the swap is atomic. Evaluation of PLACE's subforms, OLD, and NEW is
not guaranteed to be in any sense atomic with the swap, and likely won't be.

PLACE must be a CAS-able place. CAS-able places are either symbol macros,
or accessor forms with a CAR of
CAR, CDR, FIRST, REST, SVREF, SYMBOL-PLIST,
SLOT-VALUE, CLOS:SLOT-VALUE-USING-CLASS, CLOS:STANDARD-INSTANCE-ACCESS,

or one defined with DEFINE-CAS-EXPANDER.

Some CAS accessors have additional semantic constraints.
You can see their documentation with e.g. (documentation 'slot-value 'mp:cas)

This is planned to be expanded to include SYMBOL-VALUE, variables,
possibly other simple vectors, and slot accessors.

Experimental."
  (multiple-value-bind (temps values oldvar newvar cas read)
      (get-cas-expansion place env)
    (declare (ignore read))
    `(let* (,@(mapcar #'list temps values)
            (,oldvar ,old) (,newvar ,new))
       ,cas)))

(defmacro atomic-update (place update-fn &rest arguments &environment env)
  (multiple-value-bind (vars vals old new cas read)
      (get-cas-expansion place env)
    `(let* (,@(mapcar #'list vars vals)
            (,old ,read))
       (loop for ,new = (funcall ,update-fn ,@arguments ,old)
             until (eq ,old (setf ,old ,cas))
             finally (return ,new)))))

(defmacro atomic-incf (place &optional (delta 1))
  `(atomic-update ,place #'+ ,delta))

(defmacro atomic-decf (place &optional (delta 1))
  `(atomic-update ,place #'(lambda (y x) (- x y)) ,delta))

(defun get-cas-expansion (place &optional env)
  "Analogous to GET-SETF-EXPANSION. Returns the following six values:

* list of temporary variables, which will be bound as if by LET*
* list of forms, whose results will be bound to the variables
* variable for the old value of PLACE
* variable for the new value of PLACE
* A form to perform the swap, which can refer to the temporary variables
   and the variables for the old and new values
* A form to read a value from PLACE, which can refer to the temporary variables"
  (etypecase place
    (symbol
     (multiple-value-bind (expansion expanded)
         (macroexpand-1 place env)
       (if expanded
           (get-cas-expansion expansion env)
           (error "CAS on variables not supported yet")))
     #+(or)
     (let ((info (cleavir-env:variable-info env place)))
       (etypecase info
         (cleavir-env:symbol-macro-info
          (get-cas-expansion (macroexpand-1 place env) env))
         (cleavir-env:special-variable-info
          (get-cas-expansion `(symbol-value ',place) env))
         (cleavir-env:lexical-variable-info
          (lexical-cas-expansion place env)))))
    (cons
     (let* ((name (car place))
            (expander (cas-expander name)))
       (if expander
           (funcall expander place env)
           (multiple-value-bind (expansion expanded)
               (macroexpand-1 place env)
             (if expanded
                 (get-cas-expansion expansion env)
                 (default-cas-expansion place env))))))))

#+(or)
(defun lexical-cas-expansion (var &optional env)
  ;; So: For a regular local, cas is meaningless.
  ;; We can reasonably say it succeeds, i.e.
  ;; (cas x old new) = (prog1 old (setq x new))
  ;; For a closed over variable, we could do an
  ;; actual CAS. Closures are just objects, so
  ;; I think this is even reasonable. But to
  ;; support it we kind of need a special form
  ;; so that the compiler can determine the
  ;; closed-over-ness of the variable.
  ;; ...but none of this is supported right now.
  (let ((old (gensym "OLD")) (new (gensym "NEW")))
    (values nil nil old new
            `(casq ,var ,old ,new)
            var)))

(defun default-cas-expansion (place &optional env)
  (declare (ignore env))
  (error "~a is not a supported place to CAS" place)
  #+(or)
  (let ((op (car place)) (args (cdr place)))
    (default-cas-expansion-aux op `(cas ,op) args)))

;;; used below because i'm lazy
(defun default-cas-expansion-aux (op cas-op args)
  (let ((temps (loop for form in args collect (gensym)))
        (new (gensym "NEW")) (old (gensym "OLD")))
    (values temps args old new
            `(funcall #',cas-op ,old ,new ,@temps)
            `(,op ,@temps))))

(defmacro define-cas-expander (accessor lambda-list &body body
                               &environment env)
  "Analogous to DEFINE-SETF-EXPANDER, defines a CAS expander for ACCESSOR.
The body must return the six values for GET-CAS-EXPANSION.

It is up to you the definer to ensure the swap is performed atomically.
This means you will almost certainly need Clasp's synchronization operators
(e.g., CAS on some other place).

Docstrings are accessible with doc-type MP:CAS."
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (setf (cas-expander ',accessor)
           ,(ext:parse-macro accessor lambda-list body env))
     ',accessor))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Documentation support
;;;

(defmethod documentation ((object symbol) (doc-type (eql 'cas)))
  (let ((exp (cas-expander object)))
    (when exp (documentation exp t))))

(defmethod (setf documentation) (new (object symbol) (doc-type (eql 'cas)))
  (let ((exp (cas-expander object)))
    (if exp
        (setf (documentation exp t) new)
        new)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Particular CAS expansions
;;;

(define-cas-expander the (type place &environment env)
  "(cas (the y x) o n) = (cas x (the y o) (the y n))"
  (multiple-value-bind (vars vals old new cas read)
      (get-cas-expansion place env)
    (values vars vals old new
            `(let ((,old (the ,type ,old))
                   (,new (the ,type ,new)))
               ,cas)
            `(the ,type ,read))))

(define-cas-expander car (cons)
  (let ((old (gensym "OLD")) (new (gensym "NEW"))
        (ctemp (gensym "CONS")) (ctemp2 (gensym "CHECKED-CONS")))
    (values (list ctemp ctemp2)
            ;; We type check ahead of time so we don't have to do it on every
            ;; iteration in ATOMIC-UPDATE and suchlike.
            (list cons `(if (consp ,ctemp)
                            ,ctemp
                            (error 'type-error :datum ,ctemp
                                   :expected-type 'cons)))
            old new
            `(core::cas-car ,ctemp2 ,old ,new)
            `(car ,ctemp))))

(define-cas-expander cdr (cons)
  (let ((old (gensym "OLD")) (new (gensym "NEW"))
        (ctemp (gensym "CONS")) (ctemp2 (gensym "CHECKED-CONS")))
    (values (list ctemp ctemp2)
            (list cons `(if (consp ,ctemp)
                            ,ctemp
                            (error 'type-error :datum ,ctemp
                                               :expected-type 'cons)))
            old new
            `(core::cas-cdr ,ctemp2 ,old ,new)
            `(car ,ctemp))))

(define-cas-expander first (cons &environment env)
  (get-cas-expansion `(car ,cons) env))
(define-cas-expander rest (cons &environment env)
  (get-cas-expansion `(cdr ,cons) env))

(define-cas-expander svref (vector index)
  (let ((old (gensym "OLD")) (new (gensym "NEW"))
        (itemp (gensym "INDEX"))
        (vtemp1 (gensym "VECTOR")) (vtemp2 (gensym "VECTOR")))
    (values (list vtemp1 itemp vtemp2)
            (list vector index
                  `(if (simple-vector-p ,vtemp1)
                       ,vtemp1
                       (error 'type-error :datum ,vtemp1
                                          :expected-type 'simple-vector)))
            old new
            `(core::acas ,vtemp2 ,itemp ,old ,new t t t)
            ;; FIXME:
            ;; :: is a hack so that the bclasp reader doesn't complain.
            `(cleavir-primop::aref ,vtemp2 ,itemp t t t))))

(define-cas-expander symbol-plist (symbol)
  (let ((old (gensym "OLD")) (new (gensym "NEW"))
        (stemp (gensym "SYMBOL")))
    (values (list stemp) (list symbol) old new
            `(core:cas-symbol-plist ,stemp ,old ,new)
            `(symbol-plist ,stemp))))

(define-cas-expander clos:standard-instance-access (instance location)
  "The requirements of the normal STANDARD-INSTANCE-ACCESS writer
must be met, including that the slot has allocation :instance, and is
bound before the operation.
If there is a CHANGE-CLASS concurrent with this operation the
consequences are not defined."
  (let ((old (gensym "OLD")) (new (gensym "NEW"))
        (itemp (gensym "INSTANCE")) (ltemp (gensym "LOCATION")))
    (values (list itemp ltemp) (list instance location) old new
            `(core::instance-cas ,itemp ,ltemp ,old ,new)
            `(core:instance-ref ,itemp ,ltemp))))

;;; FIXME: (cas slot-value-using-class) would be a better name
;;; and make the define-cas-expander unnecessary.
;;; And we could expose it for customization.
(defgeneric cas-slot-value-using-class (old new class object slotd)
  (:argument-precedence-order class object slotd old new))

(defmethod cas-slot-value-using-class
    (old new
     (class core:std-class) object
     (slotd clos:standard-effective-slot-definition))
  (let ((loc (clos:slot-definition-location slotd)))
    (ecase (clos:slot-definition-allocation slotd)
      ((:instance) (core::instance-cas object loc old new))
      ((:class) (core::cas-car loc old new)))))
(defmethod cas-slot-value-using-class
    (old new (class built-in-class) object slotd)
  (error "Cannot modify slots of object with built-in-class"))

(define-cas-expander clos:slot-value-using-class (class instance slotd)
  "Same requirements as STANDARD-INSTANCE-ACCESS, except the slot can
have allocation :class.
Also, methods on SLOT-VALUE-USING-CLASS, SLOT-BOUNDP-USING-CLASS, and
(SETF SLOT-VALUE-USING-CLASS) are ignored (not invoked).
In the future, this may be customizable with a generic function."
  (default-cas-expansion-aux
   'clos:slot-value-using-class 'cas-slot-value-using-class
   (list class instance slotd)))

;;; Largely copied from slot-value.
;;; FIXME: Ditto above comment about CAS functions.
;;; FIXME: It would be nice to define these in CLOS, actually.
(defun cas-slot-value (old new object slot-name)
  (let* ((class (class-of object))
         (location-table (clos::class-location-table class)))
    (if location-table
        (let ((location (gethash slot-name location-table)))
          (if location
              (core::instance-cas object location old new)
              (values (slot-missing class object slot-name
                                    'cas (list old new)))))
        (let ((slotd (find slot-name (clos:class-slots class)
                           :key #'clos:slot-definition-name)))
          (if slotd
              (cas (clos:slot-value-using-class class object slotd)
                   old new)
              (values (slot-missing class object slot-name
                                    'cas (list old new))))))))

(define-cas-expander slot-value (object slot-name)
  "See SLOT-VALUE-USING-CLASS documentation for constraints.
If no slot with the given SLOT-NAME exists, SLOT-MISSING will be called,
with operation = mp:cas, and new-value a list of OLD and NEW.
If SLOT-MISSING returns, its primary value is returned."
  (default-cas-expansion-aux
   'slot-value 'cas-slot-value (list object slot-name)))
