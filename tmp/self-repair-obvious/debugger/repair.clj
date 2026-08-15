(ns debug.repair "Host-gated component candidate checking." {:visibility :prompt})

(defn check-candidate
  "Run the real component materializer against one complete replacement. Returns accepted false with diagnostics or accepted true with verified hashes."
  {:signature "(candidate {target_environment :string, target_mission :string, component_id :string, base_source_hash :string, candidate_source :string}) -> :map"}
  [candidate]
  (cap/unwrap! (tool/repair-gate.check candidate)))
