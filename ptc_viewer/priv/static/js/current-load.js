export async function commitCurrentLoad(token, { isCurrent, load, commit }) {
  if (!isCurrent(token)) return false;

  const value = await load();
  if (!isCurrent(token)) return false;

  commit(value);
  return true;
}
