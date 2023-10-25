// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {Zora1155FactoryFixtures} from "../fixtures/Zora1155FactoryFixtures.sol";
import {ProtocolRewards} from "@zoralabs/protocol-rewards/src/ProtocolRewards.sol";

import {ZoraCreator1155Impl} from "../../src/nft/ZoraCreator1155Impl.sol";
import {Zora1155} from "../../src/proxies/Zora1155.sol";
import {IZoraCreator1155Errors} from "../../src/interfaces/IZoraCreator1155Errors.sol";
import {IZoraCreator1155} from "../../src/interfaces/IZoraCreator1155.sol";
import {IMinter1155} from "../../src/interfaces/IMinter1155.sol";
import {ICreatorRoyaltiesControl} from "../../src/interfaces/ICreatorRoyaltiesControl.sol";
import {ZoraCreatorFixedPriceSaleStrategy} from "../../src/minters/fixed-price/ZoraCreatorFixedPriceSaleStrategy.sol";
import {Zora1155Factory} from "../../src/proxies/Zora1155Factory.sol";
import {ZoraCreator1155FactoryImpl} from "../../src/factory/ZoraCreator1155FactoryImpl.sol";
import {ZoraCreator1155PremintExecutorImpl} from "../../src/delegation/ZoraCreator1155PremintExecutorImpl.sol";
import {IZoraCreator1155PremintExecutor} from "../../src/interfaces/IZoraCreator1155PremintExecutor.sol";
import {ZoraCreator1155Attribution, ContractCreationConfig, TokenCreationConfig, TokenCreationConfigV2, PremintConfigV2, PremintConfig} from "../../src/delegation/ZoraCreator1155Attribution.sol";
import {ForkDeploymentConfig, Deployment} from "../../src/deployment/DeploymentConfig.sol";
import {UUPSUpgradeable} from "@zoralabs/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ProxyShim} from "../../src/utils/ProxyShim.sol";
import {ZoraCreator1155PremintExecutorImplLib} from "../../src/delegation/ZoraCreator1155PremintExecutorImplLib.sol";
import {Zora1155PremintFixtures} from "../fixtures/Zora1155PremintFixtures.sol";

contract ZoraCreator1155PreminterTest is ForkDeploymentConfig, Test {
    uint256 internal constant CONTRACT_BASE_ID = 0;
    uint256 internal constant PERMISSION_BIT_MINTER = 2 ** 2;

    ZoraCreator1155PremintExecutorImpl internal preminter;
    Zora1155Factory factoryProxy;
    ZoraCreator1155FactoryImpl factory;

    ICreatorRoyaltiesControl.RoyaltyConfiguration internal defaultRoyaltyConfig;
    uint256 internal mintFeeAmount = 0.000777 ether;

    // setup contract config
    uint256 internal creatorPrivateKey;
    address internal creator;
    address internal zora;
    address internal premintExecutor;
    address internal collector;

    IZoraCreator1155PremintExecutor.MintArguments defaultMintArguments;

    event PremintedV2(
        address indexed contractAddress,
        uint256 indexed tokenId,
        bool indexed createdNewContract,
        uint32 uid,
        address minter,
        uint256 quantityMinted
    );

    function setUp() external {
        (creator, creatorPrivateKey) = makeAddrAndKey("creator");
        zora = makeAddr("zora");
        premintExecutor = makeAddr("premintExecutor");
        collector = makeAddr("collector");

        vm.startPrank(zora);
        (, , factoryProxy, ) = Zora1155FactoryFixtures.setup1155AndFactoryProxy(zora, zora);
        vm.stopPrank();

        factory = ZoraCreator1155FactoryImpl(address(factoryProxy));

        preminter = new ZoraCreator1155PremintExecutorImpl(factory);

        defaultMintArguments = IZoraCreator1155PremintExecutor.MintArguments({mintRecipient: premintExecutor, mintComment: "blah", mintReferral: address(0)});
    }

    function makeDefaultContractCreationConfig() internal view returns (ContractCreationConfig memory) {
        return ContractCreationConfig({contractAdmin: creator, contractName: "blah", contractURI: "blah.contract"});
    }

    function getFixedPriceMinter() internal view returns (IMinter1155) {
        return factory.defaultMinters()[0];
    }

    function makeDefaultPremintConfig() internal view returns (PremintConfigV2 memory) {
        return
            PremintConfigV2({
                tokenConfig: Zora1155PremintFixtures.makeDefaultTokenCreationConfigV2(getFixedPriceMinter(), creator),
                uid: 100,
                version: 0,
                deleted: false
            });
    }

    function makePremintConfigWithCreateReferral(address createReferral) internal view returns (PremintConfigV2 memory) {
        return
            PremintConfigV2({
                tokenConfig: Zora1155PremintFixtures.makeTokenCreationConfigV2WithCreateReferral(getFixedPriceMinter(), createReferral, creator),
                uid: 100,
                version: 0,
                deleted: false
            });
    }

    function test_v1Signatures_workOnV2Contract() external {
        // 1. Make contract creation params

        // configuration of contract to create
        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfig memory premintConfig = Zora1155PremintFixtures.makeDefaultV1PremintConfig({
            fixedPriceMinter: getFixedPriceMinter(),
            royaltyRecipient: creator
        });

        // how many tokens are minted to the executor
        uint256 quantityToMint = 1;
        uint256 chainId = block.chainid;

        // get contract hash, which is unique per contract creation config, and can be used
        // retreive the address created for a contract
        address contractAddress = preminter.getContractAddress(contractConfig);

        // 2. Call smart contract to get digest to sign for creation params.
        bytes32 structHash = ZoraCreator1155Attribution.hashPremint(premintConfig);
        bytes32 digest = ZoraCreator1155Attribution.premintHashedTypeDataV4(structHash, contractAddress, ZoraCreator1155Attribution.HASHED_VERSION_1, chainId);

        // 3. Sign the digest
        // create a signature with the digest for the params
        bytes memory signature = _sign(creatorPrivateKey, digest);

        uint256 mintCost = mintFeeAmount * quantityToMint;
        // this account will be used to execute the premint, and should result in a contract being created
        vm.deal(premintExecutor, mintCost);

        // make sure sig is still valid using legacy method
        (bool isValid, , ) = preminter.isValidSignature(contractConfig, premintConfig, signature);
        assertTrue(isValid);

        // now check using new method
        (isValid, ) = preminter.isValidSignatureV1(contractConfig.contractAdmin, contractAddress, premintConfig, signature);
        assertTrue(isValid);

        // now call the premint function, using the same config that was used to generate the digest, and the signature
        vm.prank(premintExecutor);
        uint256 tokenId = preminter.premintV1{value: mintCost}(contractConfig, premintConfig, signature, quantityToMint, defaultMintArguments).tokenId;

        // get the contract address from the preminter based on the contract hash id.
        IZoraCreator1155 created1155Contract = IZoraCreator1155(contractAddress);
        // get the created contract, and make sure that tokens have been minted to the address
        assertEq(created1155Contract.balanceOf(premintExecutor, tokenId), quantityToMint);
    }

    function test_successfullyMintsTokens() external {
        // 1. Make contract creation params

        // configuration of contract to create
        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();

        // how many tokens are minted to the executor
        uint256 quantityToMint = 4;
        uint256 chainId = block.chainid;

        // get contract hash, which is unique per contract creation config, and can be used
        // retreive the address created for a contract
        address contractAddress = preminter.getContractAddress(contractConfig);

        // 2. Call smart contract to get digest to sign for creation params.
        bytes32 structHash = ZoraCreator1155Attribution.hashPremint(premintConfig);
        bytes32 digest = ZoraCreator1155Attribution.premintHashedTypeDataV4(structHash, contractAddress, ZoraCreator1155Attribution.HASHED_VERSION_2, chainId);

        // 3. Sign the digest
        // create a signature with the digest for the params
        bytes memory signature = _sign(creatorPrivateKey, digest);

        uint256 mintCost = mintFeeAmount * quantityToMint;
        // this account will be used to execute the premint, and should result in a contract being created
        vm.deal(premintExecutor, mintCost);

        // now call the premint function, using the same config that was used to generate the digest, and the signature
        vm.prank(premintExecutor);
        uint256 tokenId = preminter.premintV2{value: mintCost}(contractConfig, premintConfig, signature, quantityToMint, defaultMintArguments).tokenId;

        // get the contract address from the preminter based on the contract hash id.
        IZoraCreator1155 created1155Contract = IZoraCreator1155(contractAddress);

        // get the created contract, and make sure that tokens have been minted to the address
        assertEq(created1155Contract.balanceOf(premintExecutor, tokenId), quantityToMint);

        // alter the token creation config, create a new signature with the existing
        // contract config and new token config
        premintConfig.tokenConfig.tokenURI = "blah2.token";
        premintConfig.uid++;

        structHash = ZoraCreator1155Attribution.hashPremint(premintConfig);
        digest = ZoraCreator1155Attribution.premintHashedTypeDataV4(structHash, contractAddress, ZoraCreator1155Attribution.HASHED_VERSION_2, chainId);
        signature = _sign(creatorPrivateKey, digest);

        vm.deal(premintExecutor, mintCost);

        // premint with new token config and signature
        vm.prank(premintExecutor);
        tokenId = preminter.premintV2{value: mintCost}(contractConfig, premintConfig, signature, quantityToMint, defaultMintArguments).tokenId;

        // a new token shoudl have been created, with x tokens minted to the executor, on the same contract address
        // as before since the contract config didnt change
        assertEq(created1155Contract.balanceOf(premintExecutor, tokenId), quantityToMint);
    }

    function test_createsContractWithoutMinting() external {
        // 1. Make contract creation params

        // configuration of contract to create
        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();

        // how many tokens are minted to the executor
        uint256 chainId = block.chainid;

        // get contract hash, which is unique per contract creation config, and can be used
        // retreive the address created for a contract
        address contractAddress = preminter.getContractAddress(contractConfig);

        // 2. Call smart contract to get digest to sign for creation params.
        bytes32 structHash = ZoraCreator1155Attribution.hashPremint(premintConfig);
        bytes32 digest = ZoraCreator1155Attribution.premintHashedTypeDataV4(structHash, contractAddress, ZoraCreator1155Attribution.HASHED_VERSION_2, chainId);

        // 3. Sign the digest
        // create a signature with the digest for the params
        bytes memory signature = _sign(creatorPrivateKey, digest);

        uint256 quantityToMint = 0;

        // now call the premint function, using the same config that was used to generate the digest, and the signature
        vm.prank(premintExecutor);
        uint256 tokenId = preminter.premintV2(contractConfig, premintConfig, signature, quantityToMint, defaultMintArguments).tokenId;

        // get the contract address from the preminter based on the contract hash id.
        IZoraCreator1155 created1155Contract = IZoraCreator1155(contractAddress);

        // get the created contract, and make sure that tokens have been minted to the address
        assertEq(created1155Contract.balanceOf(premintExecutor, tokenId), 0);

        assertEq(ZoraCreator1155Impl(contractAddress).firstMinters(tokenId), address(premintExecutor));
    }

    event CreatorAttribution(bytes32 structHash, string domainName, string version, address creator, bytes signature);

    function test_premint_emitsCreatorAttribution_fromErc1155Contract() external {
        // build a premint
        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();

        // sign and execute premint
        uint256 chainId = block.chainid;

        address deterministicAddress = preminter.getContractAddress(contractConfig);
        bytes32 structHash = ZoraCreator1155Attribution.hashPremint(premintConfig);
        bytes32 digest = ZoraCreator1155Attribution.premintHashedTypeDataV4(
            structHash,
            deterministicAddress,
            ZoraCreator1155Attribution.HASHED_VERSION_2,
            chainId
        );
        bytes memory signature = _sign(creatorPrivateKey, digest);

        uint256 quantityToMint = 4;
        uint256 mintCost = mintFeeAmount * quantityToMint;
        // this account will be used to execute the premint, and should result in a contract being created
        vm.deal(collector, mintCost);

        vm.prank(collector);

        // verify CreatorAttribution was emitted from the erc1155 contract
        vm.expectEmit(true, false, false, false, deterministicAddress);
        emit CreatorAttribution(structHash, ZoraCreator1155Attribution.NAME, ZoraCreator1155Attribution.VERSION_2, creator, signature);

        // create contract and token via premint
        preminter.premintV2{value: mintCost}(contractConfig, premintConfig, signature, quantityToMint, defaultMintArguments);
    }

    /// @notice gets the chains to do fork tests on, by reading environment var FORK_TEST_CHAINS.
    /// Chains are by name, and must match whats under `rpc_endpoints` in the foundry.toml
    function getForkTestChains() private view returns (string[] memory result) {
        try vm.envString("FORK_TEST_CHAINS", ",") returns (string[] memory forkTestChains) {
            result = forkTestChains;
        } catch {
            console.log("could not get fork test chains - make sure the environment variable FORK_TEST_CHAINS is set");
            result = new string[](0);
        }
    }

    function preminterCanMintTokens() internal {
        // we are for now upgrading to correct preminter impl

        // configuration of contract to create
        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();

        // how many tokens are minted to the executor
        uint256 quantityToMint = 4;
        uint256 chainId = block.chainid;

        console.log("loading preminter");

        address contractAddress = preminter.getContractAddress(contractConfig);

        // 2. Call smart contract to get digest to sign for creation params.
        bytes32 structHash = ZoraCreator1155Attribution.hashPremint(premintConfig);
        bytes32 digest = ZoraCreator1155Attribution.premintHashedTypeDataV4(structHash, contractAddress, ZoraCreator1155Attribution.HASHED_VERSION_2, chainId);

        // 3. Sign the digest
        // create a signature with the digest for the params
        bytes memory signature = _sign(creatorPrivateKey, digest);

        // this account will be used to execute the premint, and should result in a contract being created
        premintExecutor = vm.addr(701);
        uint256 mintCost = quantityToMint * 0.000777 ether;
        // now call the premint function, using the same config that was used to generate the digest, and the signature
        vm.deal(premintExecutor, mintCost);
        vm.prank(premintExecutor);
        uint256 tokenId = preminter.premintV2{value: mintCost}(contractConfig, premintConfig, signature, quantityToMint, defaultMintArguments).tokenId;

        // get the contract address from the preminter based on the contract hash id.
        IZoraCreator1155 created1155Contract = IZoraCreator1155(contractAddress);

        // console.log("getting balance");
        // get the created contract, and make sure that tokens have been minted to the address
        uint256 balance = created1155Contract.balanceOf(premintExecutor, tokenId);

        assertEq(balance, quantityToMint, "balance");
    }

    function testTheForkPremint(string memory chainName) private {
        console.log("testing on fork: ", chainName);

        // create and select the fork, which will be used for all subsequent calls
        // it will also affect the current block chain id based on the rpc url returned
        vm.createSelectFork(vm.rpcUrl(chainName));

        // get contract hash, which is unique per contract creation config, and can be used
        // retreive the address created for a contract
        address preminterAddress = getDeployment().preminterProxy;

        if (preminterAddress == address(0)) {
            console.log("preminter not configured for chain...skipping");
            return;
        }

        // override local preminter to use the addresses from the chain
        factory = ZoraCreator1155FactoryImpl(getDeployment().factoryProxy);
        preminter = ZoraCreator1155PremintExecutorImpl(preminterAddress);
    }

    function test_fork_successfullyMintsTokens() external {
        string[] memory forkTestChains = getForkTestChains();
        for (uint256 i = 0; i < forkTestChains.length; i++) {
            testTheForkPremint(forkTestChains[i]);
        }
    }

    function test_signatureForSameContractandUid_shouldMintExistingToken() external {
        // 1. Make contract creation params

        // configuration of contract to create
        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();

        // how many tokens are minted to the executor
        uint256 quantityToMint = 2;
        uint256 chainId = block.chainid;
        string memory comment = "I love it";

        address contractAddress = preminter.getContractAddress(contractConfig);
        IZoraCreator1155 created1155Contract = IZoraCreator1155(contractAddress);

        uint256 firstTokenId = _signAndExecutePremint(contractConfig, premintConfig, creatorPrivateKey, chainId, premintExecutor, quantityToMint, comment);

        // create a sig for another token with same uid, it should mint tokens for the uid's original token
        premintConfig.tokenConfig.tokenURI = "blah2.token";
        bytes memory signature = _signPremint(contractAddress, premintConfig, creatorPrivateKey, chainId);

        uint256 mintCost = mintFeeAmount * quantityToMint;
        vm.deal(collector, mintCost);

        uint256 nextTokenId;

        uint256 beforeTokenBalance = created1155Contract.balanceOf(defaultMintArguments.mintRecipient, firstTokenId);

        vm.startPrank(collector);
        // premint with new token config and signature, but same uid - it should mint tokens for the first token
        nextTokenId = preminter.premintV2{value: mintCost}(contractConfig, premintConfig, signature, quantityToMint, defaultMintArguments).tokenId;

        assertEq(nextTokenId, firstTokenId);
        assertEq(
            created1155Contract.balanceOf(defaultMintArguments.mintRecipient, firstTokenId) - beforeTokenBalance,
            quantityToMint,
            "balance after first mint"
        );

        // change the version, it should still point to the first token
        premintConfig.version++;
        signature = _signPremint(contractAddress, premintConfig, creatorPrivateKey, chainId);

        vm.deal(collector, mintCost);

        // premint with new token config and signature - it should mint tokens for the first token
        nextTokenId = preminter.premintV2{value: mintCost}(contractConfig, premintConfig, signature, quantityToMint, defaultMintArguments).tokenId;
        vm.stopPrank();

        assertEq(nextTokenId, firstTokenId);
        assertEq(
            created1155Contract.balanceOf(defaultMintArguments.mintRecipient, firstTokenId) - beforeTokenBalance,
            quantityToMint * 2,
            "balance after second mint"
        );
    }

    function testCreateTokenPerUid() public {
        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();

        uint256 quantityToMint = 2;
        uint256 chainId = block.chainid;
        string memory comment = "I love it";

        address contractAddress = preminter.getContractAddress(contractConfig);

        uint256 firstTokenId = _signAndExecutePremint(contractConfig, premintConfig, creatorPrivateKey, chainId, premintExecutor, quantityToMint, comment);

        // creator signs a new uid, it should create a new token
        premintConfig.uid++;
        bytes memory signature = _signPremint(contractAddress, premintConfig, creatorPrivateKey, chainId);

        uint256 mintCost = mintFeeAmount * quantityToMint;
        vm.deal(collector, mintCost);

        vm.startPrank(collector);
        // premint with new token config and signature, but same uid - it should mint tokens for the first token
        uint256 nextTokenId = preminter.premintV2{value: mintCost}(contractConfig, premintConfig, signature, quantityToMint, defaultMintArguments).tokenId;

        assertEq(firstTokenId, 1);
        assertEq(nextTokenId, 2);
    }

    function test_deleted_preventsTokenFromBeingMinted() external {
        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();

        premintConfig.deleted = true;
        uint chainId = block.chainid;
        uint256 quantityToMint = 2;

        address contractAddress = preminter.getContractAddress(contractConfig);

        // 2. Call smart contract to get digest to sign for creation params.
        bytes memory signature = _signPremint(contractAddress, premintConfig, creatorPrivateKey, chainId);

        // now call the premint function, using the same config that was used to generate the digest, and the signature
        vm.expectRevert(IZoraCreator1155Errors.PremintDeleted.selector);
        vm.prank(premintExecutor);
        uint256 newTokenId = preminter.premintV2(contractConfig, premintConfig, signature, quantityToMint, defaultMintArguments).tokenId;

        assertEq(newTokenId, 0, "tokenId");

        // make sure no contract was created
        assertEq(contractAddress.code.length, 0, "contract has been deployed");
    }

    function test_emitsPremint_whenNewContract() external {
        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();
        address contractAddress = preminter.getContractAddress(contractConfig);

        // how many tokens are minted to the executor
        uint256 quantityToMint = 4;
        uint256 chainId = block.chainid;

        // Sign the premint
        bytes memory signature = _signPremint(contractAddress, premintConfig, creatorPrivateKey, chainId);

        uint256 expectedTokenId = 1;

        uint256 mintCost = mintFeeAmount * quantityToMint;
        // this account will be used to execute the premint, and should result in a contract being created
        vm.deal(premintExecutor, mintCost);

        vm.startPrank(premintExecutor);

        bool createdNewContract = true;
        vm.expectEmit(true, true, true, true);
        emit PremintedV2(contractAddress, expectedTokenId, createdNewContract, premintConfig.uid, premintExecutor, quantityToMint);
        preminter.premintV2{value: mintCost}(contractConfig, premintConfig, signature, quantityToMint, defaultMintArguments);
    }

    function test_onlyOwner_hasAdminRights_onCreatedToken() public {
        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();

        // how many tokens are minted to the executor
        uint256 quantityToMint = 4;
        uint256 chainId = block.chainid;

        string memory comment = "I love it";

        address createdContractAddress = preminter.getContractAddress(contractConfig);

        uint256 newTokenId = _signAndExecutePremint(contractConfig, premintConfig, creatorPrivateKey, chainId, premintExecutor, quantityToMint, comment);

        // get the contract address from the preminter based on the contract hash id.
        IZoraCreator1155 created1155Contract = IZoraCreator1155(createdContractAddress);

        ZoraCreatorFixedPriceSaleStrategy.SalesConfig memory newSalesConfig = ZoraCreatorFixedPriceSaleStrategy.SalesConfig({
            pricePerToken: 5 ether,
            saleStart: 0,
            saleEnd: 0,
            maxTokensPerAddress: 5,
            fundsRecipient: creator
        });

        IMinter1155 fixedPrice = factory.fixedPriceMinter();

        // have the premint contract try to set the sales config - it should revert with
        // the expected UserMissingRole error
        vm.expectRevert(
            abi.encodeWithSelector(
                IZoraCreator1155Errors.UserMissingRoleForToken.selector,
                address(preminter),
                newTokenId,
                ZoraCreator1155Impl(address(created1155Contract)).PERMISSION_BIT_SALES()
            )
        );
        vm.prank(address(preminter));
        created1155Contract.callSale(
            newTokenId,
            fixedPrice,
            abi.encodeWithSelector(ZoraCreatorFixedPriceSaleStrategy.setSale.selector, newTokenId, newSalesConfig)
        );

        // have admin/creator try to set the sales config - it should succeed
        vm.prank(creator);
        created1155Contract.callSale(
            newTokenId,
            fixedPrice,
            abi.encodeWithSelector(ZoraCreatorFixedPriceSaleStrategy.setSale.selector, newTokenId, newSalesConfig)
        );

        // have the premint contract try to set royalties config - it should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IZoraCreator1155Errors.UserMissingRoleForToken.selector,
                address(preminter),
                newTokenId,
                ZoraCreator1155Impl(address(created1155Contract)).PERMISSION_BIT_FUNDS_MANAGER()
            )
        );
        vm.prank(address(preminter));
        created1155Contract.updateRoyaltiesForToken(newTokenId, defaultRoyaltyConfig);

        // have admin/creator try to set royalties config - it should succeed
        vm.prank(creator);
        created1155Contract.updateRoyaltiesForToken(newTokenId, defaultRoyaltyConfig);
    }

    function test_premintStatus_getsStatus() external {
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();

        // how many tokens are minted to the executor
        uint256 quantityToMint = 4;
        uint256 chainId = block.chainid;
        string memory comment = "I love it";

        uint32 firstUid = premintConfig.uid;
        uint32 secondUid = firstUid + 1;

        ContractCreationConfig memory firstContractConfig = makeDefaultContractCreationConfig();
        ContractCreationConfig memory secondContractConfig = ContractCreationConfig(
            firstContractConfig.contractAdmin,
            firstContractConfig.contractURI,
            string.concat(firstContractConfig.contractName, "4")
        );

        address firstContractAddress = preminter.getContractAddress(firstContractConfig);
        uint256 tokenId = _signAndExecutePremint(firstContractConfig, premintConfig, creatorPrivateKey, chainId, premintExecutor, quantityToMint, comment);

        assertEq(IZoraCreator1155(firstContractAddress).balanceOf(premintExecutor, tokenId), quantityToMint);

        premintConfig.uid = secondUid;
        tokenId = _signAndExecutePremint(firstContractConfig, premintConfig, creatorPrivateKey, chainId, premintExecutor, quantityToMint, comment);

        assertEq(IZoraCreator1155(firstContractAddress).balanceOf(premintExecutor, tokenId), quantityToMint);

        address secondContractAddress = preminter.getContractAddress(secondContractConfig);
        tokenId = _signAndExecutePremint(secondContractConfig, premintConfig, creatorPrivateKey, chainId, premintExecutor, quantityToMint, comment);

        assertEq(IZoraCreator1155(secondContractAddress).balanceOf(premintExecutor, tokenId), quantityToMint);
    }

    function test_premintCanOnlyBeExecutedAfterStartDate(uint8 startDate, uint8 currentTime) external {
        bool shouldRevert;
        if (startDate == 0) {
            shouldRevert = false;
        } else {
            // should revert if before the start date
            shouldRevert = currentTime < startDate;
        }
        vm.warp(currentTime);

        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();
        premintConfig.tokenConfig.mintStart = startDate;

        uint256 quantityToMint = 4;
        uint256 chainId = block.chainid;

        // get signature for the premint:
        bytes memory signature = _signPremint(preminter.getContractAddress(contractConfig), premintConfig, creatorPrivateKey, chainId);

        if (shouldRevert) {
            vm.expectRevert(IZoraCreator1155Errors.MintNotYetStarted.selector);
        }

        uint256 mintCost = mintFeeAmount * quantityToMint;
        vm.deal(premintExecutor, mintCost);

        vm.prank(premintExecutor);
        preminter.premintV2{value: mintCost}(contractConfig, premintConfig, signature, quantityToMint, defaultMintArguments);
    }

    function test_premintCanOnlyBeExecutedUpToDurationFromFirstMint(uint8 startDate, uint8 duration, uint8 timeOfFirstMint, uint8 timeOfSecondMint) external {
        vm.assume(timeOfFirstMint >= startDate);
        vm.assume(timeOfSecondMint >= timeOfFirstMint);

        bool shouldRevert;
        if (duration == 0) {
            shouldRevert = false;
        } else {
            // should revert if after the duration
            shouldRevert = uint16(timeOfSecondMint) > uint16(timeOfFirstMint) + duration;
        }

        // build a premint with a token that has the given start date and duration
        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();
        address contractAddress = preminter.getContractAddress(contractConfig);

        premintConfig.tokenConfig.mintStart = startDate;
        premintConfig.tokenConfig.mintDuration = duration;

        uint256 chainId = block.chainid;

        // get signature for the premint:
        bytes memory signature = _signPremint(contractAddress, premintConfig, creatorPrivateKey, chainId);

        uint256 quantityToMint = 2;
        string memory comment = "I love it";

        uint256 mintCost = mintFeeAmount * quantityToMint;
        vm.deal(premintExecutor, mintCost);

        vm.startPrank(premintExecutor);

        vm.warp(timeOfFirstMint);
        uint256 tokenId = preminter.premintV2{value: mintCost}(contractConfig, premintConfig, signature, quantityToMint, defaultMintArguments).tokenId;

        vm.warp(timeOfSecondMint);

        // execute mint directly on the contract - and check make sure it reverts if minted after sale start
        IMinter1155 fixedPriceMinter = factory.defaultMinters()[0];
        if (shouldRevert) {
            vm.expectRevert(ZoraCreatorFixedPriceSaleStrategy.SaleEnded.selector);
        }

        vm.deal(premintExecutor, mintCost);
        IZoraCreator1155(contractAddress).mint{value: mintCost}(fixedPriceMinter, tokenId, quantityToMint, abi.encode(premintExecutor, comment));

        vm.stopPrank();
    }

    function test_premintStatus_getsIfContractHasBeenCreatedAndTokenIdForPremint() external {
        // build a premint
        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();

        // get premint status
        (bool contractCreated, uint256 tokenId) = preminter.premintStatus(preminter.getContractAddress(contractConfig), premintConfig.uid);
        // contract should not be created and token id should be 0
        assertEq(contractCreated, false);
        assertEq(tokenId, 0);

        // sign and execute premint
        uint256 newTokenId = _signAndExecutePremint(contractConfig, premintConfig, creatorPrivateKey, block.chainid, vm.addr(701), 1, "hi");

        // get status
        (contractCreated, tokenId) = preminter.premintStatus(preminter.getContractAddress(contractConfig), premintConfig.uid);
        // contract should be created and token id should be same as one that was created
        assertEq(contractCreated, true);
        assertEq(tokenId, newTokenId);

        // get status for another uid
        (contractCreated, tokenId) = preminter.premintStatus(preminter.getContractAddress(contractConfig), premintConfig.uid + 1);
        // contract should be created and token id should be 0
        assertEq(contractCreated, true);
        assertEq(tokenId, 0);
    }

    function test_premint_whenContractCreated_premintCanOnlyBeExecutedByPermissionBitMinter() external {
        // build a premint
        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();

        address contractAddress = preminter.getContractAddress(contractConfig);

        // sign and execute premint
        bytes memory signature = _signPremint(contractAddress, premintConfig, creatorPrivateKey, block.chainid);

        (bool isValidSignature, address recoveredSigner) = preminter.isValidSignatureV2(
            contractConfig.contractAdmin,
            contractAddress,
            premintConfig,
            signature
        );

        assertEq(creator, recoveredSigner, "recovered the wrong signer");
        assertTrue(isValidSignature, "signature should be valid");

        _signAndExecutePremint(contractConfig, premintConfig, creatorPrivateKey, block.chainid, premintExecutor, 1, "hi");

        // contract has been created

        // have another creator sign a premint
        uint256 newCreatorPrivateKey = 0xA11CF;
        address newCreator = vm.addr(newCreatorPrivateKey);
        PremintConfigV2 memory premintConfig2 = premintConfig;
        premintConfig2.uid++;

        // have new creator sign a premint, isValidSignature should be false, and premint should revert
        bytes memory newCreatorSignature = _signPremint(contractAddress, premintConfig2, newCreatorPrivateKey, block.chainid);

        // it should not be considered a valid signature
        (isValidSignature, ) = preminter.isValidSignatureV2(contractConfig.contractAdmin, contractAddress, premintConfig2, newCreatorSignature);

        assertFalse(isValidSignature, "signature should not be valid");

        uint256 quantityToMint = 1;
        uint256 mintCost = mintFeeAmount * quantityToMint;
        vm.deal(premintExecutor, mintCost);

        // try to mint, it should revert
        vm.expectRevert(abi.encodeWithSelector(IZoraCreator1155Errors.UserMissingRoleForToken.selector, newCreator, CONTRACT_BASE_ID, PERMISSION_BIT_MINTER));
        vm.prank(premintExecutor);
        preminter.premintV2{value: mintCost}(contractConfig, premintConfig2, newCreatorSignature, quantityToMint, defaultMintArguments);

        // now grant the new creator permission to mint
        vm.prank(creator);
        IZoraCreator1155(contractAddress).addPermission(CONTRACT_BASE_ID, newCreator, PERMISSION_BIT_MINTER);

        // should now be considered a valid signature
        (isValidSignature, ) = preminter.isValidSignatureV2(contractConfig.contractAdmin, contractAddress, premintConfig2, newCreatorSignature);
        assertTrue(isValidSignature, "valid signature after granted permission");

        vm.deal(premintExecutor, mintCost);

        // try to mint again, should not revert
        vm.prank(premintExecutor);
        preminter.premintV2{value: mintCost}(contractConfig, premintConfig2, newCreatorSignature, quantityToMint, defaultMintArguments);
    }

    function test_premintVersion_whenCreatedBeforePremint_returnsZero() external {
        vm.createSelectFork("zora", 5_789_193);

        // create preminter on fork
        vm.startPrank(zora);
        (, , factoryProxy, ) = Zora1155FactoryFixtures.setup1155AndFactoryProxy(zora, zora);
        vm.stopPrank();

        factory = ZoraCreator1155FactoryImpl(address(factoryProxy));

        preminter = new ZoraCreator1155PremintExecutorImpl(factory);

        // this is a known contract deployed from the legacy factory proxy on zora mainnet
        // that does not support getting the uid or premint sig version (it is prior to version 2)
        address erc1155BeforePremint = 0xcACBbee9C2C703274BE026B62860cF56361410f3;
        assertFalse(erc1155BeforePremint.code.length == 0);

        // if contract is not a known 1155 contract that supports getting uid or premint sig version,
        // this should return 0
        assertEq(preminter.supportedPremintSignatureVersion(erc1155BeforePremint), "0");
    }

    function testPremintWithCreateReferral() public {
        address createReferral = makeAddr("createReferral");

        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makePremintConfigWithCreateReferral(createReferral);

        uint256 createdTokenId = _signAndExecutePremint(contractConfig, premintConfig, creatorPrivateKey, block.chainid, premintExecutor, 1, "hi");

        ZoraCreator1155Impl createdContract = ZoraCreator1155Impl(preminter.getContractAddress(contractConfig));

        address storedCreateReferral = createdContract.createReferrals(createdTokenId);

        assertEq(storedCreateReferral, createReferral);
    }

    function test_premintWithNoMintRecipient_mintsTokenToMsgSender() public {
        ContractCreationConfig memory contractConfig = makeDefaultContractCreationConfig();
        PremintConfigV2 memory premintConfig = makeDefaultPremintConfig();

        address contractAddress = preminter.getContractAddress(contractConfig);

        // sign and execute premint
        bytes memory signature = _signPremint(contractAddress, premintConfig, creatorPrivateKey, block.chainid);

        IZoraCreator1155PremintExecutor.MintArguments memory mintArguments = IZoraCreator1155PremintExecutor.MintArguments({
            mintRecipient: address(0),
            mintComment: "",
            mintReferral: address(0)
        });

        uint256 quantityToMint = 3;
        uint256 mintCost = mintFeeAmount * quantityToMint;
        address executor = makeAddr("executor");
        vm.deal(executor, mintCost);

        // now call the premint function, using the same config that was used to generate the digest, and the signature
        vm.prank(executor);
        uint256 newTokenId = preminter.premintV2{value: mintCost}(contractConfig, premintConfig, signature, quantityToMint, mintArguments).tokenId;

        // assert executor gets minted the tokens
        assertEq(IZoraCreator1155(contractAddress).balanceOf(executor, newTokenId), quantityToMint);
    }

    function _signAndExecutePremint(
        ContractCreationConfig memory contractConfig,
        PremintConfigV2 memory premintConfig,
        uint256 privateKey,
        uint256 chainId,
        address executor,
        uint256 quantityToMint,
        string memory comment
    ) private returns (uint256 newTokenId) {
        bytes memory signature = _signPremint(preminter.getContractAddress(contractConfig), premintConfig, privateKey, chainId);

        IZoraCreator1155PremintExecutor.MintArguments memory mintArguments = IZoraCreator1155PremintExecutor.MintArguments({
            mintRecipient: executor,
            mintComment: comment,
            mintReferral: address(0)
        });

        uint256 mintCost = mintFeeAmount * quantityToMint;
        vm.deal(executor, mintCost);

        // now call the premint function, using the same config that was used to generate the digest, and the signature
        vm.prank(executor);
        newTokenId = preminter.premintV2{value: mintCost}(contractConfig, premintConfig, signature, quantityToMint, mintArguments).tokenId;
    }

    function _signPremint(
        address contractAddress,
        PremintConfigV2 memory premintConfig,
        uint256 privateKey,
        uint256 chainId
    ) private pure returns (bytes memory signature) {
        bytes32 structHash = ZoraCreator1155Attribution.hashPremint(premintConfig);
        bytes32 digest = ZoraCreator1155Attribution.premintHashedTypeDataV4(structHash, contractAddress, ZoraCreator1155Attribution.HASHED_VERSION_2, chainId);

        // create a signature with the digest for the params
        signature = _sign(privateKey, digest);
    }

    function _sign(uint256 privateKey, bytes32 digest) private pure returns (bytes memory) {
        // sign the message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        // combine into a single bytes array
        return abi.encodePacked(r, s, v);
    }
}
