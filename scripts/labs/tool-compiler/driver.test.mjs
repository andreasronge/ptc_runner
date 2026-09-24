import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { accountedTotal, promoteCandidate } from "./driver.mjs";
import { startFixture } from "./fixture.mjs";

const expected = {
  "/learn": [{ text: "Learn", author: "Ada" }],
  "/accept": [{ text: "Accept", author: "Ben" }],
};
const candidate = {
  container: "article",
  text_selector: "p",
  author_selector: "span",
};

async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "tool-compiler-test-"));
  const path = join(directory, "ptc.json");
  const manifest = {
    missions: { default: { data: { recipe: { old: true } } } },
  };
  const original = `${JSON.stringify(manifest, null, 2)}\n`;
  await writeFile(path, original);
  return { path, original };
}

function rows(overrides = {}) {
  return Object.entries(expected).map(([page]) => ({
    page,
    status: "ok",
    correct: true,
    ...overrides[page],
  }));
}

test("does not promote a structurally valid but wrong candidate", async () => {
  const accepted = await fixture();
  const result = await promoteCandidate({
    acceptedManifestPath: accepted.path,
    candidate,
    compilationSucceeded: true,
    expected,
    verificationRows: rows({ "/learn": { correct: false } }),
  });
  assert.equal(result.promoted, false);
  assert.equal(await readFile(accepted.path, "utf8"), accepted.original);
});

test("does not promote candidate output from a failed compiler run", async () => {
  const accepted = await fixture();
  const result = await promoteCandidate({
    acceptedManifestPath: accepted.path,
    candidate,
    compilationSucceeded: false,
    expected,
    verificationRows: rows(),
  });
  assert.equal(result.reason, "compilation failed");
  assert.equal(await readFile(accepted.path, "utf8"), accepted.original);
});

test("does not promote when an independent verification run fails", async () => {
  const accepted = await fixture();
  const result = await promoteCandidate({
    acceptedManifestPath: accepted.path,
    candidate,
    compilationSucceeded: true,
    expected,
    verificationRows: rows({ "/accept": { status: "failed", correct: false } }),
  });
  assert.equal(result.reason, "independent verification failed");
  assert.equal(await readFile(accepted.path, "utf8"), accepted.original);
});

test("promotes only after every independent check passes", async () => {
  const accepted = await fixture();
  const result = await promoteCandidate({
    acceptedManifestPath: accepted.path,
    candidate,
    compilationSucceeded: true,
    expected,
    verificationRows: rows(),
  });
  assert.equal(result.promoted, true);
  const manifest = JSON.parse(await readFile(accepted.path, "utf8"));
  assert.deepEqual(manifest.missions.default.data.recipe, candidate);
});

test("does not understate totals when any result is unaccounted", () => {
  assert.equal(accountedTotal([{ cost: 12 }, { cost: null }], "cost"), null);
  assert.equal(accountedTotal([{ cost: 12 }, { cost: 8 }], "cost"), 20);
});

test("keeps the acceptance page unavailable until independent verification", async () => {
  const web = await startFixture({ acceptanceEnabled: false });
  try {
    assert.equal((await fetch(`${web.origin}/acceptance`)).status, 404);
    assert.equal((await fetch(`${web.origin}/acceptance?/quotes`)).status, 404);
    assert.equal((await fetch(`${web.origin}/acceptance#/quotes`)).status, 404);
    web.enableAcceptance();
    assert.equal((await fetch(`${web.origin}/acceptance`)).status, 200);
  } finally {
    await web.close();
  }
});
