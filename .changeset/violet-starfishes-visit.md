---
"@zoralabs/zora-1155-contracts": minor
---

Premint v2 - for add new signature, where createReferral can be specified.  ZoraCreator1155PremintExecutor recognizes new version of the signature, and still works with the v1 (legacy) version of the signature.  ZoraCreator1155PremintExecutor can now validate signatures by passing it the contract address, instead of needing to pass the full contract creation config, enabling it to validate signatures for 1155 contracts that were not created via the premint executor contract.  1155 contract has been updated to now take abi encoded premint config, premint config version, and send it to an external library to decode the config, the signer, and setup actions.

changes to `ZoraCreator1155PremintExecutorImpl`:
* new function `premintV1` - takes a premint v1 signature and executed a premint, with added functionality of being able to specify mint referral and mint recipient
* new function `premintV2` - takes a premint v2 signature and executes a premint, with being able to specify mint referral and mint recipient
* new function `isValidSignatureV1` - takes an 1155 address, contract admin, premint v1 config and signature,  and validates the signature.  Can be used for 1155 contracts that were not created via the premint executor contract.
* new function `isValidSignatureV2` - takes an 1155 address, contract admin, premint v2 config and signature,  and validates the signature.  Can be used for 1155 contracts that were not created via the premint executor contract.
* deprecated function `premint` - call `premintV1` instead
* deprecated function `isValidSignature` - call `isValidSignatureV1` instead