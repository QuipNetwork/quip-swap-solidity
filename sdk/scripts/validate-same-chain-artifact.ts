import {readFileSync} from 'node:fs'
import {resolve} from 'node:path'
import {validateSameChainDemoArtifact} from './same-chain-artifact.js'

const input = process.argv[2]
if (input === undefined) {
  throw new Error('usage: bun run demo:same-chain:validate <artifact-path>')
}
const path = resolve(input)
const artifact: unknown = JSON.parse(readFileSync(path, 'utf8'))
validateSameChainDemoArtifact(artifact)
console.log(JSON.stringify({
  schema: artifact.schema,
  valid: true,
  tradeId: artifact.tradeId,
  transitions: artifact.transitions.length,
  negativeControls: artifact.negativeControls.length,
  terminalState: artifact.terminalOutcome.state,
  secretsPersisted: false,
  artifact: path,
}, null, 2))
