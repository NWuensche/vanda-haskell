#!/usr/bin/gnuplot


# assumed columns in statistics.csv file:
# 1         2          3      4       5               6            7           8           9                 10           11            12                    13                     14                15                        16                   17                18                19
# CPU time  iteration  rules  states  initial states  merge pairs  beam width  beam index  saturation steps  rule merges  state merges  initial-state merges  log₂ likelihood delta  likelihood delta  log₂ evaluation of merge  evaluation of merge  heuristic chosen  heuristic lowest  total saturation steps


set datafile separator ','
set key autotitle columnhead


# we just want to set GPVAL_DATA_?_M??
set terminal dumb
plot 'statistics.csv' using 2:8 with dots
iteration_min = GPVAL_DATA_X_MIN
iteration_max = GPVAL_DATA_X_MAX
beamindex_min = GPVAL_DATA_Y_MIN
beamindex_max = GPVAL_DATA_Y_MAX


set terminal pdf noenhanced size 29.7cm, 21.0cm
set output 'statistics.pdf'

set multiplot title GPVAL_PWD layout 3, 2 columnsfirst downwards

set key tmargin left

set tics out
set ytics nomirror
set y2tics

set lmargin 10
set rmargin 10

set xrange  [iteration_min : iteration_max]
set x2range [iteration_min : iteration_max]


### First column ###

delta_v(x) = (vD = x - old_v, old_v = x, vD)
old_v=0
plot 'statistics.csv' using 2:(delta_v($1)) with points pointtype 7 pointsize 0.5 title 'Δ CPU time',  \
     '' using 2:1 with points pointtype 7 pointsize 0.1 axes x1y2


plot '' using 2:3 with points pointtype 5 pointsize 0.1


plot '' using 2:4 with points pointtype 5 pointsize 0.1, '' using 2:5 with points pointtype 5 pointsize 0.1 axes x1y2


### Second column ###

accumulate(x) = (accumulationSum = accumulationSum + x)
accumulationSum = 0
# set yrange [-10 : 0]
plot '' using 2:13 with points pointtype 7 pointsize 0.5,  \
     '' using 2:(accumulate($13)) with points pointtype 7 pointsize 0.1 axes x1y2 title 'accumulated log₂ likelihood delta'


set yrange  [beamindex_min : beamindex_max]
set y2range [beamindex_min : beamindex_max]
plot '' using 2:6 with histeps,  \
     '' using 2:7 with histeps,  \
     '' using 2:8 with points linecolor 'blue' pointtype 5 pointsize 0.1


# http://psy.swansea.ac.uk/staff/carter/gnuplot/gnuplot_frequency.htm
bin_width = 0.1;
bin_number(x) = floor(x/bin_width)
rounded(x) = bin_width * ( bin_number(x) + 0.5 )
set boxwidth bin_width
set xrange  [0 : 1]
set x2range [0 : 1]
set xtics 0, bin_width
set yrange  [iteration_min : iteration_max]
set y2range [iteration_min : iteration_max]
plot '' using (rounded(($8 - 1) / $7)):(1) smooth frequency with boxes fillstyle transparent solid 0.25 title 'histogram for relative beam index',  \
     '' using (($8 - 1) / $7):2 with points pointtype 5 pointsize 0.1 axes x1y2 title 'beam index relative to beam width (transposed)'


### End ###

unset multiplot
