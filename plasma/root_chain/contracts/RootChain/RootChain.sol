pragma solidity 0.4.18;

import 'SafeMath.sol';
import 'Math.sol';
import 'RLP.sol';
import 'Merkle.sol';
import 'Validate.sol';
import 'PriorityQueue.sol';


/**
 * @title RootChain
 * @dev This contract secures a utxo payments plasma child chain to ethereum
 */

contract RootChain {
    using SafeMath for uint256;
    using RLP for bytes;
    using RLP for RLP.RLPItem;
    using RLP for RLP.Iterator;
    using Merkle for bytes32;

    /*
     * Events
     */
    event Deposit(
        address indexed depositor,
        uint256 amount,
        uint256 depositBlock
    );
    event Exit(
        address indexed exitor,
        uint256 utxoPos
    );

    /*
     *  Storage
     */
    mapping(uint256 => childBlock) public childChain;
    mapping(uint256 => exit) public exits;
    PriorityQueue exitsQueue;
    address public authority;
    /* Block numbering scheme below is needed to prevent Ethereum reorg from invalidating blocks submitted
       by operator. Two mechanisms must be in place to prevent chain from crashing:
       1) don't mine tx that spent fresh deposits; if they are reorged from existence, block is invalid
       2) disappearance of submit block does not affect operator's block numbering; hence tx submitted by
       users that address that block stay valid.
    */
    uint256 public currentChildBlock; /* ends with 000 */
    uint256 public currentDepositBlock; /* takes values in range 1..999 */
    uint256 public childBlockInterval;
    uint256 public currentFeeExit;

    struct exit {
        address owner;
        uint256 amount;
    }

    struct childBlock {
        bytes32 root;
        uint256 created_at;
    }

    /*
     *  Modifiers
     */
    modifier isAuthority() {
        require(msg.sender == authority);
        _;
    }

    /*
     * Public Functions
     */

    function RootChain()
        public
    {
        authority = msg.sender;
        childBlockInterval = 1000;
        currentChildBlock = childBlockInterval;
        currentDepositBlock = 1;
        currentFeeExit = 1;
        exitsQueue = new PriorityQueue();
    }

    // @dev Allows Plasma chain operator to submit block root
    // @param root The root of a child chain block
    function submitBlock(bytes32 root)
        public
        isAuthority
    {
        childChain[currentChildBlock] = childBlock({
            root: root,
            created_at: block.timestamp
        });
        currentChildBlock = currentChildBlock.add(childBlockInterval);
        currentDepositBlock = 1;
    }

    // @dev Allows anyone to deposit funds into the Plasma chain
    // @param txBytes The format of the transaction that'll become the deposit
    function deposit()
        public
        payable
    {
        require(currentDepositBlock < childBlockInterval);
        bytes32 root = keccak256(msg.sender, msg.value);
        uint256 depositBlock = getDepositBlock();
        childChain[depositBlock] = childBlock({
            root: root,
            created_at: block.timestamp
        });
        currentDepositBlock = currentDepositBlock.add(1);
        Deposit(msg.sender, msg.value, depositBlock);
    }

    function startDepositExit(uint256 depositPos, uint256 amount)
        public
    {
        uint256 blknum = depositPos / 1000000000;
        // Makes sure that deposit position is actually a deposit
        require(blknum % childBlockInterval != 0);
        bytes32 root = childChain[blknum].root;
        bytes32 depositHash = keccak256(msg.sender, amount);
        require(root == depositHash);
        addExitToQueue(depositPos, msg.sender, amount, childChain[blknum].created_at);
    }

    function startFeeExit(uint256 amount)
        public
        isAuthority
        returns (uint256)
    {
        addExitToQueue(currentFeeExit, msg.sender, amount, block.timestamp + 1);
        currentFeeExit = currentFeeExit.add(1);
    }

    // @dev Starts to exit a specified utxo
    // @param utxoPos The position of the exiting utxo in the format of blknum * 1000000000 + index * 10000 + oindex
    // @param txBytes The transaction being exited in RLP bytes format
    // @param proof Proof of the exiting transactions inclusion for the block specified by utxoPos
    // @param sigs Both transaction signatures and confirmations signatures used to verify that the exiting transaction has been confirmed
    function startExit(uint256 utxoPos, bytes txBytes, bytes proof, bytes sigs)
        public
    {
        var txList = txBytes.toRLPItem().toList(11); 
        uint256 blknum = utxoPos / 1000000000;
        uint256 txindex = (utxoPos % 1000000000) / 10000;
        uint256 oindex = utxoPos - blknum * 1000000000 - txindex * 10000; 
        uint256 amount = txList[7 + 2 * oindex].toUint();
        address exitor = txList[6 + 2 * oindex].toAddress(); 
        
        require(msg.sender == exitor);
        bytes32 root = childChain[blknum].root; 
        bytes32 merkleHash = keccak256(keccak256(txBytes), ByteUtils.slice(sigs, 0, 130));
        require(Validate.checkSigs(keccak256(txBytes), root, txList[0].toUint(), txList[3].toUint(), sigs));
        require(merkleHash.checkMembership(txindex, root, proof));
        addExitToQueue(utxoPos, exitor, amount, childChain[blknum].created_at);
    }

    // Priority is a given utxos position in the exit priority queue
    function addExitToQueue(uint256 utxoPos, address exitor, uint256 amount, uint256 created_at)
        private
    {
        uint256 priority = Math.max(created_at, block.timestamp - 1 weeks);
        priority = priority << 128 | utxoPos;
        require(amount > 0);
        require(exits[utxoPos].amount == 0);
        exitsQueue.insert(priority);
        exits[utxoPos] = exit({
            owner: exitor,
            amount: amount
        });
        Exit(exitor, utxoPos);
    }

    // @dev Allows anyone to challenge an exiting transaction by submitting proof of a double spend on the child chain
    // @param cUtxoPos The position of the challenging utxo
    // @param eUtxoIndex The output position of the exiting utxo
    // @param txBytes The challenging transaction in bytes RLP form
    // @param proof Proof of inclusion for the transaction used to challenge
    // @param sigs Signatures for the transaction used to challenge
    // @param confirmationSig The confirmation signature for the transaction used to challenge
    function challengeExit(uint256 cUtxoPos, uint256 eUtxoIndex, bytes txBytes, bytes proof, bytes sigs, bytes confirmationSig)
        public
    {
        uint256 eUtxoPos = getUtxoPos(txBytes, eUtxoIndex);
        uint256 txindex = (cUtxoPos % 1000000000) / 10000;
        bytes32 root = childChain[cUtxoPos / 1000000000].root;
        var txHash = keccak256(txBytes);
        var confirmationHash = keccak256(txHash, root);
        var merkleHash = keccak256(txHash, sigs);
        address owner = exits[eUtxoPos].owner;

        require(owner == ECRecovery.recover(confirmationHash, confirmationSig));
        require(merkleHash.checkMembership(txindex, root, proof));
        // Clear as much as possible from succesful challenge
        delete exits[eUtxoPos].owner;
    }

    // @dev Loops through the priority queue of exits, settling the ones whose challenge
    // @dev challenge period has ended
    function finalizeExits()
        public
    {
        uint256 twoWeekOldTimestamp = block.timestamp.sub(2 weeks);
        uint256 utxoPos;
        uint256 created_at;
        (utxoPos, created_at) = getNextExit();
        exit memory currentExit = exits[utxoPos];
        while (created_at < twoWeekOldTimestamp) {
            currentExit = exits[utxoPos];
            currentExit.owner.transfer(currentExit.amount);
            exitsQueue.delMin();
            delete exits[utxoPos].owner;

            if (exitsQueue.currentSize() > 0) {
                (utxoPos, created_at) = getNextExit();
            } else {
                return;
            }
        }
    }

    /* 
     *  Constant functions
     */
    function getChildChain(uint256 blockNumber)
        public
        view
        returns (bytes32, uint256)
    {
        return (childChain[blockNumber].root, childChain[blockNumber].created_at);
    }

    function getDepositBlock()
        public
        view
        returns (uint256)
    {
        return currentChildBlock.sub(childBlockInterval).add(currentDepositBlock);
    }

    function getExit(uint256 utxoPos)
        public
        view
        returns (address, uint256)
    {
        return (exits[utxoPos].owner, exits[utxoPos].amount);
    }

    function getUtxoPos(bytes txBytes, uint256 oIndex)
        public
        returns (uint256)
    {
        var txList = txBytes.toRLPItem().toList(11);
        uint256 oIndexShift = oIndex * 3;
        return txList[0 + oIndexShift].toUint() + txList[1 + oIndexShift].toUint() + txList[2 + oIndexShift].toUint();
    }

    function getNextExit()
        public
        view
        returns (uint256, uint256)
    {
        uint256 priority = exitsQueue.getMin();
        uint256 utxoPos = uint256(uint128(priority));
        uint256 created_at = priority >> 128;
        return (utxoPos, created_at);
    }
}
