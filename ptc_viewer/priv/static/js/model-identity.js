export function calledResolvedModels(metadata) {
  const models = [];
  const rows = Array.isArray(metadata?.llm_usage_by_model) ? metadata.llm_usage_by_model : [];
  for (const row of rows) {
    if (typeof row?.resolved_model !== 'string' || row.resolved_model === '') continue;
    if (!Number.isSafeInteger(row.calls) || row.calls <= 0) continue;
    if (!models.includes(row.resolved_model)) models.push(row.resolved_model);
  }
  return models;
}

export function modelResponseIdentity(assistant, metadata) {
  const alias = assistant?.content?.model;
  if (typeof alias !== 'string' || alias === '') return null;

  const connectors = Array.isArray(metadata?.connector_snapshots) ? metadata.connector_snapshots : [];
  for (const connector of connectors) {
    const declaration = connector?.declaration;
    const acquisition = connector?.acquisition;
    if (declaration?.source !== 'llm' || declaration?.name !== alias) continue;
    if (typeof acquisition?.resolved_model !== 'string' || acquisition.resolved_model === '') continue;
    return { alias, resolvedModel: acquisition.resolved_model };
  }

  return { alias, resolvedModel: null };
}

export function presentedAssistant(assistant, metadata) {
  const identity = modelResponseIdentity(assistant, metadata);
  if (!identity) return assistant;

  const content = { ...assistant.content };
  delete content.model;
  content.alias = identity.alias;
  if (identity.resolvedModel) content.resolved_model = identity.resolvedModel;
  return { ...assistant, content };
}
