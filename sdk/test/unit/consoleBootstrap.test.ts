import {describe, expect, it} from 'vitest'
import {runConsole} from '../../src/index.js'
import {LOCAL_BOOTSTRAP_SCHEMA, parseLocalBootstrapProfile} from '../../scripts/demo/console/bootstrap.js'

const profile = () => ({
  schema: LOCAL_BOOTSTRAP_SCHEMA,
  networkId: 'local-test',
  prototype: true,
  mockVerifier: true,
  requiredConfirmations: 3,
  deterministicTimestamp: '4000000000',
  chains: [
    {
      chainId: 31337,
      rpcUrl: 'http://127.0.0.1:8545'
    },
    {
      chainId: 31338,
      rpcUrl: 'http://localhost:8546'
    },
  ],
})

describe('local console bootstrap', () => {
  it('accepts only the explicit two-chain local mock profile', () => {
    expect(parseLocalBootstrapProfile(profile())).toMatchObject({
      networkId: 'local-test',
      requiredConfirmations: 3
    })
    expect(() => parseLocalBootstrapProfile({
...profile(),
      mockVerifier: false
    })).toThrow('explicitly enable')
    expect(() => parseLocalBootstrapProfile({
...profile(),
      chains: [{
        chainId: 31337,
        rpcUrl: 'https://rpc.example'
      }, profile().chains[1]]
    })).toThrow('local HTTP')
    expect(() => parseLocalBootstrapProfile({
...profile(),
      chains: [profile().chains[1], profile().chains[0]]
    })).toThrow('chain 31337')
    expect(() => parseLocalBootstrapProfile({
...profile(),
      chains: [{
        chainId: 31337,
        rpcUrl: 'http://127.0.0.1:8545'
      }, {
        chainId: 31338,
        rpcUrl: 'http://127.0.0.1:8545'
      }]
    })).toThrow('distinct')
  })

  it('dispatches bootstrap through the executable-only dependency', async () => {
    let received: unknown
    let stdout = '';
    let stderr = ''
    const code = await runConsole(['bootstrap-local', '--party', 'alice', '--state-root', '/output', '--config', '/profile.json', '--json'], {
      stdout: text => {
        stdout += text
      },
      stderr: text => {
        stderr += text
      }
    }, {
      bootstrapLocal: async args => {
        received = args

        return {
          networkId: 'local-test',
          aliceConfig: '/output/alice.config.json',
          bobConfig: '/output/bob.config.json',
          startedPids: [1, 2]
        }
      },
    })

    expect(code).toBe(0)
    expect(received).toEqual({
      profile: '/profile.json',
      outputDirectory: '/output'
    })
    expect(JSON.parse(stdout)).toMatchObject({
      ok: true,
      result: {
        networkId: 'local-test'
      },
      warnings: [expect.stringContaining('LOCAL PROTOTYPE ONLY')]
    })
    expect(stderr).toBe('')
  })

  it('fails closed when local process management is unavailable', async () => {
    let stdout = ''
    const code = await runConsole(['bootstrap-local', '--party', 'bob', '--state-root', '/output', '--config', '/profile.json', '--json'], {
      stdout: text => {
        stdout += text
      },
      stderr: () => undefined
    })

    expect(code).toBe(1)
    expect(JSON.parse(stdout)).toMatchObject({
      ok: false,
      error: {
        code: 'BOOTSTRAP_FAILED'
      }
    })
  })
})
