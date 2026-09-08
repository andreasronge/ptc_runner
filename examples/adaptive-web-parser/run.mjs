import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import {access, copyFile, mkdtemp, readFile, writeFile} from 'node:fs/promises'
import {delimiter, dirname, join, resolve} from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { expected, startFixture } from './fixture.mjs'

const execute = promisify(execFile)
const directory = dirname(fileURLToPath(import.meta.url))
const live = process.argv[2] === '--live'
const envFile = live ? process.argv[3] : null
assert.ok(!live || envFile, 'Usage: node run.mjs [--live /absolute/path/to/.env]')

const output = await mkdtemp(join(directory, '.ptc-private-demo-'))
const fixture = await startFixture()

async function save(path, value) {
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, {mode: 0o600})
}

async function commandPath(name) {
  const names = process.platform === 'win32' ? [`${name}.cmd`, `${name}.exe`, name] : [name]
  for (const directory of (process.env.PATH ?? '').split(delimiter)) {
    for (const candidate of names.map((file) => join(directory, file))) {
      try {
        await access(candidate)
        return candidate
      } catch {}
    }
  }
  throw new Error(`${name} is not available on PATH`)
}

async function ptc(args) {
  try {
    return await execute(process.env.PTC ?? 'ptc', args, {
      cwd: directory,
      env: {...process.env, PTC_WEB_FIXTURE_ORIGIN: fixture.origin},
      timeout: 210000,
      maxBuffer: 4 * 1024 * 1024,
    })
  } catch (error) {
    throw new Error(error.stderr || error.message)
  }
}

async function runQuery(name, path, descriptor, host) {
  const input = join(output, `${name}-input.json`)
  const envelope = join(output, `${name}-envelope.json`)
  await save(input, {url: `${fixture.origin}${path}`})
  await ptc([
    'run', 'ptc-project.json', '--host-config', host, '--input', input, '--envelope', envelope,
    ...(descriptor ? ['--component-override-descriptor', descriptor] : []),
  ])
  const result = JSON.parse(await readFile(envelope, 'utf8'))
  assert.equal(result.status, 'ok')
  assert.equal(result.execution.usage.llm_usage.length, 0, 'query runs must not call a model')
  return result.result.value.records
}

let failed
try {
  const hostSource = live ? 'ptc-host.live.json' : 'ptc-host.json'
  const host = JSON.parse(await readFile(join(directory, hostSource), 'utf8'))
  if (process.env.PTC_WEB_CLI) {
    host.install.web.transport.command = process.execPath
    host.install.web.transport.args = [resolve(process.env.PTC_WEB_CLI)]
  } else {
    const webInstall = join(output, 'web-package')
    await execute(await commandPath('npm'), [
      'install', '--prefix', webInstall, '--no-save', '--no-audit', '--no-fund', '--package-lock=false',
      'ptc-web@0.1.0',
    ], {cwd: directory, env: process.env, timeout: 120000, maxBuffer: 4 * 1024 * 1024})
    host.install.web.transport.command = process.execPath
    host.install.web.transport.args = [join(webInstall, 'node_modules/ptc-web/dist/src/cli.js')]
  }
  const runtimeHost = join(output, 'ptc-host.json')
  await save(runtimeHost, host)
  if (!live) await copyFile(join(directory, 'replay.jsonl'), join(output, 'replay.jsonl'))

  const stale = await runQuery('01-stale', '/quotes', null, runtimeHost)
  assert.deepEqual(stale, [], 'the stale parser should demonstrate the failure')

  const repairResult = join(output, 'repair-result.json')
  const repairEnvelope = join(output, 'repair-envelope.json')
  await ptc([
    'run', 'repair.ptc.json', '--host-config', runtimeHost, '--output', repairResult,
    '--envelope', repairEnvelope, ...(envFile ? ['--env-file', resolve(envFile)] : []),
  ])
  const repair = JSON.parse(await readFile(repairResult, 'utf8'))
  const repairRun = JSON.parse(await readFile(repairEnvelope, 'utf8'))
  assert.ok(repairRun.execution.usage.llm_usage.length > 0, 'repair must use the installed model')

  const candidate = join(output, 'candidate')
  await ptc([
    'materialize', 'ptc-project.json', '--target-mission', 'browser', '--component', 'site.recipe',
    '--from-result', repairResult, '--result-pointer', '/component_source', '--out', candidate,
  ])
  const descriptor = join(candidate, 'descriptor.json')
  await ptc(['validate', 'ptc-project.json', '--host-config', runtimeHost, '--component-override-descriptor', descriptor])

  const repaired = await runQuery('03-repaired', '/quotes', descriptor, runtimeHost)
  const heldOut = await runQuery('04-held-out', '/held-out', descriptor, runtimeHost)
  assert.deepEqual(repaired, expected['/quotes'])
  assert.deepEqual(heldOut, expected['/held-out'])

  await save(join(output, 'report.json'), {
    status: 'passed', mode: live ? 'live' : 'replay', stale_records: stale.length,
    recipe: repair.recipe, repaired_records: repaired.length, held_out_records: heldOut.length,
    candidate: descriptor,
  })
  console.log(JSON.stringify({
    status: 'passed', mode: live ? 'live' : 'replay', recipe: repair.recipe,
    checks: {stale_records: 0, repaired_records: repaired.length, held_out_records: heldOut.length},
    artifacts: output,
  }, null, 2))
} catch (error) {
  failed = error
  console.error(error.message)
  process.exitCode = 1
} finally {
  await fixture.close()
}
