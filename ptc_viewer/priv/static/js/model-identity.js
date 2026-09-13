export function calledResolvedModels(metadata) {
  const rows = Array.isArray(metadata?.llm_usage_by_model) ? metadata.llm_usage_by_model : [];
  return [...new Set(rows
    .filter(row => row?.calls > 0 && typeof row?.resolved_model === 'string' && row.resolved_model !== '')
    .map(row => row.resolved_model))];
}

export function modelResponseIdentity(turn, metadata) {
  const alias = turn?.response?.value?.model;
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

export function presentedAssistant(turn, metadata) {
  const assistant = turn?.assistant;
  const identity = modelResponseIdentity(turn, metadata);
  // ConversationMessage uses the envelope itself only when no content or
  // tool_calls field exists. Otherwise the content belongs to the model.
  const value = turn?.response?.value;
  if (!value || Object.hasOwn(value, 'content') || Object.hasOwn(value, 'tool_calls')) return assistant;
  if (!identity || !assistant?.content || typeof assistant.content !== 'object' ||
      Array.isArray(assistant.content) || assistant.content.model !== identity.alias) return assistant;

  const content = { ...assistant.content };
  delete content.model;
  content.alias = identity.alias;
  if (identity.resolvedModel) content.configured_resolved_model = identity.resolvedModel;
  return { ...assistant, content };
}
