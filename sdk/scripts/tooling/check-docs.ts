import {existsSync, readdirSync, readFileSync, statSync} from 'node:fs'
import {dirname, extname, resolve} from 'node:path'
import {repoRoot} from '../shared/paths.js'

const root = repoRoot

function markdownFiles(
  directory: string): string[] {
  return readdirSync(directory, {
    withFileTypes: true
  }).flatMap(entry => {
    const path = resolve(directory, entry.name)

    if (entry.isDirectory())
      return markdownFiles(path)

    return extname(entry.name) === '.md' ? [path] : []
  })
}

const current = [
  resolve(root, 'README.md'),
  resolve(root, 'ARCHITECTURE.md'),
  ...markdownFiles(resolve(root, 'docs')).filter(path => !path.includes('/docs/legacy/')),
  resolve(root, 'sdk/README.md'),
  resolve(root, 'sdk/USAGE.md'),
  resolve(root, 'sdk/CLI.md'),
  resolve(root, 'script/DEPLOYMENT.md'),
]
const archived = markdownFiles(resolve(root, 'docs/legacy'))
const all = [...current, ...archived]
const failures: string[] = []

const stale = [
  {
    pattern: /\bQuipPortal\b/g,
    label: 'retired QuipPortal name'
  },
  {
    pattern: /\bWOTS\+/g,
    label: 'retired WOTS+ design'
  },
  {
    pattern: /\btimingPolicyId\b/g,
    label: 'removed timingPolicyId'
  },
  {
    pattern: /import\s*\{[^}]*\b(?:createOmnibusClient|resolveDeployment)\b[^}]*\}\s*from ["']@quip\.network\/quip-swap-sdk["']/gs,
    label: 'legacy API imported from the current package root',
  },
]

for (const file of current) {
  const text = readFileSync(file, 'utf8')

  for (const {pattern, label} of stale) {
    pattern.lastIndex = 0

    if (pattern.test(text))
      failures.push(`${file}: ${label}`)
  }
}

const linkPattern = /\[[^\]]*\]\(([^)]+)\)/g
for (const file of all) {
  const text = readFileSync(file, 'utf8')

  for (const match of text.matchAll(linkPattern)) {
    let target = match[1]!.trim().replace(/^<|>$/g, '')

    if (/^(?:https?:|mailto:|#)/.test(target))
      continue

    target = decodeURIComponent(target.split('#', 1)[0]!)

    if (target === '')
      continue

    const path = resolve(dirname(file), target)

    if (!existsSync(path) || (!statSync(path).isFile() && !statSync(path).isDirectory())) {
      failures.push(`${file}: broken local link ${match[1]}`)
    }
  }
}

if (failures.length > 0) {
  for (const failure of failures)
    console.error(failure.replace(`${root}/`, ''))

  process.exit(1)
}
console.log(`Documentation check passed (${all.length} files).`)
