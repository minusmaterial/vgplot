;;;; vgplot.lisp

#|
    This library is an interface to the gnuplot utility.
    Copyright (C) 2013, 2014  Volker Sarodnick

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
|#

(in-package #:vgplot)

(defvar *debug* t)

(defclass plots ()
  ((plot-stream :initform (open-plot) :accessor plot-stream)
   (multiplot-p :initform nil :accessor multiplot-p)
   (tmp-file-list :initform nil :accessor tmp-file-list))
  (:documentation "Holding properties of the plot"))

(defun make-plot ()
  (make-instance 'plots))

(defun open-plot ()
  "Start gnuplot process and return stream to gnuplot"
  (do-execute "gnuplot" nil))

(defun read-no-hang (s)
  "Read from stream and return string (non blocking)"
  (sleep 0.01) ;; not perfect, better idea?
  (let ((chars))
    (do ((c (read-char-no-hang s)
            (read-char-no-hang s)))
        ((null c))
      (push c chars))
    (coerce (nreverse chars) 'string)))

(defun read-n-print-no-hang (s)
  "Read from stream and print directly (non blocking). Return read string"
  (princ (read-no-hang s)))

(defun vectorize (vals)
  "Coerce all sequences except strings to vectors"
  (mapcar #'(lambda (x) (if (stringp x)
                            x
                            (coerce x 'vector)))
          vals))

(defun parse-vals (vals)
  "Parse input values to plot and return grouped list: ((x y lbl-string) (x1 y1 lbl-string)...)"
  (cond
    ((stringp (third vals)) (cons (list (pop vals) (pop vals) (pop vals))
                                  (parse-vals vals)))
    ((stringp (second vals)) (cons (list (pop vals) nil (pop vals))
                                   (parse-vals vals)))
    ((second vals) (cons (list (pop vals) (pop vals) "")
                         (parse-vals vals)))
    (vals (list (list (first vals) nil ""))) ;; special case of plot val to index, i.e. only y exist
    (t nil)))

(defun parse-label (lbl)
  "Parse label string e.g. \"-k;label;\" and return key list (list :style style :color color :title title)."
  (let ((style "lines")
        (color "red")
        (title "")
        (start-title (or (search ";" lbl) -1)) ;; -1 because subseq jumps over first ;
        (end-title (or (search ";" lbl :from-end t) (length lbl))))
    (when (>= start-title end-title)
      ;; only one semicolon found, use the part after the first one as title
      (setf end-title (length lbl)))
    (setf title (subseq lbl (1+ start-title) end-title))
    (when (> start-title 0)
      (loop for c across (subseq lbl 0 start-title) do
           (ecase c
             (#\- (setf style "lines"))
             (#\. (setf style "dots"))
             (#\+ (setf style "points"))
             (#\o (setf style "circles"))
             (#\r (setf color "red"))
             (#\g (setf color "green"))
             (#\b (setf color "blue"))
             (#\c (setf color "cyan"))
             (#\k (setf color "black")))))
    (list :style style :color color :title title)))

(defun parse-floats (s sep)
  "Parse string s and return the found numbers separated by separator"
  (let ((c-list)
        (r-list))
    (loop for c across s do
         (cond
           ((eql c #\# ) (loop-finish)) ; rest of line is comment
           ((eql c #\ )) ; ignore space
           ((eql c #\	)) ; ignore tab
           ((eql c sep) (progn
                          (push (read-from-string (nreverse (coerce c-list 'string))) r-list)
                          (setf c-list nil)))
           (t (push c c-list))))
    ;; add also number after the last sep:
    (push (read-from-string (nreverse (coerce c-list 'string)) nil) r-list)
    (nreverse r-list)))

(defun del-tmp-files (tmp-file-list)
  "Delete files in tmp-file-list and return nil"
  (when tmp-file-list
    (loop for name in tmp-file-list do
         (when (probe-file name)
           (delete-file name))))
  nil)

(defun make-del-tmp-file-function (tmp-file-list)
  "Return a function that removes the files in tmp-file-list."
  #'(lambda ()
      (loop for name in tmp-file-list do
           (when (probe-file name)
             (delete-file name)))))

(defun add-del-tmp-files-to-exit-hook (tmp-file-list)
  "If possible, add delete of tmp files to exit hooks.
\(implemented on sbcl and clisp)"
  #+sbcl (push (make-del-tmp-file-function tmp-file-list) sb-ext:*exit-hooks*)
  #+clisp (push (make-del-tmp-file-function tmp-file-list) custom:*fini-hooks*)
  #-(or sbcl clisp) (declare (ignore tmp-file-list)))

(defun get-separator (s)
  "Return the used separator in data string
t   for whitespace \(standard separator in gnuplot)
c   separator character
nil comment line \(or empty line)"
  (let ((data-found nil)) ; to handle comment-only lines
    (loop for c across s do
         (cond 
           ((digit-char-p c) (setf data-found t))
           ((eql c #\#) (loop-finish))
           ;; ignore following characters
           ((eql c #\.))
           ((eql c #\e)) ; e could be inside a number in exponential form
           ((eql c #\E))
           ((eql c #\d)) ; even d could be inside a number...
           ((eql c #\D))
           ((eql c #\-))
           ((eql c #\+))
           ((eql c #\ ))
           ((eql c #\	))
           (t (return-from get-separator c))))
    (if data-found
        t ; there was data before EOL or comment but no other separator
        nil))) ; comment-only line

(defun count-data-columns (s &optional (separator))
  "Count data columns in strings like \"1 2 3 # comment\", seperators
could be a variable number of spaces, tabs or the optional separator"
  (let ((sep t) (num 0))
               (loop for c across s do
                    (cond
                      ((eql c #\# ) (return))
                      ((eql c (or separator #\	)) (setf sep t))
                      ((eql c #\	) (setf sep t))
                      ((eql c #\ ) (setf sep t))
                      (t (when sep
                           (incf num)
                           (setf sep nil)))))
               num))

(defun stairs (&rest vals)
  "Produce a stairstep plot.
vals could be: y                  plot y over its index
               x y                plot y = f(x)
               x y label-string   plot y = f(x) using label-string as label
               following parameters add curves to same plot e.g.:
               x y label x1 y1 label1 ...

For the syntax of label-string see documentation of plot command.

If you only want to prepare the sequences for later plot, see
function stairs-no-plot."
  (let ((par-list))
    (labels ((construct-plist (p-list pars)
               (cond
                 ((null pars)
                  (nreverse p-list))
                 ((stringp (first pars))
                  (push (first pars) p-list)
                  (construct-plist p-list (rest pars)))
                 ((= 1 (length pars))
                  (multiple-value-bind (x y) (values-list (stairs-no-plot
                                                           (first pars)))
                    (push x p-list)
                    (push y p-list)
                    (construct-plist p-list (rest pars))))
                 (t
                  (multiple-value-bind (x y) (values-list (stairs-no-plot
                                                           (first pars) (second pars)))
                    (push x p-list)
                    (push y p-list)
                    (construct-plist p-list (rest (rest pars))))))))
      (apply #'plot (construct-plist par-list (vectorize vals))))))

(defun stairs-no-plot (yx &optional y)
  "Prepare a stairstep plot, but don't actually plot it.
Return a list of 2 sequences, x and y, usable for the later plot.

If one argument is given use it as y sequence, there x are the indices.
If both arguments are given use yx as x and y is y.

If you want to plot the stairplot directly, see function stairs."
  (cond
    ((not y)
     (let* ((y (coerce yx 'vector))
            (len (length y))
            (x (range len)))
       (stairs-no-plot x y)))
    ((or (not (simple-vector-p yx)) (not (simple-vector-p y)))
     (stairs-no-plot (coerce yx 'vector) (coerce y 'vector)))
    (t (let*
           ((len (min (length yx) (length y)))
            (xx (make-array (1- (* 2 len))))
            (yy (make-array (1- (* 2 len))))
            (xi 0)
            (yi 0)
            (i 1))
    (if (= len 1)
        (list yx y)
        (progn
          ;; setup start
          ;; x0 y0
          ;;    y0
          (setf (svref xx xi) (svref yx 0))
          (setf (svref yy yi) (svref y 0))
          (setf (svref yy (incf yi)) (svref y 0))
          ;; main loop
          (loop for ii from 1 below (1- len) do
               (progn
                 (setf (svref xx (incf xi)) (svref yx i))
                 (setf (svref xx (incf xi)) (svref yx i))
                 (setf (svref yy (incf yi)) (svref y i))
                 (setf (svref yy (incf yi)) (svref y i))
                 (incf i)))
          ;; and finalize
          ;; xl
          ;; xl yl
          (setf (svref xx (incf xi)) (svref yx i))
          (setf (svref yy (incf yi)) (svref y i))
          (setf (svref xx (incf xi)) (svref yx i))
          (list xx yy)))))))

(let ((plot-list nil)       ; List holding not active plots
      (act-plot nil))       ; actual plot
  (defun format-plot (print? text &rest args)
    "Send a command directly to active gnuplot process, return gnuplots response
print also response to stdout if print? is true"
    (unless act-plot
      (setf act-plot (make-plot)))
    (apply #'format (plot-stream act-plot) text args)
    (fresh-line (plot-stream act-plot))
    (force-output (plot-stream act-plot))
    (if print?
        (read-n-print-no-hang (plot-stream act-plot))
        (read-no-hang (plot-stream act-plot))))
  (defun close-plot ()
    "Close connected gnuplot"
    (when act-plot
      (format (plot-stream act-plot) "quit~%")
      (force-output (plot-stream act-plot))
      (close (plot-stream act-plot))
      (del-tmp-files (tmp-file-list act-plot))
      (setf act-plot (pop plot-list))))
  (defun close-all-plots ()
    "Close all connected gnuplots"
    (close-plot)
    (when act-plot
      (close-all-plots)))
  (defun new-plot ()
    "Add a new plot window to a current one."
    (when act-plot
      (push act-plot plot-list)
      (setf act-plot (make-plot))))
  (defun plot (&rest vals)
    "Plot y = f(x) on active plot, create plot if needed.
vals could be: y                  plot y over its index
               y label-string     plot y over its index using label-string as label
               x y                plot y = f(x)
               x y label-string   plot y = f(x) using label-string as label
               following parameters add curves to same plot e.g.:
               x y label x1 y1 label1 ...
label:
A simple label in form of \"text\" is printed directly.

A label with added style commands: label in form \"styles;text;\":
styles can be (combinations possible):
   \"-\" lines
   \".\" dots
   \"+\" points
   \"o\" circles
   \"r\" red
   \"g\" green
   \"b\" blue
   \"c\" cyan
   \"k\" black

e.g.:
   (plot x y \"r+;red values;\") plots y = f(x) as red points with the
                                 label \"red values\"
"
    (if act-plot
        (setf (tmp-file-list act-plot) (del-tmp-files (tmp-file-list act-plot)))
        (setf act-plot (make-plot)))
    (let ((val-l (parse-vals (vectorize vals)))
          (plt-cmd nil))
      (loop for pl in val-l do
           (push (with-output-to-temporary-file (tmp-file-stream :template "vgplot-%.dat")
                   (if (null (second pl)) ;; special case plotting to index
                       (map nil #'(lambda (a) (format tmp-file-stream "~,,,,,,'eE~%" a)) (first pl))
                       (map nil #'(lambda (a b) (format tmp-file-stream "~,,,,,,'eE ~,,,,,,'eE~%" a b))
                            (first pl) (second pl))))
                 (tmp-file-list act-plot))
           (setf plt-cmd (concatenate 'string (if plt-cmd
                                                  (concatenate 'string plt-cmd ", ")
                                                  "plot ")
                                      (destructuring-bind (&key style color title) (parse-label (third pl))
                                        (format nil "\"~A\" with ~A linecolor rgb \"~A\" title \"~A\" "
                                              (first (tmp-file-list act-plot)) style color title)))))
      (format (plot-stream act-plot) "set grid~%")
      (format (plot-stream act-plot) "~A~%" plt-cmd)
      (force-output (plot-stream act-plot))
      (add-del-tmp-files-to-exit-hook (tmp-file-list act-plot)))
    (read-n-print-no-hang (plot-stream act-plot)))
  (defun bar (&rest vals)
    "Create a bar plot y = f(x) on active plot, create plot if needed.
vals could be: y                  plot y over its index
               y label-string     plot y over its index using label-string as label
               x y                plot y = f(x)
               x y label-string   plot y = f(x) using label-string as label
               following parameters add curves to same plot e.g.:
               x y label x1 y1 label1 ...
label:
A simple label in form of \"text\" is printed directly.

A label with added style commands: label in form \"styles;text;\":
styles can be following colors:
   \"r\" red
   \"g\" green
   \"b\" blue
   \"c\" cyan
   \"k\" black

e.g.:
   (bar x y \"r;red values;\") bar plot y = f(x) with red boxes and label \"red values\"
"
    (if act-plot
        (setf (tmp-file-list act-plot) (del-tmp-files (tmp-file-list act-plot)))
        (setf act-plot (make-plot)))
    (let ((val-l (parse-vals (vectorize vals)))
          (plt-cmd nil))
      (loop for pl in val-l do
           (push (with-output-to-temporary-file (tmp-file-stream :template "vgplot-%.dat")
                   (if (null (second pl))  ;; special case plotting to index
                       (map nil #'(lambda (a) (format tmp-file-stream "~,,,,,,'eE~%" a)) (first pl))
                       (map nil #'(lambda (a b) (format tmp-file-stream "~,,,,,,'eE ~,,,,,,'eE~%" a b))
                            (first pl) (second pl))))
                 (tmp-file-list act-plot))
           (setf plt-cmd (concatenate 'string (if plt-cmd
                                                  (concatenate 'string plt-cmd ", ")
                                                  "plot ")
                                      (destructuring-bind (&key style color title) (parse-label (third pl))
                                        (declare (ignore style))
                                        (format nil "\"~A\" with boxes linecolor rgb \"~A\" title \"~A\" "
                                                (first (tmp-file-list act-plot)) color title)))))
      (format (plot-stream act-plot) "set grid~%")
      (format (plot-stream act-plot) "set boxwidth 0.8 absolute~%")
      (format (plot-stream act-plot) "set style fs solid~%")
      (format (plot-stream act-plot) "~A~%" plt-cmd)
      (force-output (plot-stream act-plot))
      (add-del-tmp-files-to-exit-hook (tmp-file-list act-plot)))
    (read-n-print-no-hang (plot-stream act-plot)))
  (defun subplot (rows cols index)
    "(Experimental command, not all features work correctly yet.)
Set up a plot grid with rows by cols subwindows and use location index for next plot command.
The plot index runs row-wise.  First all the columns in a row are
filled and then the next row is filled.

For example, a plot with 2 rows by 3 cols will have following plot indices:

          +-----+-----+-----+
          |  1  |  2  |  3  |
          +-----+-----+-----+
          |  4  |  5  |  6  |
          +-----+-----+-----+

Observe, gnuplot doesn't allow interactive mouse commands in multiplot mode.
"
    (when (or (< index 1)
              (> index (* rows cols)))
      (progn
        (format t "Index out of bound~%")
        (return-from subplot nil)))
    (let ((x-size (coerce (/ 1 cols) 'float))
          (y-size (coerce (/ 1 rows) 'float))
          (x-orig)
          (y-orig))
      (setf x-orig (* x-size (mod (- index 1) cols)))
      (setf y-orig (- 1 (* y-size (+ 1 (floor (/ (- index 1) cols))))))
      ;;
      (unless act-plot
        (setf act-plot (make-plot)))
      (unless (multiplot-p act-plot)
        (format (plot-stream act-plot) "set multiplot~%")
        (setf (multiplot-p act-plot) t))
      (read-n-print-no-hang (plot-stream act-plot))
      (format (plot-stream act-plot) "set size ~A,~A~%" x-size y-size)
      (read-n-print-no-hang (plot-stream act-plot))
      (format (plot-stream act-plot) "set origin ~A,~A~%" x-orig y-orig)
      (read-n-print-no-hang (plot-stream act-plot))
      (force-output (plot-stream act-plot))
      (read-n-print-no-hang (plot-stream act-plot))))
  (defun plot-file (data-file)
    "Plot data-file directly, datafile must hold columns separated by spaces, tabs or commas
\(other separators may work), use with-lines style"
    (let ((c-num)
          (separator)
          (cmd-string (format nil "plot \"~A\" using ($1) with lines" data-file)))
      (with-open-file (in data-file :direction :input)
        (setf separator (do ((c (get-separator (read-line in))
                                (get-separator (read-line in))))
                            ((or c) c))) ; comment lines return nil, drop them
        ;; use only lines with more than zero columns, i.e. drop comment lines
        (setf c-num (do ((num (count-data-columns (read-line in) separator)
                              (count-data-columns (read-line in) separator)))
                        ((> num 0) num))))
      (loop for i from 2 to c-num do
         (setf cmd-string (concatenate 'string cmd-string
                                       (format nil ", \"~A\" using ($~A) with lines" data-file i))))
      (unless act-plot
        (setf act-plot (make-plot)))
      (format (plot-stream act-plot) "set grid~%")
      (when (characterp separator)
        (format (plot-stream act-plot) "set datafile separator \"~A\"~%" separator))
      (format (plot-stream act-plot) "~A~%" cmd-string)
      (when (characterp separator)
        (format (plot-stream act-plot) "set datafile separator~%")) ; reset separator
      (force-output (plot-stream act-plot)))
    (read-n-print-no-hang (plot-stream act-plot)))
)

;; figure is an alias to new-plot (because it's used that way in octave/matlab)
(setf (symbol-function 'figure) #'new-plot)

(defun replot ()
  "Send the replot command to gnuplot, i.e. apply all recent changes in the plot."
  (format-plot *debug* "clear~%") ;; maybe only for multiplot needed?
  (format-plot *debug* "replot"))

(defun grid (style &key (replot t))
  "Add grid to plot if style t, otherwise remove grid.
If key parameter replot is true (default) run an additional replot thereafter."
  (if style
      (format-plot *debug* "set grid")
      (format-plot *debug* "unset grid"))
  (when replot
    (replot)))

(defun title (str &key (replot t))
  "Add title str to plot. If key parameter replot is true (default)
run an additional replot thereafter."
  (format-plot *debug* "set title \"~A\"" str)
  (format-plot *debug* "show title")
  (when replot
    (replot)))

(defun xlabel (str &key (replot t))
  "Add x axis label. If key parameter replot is true (default)
run an additional replot thereafter."
  (format-plot *debug* "set xlabel \"~A\"" str)
  (format-plot *debug* "show xlabel")
  (when replot
    (replot)))

(defun ylabel (str &key (replot t))
  "Add y axis label. If key parameter replot is true (default)
run an additional replot thereafter."
  (format-plot *debug* "set ylabel \"~A\"" str)
  (format-plot *debug* "show ylabel")
  (when replot
    (replot)))

(defun text (x y text-string &key (tag) (horizontalalignment "left") (rotation 0) (font) (fontsize))
  "Add text label text-string at position x,y
optional:
   :tag nr              label number specifying which text label to modify
                        (integer you get when running (text-show-label))
   :horizontalalignment \"left\"(default), \"center\" or \"right\"
   :rotation degree     rotate text by this angle in degrees (default 0) [if the terminal can do so]
   :font \"<name>\" use this font, e.g. :font \"Times\" [terminal depending, gnuplot help
                        recommends: http://fontconfig.org/fontconfig-user.html for more information]
   :fontsize nr

Observe, it could alter the font of the labels (aka legend or key in
gnuplot terms) if you change font or fontsize of a text field. To
explicitly chose fontsize (or font) for the label you could use:

\(format-plot t \"set key font \\\",10\\\"\"\)
\(replot\)
"
  (let ((cmd-str "set label ")
        (tag-str (and tag (format nil " ~a " tag)))
        (text-str (format nil " \"~a\" " text-string))
        (at-str (format nil " at ~a,~a " x y))
        (al-str (format nil " ~a " horizontalalignment))
        (rot-str (format nil " rotate by ~a " rotation))
        (font-str (and (or font fontsize)
                       (format nil " font \"~a,~a\" " (or font "") (or fontsize "")))))
    (format-plot *debug* (concatenate 'string cmd-str tag-str text-str at-str al-str rot-str font-str)))
  (replot))

(defun text-show-label ()
  "Show text labels. This is useful to get the tag number for (text-delete)"
  (format-plot t "show label"))

(defun text-delete (&rest tags)
  "Delete text labels specified by tags.
A tag is the number of the text label you get when running (text-show-label)."
  (loop for tag in tags do
       (format-plot *debug* "unset label ~a" tag))
  (replot))

(defun parse-axis (axis-s)
  "Parse gnuplot string e.g.
\"	set xrange [ * : 4.00000 ] noreverse nowriteback  # (currently [1.00000:] )\"
and return range as a list of floats, e.g. '(1.0 3.0)"
  ;;                                       number before colon
  (cl-ppcre:register-groups-bind (min) ("([-\\d.]+) ?:" axis-s)
    ;;                                     number efter colon
    (cl-ppcre:register-groups-bind (max) (": ?([-\\d.]+)" axis-s)
      (mapcar (lambda (s) (float (read-from-string s))) (list min max)))))

(defun axis (&optional limit-list)
  "Set axis to limit-list and return actual limit-list, limit-list could be:
'(xmin xmax) or '(xmin xmax ymin ymax),
values can be:
  a number: use it as the corresponding limit
  nil:      do not change this limit
  t:        autoscale this limit
without limit-list do return current axis."
  (unless (null limit-list)
    ;; gather actual limits
    (let* ((is-limit (append (parse-axis (format-plot *debug* "show xrange"))
                             (parse-axis (format-plot *debug* "show yrange"))))
           (limit (loop for i to 3 collect
                       (let ((val (nth i limit-list)))
                         (cond ((numberp val) (format nil "~,,,,,,'eE" val))
                               ((or val) "*")            ; autoscale
                               (t (nth i is-limit))))))) ; same value again
      (format-plot *debug* "set xrange [~a:~a]" (first limit) (second limit))
      (format-plot *debug* "set yrange [~a:~a]" (third limit) (fourth limit))
      (replot)))
  ;; and return current axis settings
  (append (parse-axis (format-plot *debug* "show xrange"))
          (parse-axis (format-plot *debug* "show yrange"))))

(defun load-data-file (fname)
  "Return a list of found vectors (one vector for one column) in data file fname 
\(e.g. csv-file)"
  (let ((c-num)
        (separator)
        (val-list))
    (with-open-file (in fname :direction :input)
      (setf separator (do ((c (get-separator (read-line in))
                              (get-separator (read-line in))))
                          ((or c) c))) ; comment lines return nil, drop them
      ;; use only lines with more than zero columns, i.e. drop comment lines
      (setf c-num (do ((num (count-data-columns (read-line in) separator)
                            (count-data-columns (read-line in) separator)))
                      ((> num 0) num))))
    (dotimes (i c-num)
      (push (make-array 100 :element-type 'number :adjustable t :fill-pointer 0) val-list))

    (with-open-file (in fname :direction :input)
      (let ((float-list))
        (do ((line (read-line in nil 'eof)
                   (read-line in nil 'eof)))
            ((eql line 'eof))
          (setf float-list (parse-floats line separator))
          (and (first float-list) ; ignore comment lines
               (mapcar #'vector-push-extend float-list val-list)))))
    val-list))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; exported utilities

(defun range (a &optional b (step 1))
  "Return vector of values in a certain range:
\(range limit\) return natural numbers below limit
\(range start limit\) return ordinary numbers starting with start below limit
\(range start limit step\) return numbers starting with start, successively adding step untill reaching limit \(excluding\)"
  (let ((len) (vec))
    (unless b
      (setf b a
            a 0))
    (setf len (ceiling (/ (- b a) step)))
    (setf vec (make-array len))
    (loop for i below len do
         (setf (svref vec i) a)
         (incf a step))
    vec))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; other utilities

(defun make-doc ()
  "Update README and html documentation. Load cl-api before use."
  (with-open-file (stream "README" :direction :output :if-exists :supersede)
    (write-string (documentation (find-package :vgplot) 't) stream))
  ;; dependency to cl-api not defined in asd-file because I don't want getting
  ;; this dependency (make-doc is internal and should only be used by developer)
  ;; ignore that :api-gen is probably not loaded in standard case
  (ignore-errors (funcall (find-symbol "API-GEN" 'cl-api) :vgplot "doc/vgplot.html")))
