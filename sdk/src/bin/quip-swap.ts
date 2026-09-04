#!/usr/bin/env node
import {runConsole} from '../console/consoleApp.js'
import {bootstrapConsoleLocal} from '../../scripts/demo/console/bootstrap.js'

const exitCode = await runConsole(process.argv.slice(2), {
  stdout: text => process.stdout.write(text),
  stderr: text => process.stderr.write(text),
  stdin: async () => {
    const chunks: Buffer[] = []
    for await (const chunk of process.stdin) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
    return Buffer.concat(chunks).toString('utf8')
  },
}, {bootstrapLocal: bootstrapConsoleLocal})
process.exitCode = exitCode
