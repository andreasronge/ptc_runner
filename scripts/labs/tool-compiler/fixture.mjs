import { createServer } from 'node:http'

// Search sees two DOM shapes. Acceptance adds a third, unseen shape, while a
// decoy `.speaker` in the nav punishes the first selector that happens to match.
const filler = Array.from({ length: 40 }, (_, index) =>
  `Row ${index + 1}: archival note, no quotation, retained for bulk only.`,
)

export const expected = {
  '/quotes': [
    { text: 'Measure the change before changing the measure.', author: 'Ada North' },
    { text: 'A useful question leaves room for evidence.', author: 'Ben West' },
  ],
  '/validation': [
    { text: 'Keep the observation separate from the guess.', author: 'Eli River' },
    { text: 'A repair earns trust through another test.', author: 'Gus Lake' },
  ],
  '/acceptance': [
    { text: 'An unseen shape keeps selection honest.', author: 'Mia Stone' },
    { text: 'Promotion follows proof, not promise.', author: 'Ned Grove' },
  ],
  '/ledger': [
    { text: 'Bulk hides the signal until someone counts it.', author: 'Ida Frost' },
    { text: 'A long page is not a complicated one.', author: 'Job Marsh' },
    { text: 'Read less by choosing better.', author: 'Kit Vale' },
  ],
}

function card(path, { text, author }) {
  if (path === '/acceptance') {
    return `<article class="entry"><div class="copy"><p class="words">${text}</p></div><footer><strong>By</strong><span class="speaker">${author}</span></footer></article>`
  }
  return path === '/validation'
    ? `<article class="entry"><header><span class="speaker">${author}</span></header><section><p class="words">${text}</p></section></article>`
    : `<article class="entry"><p class="words">${text}</p><span class="speaker">${author}</span></article>`
}

function page(path) {
  const records = expected[path]
  if (!records) return null
  const cards = records.map((record) => card(path, record)).join('')
  const bulk =
    path === '/ledger'
      ? filler.map((line) => `<p class="note">${line}</p>`).join('')
      : ''
  return `<!doctype html><html><head><title>Quotation board</title></head><body><nav><span class="speaker">Navigation editor</span></nav><main><h1>Quotations</h1>${bulk}${cards}</main></body></html>`
}

export async function startFixture() {
  const server = createServer((request, response) => {
    const path = new URL(request.url, 'http://fixture.invalid').pathname
    const html = page(path)
    response.writeHead(html ? 200 : 404, {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
    })
    response.end(html ?? 'Not found')
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  return {
    origin: `http://127.0.0.1:${server.address().port}`,
    close: () =>
      new Promise((resolve, reject) => {
        server.closeAllConnections()
        server.close((error) => (error ? reject(error) : resolve()))
      }),
  }
}
