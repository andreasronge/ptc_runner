(ns temperature "Temperature conversion API." {:visibility :prompt})

(defn celsius->fahrenheit
  "Convert Celsius to Fahrenheit."
  {:signature "(celsius :float) -> {fahrenheit :float}"}
  [celsius]
  {"fahrenheit" (+ (* celsius 1.8) 32)})
