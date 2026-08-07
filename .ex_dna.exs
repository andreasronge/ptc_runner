%{
  # Alias groups repeated across sibling modules are not duplicated logic, and
  # `use`/`import` blocks are boilerplate the gate should never fail on.
  excluded_macros: [:alias, :import, :require, :use],
  min_mass: 30
}
