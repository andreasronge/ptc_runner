export function attestedResolvedModels(metadata) {
  const models = [];
  const connectors = Array.isArray(metadata?.connector_snapshots) ? metadata.connector_snapshots : [];
  for (const connector of connectors) {
    const acquisition = connector?.acquisition;
    if (typeof acquisition?.resolved_model !== 'string' || acquisition.resolved_model === '') continue;
    if (!models.includes(acquisition.resolved_model)) models.push(acquisition.resolved_model);
  }
  return models;
}

export function modelResponseIdentity(turn, metadata) {
  const alias = turn?.response?.value?.model ?? turn?.assistant?.content?.model;
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
  if (!identity || !assistant?.content || typeof assistant.content !== 'object' ||
      Array.isArray(assistant.content) || assistant.content.model !== identity.alias) return assistant;

  const content = { ...assistant.content };
  delete content.model;
  content.alias = identity.alias;
  if (identity.resolvedModel) content.resolved_model = identity.resolvedModel;
  return { ...assistant, content };
}
