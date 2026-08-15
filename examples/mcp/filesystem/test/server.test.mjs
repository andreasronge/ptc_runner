import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { tmpdir } from 'node:os'
import test from 'node:test'

const here = dirname(fileURLToPath(import.meta.url))
const SERVER = join(here, '..', 'dist', 'server.js')
const FIXTURE = join(here, 'fixture')

const PROTOCOL = '2026-07-28'
const SNAPSHOT_PREFIX = 'ptc-runner-filesystem-'

/**
 * Drives the built bundle over real stdio, the same way PtcRunner will.
 *
 * Testing the bundle rather than the TypeScript source keeps the artifact that
 * actually ships under test — a passing source build with a stale `dist` would
 * otherwise look green.
 */
function startServer(args) {
  const child = spawn(process.execPath, [SERVER, ...args], { stdio: ['pipe', 'pipe', 'pipe'] })
  let stdout = ''
  let stderr = ''
  const waiters = new Map()

  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    stdout += chunk

    for (let newline = stdout.indexOf('\n'); newline !== -1; newline = stdout.indexOf('\n')) {
      const line = stdout.slice(0, newline)
      stdout = stdout.slice(newline + 1)
      if (line.trim() === '') continue

      const message = JSON.parse(line)
      const waiter = waiters.get(message.id)
      if (waiter) {
        waiters.delete(message.id)
        waiter(message)
      }
    }
  })

  child.stderr.setEncoding('utf8')
  child.stderr.on('data', (chunk) => {
    stderr += chunk
  })

  let nextId = 0

  return {
    child,
    stderr: () => stderr,
    request(method, params = {}) {
      nextId += 1
      const id = nextId

      const payload = {
        jsonrpc: '2.0',
        id,
        method,
        params: {
          ...params,
          _meta: {
            'io.modelcontextprotocol/protocolVersion': PROTOCOL,
            'io.modelcontextprotocol/clientInfo': { name: 'conformance', version: '0' },
            'io.modelcontextprotocol/clientCapabilities': {},
          },
        },
      }

      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`timed out awaiting ${method}`)), 15_000)
        waiters.set(id, (message) => {
          clearTimeout(timer)
          resolve(message)
        })
        child.stdin.write(`${JSON.stringify(payload)}\n`)
      })
    },
    async close() {
      child.stdin.end()
      await new Promise((resolve) => child.once('exit', resolve))
    },
  }
}

async function withServer(args, body) {
  const server = startServer(args)
  try {
    await body(server)
  } finally {
    await server.close()
  }
}

const INCLUDE_LIB = ['--root', FIXTURE, '--include', 'lib/**']

function structured(response) {
  assert.equal(response.error, undefined, JSON.stringify(response.error))
  return response.result.structuredContent
}

async function call(server, name, args = {}) {
  return structured(await server.request('tools/call', { name, arguments: args }))
}

async function collect(server, name, args = {}) {
  const items = []
  let cursor
  let pages = 0

  do {
    const result = await call(server, name, { ...args, ...(cursor === undefined ? {} : { cursor }) })
    assert.deepEqual(Object.keys(result).sort(), ['items', 'next_cursor', 'snapshot_hash'])
    items.push(...result.items)
    cursor = result.next_cursor ?? undefined
    pages += 1
    assert.ok(pages < 10_000, 'cursor traversal must make progress')
  } while (cursor !== undefined)

  return items
}

async function withGeneratedServer(files, body) {
  const root = mkdtempSync(join(tmpdir(), 'ptc-filesystem-test-'))
  try {
    for (const [path, contents] of Object.entries(files)) {
      mkdirSync(dirname(join(root, path)), { recursive: true })
      writeFileSync(join(root, path), contents)
    }
    await withServer(['--root', root, '--include', '**'], (server) => body(server, root))
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}

function waitForSnapshot(createdBefore) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 15_000
    const timer = setInterval(() => {
      const created = readdirSync(tmpdir()).find(
        (name) => name.startsWith(SNAPSHOT_PREFIX) && !createdBefore.has(name),
      )
      if (created !== undefined) {
        clearInterval(timer)
        resolve(join(tmpdir(), created))
      } else if (Date.now() >= deadline) {
        clearInterval(timer)
        reject(new Error('timed out awaiting private snapshot creation'))
      }
    }, 1)
  })
}

test('advertises exactly the five read-only tools', async () => {
  await withServer(INCLUDE_LIB, async (server) => {
    const response = await server.request('tools/list')
    const names = response.result.tools.map((tool) => tool.name).sort()

    assert.deepEqual(names, [
      'list_directory',
      'read_text_file',
      'search_files',
      'search_text',
      'snapshot_info',
    ])

    for (const tool of response.result.tools) {
      assert.equal(tool.annotations.readOnlyHint, true, `${tool.name} must be read-only`)
    }
  })
})

test('inclusion selects only matching files', async () => {
  await withServer(INCLUDE_LIB, async (server) => {
    const listing = await call(server, 'search_files', { query: '.ex' })
    const paths = listing.items.map((item) => item.path)

    assert.ok(paths.includes('lib/alpha.ex'))
    assert.ok(paths.includes('lib/beta.ex'))
  })
})

test('a path outside the include rules is never inventoried', async () => {
  await withServer(INCLUDE_LIB, async (server) => {
    const listing = await call(server, 'search_files', { query: 'creds' })
    assert.deepEqual(listing.items, [])

    const search = await call(server, 'search_text', { query: 'must-not-appear' })
    assert.deepEqual(search.items, [], 'excluded content must not be searchable')

    const read = await server.request('tools/call', {
      name: 'read_text_file',
      arguments: { path: 'secrets/creds.env' },
    })
    assert.ok(read.result.isError || read.error, 'excluded file must not be readable')
  })
})

test('exclusion narrows an include', async () => {
  await withServer([...INCLUDE_LIB, '--exclude', 'lib/beta.ex'], async (server) => {
    const listing = await call(server, 'search_files', { query: 'beta' })
    assert.deepEqual(listing.items, [])
  })
})

test('capture requires at least one include and defaults to nothing', async () => {
  const server = startServer(['--root', FIXTURE])
  const code = await new Promise((resolve) => server.child.once('exit', resolve))

  assert.notEqual(code, 0, 'a server with no include rules must refuse to start')
  assert.match(server.stderr(), /include/i)
})

test('configured file and total byte ceilings fail closed without snapshot orphans', async () => {
  for (const { files, args } of [
    { files: { 'large.txt': '12345' }, args: ['--max-file-bytes', '4'] },
    { files: { 'one.txt': '123', 'two.txt': '456' }, args: ['--max-total-bytes', '5'] },
  ]) {
    const root = mkdtempSync(join(tmpdir(), 'ptc-filesystem-limit-test-'))
    const createdBefore = new Set(readdirSync(tmpdir()).filter((name) => name.startsWith(SNAPSHOT_PREFIX)))
    try {
      for (const [path, contents] of Object.entries(files)) writeFileSync(join(root, path), contents)
      const server = startServer(['--root', root, '--include', '**', ...args])
      const code = await new Promise((resolve) => server.child.once('exit', resolve))

      assert.equal(code, 64)
      assert.match(server.stderr(), /snapshot byte limit exceeded/)
      const createdAfter = readdirSync(tmpdir()).filter(
        (name) => name.startsWith(SNAPSHOT_PREFIX) && !createdBefore.has(name),
      )
      assert.deepEqual(createdAfter, [], 'failed captures must remove private snapshot bytes')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }
})

test('traversal, absolute paths, and NUL are rejected', async () => {
  await withServer(INCLUDE_LIB, async (server) => {
    for (const path of ['../package.json', '/etc/hostname', 'lib/../../escape', 'lib\u0000.ex']) {
      const response = await server.request('tools/call', {
        name: 'read_text_file',
        arguments: { path },
      })
      assert.ok(response.result?.isError || response.error, `${path} must be rejected`)
    }
  })
})

test('symbolic links are not followed', async () => {
  await withServer(INCLUDE_LIB, async (server) => {
    const listing = await call(server, 'search_files', { query: 'escape' })
    assert.deepEqual(listing.items, [], 'a symlink inside the root must not enter the snapshot')
  })
})

test('non-UTF-8 files are not captured and UTF-8 is preserved', async () => {
  await withServer(INCLUDE_LIB, async (server) => {
    const binary = await call(server, 'search_files', { query: 'binary' })
    assert.deepEqual(binary.items, [], 'invalid UTF-8 must not be captured')

    const read = await call(server, 'read_text_file', { path: 'lib/utf8.ex' })
    assert.equal(read.items.map((item) => item.text).join(''), 'café unicode\n')
  })
})

test('listings are ordered and paginate through an opaque cursor', async () => {
  await withServer(INCLUDE_LIB, async (server) => {
    const first = await call(server, 'search_files', { query: '.ex', limit: 1 })
    assert.equal(first.items.length, 1)
    assert.ok(first.next_cursor, 'a partial page must carry a cursor')

    const second = await call(server, 'search_files', { query: '.ex', limit: 1, cursor: first.next_cursor })
    assert.equal(second.items.length, 1)
    assert.notDeepEqual(first.items, second.items)

    const ordered = [first.items[0].path, second.items[0].path]
    assert.deepEqual([...ordered].sort(), ordered, 'pages must follow sorted order')
  })
})

test('cursors are bound to the snapshot, tool, and normalized query', async () => {
  let foreign
  await withServer(INCLUDE_LIB, async (server) => {
    foreign = (await call(server, 'search_files', { query: '.ex', limit: 1 })).next_cursor
  })

  await withServer([...INCLUDE_LIB, '--exclude', 'lib/beta.ex'], async (server) => {
    const response = await server.request('tools/call', {
      name: 'search_files',
      arguments: { query: '.ex', cursor: foreign },
    })
    assert.ok(response.result?.isError || response.error, 'a foreign cursor must not resume')
  })

  await withServer(INCLUDE_LIB, async (server) => {
    const cursor = (await call(server, 'search_files', { query: '.ex', limit: 1 })).next_cursor

    for (const [name, args] of [
      ['search_files', { query: 'alpha', cursor }],
      ['read_text_file', { path: 'lib/alpha.ex', cursor }],
    ]) {
      const response = await server.request('tools/call', { name, arguments: args })
      assert.ok(response.result?.isError || response.error, `${name} must reject a cursor from another scope`)
    }

    const tampered = `${cursor.slice(0, -1)}${cursor.endsWith('a') ? 'b' : 'a'}`
    const response = await server.request('tools/call', {
      name: 'search_files',
      arguments: { query: '.ex', cursor: tampered },
    })
    assert.ok(response.result?.isError || response.error, 'a modified cursor must be rejected')
  })
})

test('read_text_file uses the common cursor envelope', async () => {
  await withServer(INCLUDE_LIB, async (server) => {
    const whole = await collect(server, 'read_text_file', { path: 'lib/alpha.ex', limit: 1 })
    assert.equal(whole.map((item) => item.text).join(''), 'alpha line one\nalpha line two\n')
    assert.equal(whole[0].byte_offset, 0)
  })
})

test('a file above the former 1 MiB ceiling reconstructs exactly across UTF-8 pages', async () => {
  const text = `${'x'.repeat(1_100_000)}é${'y'.repeat(100_000)}\n`

  await withGeneratedServer({ 'huge.txt': text }, async (server) => {
    const chunks = await collect(server, 'read_text_file', { path: 'huge.txt', limit: 2 })
    assert.ok(chunks.length > 2)
    assert.equal(chunks.map((item) => item.text).join(''), text)
  })
})

test('tool reads stay bound to the startup snapshot after the source changes', async () => {
  await withGeneratedServer({ 'stable.txt': 'captured\n' }, async (server, root) => {
    await call(server, 'snapshot_info')
    writeFileSync(join(root, 'stable.txt'), 'changed\n')
    const chunks = await collect(server, 'read_text_file', { path: 'stable.txt' })
    assert.equal(chunks.map((item) => item.text).join(''), 'captured\n')
  })
})

test('search evidence carries path and line numbers', async () => {
  await withServer(INCLUDE_LIB, async (server) => {
    const search = await call(server, 'search_text', { query: 'needle' })
    assert.equal(search.items.length, 1)
    assert.equal(search.items[0].path, 'lib/beta.ex')
    assert.equal(search.items[0].line, 1)
  })
})

test('search_text traverses beyond the former 500-match ceiling', async () => {
  const text = Array.from({ length: 620 }, (_, index) => `needle ${index}\n`).join('')

  await withGeneratedServer({ 'many.txt': text }, async (server) => {
    const matches = await collect(server, 'search_text', { query: 'needle', limit: 37 })
    assert.equal(matches.length, 620)
    assert.deepEqual(matches.map((item) => item.line), Array.from({ length: 620 }, (_, index) => index + 1))
  })
})

test('search_text makes cursor progress through a huge sparse line', async () => {
  const text = `${'a'.repeat(600_000)}needle\n`

  await withGeneratedServer({ 'sparse.txt': text }, async (server) => {
    const first = await call(server, 'search_text', { query: 'needle', limit: 1 })
    assert.deepEqual(first.items, [])
    assert.ok(first.next_cursor, 'a scan budget stop must return a progress cursor')

    const matches = await collect(server, 'search_text', { query: 'needle', limit: 1 })
    assert.equal(matches.length, 1)
    assert.equal(matches[0].line, 1)
  })
})

test('escape-heavy pages fit below a 64 KiB decoded MCP result ceiling', async () => {
  const text = `${'\u0001'.repeat(40_000)}\n`

  await withGeneratedServer({ 'controls.txt': text }, async (server) => {
    let cursor
    do {
      const response = await server.request('tools/call', {
        name: 'read_text_file',
        arguments: { path: 'controls.txt', limit: 8, ...(cursor === undefined ? {} : { cursor }) },
      })
      assert.equal(response.error, undefined)
      assert.ok(Buffer.byteLength(JSON.stringify(response.result), 'utf8') < 64_000)
      cursor = response.result.structuredContent.next_cursor ?? undefined
    } while (cursor !== undefined)
  })
})

test('every data-bearing result carries the same snapshot hash', async () => {
  await withServer(INCLUDE_LIB, async (server) => {
    const info = await call(server, 'snapshot_info')
    assert.match(info.snapshot_hash, /^sha256:[0-9a-f]{64}$/)

    for (const [name, args] of [
      ['list_directory', {}],
      ['search_files', { query: '.ex' }],
      ['search_text', { query: 'alpha' }],
      ['read_text_file', { path: 'lib/alpha.ex' }],
    ]) {
      const result = await call(server, name, args)
      assert.equal(result.snapshot_hash, info.snapshot_hash, `${name} must cite the same snapshot`)
    }
  })
})

test('snapshot_info never discloses the host root', async () => {
  await withServer(INCLUDE_LIB, async (server) => {
    const info = await call(server, 'snapshot_info')
    const serialized = JSON.stringify(info)

    assert.ok(!serialized.includes(FIXTURE), 'the host root must not appear in a result')
    assert.ok(!serialized.includes('/home'), 'no absolute host path may appear in a result')
  })
})

test('errors are bounded text without stacktraces or host paths', async () => {
  await withServer(INCLUDE_LIB, async (server) => {
    const response = await server.request('tools/call', {
      name: 'read_text_file',
      arguments: { path: 'lib/missing.ex' },
    })

    const serialized = JSON.stringify(response)
    assert.ok(!serialized.includes('    at '), 'no stacktrace may reach the client')
    assert.ok(!serialized.includes(FIXTURE), 'no host path may reach the client')
  })
})

test('backing-store I/O failures return a fixed message without temporary paths', async () => {
  const root = mkdtempSync(join(tmpdir(), 'ptc-filesystem-io-test-'))
  const createdBefore = new Set(readdirSync(tmpdir()).filter((name) => name.startsWith(SNAPSHOT_PREFIX)))
  writeFileSync(join(root, 'stable.txt'), 'captured\n')
  const server = startServer(['--root', root, '--include', '**'])

  try {
    const snapshotPath = await waitForSnapshot(createdBefore)
    await call(server, 'snapshot_info')
    rmSync(snapshotPath, { recursive: true, force: true })

    const response = await server.request('tools/call', {
      name: 'read_text_file',
      arguments: { path: 'stable.txt' },
    })
    const serialized = JSON.stringify(response)
    assert.match(serialized, /snapshot backing store is unavailable/)
    assert.equal(serialized.includes(snapshotPath), false)
    assert.equal(serialized.includes(tmpdir()), false)
  } finally {
    await server.close()
    rmSync(root, { recursive: true, force: true })
  }
})

test('cancellation leaves the server usable', async () => {
  await withServer(INCLUDE_LIB, async (server) => {
    server.child.stdin.write(
      `${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: 999 } })}\n`,
    )

    const after = await call(server, 'snapshot_info')
    assert.match(after.snapshot_hash, /^sha256:/)
  })
})

test('closing stdin terminates the server cleanly', async () => {
  const server = startServer(INCLUDE_LIB)
  await call(server, 'snapshot_info')

  server.child.stdin.end()
  const code = await new Promise((resolve) => server.child.once('exit', resolve))

  assert.equal(code, 0, 'end of input must be an ordinary shutdown')
})

test('SIGTERM during startup removes the private disk snapshot', async () => {
  const root = mkdtempSync(join(tmpdir(), 'ptc-filesystem-signal-test-'))
  const createdBefore = new Set(readdirSync(tmpdir()).filter((name) => name.startsWith(SNAPSHOT_PREFIX)))
  writeFileSync(join(root, 'large.txt'), Buffer.alloc(64 * 1_024 * 1_024, 'x'))
  const server = startServer(['--root', root, '--include', '**'])

  try {
    const snapshotPath = await waitForSnapshot(createdBefore)
    const exited = new Promise((resolve) => server.child.once('exit', (code, signal) => resolve({ code, signal })))
    server.child.kill('SIGTERM')

    assert.deepEqual(await exited, { code: 0, signal: null })
    assert.equal(existsSync(snapshotPath), false, 'catchable termination must remove captured bytes')
  } finally {
    if (server.child.exitCode === null && server.child.signalCode === null) server.child.kill('SIGKILL')
    rmSync(root, { recursive: true, force: true })
  }
})

test('stdout carries protocol messages only', async () => {
  await withServer(INCLUDE_LIB, async (server) => {
    const response = await server.request('tools/list')
    assert.equal(response.jsonrpc, '2.0')
    assert.equal(server.stderr().includes('{"jsonrpc"'), false)
  })
})
