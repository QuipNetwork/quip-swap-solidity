#!/usr/bin/env node
import {runConsole} from '../consoleApp.js'
import {bootstrapConsoleLocal} from '../../scripts/console-bootstrap.js'

const exitCode = await runConsole(process.argv.slice(2), {
  stdout: text => process.stdout.write(text),
  stderr: text => process.stderr.write(text),
}, {bootstrapLocal: bootstrapConsoleLocal})
process.exitCode = exitCode
