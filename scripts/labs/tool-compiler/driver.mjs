import { readFile, rename, writeFile } from "node:fs/promises";

export function validRecipe(recipe) {
  return ["container", "text_selector", "author_selector"].every(
    (key) => typeof recipe?.[key] === "string" && recipe[key].length > 0,
  );
}

export function recordsAreCorrect(want, records) {
  if (!Array.isArray(records) || records.length !== want.length) return false;
  return want.every((row) =>
    records.some(
      (got) =>
        String(got?.text ?? "").trim() === row.text &&
        String(got?.author ?? "").trim() === row.author,
    ),
  );
}

export function verificationPassed(expected, rows) {
  return Object.keys(expected).every((path) => {
    const row = rows.find((candidate) => candidate.page === path);
    return row?.status === "ok" && row.correct === true;
  });
}

export function accountedTotal(rows, key) {
  if (rows.some((row) => row[key] == null)) return null;
  return rows.reduce((sum, row) => sum + row[key], 0);
}

export async function promoteCandidate({
  acceptedManifestPath,
  candidate,
  compilationSucceeded,
  expected,
  verificationRows,
}) {
  if (!compilationSucceeded) {
    return { promoted: false, reason: "compilation failed" };
  }
  if (!validRecipe(candidate)) {
    return { promoted: false, reason: "candidate is invalid" };
  }
  if (!verificationPassed(expected, verificationRows)) {
    return { promoted: false, reason: "independent verification failed" };
  }

  const manifest = JSON.parse(await readFile(acceptedManifestPath, "utf8"));
  manifest.missions.default.data = { recipe: candidate };
  const pendingPath = `${acceptedManifestPath}.pending`;
  await writeFile(pendingPath, `${JSON.stringify(manifest, null, 2)}\n`);
  await rename(pendingPath, acceptedManifestPath);
  return { promoted: true };
}
