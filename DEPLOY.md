# How to deploy PNGEncoder

`./deploy.sh` is an interactive deploy script. It signs with a **Ledger hardware
wallet**. It takes you through a local dry run, then Sepolia, then mainnet. It
applies the same checks each time.

```bash
./deploy.sh                 # interactive: pick the network from a menu
./deploy.sh --dry-run       # simulate only: no chain, no Ledger needed
./deploy.sh --sepolia       # guided deploy to the Sepolia testnet
./deploy.sh --mainnet       # guided deploy to Ethereum mainnet
```

**On Windows with PowerShell**, use the `deploy.ps1` script. It accepts the same
flags. It sends the flags to `deploy.sh` through Git Bash, where `forge` and
`cast` are available:

```powershell
.\deploy.ps1 --sepolia
.\deploy.ps1 --mainnet --hd-path "m/44'/60'/0'/0/0"
```

> Run the script from the repository root. Use Git Bash, WSL, macOS or Linux, or
> use `deploy.ps1` from PowerShell.
>
> Foundry connects to the Ledger through USB HID. Before you start:
>
> 1. Connect the Ledger.
> 2. Unlock the Ledger.
> 3. Open the Ethereum app.
> 4. Make sure that no other application (for example Ledger Live) uses the
>    device.
>
> The shell that starts the script has no effect on Ledger signing. `forge` and
> `cast` do the signing.

## What the script deploys

`PNGEncoder` links the `Deflate` library, so a deploy has **two transactions**:

1. `Deflate`, through the deterministic CREATE2 factory.
2. `PNGEncoder`, linked to `Deflate`.

`forge` deploys and links the library automatically. You sign the two
transactions on the Ledger. The two contracts have no constructor arguments.

## Steps and checks

1. **Toolchain**: The script makes sure that `forge` and `cast` are available
   and that Foundry is ≥ 1.0 (Cancun).
2. **Repository state**: The script shows the branch and the commit. It gives a
   warning if the working tree has changes that are not committed. Deploy only a
   known, reviewed commit.
3. **Build and test**: The script does a new `forge build` and runs the full
   test suite. Use `--no-tests` to skip the tests. The script does not deploy
   code that fails the tests.
4. **Network**: Select dry run, Sepolia or mainnet.
5. **RPC and chain checks**: The script makes sure that the chain id of the RPC
   agrees with the selected network. This prevents a deploy to the wrong
   network. The script also makes sure that the CREATE2 factory is on the chain.
6. **Account**: Select the Ledger account: Ledger Live (`m/44'/60'/x'/0/0`),
   legacy (`m/44'/60'/0'/x`) or a custom path. The script shows each address and
   its balance.
7. **Cost preview**: The script shows the current gas price, your balance and
   the estimated deploy cost.
8. **Simulation**: The script always does a dry run before it broadcasts.
9. **Confirmation**: The script asks for an explicit typed confirmation. For
   mainnet, you must type `mainnet` and then confirm again.
10. **Broadcast**: The script uses `--ledger --slow` (one transaction at a
    time). It does **not** publish the source unless you give `--verify` (see
    below).
11. **Verify and record**: The script checks the on-chain code again. Then it
    writes `deployments/<network>.json` (address, commit, deployer, transaction
    hashes).

## Source publication (Etherscan verification)

Verification is **optional and independent of the deploy**. You can deploy
without publication and publish the source later.

- **At deploy time**: Add `--verify`. This requires `ETHERSCAN_API_KEY`.
  Verification is **off by default**: `./deploy.sh --mainnet` without `--verify`
  publishes nothing.
- **Later**: Run `./verify.sh <network>`, or `.\verify.ps1 <network>` in
  PowerShell. The script reads `deployments/<network>.json`. It verifies the
  `Deflate` library and the linked `PNGEncoder`.

Run the verify script from the repository root at the **same commit that you
deployed**. Verification compiles the source again, and a different commit gives
different bytecode. `verify.sh` gives a warning if the commit is different.

## Configuration

Copy `.env.example` to `.env` and fill in the values. Git ignores `.env`.

```bash
SEPOLIA_RPC_URL=...      # your RPC provider
MAINNET_RPC_URL=...
ETHERSCAN_API_KEY=...    # for --verify; one key works on all chains (Etherscan v2)
```

`./deploy.sh` loads `.env` automatically. You can override each value for one
run with flags (`--rpc-url`, `--hd-path`, `--sender`, `--verify`, `--no-tests`).
If an RPC URL is missing, the script asks for it.

## Deploy without the wrapper

The wrapper runs a standard Foundry script. You can also run that script
directly:

```bash
# simulate
forge script script/Deploy.s.sol:Deploy --rpc-url "$MAINNET_RPC_URL" --sender 0xYourAddr

# broadcast with a Ledger
forge script script/Deploy.s.sol:Deploy --rpc-url "$MAINNET_RPC_URL" \
  --ledger --mnemonic-derivation-paths "m/44'/60'/0'/0/0" --sender 0xYourAddr \
  --broadcast --slow --verify --etherscan-api-key "$ETHERSCAN_API_KEY" --chain 1
```
