# yETH contracts

Based on the weighted stableswap invariant, as derived in the [whitepaper](./whitepaper/whitepaper.pdf).
Pool and staking contract follow [specification](./SPECIFICATION.md).

### Install dependencies
```sh
# Install foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
# Install ape and mpmath
pip install eth-ape
pip install mpmath
# Install required ape plugins
ape plugins install .
```

### Run tests
```sh
ape test
```
