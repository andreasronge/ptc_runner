const RETRY_DELAY_MS = 1500;

// Serializes every Runs catalog render behind a monotonically increasing
// generation. A fresh refresh invalidates both older responses and load-more
// controls rendered by an older generation.
export function createRunCatalog({
  fetchPage,
  renderPage,
  reportError,
  clearError,
  scheduleRetry = (callback, delay) => setTimeout(callback, delay),
  cancelRetry = handle => clearTimeout(handle)
}) {
  let generation = 0;
  let retryTimer = null;

  const clearScheduledRetry = () => {
    if (retryTimer !== null) cancelRetry(retryTimer);
    retryTimer = null;
  };

  const scheduleFreshRetry = failedGeneration => {
    clearScheduledRetry();
    retryTimer = scheduleRetry(() => {
      retryTimer = null;
      if (generation === failedGeneration) void refresh();
    }, RETRY_DELAY_MS);
  };

  const request = async (cursor, priorRuns, requestGeneration) => {
    try {
      const page = await fetchPage(cursor);
      if (generation !== requestGeneration) return true;

      clearScheduledRetry();
      renderPage(page, priorRuns, requestGeneration);
      clearError();
      return true;
    } catch (error) {
      if (generation !== requestGeneration) return true;

      reportError(error instanceof Error ? error.message : 'Canonical run listing is unavailable.');
      scheduleFreshRetry(requestGeneration);
      return false;
    }
  };

  const refresh = () => {
    clearScheduledRetry();
    generation += 1;
    return request(null, [], generation);
  };

  const loadMore = (cursor, priorRuns, renderedGeneration) => {
    if (!cursor || renderedGeneration !== generation) return Promise.resolve(false);
    return request(cursor, priorRuns, renderedGeneration);
  };

  return { refresh, loadMore };
}
