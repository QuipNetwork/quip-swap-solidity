/**
 * Anvil process management for integration tests.
 *
 * Lifecycle implemented here:
 * 1. PORT SELECTION — ask the OS for a free port (bind to port 0, read the
 *    assigned port, release it) so parallel test runs never collide on a
 *    hardcoded port.
 * 2. SPAWN — start `anvil --port <p> --chain-id <id>` as a child process.
 * 3. READINESS WAIT — poll `eth_chainId` over HTTP until the node answers
 *    (or a timeout elapses), so tests never race the node's startup.
 * 4. TEARDOWN — `stop()` kills the child process; runners call it in a
 *    `finally` block so the node dies whether tests pass or fail.
 *
 * Test infrastructure only — never exported from the SDK package.
 */
import {spawn} from 'node:child_process'
import type {ChildProcess} from 'node:child_process'
import {createServer} from 'node:net'

/** A running Anvil instance. */
export interface AnvilInstance {
  /** The HTTP RPC endpoint, e.g. `http://127.0.0.1:53121`. */
  readonly rpcUrl: string
  /** The port the node listens on. */
  readonly port: number
  /** The chain id the node was started with. */
  readonly chainId: number
  /** Kills the node. Safe to call more than once. */
  stop(): void
}

/**
 * Asks the OS for a currently free TCP port.
 *
 * @returns A port number that was free at probe time. (A tiny race with
 *   other processes is possible but acceptable for tests; Anvil fails fast
 *   if the port is taken and the runner surfaces the error.)
 */
export function getFreePort(): Promise<number> {
  return new Promise((
    resolve,
    reject) => {
    const server = createServer()

    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()

      if (address === null || typeof address === 'string') {
        server.close()
        reject(new Error('could not determine a free port'))

        return
      }

      const {port} = address

      server.close(() => resolve(port))
    })
  })
}

/**
 * Starts an Anvil node and waits until its RPC endpoint responds.
 *
 * @param options.chainId - The chain id to run with (e.g. 31337 / 31338).
 * @param options.port - Optional fixed port; a free port is chosen otherwise.
 * @returns The running {@link AnvilInstance}.
 * @throws Error when Anvil exits early or does not become ready in time.
 */
export async function startAnvil(
  options: {
    chainId: number;
    port?: number
  }): Promise<AnvilInstance> {
  const port = options.port ?? (await getFreePort())
  const rpcUrl = `http://127.0.0.1:${port}`

  const child: ChildProcess = spawn(
    'anvil',
    ['--port', String(port), '--chain-id', String(options.chainId), '--silent'],
    {
      stdio: ['ignore', 'pipe', 'pipe']
    },
  )

  let exited = false
  let stderr = ''

  child.stderr?.on('data', chunk => {
    stderr += String(chunk)
  })
  child.once('exit', () => {
    exited = true
  })

  const stop = (): void => {
    if (!exited)
      child.kill('SIGTERM')
  }

  // readiness wait: poll eth_chainId until the node answers
  const deadline = Date.now() + 30_000

  for (; ;) {
    if (exited) {
      throw new Error(`anvil exited during startup (port ${port}): ${stderr}`)
    }

    try {
      const response = await fetch(rpcUrl, {
        method: 'POST',
        headers: {
          'content-type': 'application/json'
        },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: 'eth_chainId',
          params: []
        }),
      })

      if (response.ok) {
        const body = (await response.json()) as {
          result?: string
        }

        if (body.result !== undefined)
          break
      }
    }
    catch {
      // not up yet — keep polling
    }

    if (Date.now() > deadline) {
      stop()

      throw new Error(`anvil did not become ready on port ${port} within 30s`)
    }

    await new Promise(resolve => setTimeout(resolve, 100))
  }

  return {
    rpcUrl,
    port,
    chainId: options.chainId,
    stop
  }
}
