(ns history "Read canonical traces from the main gateway." {:visibility :prompt})

(defn runs {:effect :read} [args] (response/value (tool/history.runs args)))
(defn open {:effect :read} [args] (response/value (tool/history.open args)))
(defn read {:effect :read} [args] (response/value (tool/history.read args)))
(defn counters {:effect :read} [args] (response/value (tool/history.counters args)))
