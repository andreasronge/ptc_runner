(ns demo.greet "Second pure mission for the live-launch demo." {:visibility :prompt})

(defn hello [name]
  {"greeting" (str "Hello, " name "!")
   "length" (count name)})
