(in-package :mediabox-png)

(defun get-channel-count ()
  (ecase (color-type *png-object*)
    (:truecolour 3)
    (:truecolour-alpha 4)
    (:indexed-colour 1)
    (:greyscale-alpha 2)
    (:greyscale 1)))

(defun get-sample-bytes ()
  (max 1 (/ (bit-depth *png-object*) 8)))

(defun get-pixel-bytes ()
  (* (get-sample-bytes) (get-channel-count)))

(defun get-scanline-bytes (width)
  (ceiling (* (bit-depth *png-object*)
              (get-channel-count)
              width)
           8))

(defun get-image-bytes ()
  (with-slots (width height) *png-object*
    (+ height (* height (get-scanline-bytes width)))))

(define-constant +filter-type-none+ 0)
(define-constant +filter-type-sub+ 1)
(define-constant +filter-type-up+ 2)
(define-constant +filter-type-average+ 3)
(define-constant +filter-type-paeth+ 4)

(defun allocate-image-data ()
  (with-slots (width height color-type bit-depth) *png-object*
    (make-array (case color-type
                  ((:truecolour :indexed-colour) `(,height ,width 3))
                  (:truecolour-alpha `(,height ,width 4))
                  (:greyscale-alpha `(,height ,width 2))
                  (:greyscale `(,height ,width)))
                :element-type (ecase bit-depth
                                ((1 2 4 8) 'ub8)
                                (16 'ub16)))))

(declaim (inline unfilter-sub))
(defun unfilter-sub (x data start pixel-bytes)
  (declare (ub8a1d data)
           (ub8 pixel-bytes)
           (ub32 x)
           (fixnum start)
           (optimize speed))
  (if (>= x pixel-bytes)
      (aref data (+ start (- x pixel-bytes)))
      0))

(declaim (inline unfilter-up))
(defun unfilter-up (x y data start-up)
  (declare (ub8a1d data)
           (ub32 x y)
           (fixnum start-up)
           (optimize speed))
  (if (zerop y)
      0
      (aref data (+ x start-up))))

(declaim (inline unfilter-average))
(defun unfilter-average (x y data start start-up pixel-bytes)
  (declare (ub8a1d data)
           (ub32 x y)
           (fixnum start start-up)
           (ub8 pixel-bytes)
           (optimize speed))
  (let ((a (unfilter-sub x data start pixel-bytes))
        (b (unfilter-up x y data start-up)))
    (declare (ub8 a b))
    (floor (+ a b) 2)))

(declaim (inline unfilter-paeth))
(defun unfilter-paeth (x y data start-left start-up pixel-bytes)
  (declare (ub8a1d data)
           (ub32 x y)
           (fixnum start-left start-up)
           (ub8 pixel-bytes)
           (optimize speed))
  (let* ((a (unfilter-sub x data start-left pixel-bytes))
         (b (unfilter-up x y data start-up))
         (c (if (plusp y)
                (unfilter-sub x data start-up pixel-bytes)
                0))
         (p (- (+ a b) c))
         (pa (abs (- p a)))
         (pb (abs (- p b)))
         (pc (abs (- p c))))
    (cond ((and (<= pa pb) (<= pa pc)) a)
          ((<= pb pc) b)
          (t c))))

(declaim (inline unfilter-byte))
(defun unfilter-byte (filter x y data start start-up pixel-bytes)
  (ecase filter
    (#.+filter-type-none+ 0)
    (#.+filter-type-sub+ (unfilter-sub x data start pixel-bytes))
    (#.+filter-type-up+ (unfilter-up x y data start-up))
    (#.+filter-type-average+
     (unfilter-average x y data start start-up pixel-bytes))
    (#.+filter-type-paeth+
     (unfilter-paeth x y data start start-up pixel-bytes))))

(defun unfilter (data width height start)
  (declare (ub32 width height)
           (fixnum start)
           (ub8a1d data))
  (loop :with pixel-bytes = (get-pixel-bytes)
        :with scanline-bytes fixnum = (get-scanline-bytes width)
        :with row-bytes = (1+ scanline-bytes)
        :for y :below height
        :for in-start :from start :by row-bytes
        :for left-start :from start :by scanline-bytes
        :for up-start :from (- start scanline-bytes) :by scanline-bytes
        :for filter = (aref data in-start)
        :do (loop :for xs fixnum :from (1+ in-start)
                  :for xo fixnum :from left-start
                  :for x fixnum :below scanline-bytes
                  :for sample = (aref data xs)
                  :for out = (unfilter-byte filter x y data left-start up-start
                                            pixel-bytes)
                  :do (setf (aref data xo)
                            (ldb (byte 8 0) (+ sample out))))))

(defun decode ()
  (let ((data (data *png-object*)))
    (with-slots (width height bit-depth interlace-method) *png-object*
      (declare (ub8a1d data))
      (setf (data *png-object*) (allocate-image-data))
      (if (eql interlace-method :null)
          (unfilter data width height 0)
          (setf data (deinterlace-adam7 data)))
      (assert (and (typep bit-depth 'ub8)
                   (member bit-depth '(1 2 4 8 16))))
      (let ((image-data (data *png-object*)))
        (if (= bit-depth 16)
            (locally (declare (ub16a image-data))
              (loop :for d :below (array-total-size image-data)
                    :for s :below (array-total-size data) :by 2
                    :for v :of-type ub16
                      = (locally (declare (optimize (safety 0)))
                          (dpb (aref data s) (byte 8 8)
                               (aref data (1+ s))))
                    :do (locally (declare (optimize (safety 0)))
                          (setf (row-major-aref image-data d) v))))
            (locally (declare (ub8a image-data))
              (loop :for d :below (array-total-size image-data)
                    :for s :below (array-total-size data)
                    :do (setf (row-major-aref image-data d)
                              (aref data s)))))))
    *png-object*))
