#[
// ┏━━━┓━┏┓━┏┓━━┏━━━┓━━┏━━━┓━━━━┏━━━┓━━━━━━━━━━━━━━━━━━━┏┓━━━━━┏━━━┓━━━━━━━━━┏┓━━━━━━━━━━━━━━┏┓━
// ┃┏━━┛┏┛┗┓┃┃━━┃┏━┓┃━━┃┏━┓┃━━━━┗┓┏┓┃━━━━━━━━━━━━━━━━━━┏┛┗┓━━━━┃┏━┓┃━━━━━━━━┏┛┗┓━━━━━━━━━━━━┏┛┗┓
// ┃┗━━┓┗┓┏┛┃┗━┓┗┛┏┛┃━━┃┃━┃┃━━━━━┃┃┃┃┏━━┓┏━━┓┏━━┓┏━━┓┏┓┗┓┏┛━━━━┃┃━┗┛┏━━┓┏━┓━┗┓┏┛┏━┓┏━━┓━┏━━┓┗┓┏┛
// ┃┏━━┛━┃┃━┃┏┓┃┏━┛┏┛━━┃┃━┃┃━━━━━┃┃┃┃┃┏┓┃┃┏┓┃┃┏┓┃┃━━┫┣┫━┃┃━━━━━┃┃━┏┓┃┏┓┃┃┏┓┓━┃┃━┃┏┛┗━┓┃━┃┏━┛━┃┃━
// ┃┗━━┓━┃┗┓┃┃┃┃┃┃┗━┓┏┓┃┗━┛┃━━━━┏┛┗┛┃┃┃━┫┃┗┛┃┃┗┛┃┣━━┃┃┃━┃┗┓━━━━┃┗━┛┃┃┗┛┃┃┃┃┃━┃┗┓┃┃━┃┗┛┗┓┃┗━┓━┃┗┓
// ┗━━━┛━┗━┛┗┛┗┛┗━━━┛┗┛┗━━━┛━━━━┗━━━┛┗━━┛┃┏━┛┗━━┛┗━━┛┗┛━┗━┛━━━━┗━━━┛┗━━┛┗┛┗┛━┗━┛┗┛━┗━━━┛┗━━┛━┗━┛
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┃┃━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┗┛━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// SPDX-License-Identifier: CC0-1.0

pragma solidity 0.6.11;

// This interface is designed to be compatible with the Vyper version.
/// @notice This is the Ethereum 2.0 deposit contract interface.
/// For more information see the Phase 0 specification under https://github.com/ethereum/eth2.0-specs
interface IDepositContract {
    /// @notice A processed deposit event.
    event DepositEvent(
        bytes pubkey,
        bytes withdrawal_credentials,
        bytes amount,
        bytes signature,
        bytes index
    );

    /// @notice Submit a Phase 0 DepositData object.
    /// @param pubkey A BLS12-381 public key.
    /// @param withdrawal_credentials Commitment to a public key for withdrawals.
    /// @param signature A BLS12-381 signature.
    /// @param deposit_data_root The SHA-256 hash of the SSZ-encoded DepositData object.
    /// Used as a protection against malformed input.
    function deposit(
        bytes calldata pubkey,
        bytes calldata withdrawal_credentials,
        bytes calldata signature,
        bytes32 deposit_data_root
    ) external payable;

    /// @notice Query the current deposit root hash.
    /// @return The deposit root hash.
    function get_deposit_root() external view returns (bytes32);

    /// @notice Query the current deposit count.
    /// @return The deposit count encoded as a little endian 64-bit number.
    function get_deposit_count() external view returns (bytes memory);
}

// Based on official specification in https://eips.ethereum.org/EIPS/eip-165
interface ERC165 {
    /// @notice Query if a contract implements an interface
    /// @param interfaceId The interface identifier, as specified in ERC-165
    /// @dev Interface identification is specified in ERC-165. This function
    ///  uses less than 30,000 gas.
    /// @return `true` if the contract implements `interfaceId` and
    ///  `interfaceId` is not 0xffffffff, `false` otherwise
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);
}

// This is a rewrite of the Vyper Eth2.0 deposit contract in Solidity.
// It tries to stay as close as possible to the original source code.
/// @notice This is the Ethereum 2.0 deposit contract interface.
/// For more information see the Phase 0 specification under https://github.com/ethereum/eth2.0-specs
contract DepositContract is IDepositContract, ERC165 {
    uint constant DEPOSIT_CONTRACT_TREE_DEPTH = 32;
    // NOTE: this also ensures `deposit_count` will fit into 64-bits
    uint constant MAX_DEPOSIT_COUNT = 2**DEPOSIT_CONTRACT_TREE_DEPTH - 1;

    bytes32[DEPOSIT_CONTRACT_TREE_DEPTH] branch;
    uint256 deposit_count;

    bytes32[DEPOSIT_CONTRACT_TREE_DEPTH] zero_hashes;

    constructor() public {
        // Compute hashes in empty sparse Merkle tree
        for (uint height = 0; height < DEPOSIT_CONTRACT_TREE_DEPTH - 1; height++)
            zero_hashes[height + 1] = sha256(abi.encodePacked(zero_hashes[height], zero_hashes[height]));
    }

    function get_deposit_root() override external view returns (bytes32) {
        bytes32 node;
        uint size = deposit_count;
        for (uint height = 0; height < DEPOSIT_CONTRACT_TREE_DEPTH; height++) {
            if ((size & 1) == 1)
                node = sha256(abi.encodePacked(branch[height], node));
            else
                node = sha256(abi.encodePacked(node, zero_hashes[height]));
            size /= 2;
        }
        return sha256(abi.encodePacked(
            node,
            to_little_endian_64(uint64(deposit_count)),
            bytes24(0)
        ));
    }

    function get_deposit_count() override external view returns (bytes memory) {
        return to_little_endian_64(uint64(deposit_count));
    }

    function deposit(
        bytes calldata pubkey,
        bytes calldata withdrawal_credentials,
        bytes calldata signature,
        bytes32 deposit_data_root
    ) override external payable {
        // Extended ABI length checks since dynamic types are used.
        require(pubkey.length == 48, "DepositContract: invalid pubkey length");
        require(withdrawal_credentials.length == 32, "DepositContract: invalid withdrawal_credentials length");
        require(signature.length == 96, "DepositContract: invalid signature length");

        // Check deposit amount
        require(msg.value >= 1 ether, "DepositContract: deposit value too low");
        require(msg.value % 1 gwei == 0, "DepositContract: deposit value not multiple of gwei");
        uint deposit_amount = msg.value / 1 gwei;
        require(deposit_amount <= type(uint64).max, "DepositContract: deposit value too high");

        // Emit `DepositEvent` log
        bytes memory amount = to_little_endian_64(uint64(deposit_amount));
        emit DepositEvent(
            pubkey,
            withdrawal_credentials,
            amount,
            signature,
            to_little_endian_64(uint64(deposit_count))
        );

        // Compute deposit data root (`DepositData` hash tree root)
        bytes32 pubkey_root = sha256(abi.encodePacked(pubkey, bytes16(0)));
        bytes32 signature_root = sha256(abi.encodePacked(
            sha256(abi.encodePacked(signature[:64])),
            sha256(abi.encodePacked(signature[64:], bytes32(0)))
        ));
        bytes32 node = sha256(abi.encodePacked(
            sha256(abi.encodePacked(pubkey_root, withdrawal_credentials)),
            sha256(abi.encodePacked(amount, bytes24(0), signature_root))
        ));

        // Verify computed and expected deposit data roots match
        require(node == deposit_data_root, "DepositContract: reconstructed DepositData does not match supplied deposit_data_root");

        // Avoid overflowing the Merkle tree (and prevent edge case in computing `branch`)
        require(deposit_count < MAX_DEPOSIT_COUNT, "DepositContract: merkle tree full");

        // Add deposit data root to Merkle tree (update a single `branch` node)
        deposit_count += 1;
        uint size = deposit_count;
        for (uint height = 0; height < DEPOSIT_CONTRACT_TREE_DEPTH; height++) {
            if ((size & 1) == 1) {
                branch[height] = node;
                return;
            }
            node = sha256(abi.encodePacked(branch[height], node));
            size /= 2;
        }
        // As the loop should always end prematurely with the `return` statement,
        // this code should be unreachable. We assert `false` just to be safe.
        assert(false);
    }

    function supportsInterface(bytes4 interfaceId) override external pure returns (bool) {
        return interfaceId == type(ERC165).interfaceId || interfaceId == type(IDepositContract).interfaceId;
    }

    function to_little_endian_64(uint64 value) internal pure returns (bytes memory ret) {
        ret = new bytes(8);
        bytes8 bytesValue = bytes8(value);
        // Byteswapping during copying to bytes.
        ret[0] = bytesValue[7];
        ret[1] = bytesValue[6];
        ret[2] = bytesValue[5];
        ret[3] = bytesValue[4];
        ret[4] = bytesValue[3];
        ret[5] = bytesValue[2];
        ret[6] = bytesValue[1];
        ret[7] = bytesValue[0];
    }
}
]#

# source: https://etherscan.io/address/0x00000000219ab540356cbb839cbe05303d7705fa#code

const DepositContractCode* = "0x" &
  "608060405234801561001057600080fd5b5060005b601f811015610102576002" &
  "6021826020811061002c57fe5b01546021836020811061003b57fe5b01546040" &
  "5160200180838152602001828152602001925050506040516020818303038152" &
  "906040526040518082805190602001908083835b602083106100925780518252" &
  "601f199092019160209182019101610073565b51815160209384036101000a60" &
  "001901801990921691161790526040519190930194509192505080830381855a" &
  "fa1580156100d1573d6000803e3d6000fd5b5050506040513d60208110156100" &
  "e657600080fd5b5051602160018301602081106100f857fe5b01556001016100" &
  "14565b506118d680620001136000396000f3fe60806040526004361061003f57" &
  "60003560e01c806301ffc9a71461004457806322895118146100a4578063621f" &
  "d130146101ba578063c5f2892f14610244575b600080fd5b3480156100505760" &
  "0080fd5b506100906004803603602081101561006757600080fd5b50357fffff" &
  "ffff000000000000000000000000000000000000000000000000000000001661" &
  "026b565b604080519115158252519081900360200190f35b6101b86004803603" &
  "60808110156100ba57600080fd5b810190602081018135640100000000811115" &
  "6100d557600080fd5b8201836020820111156100e757600080fd5b8035906020" &
  "019184600183028401116401000000008311171561010957600080fd5b919390" &
  "92909160208101903564010000000081111561012757600080fd5b8201836020" &
  "8201111561013957600080fd5b80359060200191846001830284011164010000" &
  "00008311171561015b57600080fd5b9193909290916020810190356401000000" &
  "0081111561017957600080fd5b82018360208201111561018b57600080fd5b80" &
  "3590602001918460018302840111640100000000831117156101ad57600080fd" &
  "5b919350915035610304565b005b3480156101c657600080fd5b506101cf6110" &
  "b5565b6040805160208082528351818301528351919283929083019185019080" &
  "838360005b838110156102095781810151838201526020016101f1565b505050" &
  "50905090810190601f1680156102365780820380516001836020036101000a03" &
  "1916815260200191505b509250505060405180910390f35b3480156102505760" &
  "0080fd5b506102596110c7565b60408051918252519081900360200190f35b60" &
  "007fffffffff0000000000000000000000000000000000000000000000000000" &
  "000082167f01ffc9a70000000000000000000000000000000000000000000000" &
  "000000000014806102fe57507fffffffff000000000000000000000000000000" &
  "0000000000000000000000000082167f85640907000000000000000000000000" &
  "00000000000000000000000000000000145b92915050565b6030861461035d57" &
  "6040517f08c379a0000000000000000000000000000000000000000000000000" &
  "0000000081526004018080602001828103825260268152602001806118056026" &
  "913960400191505060405180910390fd5b602084146103b6576040517f08c379" &
  "a000000000000000000000000000000000000000000000000000000000815260" &
  "040180806020018281038252603681526020018061179c603691396040019150" &
  "5060405180910390fd5b6060821461040f576040517f08c379a0000000000000" &
  "0000000000000000000000000000000000000000000081526004018080602001" &
  "8281038252602981526020018061187860299139604001915050604051809103" &
  "90fd5b670de0b6b3a7640000341015610470576040517f08c379a00000000000" &
  "0000000000000000000000000000000000000000000000815260040180806020" &
  "0182810382526026815260200180611852602691396040019150506040518091" &
  "0390fd5b633b9aca003406156104cd576040517f08c379a00000000000000000" &
  "0000000000000000000000000000000000000000815260040180806020018281" &
  "03825260338152602001806117d26033913960400191505060405180910390fd" &
  "5b633b9aca00340467ffffffffffffffff811115610535576040517f08c379a0" &
  "0000000000000000000000000000000000000000000000000000000081526004" &
  "0180806020018281038252602781526020018061182b60279139604001915050" &
  "60405180910390fd5b6060610540826114ba565b90507f649bbc62d0e31342af" &
  "ea4e5cd82d4049e7e1ee912fc0889aa790803be39038c589898989858a8a6105" &
  "756020546114ba565b6040805160a08082528101899052908190602082019082" &
  "01606083016080840160c085018e8e80828437600083820152601f017fffffff" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0169091" &
  "0187810386528c815260200190508c8c808284376000838201819052601f9091" &
  "017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
  "ffe01690920188810386528c5181528c51602091820193918e01925090819084" &
  "9084905b83811015610648578181015183820152602001610630565b50505050" &
  "905090810190601f1680156106755780820380516001836020036101000a0319" &
  "16815260200191505b5086810383528881526020018989808284376000838201" &
  "819052601f9091017fffffffffffffffffffffffffffffffffffffffffffffff" &
  "ffffffffffffffffe0169092018881038452895181528951602091820193918b" &
  "019250908190849084905b838110156106ef5781810151838201526020016106" &
  "d7565b50505050905090810190601f16801561071c5780820380516001836020" &
  "036101000a031916815260200191505b509d5050505050505050505050505050" &
  "60405180910390a1600060028a8a600060801b60405160200180848480828437" &
  "7fffffffffffffffffffffffffffffffff000000000000000000000000000000" &
  "0090941691909301908152604080517fffffffffffffffffffffffffffffffff" &
  "fffffffffffffffffffffffffffffff081840301815260109092019081905281" &
  "5191955093508392506020850191508083835b602083106107fc57805182527f" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0" &
  "90920191602091820191016107bf565b51815160209384036101000a7fffffff" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffff018019" &
  "90921691161790526040519190930194509192505080830381855afa15801561" &
  "0859573d6000803e3d6000fd5b5050506040513d602081101561086e57600080" &
  "fd5b5051905060006002806108846040848a8c6116fe565b6040516020018083" &
  "8380828437808301925050509250505060405160208183030381529060405260" &
  "40518082805190602001908083835b602083106108f857805182527fffffffff" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffffffffe090920191" &
  "602091820191016108bb565b51815160209384036101000a7fffffffffffffff" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffff01801990921691" &
  "161790526040519190930194509192505080830381855afa158015610955573d" &
  "6000803e3d6000fd5b5050506040513d602081101561096a57600080fd5b5051" &
  "600261097b896040818d6116fe565b6040516000906020018084848082843791" &
  "9091019283525050604080518083038152602092830191829052805190945090" &
  "925082918401908083835b602083106109f457805182527fffffffffffffffff" &
  "ffffffffffffffffffffffffffffffffffffffffffffffe09092019160209182" &
  "0191016109b7565b51815160209384036101000a7fffffffffffffffffffffff" &
  "ffffffffffffffffffffffffffffffffffffffffff0180199092169116179052" &
  "6040519190930194509192505080830381855afa158015610a51573d6000803e" &
  "3d6000fd5b5050506040513d6020811015610a6657600080fd5b505160408051" &
  "6020818101949094528082019290925280518083038201815260609092019081" &
  "905281519192909182918401908083835b60208310610ada57805182527fffff" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe09092" &
  "019160209182019101610a9d565b51815160209384036101000a7fffffffffff" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffffffff0180199092" &
  "1691161790526040519190930194509192505080830381855afa158015610b37" &
  "573d6000803e3d6000fd5b5050506040513d6020811015610b4c57600080fd5b" &
  "50516040805160208101858152929350600092600292839287928f928f920183" &
  "8380828437808301925050509350505050604051602081830303815290604052" &
  "6040518082805190602001908083835b60208310610bd957805182527fffffff" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0909201" &
  "9160209182019101610b9c565b51815160209384036101000a7fffffffffffff" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffffff018019909216" &
  "91161790526040519190930194509192505080830381855afa158015610c3657" &
  "3d6000803e3d6000fd5b5050506040513d6020811015610c4b57600080fd5b50" &
  "516040518651600291889160009188916020918201918291908601908083835b" &
  "60208310610ca957805182527fffffffffffffffffffffffffffffffffffffff" &
  "ffffffffffffffffffffffffe09092019160209182019101610c6c565b600183" &
  "6020036101000a03801982511681845116808217855250505050505090500183" &
  "67ffffffffffffffff191667ffffffffffffffff191681526018018281526020" &
  "0193505050506040516020818303038152906040526040518082805190602001" &
  "908083835b60208310610d4e57805182527fffffffffffffffffffffffffffff" &
  "ffffffffffffffffffffffffffffffffffe09092019160209182019101610d11" &
  "565b51815160209384036101000a7fffffffffffffffffffffffffffffffffff" &
  "ffffffffffffffffffffffffffffff0180199092169116179052604051919093" &
  "0194509192505080830381855afa158015610dab573d6000803e3d6000fd5b50" &
  "50506040513d6020811015610dc057600080fd5b505160408051602081810194" &
  "9094528082019290925280518083038201815260609092019081905281519192" &
  "909182918401908083835b60208310610e3457805182527fffffffffffffffff" &
  "ffffffffffffffffffffffffffffffffffffffffffffffe09092019160209182" &
  "019101610df7565b51815160209384036101000a7fffffffffffffffffffffff" &
  "ffffffffffffffffffffffffffffffffffffffffff0180199092169116179052" &
  "6040519190930194509192505080830381855afa158015610e91573d6000803e" &
  "3d6000fd5b5050506040513d6020811015610ea657600080fd5b505190508581" &
  "14610f02576040517f08c379a000000000000000000000000000000000000000" &
  "0000000000000000008152600401808060200182810382526054815260200180" &
  "6117486054913960600191505060405180910390fd5b60205463ffffffff1161" &
  "0f60576040517f08c379a0000000000000000000000000000000000000000000" &
  "0000000000000081526004018080602001828103825260218152602001806117" &
  "276021913960400191505060405180910390fd5b602080546001019081905560" &
  "005b60208110156110a9578160011660011415610fa057826000826020811061" &
  "0f9157fe5b0155506110ac95505050505050565b600260008260208110610faf" &
  "57fe5b0154846040516020018083815260200182815260200192505050604051" &
  "6020818303038152906040526040518082805190602001908083835b60208310" &
  "61102557805182527fffffffffffffffffffffffffffffffffffffffffffffff" &
  "ffffffffffffffffe09092019160209182019101610fe8565b51815160209384" &
  "036101000a7fffffffffffffffffffffffffffffffffffffffffffffffffffff" &
  "ffffffffffff0180199092169116179052604051919093019450919250508083" &
  "0381855afa158015611082573d6000803e3d6000fd5b5050506040513d602081" &
  "101561109757600080fd5b50519250600282049150600101610f6e565b50fe5b" &
  "50505050505050565b60606110c26020546114ba565b905090565b6020546000" &
  "908190815b60208110156112f05781600116600114156111e657600260008260" &
  "2081106110f557fe5b0154846040516020018083815260200182815260200192" &
  "5050506040516020818303038152906040526040518082805190602001908083" &
  "835b6020831061116b57805182527fffffffffffffffffffffffffffffffffff" &
  "ffffffffffffffffffffffffffffe0909201916020918201910161112e565b51" &
  "815160209384036101000a7fffffffffffffffffffffffffffffffffffffffff" &
  "ffffffffffffffffffffffff0180199092169116179052604051919093019450" &
  "9192505080830381855afa1580156111c8573d6000803e3d6000fd5b50505060" &
  "40513d60208110156111dd57600080fd5b505192506112e2565b600283602183" &
  "602081106111f657fe5b01546040516020018083815260200182815260200192" &
  "5050506040516020818303038152906040526040518082805190602001908083" &
  "835b6020831061126b57805182527fffffffffffffffffffffffffffffffffff" &
  "ffffffffffffffffffffffffffffe0909201916020918201910161122e565b51" &
  "815160209384036101000a7fffffffffffffffffffffffffffffffffffffffff" &
  "ffffffffffffffffffffffff0180199092169116179052604051919093019450" &
  "9192505080830381855afa1580156112c8573d6000803e3d6000fd5b50505060" &
  "40513d60208110156112dd57600080fd5b505192505b60028204915060010161" &
  "10d1565b506002826112ff6020546114ba565b600060401b6040516020018084" &
  "815260200183805190602001908083835b6020831061135a57805182527fffff" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe09092" &
  "01916020918201910161131d565b51815160209384036101000a7fffffffffff" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffffffff0180199092" &
  "1691161790527fffffffffffffffffffffffffffffffffffffffffffffffff00" &
  "0000000000000095909516920191825250604080518083037fffffffffffffff" &
  "fffffffffffffffffffffffffffffffffffffffffffffffff801815260189092" &
  "0190819052815191955093508392850191508083835b6020831061143f578051" &
  "82527fffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
  "ffffe09092019160209182019101611402565b51815160209384036101000a7f" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
  "01801990921691161790526040519190930194509192505080830381855afa15" &
  "801561149c573d6000803e3d6000fd5b5050506040513d60208110156114b157" &
  "600080fd5b50519250505090565b604080516008808252818301909252606091" &
  "60208201818036833701905050905060c082901b8060071a60f81b8260008151" &
  "81106114f457fe5b60200101907effffffffffffffffffffffffffffffffffff" &
  "ffffffffffffffffffffffffff1916908160001a9053508060061a60f81b8260" &
  "018151811061153757fe5b60200101907effffffffffffffffffffffffffffff" &
  "ffffffffffffffffffffffffffffffff1916908160001a9053508060051a60f8" &
  "1b8260028151811061157a57fe5b60200101907effffffffffffffffffffffff" &
  "ffffffffffffffffffffffffffffffffffffff1916908160001a905350806004" &
  "1a60f81b826003815181106115bd57fe5b60200101907effffffffffffffffff" &
  "ffffffffffffffffffffffffffffffffffffffffffff1916908160001a905350" &
  "8060031a60f81b8260048151811061160057fe5b60200101907effffffffffff" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffff1916908160001a" &
  "9053508060021a60f81b8260058151811061164357fe5b60200101907effffff" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff19169081" &
  "60001a9053508060011a60f81b8260068151811061168657fe5b60200101907e" &
  "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff19" &
  "16908160001a9053508060001a60f81b826007815181106116c957fe5b602001" &
  "01907effffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
  "ffff1916908160001a90535050919050565b6000808585111561170d578182fd" &
  "5b83861115611719578182fd5b505082019391909203915056fe4465706f7369" &
  "74436f6e74726163743a206d65726b6c6520747265652066756c6c4465706f73" &
  "6974436f6e74726163743a207265636f6e7374727563746564204465706f7369" &
  "744461746120646f6573206e6f74206d6174636820737570706c696564206465" &
  "706f7369745f646174615f726f6f744465706f736974436f6e74726163743a20" &
  "696e76616c6964207769746864726177616c5f63726564656e7469616c73206c" &
  "656e6774684465706f736974436f6e74726163743a206465706f736974207661" &
  "6c7565206e6f74206d756c7469706c65206f6620677765694465706f73697443" &
  "6f6e74726163743a20696e76616c6964207075626b6579206c656e6774684465" &
  "706f736974436f6e74726163743a206465706f7369742076616c756520746f6f" &
  "20686967684465706f736974436f6e74726163743a206465706f736974207661" &
  "6c756520746f6f206c6f774465706f736974436f6e74726163743a20696e7661" &
  "6c6964207369676e6174757265206c656e677468a2646970667358221220dcec" &
  "a8706b29e917dacf25fceef95acac8d90d765ac926663ce4096195952b616473" &
  "6f6c634300060b0033"