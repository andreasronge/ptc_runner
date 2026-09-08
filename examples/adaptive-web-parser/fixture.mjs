import { createServer } from 'node:http'

export const expected = {
  '/quotes': [
    { text: 'Measure the change before changing the measure.', author: 'Ada North' },
    { text: 'A useful question leaves room for evidence.', author: 'Ben West' },
  ],
  '/held-out': [
    { text: 'Keep the observation separate from the guess.', author: 'Eli River' },
    { text: 'A repair earns trust through another test.', author: 'Gus Lake' },
  ],
}

function page(path) {
  const records = expected[path]
  if (!records) return null
  const cards = records
    .map(({ text, author }) =>
      path === '/held-out'
        ? `<article class="entry"><header><span class="speaker">${author}</span></header><section><p class="words">${text}</p></section></article>`
        : `<article class="entry"><p class="words">${text}</p><span class="speaker">${author}</span></article>`,
    )
    .join('')
  return `<!doctype html><html><head><title>Changing quotation board</title></head><body><nav><span class="speaker">Navigation editor</span></nav><main><h1>Quotations</h1>${cards}</main></body></html>`
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
