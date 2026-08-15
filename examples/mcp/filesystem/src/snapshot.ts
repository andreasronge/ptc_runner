import { createHash } from 'node:crypto'
import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  mkdtempSync,
  openSync,
  opendirSync,
  readSync,
  rmSync,
  statfsSync,
  writeSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join, relative, resolve, sep } from 'node:path'

/** Metadata for one file in the private, disk-backed immutable capture. */
export interface SnapshotFile {
  readonly snapshotPath: string
  readonly bytes: number
  readonly contentHash: string
}

export interface Snapshot {
  /** Relative POSIX paths, lexicographically sorted. */
  readonly paths: readonly string[]
  readonly files: ReadonlyMap<string, SnapshotFile>
  /** Derived only from relative paths, byte lengths, and captured content. */
  readonly hash: string
  readonly totalBytes: number
  readonly truncated: { readonly files: false; readonly depth: false }
  /** Idempotently removes the private snapshot directory. */
  readonly cleanup: () => void
}

export interface CaptureOptions {
  readonly root: string
  readonly include: readonly string[]
  readonly exclude?: readonly string[]
  readonly limits?: Partial<Limits>
}

export interface Limits {
  readonly maxFiles: number
  readonly maxDepth: number
  readonly maxDirectories: number
  readonly maxEntries: number
  readonly maxFileBytes: number
  readonly maxTotalBytes: number
}

export const DEFAULT_LIMITS: Limits = {
  maxFiles: 4_096,
  maxDepth: 32,
  maxDirectories: 8_192,
  maxEntries: 100_000,
  maxFileBytes: Number.MAX_SAFE_INTEGER,
  maxTotalBytes: Number.MAX_SAFE_INTEGER,
}

const COPY_BUFFER_BYTES = 65_536
const TEMP_DISK_RESERVE_BYTES = 64n * 1_024n * 1_024n

export class CaptureError extends Error {}

/**
 * Streams the selected UTF-8 files into a private immutable disk snapshot.
 *
 * File bytes are never retained as a whole in the Node heap. The root must be
 * trusted and quiescent during this startup capture; portable Node path APIs do
 * not provide descriptor-confined traversal of every ancestor.
 */
export function capture(options: CaptureOptions): Snapshot {
  if (options.include.length === 0) throw new CaptureError('at least one include pattern is required')

  const limits = { ...DEFAULT_LIMITS, ...options.limits }
  validateLimits(limits)
  const root = resolve(options.root)
  const rootStat = statOrThrow(root, 'root')
  if (!rootStat.isDirectory()) throw new CaptureError('root is not a directory')

  const include = options.include.map(compileGlob)
  const exclude = (options.exclude ?? []).map(compileGlob)
  const maxTotalBytes = Math.min(limits.maxTotalBytes, availableSnapshotBytes(tmpdir()))
  const maxFileBytes = Math.min(limits.maxFileBytes, maxTotalBytes)
  const snapshotRoot = mkdtempSync(join(tmpdir(), 'ptc-runner-filesystem-'))
  const files = new Map<string, SnapshotFile>()
  let totalBytes = 0
  let visitedDirectories = 0
  let visitedEntries = 0
  let cleaned = false

  const cleanup = (): void => {
    if (cleaned) return
    cleaned = true
    rmSync(snapshotRoot, { recursive: true, force: true })
  }

  const walk = (directory: string, prefix: string, depth: number): void => {
    if (depth > limits.maxDepth) throw new CaptureError('directory depth limit exceeded')
    visitedDirectories += 1
    if (visitedDirectories > limits.maxDirectories) throw new CaptureError('directory limit exceeded')

    const entries = opendirSync(directory)
    try {
      for (let entry = entries.readSync(); entry !== null; entry = entries.readSync()) {
        visitedEntries += 1
        if (visitedEntries > limits.maxEntries) throw new CaptureError('directory entry limit exceeded')

        const relativePath = prefix === '' ? entry.name : `${prefix}/${entry.name}`
        if (normalizeRelative(relativePath) === null) {
          throw new CaptureError('path exceeds the supported relative-path contract')
        }
        if (matchesAny(relativePath, exclude)) continue

        const absolute = join(directory, entry.name)
        const stat = lstatSync(absolute, { throwIfNoEntry: false })
        if (!stat || stat.isSymbolicLink()) continue

        if (stat.isDirectory()) {
          walk(absolute, relativePath, depth + 1)
          continue
        }

        if (!stat.isFile() || !matchesAny(relativePath, include)) continue
        if (files.size >= limits.maxFiles) throw new CaptureError('file limit exceeded')

        const captured = captureFile(
          absolute,
          join(snapshotRoot, String(files.size)),
          Math.min(maxFileBytes, maxTotalBytes - totalBytes),
        )
        if (captured === null) continue
        files.set(relativePath, captured)
        totalBytes += captured.bytes
      }
    } finally {
      entries.closeSync()
    }
  }

  try {
    walk(root, '', 0)
    const paths = [...files.keys()].sort()

    return {
      paths,
      files,
      hash: hashOf(paths, files),
      totalBytes,
      truncated: { files: false, depth: false },
      cleanup,
    }
  } catch (error) {
    cleanup()
    if (error instanceof CaptureError) throw error
    throw new CaptureError('capture failed')
  }
}

function captureFile(sourcePath: string, snapshotPath: string, maxBytes: number): SnapshotFile | null {
  const noFollow = typeof constants.O_NOFOLLOW === 'number' ? constants.O_NOFOLLOW : 0
  let source: number | undefined
  let target: number | undefined

  try {
    try {
      source = openSync(sourcePath, constants.O_RDONLY | noFollow)
      const before = fstatSync(source)
      if (!before.isFile()) return null
      if (before.size > maxBytes) throw new CaptureError('snapshot byte limit exceeded')

      target = openSync(snapshotPath, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600)
      const digest = createHash('sha256')
      const decoder = new TextDecoder('utf-8', { fatal: true })
      const buffer = Buffer.allocUnsafe(COPY_BUFFER_BYTES)
      let bytes = 0

      for (let count = readSync(source, buffer, 0, buffer.length, null); count > 0; ) {
        if (bytes + count > maxBytes) throw new CaptureError('snapshot byte limit exceeded')
        const chunk = buffer.subarray(0, count)
        decoder.decode(chunk, { stream: true })
        digest.update(chunk)
        writeAll(target, chunk)
        bytes += count
        count = readSync(source, buffer, 0, buffer.length, null)
      }
      decoder.decode()

      const after = fstatSync(source)
      if (after.size !== before.size || after.mtimeMs !== before.mtimeMs || bytes !== after.size) {
        throw new CaptureError('source changed during capture')
      }

      return { snapshotPath, bytes, contentHash: digest.digest('hex') }
    } finally {
      if (target !== undefined) closeSync(target)
      if (source !== undefined) closeSync(source)
    }
  } catch (error) {
    rmSync(snapshotPath, { force: true })
    if (error instanceof TypeError) return null
    throw error
  }
}

function validateLimits(limits: Limits): void {
  const positive = [limits.maxFiles, limits.maxDirectories, limits.maxEntries, limits.maxFileBytes, limits.maxTotalBytes]
  if (
    positive.some((value) => !Number.isSafeInteger(value) || value < 1) ||
    !Number.isSafeInteger(limits.maxDepth) ||
    limits.maxDepth < 0
  ) {
    throw new CaptureError('capture limits are not valid')
  }
}

function availableSnapshotBytes(path: string): number {
  const stat = statfsSync(path, { bigint: true })
  const available = stat.bavail * stat.bsize
  const usable = available > TEMP_DISK_RESERVE_BYTES ? available - TEMP_DISK_RESERVE_BYTES : 0n
  return Number(usable > BigInt(Number.MAX_SAFE_INTEGER) ? BigInt(Number.MAX_SAFE_INTEGER) : usable)
}

function writeAll(descriptor: number, bytes: Buffer): void {
  let offset = 0
  while (offset < bytes.length) offset += writeSync(descriptor, bytes, offset, bytes.length - offset)
}

export function normalizeRelative(value: string): string | null {
  if (value === '') return ''
  if (value.includes('\0') || value.startsWith('/') || value.includes('\\')) return null
  if (value.length > 1_024 || /^[a-zA-Z]:/.test(value)) return null

  const segments = value.split('/').filter((segment) => segment !== '')
  if (segments.some((segment) => segment === '.' || segment === '..')) return null
  return segments.join('/')
}

function hashOf(paths: readonly string[], files: ReadonlyMap<string, SnapshotFile>): string {
  const digest = createHash('sha256')
  for (const path of paths) {
    const file = files.get(path)!
    digest.update(path, 'utf8')
    digest.update('\0')
    digest.update(String(file.bytes), 'utf8')
    digest.update('\0')
    digest.update(file.contentHash, 'ascii')
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

function compileGlob(pattern: string): RegExp {
  let source = '^'
  for (let index = 0; index < pattern.length; index += 1) {
    const character = pattern[index]
    if (character === '*') {
      if (pattern[index + 1] === '*') {
        index += 1
        if (pattern[index + 1] === '/') {
          index += 1
          source += '(?:[^/]+/)*'
        } else source += '.*'
      } else source += '[^/]*'
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
