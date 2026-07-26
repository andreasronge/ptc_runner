import { createHash } from 'node:crypto'
import { lstatSync, readdirSync, readFileSync } from 'node:fs'
import { join, relative, resolve, sep } from 'node:path'

/**
 * An immutable capture of the host-supplied root.
 *
 * Everything the server can ever answer comes from this structure. It is built
 * once, before discovery completes, and no tool reads the filesystem again — so
 * a file that changes, appears, or disappears after capture cannot alter a
 * result, and a path that was excluded was never opened and cannot leak through
 * a later query.
 */
export interface Snapshot {
  /** Relative POSIX paths, lexicographically sorted. Sort order is the pagination order. */
  readonly paths: readonly string[]
  readonly files: ReadonlyMap<string, SnapshotFile>
  /** Content hash over the captured set. Safe to publish: derived from relative paths and bytes, never the host root. */
  readonly hash: string
  readonly totalBytes: number
  readonly truncated: SnapshotTruncation
}

export interface SnapshotFile {
  readonly lines: readonly string[]
  readonly bytes: number
}

export interface SnapshotTruncation {
  readonly files: boolean
  readonly bytes: boolean
  readonly depth: boolean
}

export interface CaptureOptions {
  readonly root: string
  readonly include: readonly string[]
  readonly exclude?: readonly string[]
  readonly limits?: Partial<Limits>
}

export interface Limits {
  readonly maxFiles: number
  readonly maxFileBytes: number
  readonly maxTotalBytes: number
  readonly maxDepth: number
}

export const DEFAULT_LIMITS: Limits = {
  maxFiles: 4_096,
  maxFileBytes: 1_048_576,
  maxTotalBytes: 33_554_432,
  maxDepth: 32,
}

export class CaptureError extends Error {}

/**
 * Captures `root` under the host's include rules.
 *
 * Include patterns are mandatory and the default is no files: a server started
 * without them exposes nothing rather than everything. Excludes may only remove
 * from what the includes selected, so narrowing is always safe and widening is
 * impossible.
 */
export function capture(options: CaptureOptions): Snapshot {
  if (options.include.length === 0) {
    throw new CaptureError('at least one include pattern is required')
  }

  const limits = { ...DEFAULT_LIMITS, ...options.limits }
  const root = resolve(options.root)
  const rootStat = statOrThrow(root, 'root')

  if (!rootStat.isDirectory()) {
    throw new CaptureError('root is not a directory')
  }

  const include = options.include.map(compileGlob)
  const exclude = (options.exclude ?? []).map(compileGlob)
  const files = new Map<string, SnapshotFile>()
  const truncated = { files: false, bytes: false, depth: false }
  let totalBytes = 0

  const walk = (directory: string, prefix: string, depth: number): void => {
    if (depth > limits.maxDepth) {
      truncated.depth = true
      return
    }

    // Sorted traversal makes the capture itself deterministic, so the snapshot
    // hash depends on content rather than on directory iteration order.
    for (const entry of readdirSync(directory).sort()) {
      if (files.size >= limits.maxFiles) {
        truncated.files = true
        return
      }

      const absolute = join(directory, entry)
      const relativePath = prefix === '' ? entry : `${prefix}/${entry}`

      // Excluded paths are skipped before any stat or open, so a secret, a
      // private result directory, or a dependency tree below the root is never
      // inventoried merely because it exists.
      if (matchesAny(relativePath, exclude)) continue

      const stat = lstatSync(absolute, { throwIfNoEntry: false })
      if (!stat) continue

      // Symlinks are rejected rather than followed: resolving one would let a
      // link inside the root reach bytes outside it.
      if (stat.isSymbolicLink()) continue

      if (stat.isDirectory()) {
        walk(absolute, relativePath, depth + 1)
        continue
      }

      if (!stat.isFile()) continue
      if (!matchesAny(relativePath, include)) continue
      if (stat.size > limits.maxFileBytes) continue

      if (totalBytes + stat.size > limits.maxTotalBytes) {
        truncated.bytes = true
        return
      }

      const raw = readFileSync(absolute)
      const text = raw.toString('utf8')

      // Round-trip check: a lossy decode means the bytes were not UTF-8, and a
      // server promising bounded UTF-8 must not hand back replacement
      // characters as if they were content.
      if (!Buffer.from(text, 'utf8').equals(raw)) continue

      totalBytes += stat.size
      files.set(relativePath, { lines: splitLines(text), bytes: stat.size })
    }
  }

  walk(root, '', 0)

  const paths = [...files.keys()].sort()
  return { paths, files, hash: hashOf(paths, files), totalBytes, truncated }
}

/**
 * Validates a client-supplied relative path.
 *
 * Rejects absolute paths, NUL bytes, empty, `.` and `..` segments, and Windows
 * separators. Traversal fails here rather than resolving, so no query can name
 * a location outside the captured set.
 */
export function normalizeRelative(value: string): string | null {
  if (value === '') return ''
  if (value.includes('\0')) return null
  if (value.startsWith('/') || value.includes('\\')) return null
  if (value.length > 1_024) return null
  if (/^[a-zA-Z]:/.test(value)) return null

  const segments = value.split('/').filter((segment) => segment !== '')
  if (segments.some((segment) => segment === '.' || segment === '..')) return null

  return segments.join('/')
}

function splitLines(text: string): string[] {
  const normalized = text.replace(/\r\n/g, '\n')
  const lines = normalized.split('\n')
  // A trailing newline terminates the last line rather than starting an empty one.
  if (lines.length > 1 && lines[lines.length - 1] === '') lines.pop()
  return lines
}

function hashOf(paths: readonly string[], files: ReadonlyMap<string, SnapshotFile>): string {
  const digest = createHash('sha256')

  for (const path of paths) {
    const file = files.get(path)!
    digest.update(path, 'utf8')
    digest.update('\0')
    digest.update(String(file.bytes), 'utf8')
    digest.update('\0')
    digest.update(file.lines.join('\n'), 'utf8')
    digest.update('\0')
  }

  return `sha256:${digest.digest('hex')}`
}

function statOrThrow(path: string, label: string) {
  const stat = lstatSync(path, { throwIfNoEntry: false })
  if (!stat) throw new CaptureError(`${label} does not exist`)
  if (stat.isSymbolicLink()) throw new CaptureError(`${label} must not be a symbolic link`)
  return stat
}

function matchesAny(path: string, patterns: readonly RegExp[]): boolean {
  return patterns.some((pattern) => pattern.test(path))
}

/**
 * Compiles a bounded glob: `**` spans separators, `*` and `?` do not.
 *
 * Deliberately small. A full glob engine would be a second, less reviewable
 * confinement surface, and the host only needs to select directory subtrees
 * and extensions.
 */
function compileGlob(pattern: string): RegExp {
  let source = '^'

  for (let index = 0; index < pattern.length; index += 1) {
    const character = pattern[index]

    if (character === '*') {
      if (pattern[index + 1] === '*') {
        index += 1

        // `**/` spans whole segments so `**/x` matches `x` and `a/b/x`; a
        // trailing `**` spans the remainder including the final segment, so
        // `lib/**` matches `lib/a.ex` rather than only directories.
        if (pattern[index + 1] === '/') {
          index += 1
          source += '(?:[^/]+/)*'
        } else {
          source += '.*'
        }
      } else {
        source += '[^/]*'
      }
      continue
    }

    if (character === '?') {
      source += '[^/]'
      continue
    }

    source += character.replace(/[.+^${}()|[\]\\]/g, '\\$&')
  }

  return new RegExp(`${source}$`)
}

export function posixJoin(prefix: string, name: string): string {
  return prefix === '' ? name : `${prefix}/${name}`
}

export function relativeWithin(root: string, absolute: string): string {
  return relative(root, absolute).split(sep).join('/')
}
