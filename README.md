# Swapr fee receiver hack

At block xxx on Gnosis Chain, attacker
`0x740d618e92484b6f142e49b3644b26cc370232be` deployed a contract and started
draining the Swapr fee receiver of all its most valuable LP tokens (Swapr's
protocol fee). After some analysis and determining what was going on, this repo
was created to test how the hacker exploited the contract.

The repo containsa `FakePair` smart contract that exploits a series of
vulnerabilities in the fee receiver contract in order to drain it of some of the
LP tokens stored there as minted by Swapr when collecting protocol fees. The
stolen LP tokens are all representing pairs with at least one of the tow tokens
being the native currency wrapper on the target chain (in the specific case
WXDAI on Gnosis chain).

`SimulateHack` is the second contract in the repo, and its role is to simulate
the hack and check some constraints to see if it was performed correctly. The
simulation is performed at block `23729495`, exactly one block before the hacker
started their attack.

In order to run the simulation and analyze traces, make sure you follow these
steps:

- Clone the repo with submodule recursion (`git clone --recurse-submodules`). On
  a standard clone, remember to run `git submodule update --init --recursive` in
  order to install dependencies (`forge-std` and `solmate`).
- Install Foundry (you can get it [here](https://getfoundry.sh/)).
- Run `forge test -vvvv`

In order to better understand what's going on, please check the contracs' code,
they're well commented to help explained exactly what happened.
