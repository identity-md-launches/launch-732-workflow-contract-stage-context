# Genesis Protocol — contracts

Genesis Protocol is a community utility token for the Sepolia network. This repository holds the
contract stage of its launch: one contract, the launch token, with its tests and ABI.

| Item | Value |
| --- | --- |
| Contract | `LaunchToken` in `src/LaunchToken.sol` |
| Name | `GENESIS PROTOCOL` |
| Symbol | `GENESIS` |
| Decimals | 18 |
| Total supply | 1,000,000,000 tokens (10^27 minor units), fixed |
| Constructor arguments | none |
| Target network | Sepolia (chain id 11155111) |
| ABI | `docs/abi/LaunchToken.json` |

This is a token-only launch. The brief asks for a standard ERC-20 and names no other on-chain
behaviour, so there are no application contracts and the manifest's `contracts` list is empty.

## What the token does

`LaunchToken` is a plain ERC-20: `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`,
`allowance`, `transfer`, `approve`, `transferFrom`, and the `Transfer` and `Approval` events.

- The constructor mints the whole supply to its deployer and emits `Transfer(0x0, deployer, 10^27)`.
- `totalSupply` is a compile-time constant. No code path mints or burns.
- A transfer moves exactly the amount asked. There is no fee, tax, limit, cooldown or blocklist.
- There is no owner, admin, pause, upgrade or proxy. Nobody has any privileged power over the token.
- The contract makes no external calls and does not accept ETH, so it has no reentrancy surface.
- It is written without an inherited library, so the deployed bytecode is exactly the one source file.

Failures revert with custom errors:

| Error | When |
| --- | --- |
| `InsufficientBalance(sender, balance, needed)` | the sender holds less than the amount |
| `InsufficientAllowance(spender, allowance, needed)` | `transferFrom` exceeds the spender's allowance |
| `InvalidReceiver(receiver)` | a transfer to the zero address |
| `InvalidSpender(spender)` | an approval to the zero address |

### Behaviour integrators should know

- An allowance of `type(uint256).max` is unlimited and is not reduced by `transferFrom`.
- `transferFrom` always spends allowance, including when the caller is the `from` account.
- `approve` overwrites the allowance. The usual ERC-20 approve race applies when changing a non-zero
  allowance; set it to zero first if that matters. There is no `permit`, `increaseAllowance` or
  `decreaseAllowance`.
- Tokens cannot be sent to the zero address. Tokens sent to any other address that cannot move them,
  including the token contract itself, are permanently stuck. There is no rescue function, by design.
- "Circulating supply" is not an on-chain value. A dashboard has to define it itself, for example
  total supply minus the balances of the pool and other named holders.

## What the brief asked and what this does not do

The brief's token specification (name, symbol, 1,000,000,000 supply, 18 decimals, standard ERC-20)
matches the launch token rules, so nothing in it was refused or changed. The brief also mentions
decentralized trading and liquidity pool status: the pool is created and seeded by the launch
factory, not by anything in this repository. The token contains no trading, fee or pool logic.

## Deployment parameters

The token is deployed by the network's launch services through `ProjectFactory`, not from this
repository. This repository contains no deploy script, broadcasts nothing and holds no keys.

- **Constructor:** no arguments, nonpayable.
- **Deployer:** the factory. It receives the whole supply and checks it holds exactly 10^27 units,
  reverting with `SupplyMismatch` otherwise.
- **Distribution:** done entirely by the factory under the launch policy. 10% goes to the swarm: 2%
  equally among wallets that did accepted work on the launch, and 8% equally among the paired seats
  connected at admission. The other 90% is the requester's: the share they chose seeds the pool
  (80% of supply unless they chose otherwise) and the rest goes to their wallet. The token knows
  nothing about this split and gives nobody a reserved share.
- **Pool:** created by the factory with its own initialization guard, seeded with the launch token
  only, and paired with native ETH unless the request chose the chain's pair token. The pool trades
  at the network's trading fee, read by the factory from the chain's `LaunchFees` contract. Frontends
  must use the exact pool key from the deployment handoff.
- **Manifest values:** kind `evm_project`, launch token `LaunchToken`, token decimals 18, an empty
  `contracts` list. The manifest step writes `launch.json`; it is not part of this contribution.

### Build settings

Set in `foundry.toml`. Changing any of them changes the bytecode.

| Setting | Value |
| --- | --- |
| `solc` | 0.8.26 |
| `evm_version` | cancun |
| `optimizer` | on, 200 runs |
| `bytecode_hash` | none |

`ffi` and filesystem access are not enabled. `forge-std` v1.9.7 is vendored as ordinary files in
`lib/forge-std-1.9.7` (sources and licences only) and is used by tests only.

## Assumptions

- The target chain supports the Cancun EVM. Sepolia does.
- The deployer is the launch factory and distributes the supply as described above. If anything else
  deploys the token, that deployer simply holds the whole supply.
- The launch policy supply is 10^27 minor units and the manifest declares 18 decimals.
- Token name and symbol are taken verbatim from the brief, including the upper-case name.

## Operational responsibilities

| Who | Responsibility |
| --- | --- |
| Launch services and deployer | Publishing source, attestation, admission, deployment, supply split, pool creation, explorer verification |
| Manifest step | Writing `launch.json` to describe this source |
| Independent reviewer | Adversarial review of source and manifest before release |
| Frontend | Reading token metrics from the deployed address and pool status from the handoff pool key |
| Token holders | Their own keys and allowances; nobody can recover lost tokens or revoke an allowance for them |

After deployment nobody operates the token. There is nothing to configure, pause, upgrade or rotate.

## Tests

```sh
forge build
forge test
forge fmt --check
```

`test/LaunchToken.t.sol` covers metadata, the supply and its mint to the deployer, the genesis
event, exact transfers, allowances and `transferFrom`, every revert path, the absence of mint, burn,
owner and pause entry points, refusal of ETH, fuzzed transfers and allowances, and a scan of the
runtime bytecode for call, create, delegatecall and selfdestruct opcodes.

`test/LaunchToken.invariant.t.sol` runs random transfers, approvals, `transferFrom` calls and
arbitrary calldata from outsiders, and checks that total supply stays constant, that balances always
sum to the supply, and that no outsider ever obtains tokens.

The tests read no environment variables and do not depend on order or on the calling address.

## Security status and open items

Passing tests are not a security audit. The security checklist supplied with this task was applied
while writing the contract; the items for oracles, swaps, proxies, signatures, delegatecall and
arbitrary-token handling do not apply because the token has none of those.

- Only `forge build`, `forge test` including fuzz and invariant runs, and `forge fmt` were run.
  Slither and Mythril were not available and were not run.
- An independent review of the source and manifest is still required before release.
- Source verification on the block explorer belongs to the deployer after deployment.
- The pair currency and the requester's pool share are launch policy choices, not set here.
