set encoding utf8
set termoption noenhanced
set title "*virtual ground test: opamp gain = 1000"
set xlabel "s"
set ylabel "V"
set grid
unset logscale x 
set xrange [0.000000e+00:5.000000e-02]
unset logscale y 
set yrange [-1.097635e-01:1.097635e-01]
#set xtics 1
#set x2tics 1
#set ytics 1
#set y2tics 1
set format y "%g"
set format x "%g"
plot 'v(in).data' using 1:2 with lines lw 1 title "v(out)",\
'v(in).data' using 3:4 with lines lw 1 title "v(inn)"
set terminal push
set terminal png noenhanced
set out 'v(in).png'
replot
set term pop
replot
