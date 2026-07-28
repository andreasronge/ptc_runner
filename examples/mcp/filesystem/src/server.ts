import { McpServer, fromJsonSchema, type JsonSchemaType } from '@modelcontextprotocol/server'
import { serveStdio } from '@modelcontextprotocol/server/stdio'

import { capture, normalizeRelative, type Snapshot } from './snapshot.js'

const MAX_PAGE = 200
const MAX_MATCHES = 500
const MAX_READ_LINES = 2_000
const MAX_RESULT_BYTES = 262_144

interface Arguments {
  root: string
  include: string[]
  exclude: string[]
}

/** A bounded, actionable failure. Never carries a stacktrace or a host path. */
class ToolError extends Error {}

function parseArguments(argv: readonly string[]): Arguments {
  const parsed: Arguments = { root: '', include: [], exclude: [] }

  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index]
    const value = argv[index + 1]

    if (value === undefined) throw new Error(`missing value for ${flag}`)

    if (flag === '--root') parsed.root = value
    else if (flag === '--include') parsed.include.push(value)
    else if (flag === '--exclude') parsed.exclude.push(value)
    else throw new Error(`unknown option ${flag}`)

    index += 1
  }

  if (parsed.root === '') throw new Error('--root is required')
  return parsed
}

/**
 * Encodes a page position.
 *
 * The cursor carries the snapshot hash so a cursor minted against one capture
 * cannot silently resume against another; an opaque token also keeps clients
 * from constructing offsets by hand.
 */
function encodeCursor(hash: string, offset: number): string {
  return Buffer.from(`${hash}:${offset}`, 'utf8').toString('base64url')
}

function decodeCursor(hash: string, cursor: string | undefined): number {
  if (cursor === undefined) return 0

  const decoded = Buffer.from(cursor, 'base64url').toString('utf8')
  const separator = decoded.lastIndexOf(':')
  if (separator === -1) throw new ToolError('cursor is not valid')

  if (decoded.slice(0, separator) !== hash) {
    throw new ToolError('cursor was issued for a different snapshot')
  }

  const offset = Number(decoded.slice(separator + 1))
  if (!Number.isSafeInteger(offset) || offset < 0) throw new ToolError('cursor is not valid')
  return offset
}

function boundedPage(limit: unknown): number {
  if (limit === undefined) return MAX_PAGE
  if (typeof limit !== 'number' || !Number.isSafeInteger(limit) || limit < 1) {
    throw new ToolError('limit must be a positive integer')
  }
  return Math.min(limit, MAX_PAGE)
}

function requirePath(value: unknown, field: string): string {
  if (typeof value !== 'string') throw new ToolError(`${field} must be a string`)
  const normalized = normalizeRelative(value)
  if (normalized === null) throw new ToolError(`${field} is not a relative path inside the snapshot`)
  return normalized
}

/** Every data-bearing result carries the hash, so a citation binds to the bytes actually queried. */
function page<T>(snapshot: Snapshot, items: readonly T[], offset: number, limit: number) {
  const slice = items.slice(offset, offset + limit)
  const next = offset + slice.length

  return {
    snapshot_hash: snapshot.hash,
    items: slice,
    next_cursor: next < items.length ? encodeCursor(snapshot.hash, next) : undefined,
  }
}


const HASH = { type: 'string' as const }
const CURSOR = { type: 'string' as const }

/** Paged results share one envelope so a client learns the shape once. */
function pagedOutput(itemProperties: Record<string, unknown>): JsonSchemaType {
  return {
    type: 'object',
    properties: {
      snapshot_hash: HASH,
      items: {
        type: 'array',
        items: { type: 'object', properties: itemProperties, additionalProperties: false },
      },
      next_cursor: CURSOR,
    },
    required: ['snapshot_hash', 'items'],
    additionalProperties: true,
  } as JsonSchemaType
}

export function createServer(snapshot: Snapshot): McpServer {
  const server = new McpServer(
    { name: 'ptc-runner-filesystem-sample', version: '0.1.0' },
    {
      instructions:
        'Read-only access to an immutable snapshot captured at startup. Paths are relative; the filesystem is never re-read.',
    },
  )

  const readOnly = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
  // Snapshot contents depend on host include rules, so the catalog is not
  // provably identical across users and must not be cached publicly.
  const meta = { 'io.modelcontextprotocol/cacheScope': 'private' as const }

  server.registerTool(
    'list_directory',
    {
      title: 'List directory',
      description: 'Sorted, paginated entries directly under a relative prefix of the snapshot.',
      annotations: readOnly,
      _meta: meta,
      outputSchema: fromJsonSchema<Record<string, unknown>>(
        pagedOutput({ name: { type: 'string' }, kind: { type: 'string' }, path: { type: 'string' } }),
      ),
      inputSchema: fromJsonSchema<Record<string, unknown>>({
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Relative directory prefix; omit for the root.' },
          cursor: { type: 'string' },
          limit: { type: 'integer', minimum: 1, maximum: MAX_PAGE },
        },
        additionalProperties: false,
      }),
    },
    async (args: Record<string, unknown>) => {
      const prefix = args.path === undefined ? '' : requirePath(args.path, 'path')
      const scope = prefix === '' ? '' : `${prefix}/`
      const entries = new Map<string, 'file' | 'directory'>()

      for (const path of snapshot.paths) {
        if (!path.startsWith(scope)) continue
        const remainder = path.slice(scope.length)
        const separator = remainder.indexOf('/')
        if (separator === -1) entries.set(remainder, 'file')
        else entries.set(remainder.slice(0, separator), 'directory')
      }

      const items = [...entries.entries()]
        .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0))
        .map(([name, kind]) => ({ name, kind, path: scope + name }))

      const limit = boundedPage(args.limit)
      return structured(page(snapshot, items, decodeCursor(snapshot.hash, args.cursor as string), limit))
    },
  )

  server.registerTool(
    'search_files',
    {
      title: 'Search files',
      description: 'Sorted, paginated snapshot paths matching a literal substring.',
      annotations: readOnly,
      _meta: meta,
      outputSchema: fromJsonSchema<Record<string, unknown>>(pagedOutput({ path: { type: 'string' } })),
      inputSchema: fromJsonSchema<Record<string, unknown>>({
        type: 'object',
        properties: {
          query: { type: 'string', minLength: 1 },
          cursor: { type: 'string' },
          limit: { type: 'integer', minimum: 1, maximum: MAX_PAGE },
        },
        required: ['query'],
        additionalProperties: false,
      }),
    },
    async (args: Record<string, unknown>) => {
      if (typeof args.query !== 'string' || args.query === '') {
        throw new ToolError('query must be a non-empty string')
      }

      const items = snapshot.paths
        .filter((path) => path.includes(args.query as string))
        .map((path) => ({ path }))

      const limit = boundedPage(args.limit)
      return structured(page(snapshot, items, decodeCursor(snapshot.hash, args.cursor as string), limit))
    },
  )

  server.registerTool(
    'search_text',
    {
      title: 'Search text',
      description: 'Literal text search returning path and line evidence.',
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
          limit: { type: 'integer', minimum: 1, maximum: MAX_PAGE },
        },
        required: ['query'],
        additionalProperties: false,
      }),
    },
    async (args: Record<string, unknown>) => {
      if (typeof args.query !== 'string' || args.query === '') {
        throw new ToolError('query must be a non-empty string')
      }

      const scope = args.path === undefined ? '' : requirePath(args.path, 'path')
      const matches: Array<{ path: string; line: number; text: string }> = []

      for (const path of snapshot.paths) {
        if (scope !== '' && path !== scope && !path.startsWith(`${scope}/`)) continue
        const file = snapshot.files.get(path)!

        file.lines.forEach((text, offset) => {
          if (matches.length >= MAX_MATCHES) return
          if (!text.includes(args.query as string)) return
          matches.push({ path, line: offset + 1, text: text.slice(0, 1_024) })
        })

        if (matches.length >= MAX_MATCHES) break
      }

      const limit = boundedPage(args.limit)
      const result = page(snapshot, matches, decodeCursor(snapshot.hash, args.cursor as string), limit)
      return structured({ ...result, match_limit_reached: matches.length >= MAX_MATCHES })
    },
  )

  server.registerTool(
    'read_text_file',
    {
      title: 'Read text file',
      description: 'One bounded UTF-8 line range with stable line numbers and explicit end-of-file.',
      annotations: readOnly,
      _meta: meta,
      outputSchema: fromJsonSchema<Record<string, unknown>>({
        type: 'object',
        properties: {
          snapshot_hash: HASH,
          path: { type: 'string' },
          lines: {
            type: 'array',
            items: {
              type: 'object',
              properties: { line: { type: 'integer' }, text: { type: 'string' } },
              additionalProperties: false,
            },
          },
          total_lines: { type: 'integer' },
          end_of_file: { type: 'boolean' },
          truncated: { type: 'boolean' },
        },
        required: ['snapshot_hash', 'path', 'lines', 'total_lines', 'end_of_file', 'truncated'],
        additionalProperties: false,
      }),
      inputSchema: fromJsonSchema<Record<string, unknown>>({
        type: 'object',
        properties: {
          path: { type: 'string', minLength: 1 },
          start_line: { type: 'integer', minimum: 1 },
          line_count: { type: 'integer', minimum: 1, maximum: MAX_READ_LINES },
        },
        required: ['path'],
        additionalProperties: false,
      }),
    },
    async (args: Record<string, unknown>) => {
      const path = requirePath(args.path, 'path')
      const file = snapshot.files.get(path)
      if (!file) throw new ToolError('path is not part of the snapshot')

      const start = args.start_line === undefined ? 1 : Number(args.start_line)
      if (!Number.isSafeInteger(start) || start < 1) throw new ToolError('start_line must be a positive integer')

      const requested = args.line_count === undefined ? MAX_READ_LINES : Number(args.line_count)
      if (!Number.isSafeInteger(requested) || requested < 1) {
        throw new ToolError('line_count must be a positive integer')
      }

      const count = Math.min(requested, MAX_READ_LINES)
      const selected = file.lines.slice(start - 1, start - 1 + count)

      // Trim to the result ceiling rather than returning an oversized payload,
      // and say so, so a caller can page instead of silently losing content.
      let bytes = 0
      let truncated = false
      const lines: Array<{ line: number; text: string }> = []

      for (const [offset, text] of selected.entries()) {
        bytes += Buffer.byteLength(text, 'utf8') + 1
        if (bytes > MAX_RESULT_BYTES) {
          truncated = true
          break
        }
        lines.push({ line: start + offset, text })
      }

      return structured({
        snapshot_hash: snapshot.hash,
        path,
        lines,
        total_lines: file.lines.length,
        end_of_file: !truncated && start - 1 + selected.length >= file.lines.length,
        truncated,
      })
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
            properties: { files: { type: 'boolean' }, bytes: { type: 'boolean' }, depth: { type: 'boolean' } },
            additionalProperties: false,
          },
        },
        required: ['snapshot_hash', 'file_count', 'total_bytes', 'truncated'],
        additionalProperties: false,
      }),
      inputSchema: fromJsonSchema<Record<string, unknown>>({ type: 'object', properties: {}, additionalProperties: false }),
    },
    // Deliberately reports no root, no host path, and no absolute location.
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

function structured(value: Record<string, unknown>) {
  return {
    content: [{ type: 'text' as const, text: JSON.stringify(value) }],
    structuredContent: value,
  }
}

const isEntryPoint = process.argv[1] !== undefined

if (isEntryPoint) {
  try {
    const args = parseArguments(process.argv.slice(2))
    const snapshot = capture({ root: args.root, include: args.include, exclude: args.exclude })
    serveStdio(() => createServer(snapshot))
  } catch (error) {
    // Startup diagnostics go to stderr: stdout carries protocol messages only.
    process.stderr.write(`${error instanceof Error ? error.message : 'startup failed'}\n`)
    process.exit(64)
  }
}
