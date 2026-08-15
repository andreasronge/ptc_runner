import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto'
import { closeSync, openSync, readSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { McpServer, fromJsonSchema, type JsonSchemaType } from '@modelcontextprotocol/server'
import { serveStdio } from '@modelcontextprotocol/server/stdio'

import { capture, normalizeRelative, type Snapshot, type SnapshotFile } from './snapshot.js'

const MAX_PAGE = 200
const MAX_READ_CHUNKS = 8
const READ_CHUNK_BYTES = 2_048
const SEARCH_BUFFER_BYTES = 8_192
const SEARCH_SCAN_BYTES = 262_144
const MAX_QUERY_BYTES = 256
const MAX_EVIDENCE_BYTES = 1_024
const MAX_LOGICAL_RESULT_BYTES = 48_000

interface Arguments {
  root: string
  include: string[]
  exclude: string[]
  maxFileBytes?: number
  maxTotalBytes?: number
}

type Position = number | SearchPosition

interface SearchPosition {
  file: number
  offset: number
  lineStart: number
  line: number
  matched: boolean
}

interface Candidate<T> {
  item: T
  position: Position
}

/** A bounded, actionable failure. Never carries a stacktrace or a host path. */
class ToolError extends Error {}

const cursorKeys = new WeakMap<Snapshot, Buffer>()

function cursorKey(snapshot: Snapshot): Buffer {
  const existing = cursorKeys.get(snapshot)
  if (existing) return existing
  const created = randomBytes(32)
  cursorKeys.set(snapshot, created)
  return created
}

function parseArguments(argv: readonly string[]): Arguments {
  const parsed: Arguments = { root: '', include: [], exclude: [] }
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index]
    const value = argv[index + 1]
    if (value === undefined) throw new Error(`missing value for ${flag}`)
    if (flag === '--root') parsed.root = value
    else if (flag === '--include') parsed.include.push(value)
    else if (flag === '--exclude') parsed.exclude.push(value)
    else if (flag === '--max-file-bytes') parsed.maxFileBytes = positiveIntegerOption(value, flag)
    else if (flag === '--max-total-bytes') parsed.maxTotalBytes = positiveIntegerOption(value, flag)
    else throw new Error(`unknown option ${flag}`)
    index += 1
  }
  if (parsed.root === '') throw new Error('--root is required')
  return parsed
}

function positiveIntegerOption(value: string, flag: string): number {
  if (!/^[1-9][0-9]*$/.test(value)) throw new Error(`${flag} must be a positive integer`)
  const parsed = Number(value)
  if (!Number.isSafeInteger(parsed)) throw new Error(`${flag} is too large`)
  return parsed
}

function scopeOf(tool: string, arguments_: Record<string, unknown>): string {
  return createHash('sha256').update(tool).update('\0').update(JSON.stringify(arguments_)).digest('hex')
}

function encodeCursor(snapshot: Snapshot, scope: string, position: Position): string {
  const payload = Buffer.from(JSON.stringify({ v: 1, h: snapshot.hash, s: scope, p: position }), 'utf8').toString(
    'base64url',
  )
  const signature = createHmac('sha256', cursorKey(snapshot)).update(payload, 'ascii').digest('base64url')
  return `${payload}.${signature}`
}

function decodeCursor(
  snapshot: Snapshot,
  scope: string,
  cursor: unknown,
  validPosition: (position: unknown) => position is Position,
  first: Position,
): Position {
  if (cursor === undefined) return first
  if (typeof cursor !== 'string' || cursor === '' || cursor.length > 4_096) {
    throw new ToolError('cursor is not valid')
  }

  try {
    const parts = cursor.split('.')
    if (parts.length !== 2 || parts.some((part) => !/^[A-Za-z0-9_-]+$/.test(part))) {
      throw new ToolError('cursor is not valid')
    }
    const [payload, encodedSignature] = parts as [string, string]
    const signature = Buffer.from(encodedSignature, 'base64url')
    const expected = createHmac('sha256', cursorKey(snapshot)).update(payload, 'ascii').digest()
    if (signature.length !== expected.length || !timingSafeEqual(signature, expected)) {
      throw new ToolError('cursor is not valid')
    }

    const decoded = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')) as Record<string, unknown>
    if (
      decoded.v !== 1 ||
      decoded.h !== snapshot.hash ||
      decoded.s !== scope ||
      !validPosition(decoded.p) ||
      Object.keys(decoded).sort().join(',') !== 'h,p,s,v'
    ) {
      throw new ToolError('cursor was issued for a different traversal')
    }
    return decoded.p
  } catch (error) {
    if (error instanceof ToolError) throw error
    throw new ToolError('cursor is not valid')
  }
}

function offsetPosition(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
}

function searchPosition(snapshot: Snapshot, value: unknown): value is SearchPosition {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false
  const position = value as Record<string, unknown>
  return (
    Object.keys(position).sort().join(',') === 'file,line,lineStart,matched,offset' &&
    Number.isSafeInteger(position.file) &&
    (position.file as number) >= 0 &&
    (position.file as number) < snapshot.paths.length &&
    Number.isSafeInteger(position.offset) &&
    (position.offset as number) >= 0 &&
    Number.isSafeInteger(position.lineStart) &&
    (position.lineStart as number) >= 0 &&
    (position.lineStart as number) <= (position.offset as number) &&
    Number.isSafeInteger(position.line) &&
    (position.line as number) >= 1 &&
    typeof position.matched === 'boolean'
  )
}

function boundedPage(limit: unknown, maximum = MAX_PAGE): number {
  if (limit === undefined) return maximum
  if (typeof limit !== 'number' || !Number.isSafeInteger(limit) || limit < 1) {
    throw new ToolError('limit must be a positive integer')
  }
  return Math.min(limit, maximum)
}

function requirePath(value: unknown, field: string): string {
  if (typeof value !== 'string') throw new ToolError(`${field} must be a string`)
  const normalized = normalizeRelative(value)
  if (normalized === null) throw new ToolError(`${field} is not a relative path inside the snapshot`)
  return normalized
}

function requireQuery(value: unknown): string {
  if (typeof value !== 'string' || value === '') throw new ToolError('query must be a non-empty string')
  const bytes = Buffer.byteLength(value, 'utf8')
  if (bytes > MAX_QUERY_BYTES || value.includes('\n') || value.includes('\r')) {
    throw new ToolError('query must be one line of at most 256 UTF-8 bytes')
  }
  return value
}

const HASH = { type: 'string' as const }
function pagedOutput(itemProperties: Record<string, unknown>): JsonSchemaType {
  return {
    type: 'object',
    properties: {
      snapshot_hash: HASH,
      items: {
        type: 'array',
        items: { type: 'object', properties: itemProperties, additionalProperties: false },
      },
    },
    // PtcRunner's deliberately small frozen schema subset has no nullable
    // union. The runtime value always includes next_cursor, including null at
    // completion; descriptions document it while this validator permits it as
    // the sole forward-compatible extra field.
    required: ['snapshot_hash', 'items'],
    additionalProperties: true,
  } as JsonSchemaType
}

function pageValue<T>(
  snapshot: Snapshot,
  scope: string,
  start: Position,
  candidates: readonly Candidate<T>[],
  finalPosition: Position | null,
) {
  const kept = [...candidates]
  let next = finalPosition

  while (true) {
    const value = {
      snapshot_hash: snapshot.hash,
      items: kept.map((candidate) => candidate.item),
      next_cursor: next === null ? null : encodeCursor(snapshot, scope, next),
    }
    if (logicalResultBytes(value) <= MAX_LOGICAL_RESULT_BYTES) return value
    const removed = kept.pop()
    if (removed === undefined) throw new ToolError('one result item exceeds the result ceiling')
    next = kept.length === 0 ? start : kept[kept.length - 1]!.position
  }
}

function arrayPage<T>(snapshot: Snapshot, scope: string, items: readonly T[], offset: number, limit: number) {
  if (offset > items.length) throw new ToolError('cursor position is not valid')
  const end = Math.min(offset + limit, items.length)
  const candidates = items.slice(offset, end).map((item, index) => ({ item, position: offset + index + 1 }))
  return pageValue(snapshot, scope, offset, candidates, end < items.length ? end : null)
}

export function createServer(snapshot: Snapshot): McpServer {
  const server = new McpServer(
    { name: 'ptc-runner-filesystem-sample', version: '0.2.0' },
    {
      instructions:
        'Read-only access to an immutable disk-backed snapshot captured at startup. Paths are relative; source files are never re-read.',
    },
  )
  const readOnly = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
  const meta = { 'io.modelcontextprotocol/cacheScope': 'private' as const }

  server.registerTool(
    'list_directory',
    {
      title: 'List directory',
      description: 'Sorted entries directly under a relative prefix. Follow next_cursor until null.',
      annotations: readOnly,
      _meta: meta,
      outputSchema: fromJsonSchema<Record<string, unknown>>(
        pagedOutput({ name: { type: 'string' }, kind: { type: 'string' }, path: { type: 'string' } }),
      ),
      inputSchema: fromJsonSchema<Record<string, unknown>>({
        type: 'object',
        properties: { path: { type: 'string' }, cursor: { type: 'string' }, limit: { type: 'integer', minimum: 1 } },
        additionalProperties: false,
      }),
    },
    async (args: Record<string, unknown>) => {
      const prefix = args.path === undefined ? '' : requirePath(args.path, 'path')
      const traversalScope = scopeOf('list_directory', { path: prefix })
      const offset = decodeCursor(snapshot, traversalScope, args.cursor, offsetPosition, 0) as number
      const pathScope = prefix === '' ? '' : `${prefix}/`
      const entries = new Map<string, 'file' | 'directory'>()
      for (const path of snapshot.paths) {
        if (!path.startsWith(pathScope)) continue
        const remainder = path.slice(pathScope.length)
        if (remainder === '') continue
        const separator = remainder.indexOf('/')
        if (separator === -1) entries.set(remainder, 'file')
        else entries.set(remainder.slice(0, separator), 'directory')
      }
      const items = [...entries.entries()]
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([name, kind]) => ({ name, kind, path: pathScope + name }))
      return structured(arrayPage(snapshot, traversalScope, items, offset, boundedPage(args.limit)))
    },
  )

  server.registerTool(
    'search_files',
    {
      title: 'Search files',
      description: 'Sorted snapshot paths containing a literal substring. Follow next_cursor until null.',
      annotations: readOnly,
      _meta: meta,
      outputSchema: fromJsonSchema<Record<string, unknown>>(pagedOutput({ path: { type: 'string' } })),
      inputSchema: fromJsonSchema<Record<string, unknown>>({
        type: 'object',
        properties: { query: { type: 'string', minLength: 1 }, cursor: { type: 'string' }, limit: { type: 'integer', minimum: 1 } },
        required: ['query'],
        additionalProperties: false,
      }),
    },
    async (args: Record<string, unknown>) => {
      const query = requireQuery(args.query)
      const traversalScope = scopeOf('search_files', { query })
      const offset = decodeCursor(snapshot, traversalScope, args.cursor, offsetPosition, 0) as number
      const items = snapshot.paths.filter((path) => path.includes(query)).map((path) => ({ path }))
      return structured(arrayPage(snapshot, traversalScope, items, offset, boundedPage(args.limit)))
    },
  )

  server.registerTool(
    'search_text',
    {
      title: 'Search text',
      description: 'Streaming literal line search. Empty progress pages may carry next_cursor; follow it until null.',
      annotations: readOnly,
      _meta: meta,
      outputSchema: fromJsonSchema<Record<string, unknown>>(
        pagedOutput({ path: { type: 'string' }, line: { type: 'integer' }, text: { type: 'string' } }),
      ),
      inputSchema: fromJsonSchema<Record<string, unknown>>({
        type: 'object',
        properties: {
          query: { type: 'string', minLength: 1 },
          path: { type: 'string' },
          cursor: { type: 'string' },
          limit: { type: 'integer', minimum: 1 },
        },
        required: ['query'],
        additionalProperties: false,
      }),
    },
    async (args: Record<string, unknown>) => {
      const query = requireQuery(args.query)
      const path = args.path === undefined ? '' : requirePath(args.path, 'path')
      const traversalScope = scopeOf('search_text', { path, query })
      const first: SearchPosition = { file: 0, offset: 0, lineStart: 0, line: 1, matched: false }
      const start = decodeCursor(
        snapshot,
        traversalScope,
        args.cursor,
        (value): value is SearchPosition => searchPosition(snapshot, value),
        first,
      ) as SearchPosition
      const result = snapshotIO(() => scanText(snapshot, path, query, start, boundedPage(args.limit)))
      return structured(pageValue(snapshot, traversalScope, start, result.candidates, result.next))
    },
  )

  server.registerTool(
    'read_text_file',
    {
      title: 'Read text file',
      description: 'Bounded exact UTF-8 chunks. Concatenate item text and follow next_cursor until null.',
      annotations: readOnly,
      _meta: meta,
      outputSchema: fromJsonSchema<Record<string, unknown>>(
        pagedOutput({ byte_offset: { type: 'integer' }, text: { type: 'string' } }),
      ),
      inputSchema: fromJsonSchema<Record<string, unknown>>({
        type: 'object',
        properties: {
          path: { type: 'string', minLength: 1 },
          cursor: { type: 'string' },
          limit: { type: 'integer', minimum: 1, maximum: MAX_READ_CHUNKS },
        },
        required: ['path'],
        additionalProperties: false,
      }),
    },
    async (args: Record<string, unknown>) => {
      const path = requirePath(args.path, 'path')
      const file = snapshot.files.get(path)
      if (!file) throw new ToolError('path is not part of the snapshot')
      const traversalScope = scopeOf('read_text_file', { path })
      const offset = decodeCursor(snapshot, traversalScope, args.cursor, offsetPosition, 0) as number
      return structured(
        snapshotIO(() => readPage(snapshot, file, traversalScope, offset, boundedPage(args.limit, MAX_READ_CHUNKS))),
      )
    },
  )

  server.registerTool(
    'snapshot_info',
    {
      title: 'Snapshot info',
      description: 'Content hash and bounded inventory statistics for the captured snapshot.',
      annotations: readOnly,
      _meta: meta,
      outputSchema: fromJsonSchema<Record<string, unknown>>({
        type: 'object',
        properties: {
          snapshot_hash: HASH,
          file_count: { type: 'integer' },
          total_bytes: { type: 'integer' },
          truncated: {
            type: 'object',
            properties: { files: { type: 'boolean' }, depth: { type: 'boolean' } },
            additionalProperties: false,
          },
        },
        required: ['snapshot_hash', 'file_count', 'total_bytes', 'truncated'],
        additionalProperties: false,
      }),
      inputSchema: fromJsonSchema<Record<string, unknown>>({ type: 'object', properties: {}, additionalProperties: false }),
    },
    async () =>
      structured({
        snapshot_hash: snapshot.hash,
        file_count: snapshot.paths.length,
        total_bytes: snapshot.totalBytes,
        truncated: snapshot.truncated,
      }),
  )

  return server
}

function readPage(snapshot: Snapshot, file: SnapshotFile, scope: string, offset: number, limit: number) {
  if (offset > file.bytes) throw new ToolError('cursor position is not valid')
  const descriptor = openSync(file.snapshotPath, 'r')
  const candidates: Array<Candidate<{ byte_offset: number; text: string }>> = []
  let position = offset
  try {
    while (position < file.bytes && candidates.length < limit) {
      const requested = Math.min(READ_CHUNK_BYTES, file.bytes - position)
      const buffer = Buffer.allocUnsafe(requested)
      const count = readSync(descriptor, buffer, 0, requested, position)
      if (count <= 0) throw new ToolError('snapshot read failed')
      const bytes = buffer.subarray(0, count)
      const safeLength = position + count === file.bytes ? count : validUtf8Prefix(bytes)
      if (safeLength <= 0) throw new ToolError('snapshot UTF-8 boundary is invalid')
      const next = position + safeLength
      candidates.push({ item: { byte_offset: position, text: bytes.subarray(0, safeLength).toString('utf8') }, position: next })
      position = next
    }
  } finally {
    closeSync(descriptor)
  }
  return pageValue(snapshot, scope, offset, candidates, position < file.bytes ? position : null)
}

function validUtf8Prefix(bytes: Buffer): number {
  for (let length = bytes.length; length >= Math.max(bytes.length - 3, 0); length -= 1) {
    try {
      new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, length))
      return length
    } catch {
      // At most three trailing bytes can belong to an incomplete UTF-8 scalar.
    }
  }
  return 0
}

function scanText(snapshot: Snapshot, pathScope: string, query: string, start: SearchPosition, limit: number) {
  const queryBytes = Buffer.from(query, 'utf8')
  const failure = kmpFailure(queryBytes)
  const candidates: Array<Candidate<{ path: string; line: number; text: string }>> = []
  let position = { ...start }
  let scanned = 0

  while (position.file < snapshot.paths.length && candidates.length < limit && scanned < SEARCH_SCAN_BYTES) {
    const path = snapshot.paths[position.file]!
    if (pathScope !== '' && path !== pathScope && !path.startsWith(`${pathScope}/`)) {
      position = nextFile(position.file)
      continue
    }

    const file = snapshot.files.get(path)!
    if (position.offset > file.bytes || position.lineStart > position.offset) throw new ToolError('cursor position is not valid')
    const descriptor = openSync(file.snapshotPath, 'r')
    try {
      let matchState = restoreMatchState(descriptor, position, queryBytes, failure)
      const buffer = Buffer.allocUnsafe(Math.min(SEARCH_BUFFER_BYTES, Math.max(file.bytes - position.offset, 1)))

      while (position.offset < file.bytes && candidates.length < limit && scanned < SEARCH_SCAN_BYTES) {
        const wanted = Math.min(buffer.length, file.bytes - position.offset, SEARCH_SCAN_BYTES - scanned)
        const count = readSync(descriptor, buffer, 0, wanted, position.offset)
        if (count <= 0) throw new ToolError('snapshot read failed')

        for (let index = 0; index < count; index += 1) {
          const byte = buffer[index]!
          position.offset += 1
          scanned += 1

          if (byte === 0x0a) {
            if (position.matched) {
              const item = { path, line: position.line, text: evidence(descriptor, position.lineStart, position.offset - 1) }
              const resume = { ...position, lineStart: position.offset, line: position.line + 1, matched: false }
              candidates.push({ item, position: resume })
            }
            position.lineStart = position.offset
            position.line += 1
            position.matched = false
            matchState = 0
            if (candidates.length >= limit) break
            continue
          }

          matchState = kmpStep(queryBytes, failure, matchState, byte)
          if (matchState === queryBytes.length) {
            position.matched = true
            matchState = failure[matchState - 1] ?? 0
          }
        }
      }

      if (position.offset >= file.bytes) {
        if (position.matched && position.offset > position.lineStart && candidates.length < limit) {
          const resume = nextFile(position.file)
          candidates.push({
            item: { path, line: position.line, text: evidence(descriptor, position.lineStart, position.offset) },
            position: resume,
          })
        }
        position = nextFile(position.file)
      }
    } finally {
      closeSync(descriptor)
    }
  }

  return { candidates, next: position.file < snapshot.paths.length ? position : null }
}

function nextFile(file: number): SearchPosition {
  return { file: file + 1, offset: 0, lineStart: 0, line: 1, matched: false }
}

function restoreMatchState(
  descriptor: number,
  position: SearchPosition,
  query: Buffer,
  failure: readonly number[],
): number {
  const overlap = Math.min(query.length - 1, position.offset - position.lineStart)
  if (overlap <= 0) return 0
  const bytes = Buffer.allocUnsafe(overlap)
  const count = readSync(descriptor, bytes, 0, overlap, position.offset - overlap)
  if (count !== overlap) throw new ToolError('snapshot read failed')
  let state = 0
  for (const byte of bytes) {
    state = kmpStep(query, failure, state, byte)
    if (state === query.length) state = failure[state - 1] ?? 0
  }
  return state
}

function evidence(descriptor: number, start: number, end: number): string {
  const length = Math.min(Math.max(end - start, 0), MAX_EVIDENCE_BYTES)
  if (length === 0) return ''
  const bytes = Buffer.allocUnsafe(length)
  const count = readSync(descriptor, bytes, 0, length, start)
  if (count !== length) throw new ToolError('snapshot read failed')
  const safeLength = end - start <= MAX_EVIDENCE_BYTES ? length : validUtf8Prefix(bytes)
  return bytes.subarray(0, safeLength).toString('utf8').replace(/\r$/, '')
}

function kmpFailure(query: Buffer): number[] {
  const failure = Array<number>(query.length).fill(0)
  for (let index = 1, prefix = 0; index < query.length; index += 1) {
    while (prefix > 0 && query[index] !== query[prefix]) prefix = failure[prefix - 1]!
    if (query[index] === query[prefix]) prefix += 1
    failure[index] = prefix
  }
  return failure
}

function kmpStep(query: Buffer, failure: readonly number[], state: number, byte: number): number {
  while (state > 0 && byte !== query[state]) state = failure[state - 1]!
  if (byte === query[state]) state += 1
  return state
}

function structured(value: Record<string, unknown>) {
  return { content: [{ type: 'text' as const, text: JSON.stringify(value) }], structuredContent: value }
}

function logicalResultBytes(value: Record<string, unknown>): number {
  return Buffer.byteLength(JSON.stringify(structured(value)), 'utf8')
}

function snapshotIO<T>(operation: () => T): T {
  try {
    return operation()
  } catch (error) {
    if (error instanceof ToolError) throw error
    throw new ToolError('snapshot backing store is unavailable')
  }
}

const isEntryPoint = process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)

if (isEntryPoint) {
  let snapshot: Snapshot | undefined
  let transport: ReturnType<typeof serveStdio> | undefined
  let shuttingDown = false
  const cleanup = (): void => snapshot?.cleanup()
  const shutdown = (): void => {
    if (shuttingDown) return
    shuttingDown = true

    if (transport === undefined) {
      cleanup()
      process.exit(0)
    }

    void Promise.resolve()
      .then(() => transport!.close())
      .finally(() => {
        cleanup()
        process.exit(0)
      })
  }

  // Install protection before capture. A signal received during the
  // synchronous copy is delivered when control returns to the event loop, at
  // which point `snapshot` is set and can be removed.
  process.once('SIGINT', shutdown)
  process.once('SIGTERM', shutdown)
  process.once('exit', cleanup)

  try {
    const args = parseArguments(process.argv.slice(2))
    snapshot = capture({
      root: args.root,
      include: args.include,
      exclude: args.exclude,
      limits: {
        ...(args.maxFileBytes === undefined ? {} : { maxFileBytes: args.maxFileBytes }),
        ...(args.maxTotalBytes === undefined ? {} : { maxTotalBytes: args.maxTotalBytes }),
      },
    })
    transport = serveStdio(() => createServer(snapshot!), {
      onerror: () => process.stderr.write('filesystem server transport error\n'),
    })
  } catch (error) {
    cleanup()
    process.stderr.write(`${error instanceof Error ? error.message : 'startup failed'}\n`)
    process.exit(64)
  }
}
