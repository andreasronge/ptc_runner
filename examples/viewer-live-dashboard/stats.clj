(ns demo.stats "Pure mission helpers for the live-launch demo." {:visibility :prompt})

(defn summarize [xs]
  {"count" (count xs)
   "sum" (reduce + 0 xs)
   "max" (apply max xs)})
