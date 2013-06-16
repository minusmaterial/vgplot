;;;; package.lisp

(defpackage #:vgplot
  (:use :cl)
  (:import-from :ltk :do-execute)
  (:import-from :cl-fad :with-output-to-temporary-file)
  (:documentation "# vgplot

This common lisp library is an interface to the gnuplot plotting
utility.

The intention of the API is to be similar to some of the plot commands
of octave or matlab.

## Usage

(asdf:load-system :vgplot)

(vgplot:plot '(1 2 3) '(0 -2 17))

For examples run the demo function in vgplot.lisp:

(vgplot:demo)

and see API documentation in doc/vgplot.html

## License

Copyright (C) 2013 Volker Sarodnick

GNU General Public License
")
  (:export :axis
           :close-all-plots
           :close-plot
           :demo
           :figure
           :format-plot
           :grid
           :new-plot
           :plot
           :plot-file
           :replot
           :range))
